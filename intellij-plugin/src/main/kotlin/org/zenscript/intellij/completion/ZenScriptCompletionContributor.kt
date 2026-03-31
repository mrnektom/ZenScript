package org.zenscript.intellij.completion

import com.intellij.codeInsight.completion.*
import com.intellij.codeInsight.lookup.LookupElementBuilder
import com.intellij.lang.ASTNode
import com.intellij.patterns.PlatformPatterns
import com.intellij.psi.PsiElement
import com.intellij.psi.TokenType
import com.intellij.psi.util.PsiTreeUtil
import com.intellij.util.ProcessingContext
import com.intellij.icons.AllIcons
import org.zenscript.intellij.ZenScriptFile
import org.zenscript.intellij.ZenScriptLanguage
import org.zenscript.intellij.psi.*
import org.zenscript.intellij.reference.ZenScriptResolveUtil

class ZenScriptCompletionContributor : CompletionContributor() {
    init {
        // 4a. Identifier completion in expressions
        extend(
            CompletionType.BASIC,
            PlatformPatterns.psiElement()
                .withLanguage(ZenScriptLanguage),
            IdentifierCompletionProvider()
        )
    }

    private class IdentifierCompletionProvider : CompletionProvider<CompletionParameters>() {
        companion object {
            private val KEYWORDS = listOf(
                "let", "const", "fn", "if", "else", "while", "for", "return",
                "enum", "struct", "import", "use", "export", "break", "continue",
                "match", "true", "false", "external", "pub"
            )
            private val BUILTIN_TYPES = listOf("number", "string", "bool", "void", "char")
        }

        override fun addCompletions(
            parameters: CompletionParameters,
            context: ProcessingContext,
            result: CompletionResultSet
        ) {
            val position = parameters.position
            val parent = position.parent

            when {
                // 4c. Dot-access completion (member access)
                parent is ZenScriptReferenceExpression && isDotAccess(parent) -> {
                    addDotCompletions(parent, result)
                }
                // Struct literal field completion
                parent is ZenScriptReferenceExpression && isStructLiteralContext(parent) -> {
                    addStructLiteralFieldCompletions(parent, result)
                }
                // 4b. Type annotation completion
                parent is ZenScriptTypeReferenceElement -> {
                    addTypeCompletions(position, result)
                }
                // 4e. Use statement variant completion
                parent is ZenScriptImportSymbol && parent.parent is ZenScriptUseStatement -> {
                    addUseVariantCompletions(parent.parent as ZenScriptUseStatement, result)
                }
                // 4f. Import path completion
                parent is ZenScriptImportPath -> {
                    addImportPathCompletions(parent, result)
                }
                // 4a. General identifier completion + 4d. Keywords
                parent is ZenScriptReferenceExpression -> {
                    addIdentifierCompletions(position, result)
                    addKeywordCompletions(result)
                }
                // Top-level keyword completion (when typing outside any expression)
                parent is ZenScriptFile || isTopLevelContext(position) -> {
                    addKeywordCompletions(result)
                }
            }
        }

        private fun skipWhitespacePrev(node: ASTNode?): ASTNode? {
            var current = node
            while (current != null && (current.elementType == TokenType.WHITE_SPACE ||
                        current.elementType == ZenScriptTokenTypes.WHITE_SPACE)) {
                current = current.treePrev
            }
            return current
        }

        private fun isDotAccess(refExpr: ZenScriptReferenceExpression): Boolean {
            val prevNode = skipWhitespacePrev(refExpr.node.treePrev)
            return prevNode != null && prevNode.elementType == ZenScriptTokenTypes.DOT
        }

        private fun isTopLevelContext(position: PsiElement): Boolean {
            var current = position.parent
            while (current != null) {
                if (current is ZenScriptFile) return true
                if (current is ZenScriptNamedElement) return false
                current = current.parent
            }
            return false
        }

        // 4a. Identifier completions
        private fun addIdentifierCompletions(position: PsiElement, result: CompletionResultSet) {
            val variants = ZenScriptResolveUtil.collectVariantElements(position)
            for (element in variants) {
                val name = element.name ?: continue
                val lookup = when (element) {
                    is ZenScriptFnDeclaration -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Function)
                        .withTailText("()", true)
                    is ZenScriptVarDeclaration -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Variable)
                    is ZenScriptStructDeclaration -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Class)
                    is ZenScriptEnumDeclaration -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Enum)
                    is ZenScriptEnumVariant -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Field)
                    is ZenScriptParameter -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Parameter)
                    is ZenScriptImportSymbol -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Include)
                    else -> LookupElementBuilder.create(name)
                }
                result.addElement(lookup)
            }
        }

        // 4b. Type completions
        private fun addTypeCompletions(position: PsiElement, result: CompletionResultSet) {
            // Add builtin types
            for (typeName in BUILTIN_TYPES) {
                result.addElement(
                    LookupElementBuilder.create(typeName).bold()
                )
            }
            // Add user-defined types (structs and enums)
            val variants = ZenScriptResolveUtil.collectVariantElements(position)
            for (element in variants) {
                val name = element.name ?: continue
                val lookup = when (element) {
                    is ZenScriptStructDeclaration -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Class)
                    is ZenScriptEnumDeclaration -> LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Enum)
                    else -> continue
                }
                result.addElement(lookup)
            }
        }

        private fun isStructLiteralContext(refExpr: ZenScriptReferenceExpression): Boolean {
            if (findStructDeclForLiteral(refExpr) == null) return false
            // If the previous non-whitespace token is COLON, we're in value position (e.g. `x: <caret>`)
            var prev: PsiElement? = refExpr.prevSibling
            while (prev != null && prev.node.elementType == TokenType.WHITE_SPACE) {
                prev = prev.prevSibling
            }
            if (prev?.node?.elementType == ZenScriptTokenTypes.COLON) return false
            return true
        }

        private fun findStructDeclForLiteral(refExpr: ZenScriptReferenceExpression): ZenScriptStructDeclaration? {
            // Walk backwards to find the opening LBRACE
            var prev: PsiElement? = refExpr.prevSibling
            while (prev != null && prev.node.elementType != ZenScriptTokenTypes.LBRACE) {
                prev = prev.prevSibling
            }
            if (prev == null) return null

            // The REFERENCE_EXPRESSION before the LBRACE is the struct name
            var structNameRef: PsiElement? = prev.prevSibling
            while (structNameRef != null && structNameRef.node.elementType == TokenType.WHITE_SPACE) {
                structNameRef = structNameRef.prevSibling
            }
            if (structNameRef !is ZenScriptReferenceExpression) return null

            val resolved = structNameRef.reference.resolve()
            return resolved as? ZenScriptStructDeclaration
        }

        private fun addStructLiteralFieldCompletions(refExpr: ZenScriptReferenceExpression, result: CompletionResultSet) {
            val structDecl = findStructDeclForLiteral(refExpr) ?: return
            for (field in ZenScriptResolveUtil.collectStructFields(structDecl)) {
                val name = field.name ?: continue
                result.addElement(
                    LookupElementBuilder.create(name)
                        .withIcon(AllIcons.Nodes.Field)
                        .withTailText(": ", true)
                        .withInsertHandler { context, _ ->
                            val offset = context.tailOffset
                            context.document.insertString(offset, ": ")
                            context.editor.caretModel.moveToOffset(offset + 2)
                        }
                )
            }
            result.stopHere()
        }

        // 4c. Dot-access completions (member access)
        private fun addDotCompletions(refExpr: ZenScriptReferenceExpression, result: CompletionResultSet) {
            // Find the expression before the dot, skipping whitespace
            val dot = skipWhitespacePrev(refExpr.node.treePrev) ?: return
            if (dot.elementType != ZenScriptTokenTypes.DOT) return
            val beforeDot = skipWhitespacePrev(dot.treePrev) ?: return
            val beforeDotPsi = beforeDot.psi

            val resolved = when (beforeDotPsi) {
                is ZenScriptReferenceExpression -> beforeDotPsi.reference.resolve()
                else -> null
            }

            when (resolved) {
                is ZenScriptEnumDeclaration -> {
                    for (variant in ZenScriptResolveUtil.collectEnumVariants(resolved)) {
                        val name = variant.name ?: continue
                        result.addElement(
                            LookupElementBuilder.create(name)
                                .withIcon(AllIcons.Nodes.Field)
                        )
                    }
                }
                is ZenScriptStructDeclaration -> {
                    for (field in ZenScriptResolveUtil.collectStructFields(resolved)) {
                        val name = field.name ?: continue
                        result.addElement(
                            LookupElementBuilder.create(name)
                                .withIcon(AllIcons.Nodes.Field)
                        )
                    }
                }
                is ZenScriptVarDeclaration, is ZenScriptParameter -> {
                    // Resolve the type via the type reference's own reference
                    val typeRef = PsiTreeUtil.findChildOfType(resolved, ZenScriptTypeReferenceElement::class.java)
                    val typeDecl = typeRef?.reference?.resolve()
                    if (typeDecl is ZenScriptStructDeclaration) {
                        for (field in ZenScriptResolveUtil.collectStructFields(typeDecl)) {
                            val name = field.name ?: continue
                            result.addElement(
                                LookupElementBuilder.create(name)
                                    .withIcon(AllIcons.Nodes.Field)
                            )
                        }
                    }
                }
            }
        }

        // 4d. Keyword completions
        private fun addKeywordCompletions(result: CompletionResultSet) {
            for (keyword in KEYWORDS) {
                result.addElement(
                    LookupElementBuilder.create(keyword).bold()
                )
            }
        }

        // 4e. Use statement variant completions
        private fun addUseVariantCompletions(useStmt: ZenScriptUseStatement, result: CompletionResultSet) {
            val enumName = useStmt.getEnumName() ?: return
            val enumDecl = ZenScriptResolveUtil.resolveInScope(useStmt, enumName)
            if (enumDecl is ZenScriptEnumDeclaration) {
                for (variant in ZenScriptResolveUtil.collectEnumVariants(enumDecl)) {
                    val name = variant.name ?: continue
                    result.addElement(
                        LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Field)
                    )
                }
            }
        }

        // 4f. Import path completions
        private fun addImportPathCompletions(importPath: ZenScriptImportPath, result: CompletionResultSet) {
            val containingFile = importPath.containingFile?.virtualFile ?: return
            val dir = containingFile.parent ?: return
            for (child in dir.children) {
                if (child.extension == "zs" && child != containingFile) {
                    result.addElement(
                        LookupElementBuilder.create("./${child.name}")
                            .withIcon(AllIcons.FileTypes.Any_type)
                    )
                }
            }
        }
    }
}
