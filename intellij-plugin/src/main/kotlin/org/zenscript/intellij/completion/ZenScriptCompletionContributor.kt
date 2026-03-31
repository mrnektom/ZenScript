package org.zenscript.intellij.completion

import com.intellij.codeInsight.completion.*
import com.intellij.codeInsight.lookup.LookupElementBuilder
import com.intellij.lang.ASTNode
import com.intellij.openapi.command.WriteCommandAction
import com.intellij.openapi.diagnostic.Logger
import com.intellij.patterns.PlatformPatterns
import com.intellij.psi.PsiDocumentManager
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
            private val LOG = Logger.getInstance(IdentifierCompletionProvider::class.java)
            private val KEYWORDS = listOf(
                "let", "const", "fn", "if", "else", "while", "for", "return",
                "enum", "struct", "import", "use", "export", "break", "continue",
                "match", "true", "false", "external", "pub"
            )
            private val BUILTIN_TYPES = listOf("number", "string", "boolean", "void", "char", "long", "short", "byte")
        }

        override fun addCompletions(
            parameters: CompletionParameters,
            context: ProcessingContext,
            result: CompletionResultSet
        ) {
            val position = parameters.position
            val parent = position.parent
            val originalFile = parameters.originalFile as? ZenScriptFile
            LOG.warn("ZenScript completion: position=${position::class.simpleName}, parent=${parent::class.simpleName}(${parent.node.elementType})")

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
                    if (originalFile != null) addProjectSymbolCompletions(originalFile, result, typesOnly = true)
                }
                // Import symbol completion: import { <caret> } from "./file.zs"
                parent is ZenScriptImportSymbol && parent.parent is ZenScriptImportStatement -> {
                    addImportSymbolCompletions(parent.parent as ZenScriptImportStatement, originalFile, result)
                }
                // 4e. Use statement variant completion
                parent is ZenScriptImportSymbol && parent.parent is ZenScriptUseStatement -> {
                    addUseVariantCompletions(parent.parent as ZenScriptUseStatement, result)
                }
                // 4f. Import path completion
                parent is ZenScriptImportPath -> {
                    addImportPathCompletions(parent, originalFile, result)
                }
                // 4a. General identifier completion + 4d. Keywords
                parent is ZenScriptReferenceExpression -> {
                    addIdentifierCompletions(position, result)
                    if (originalFile != null) addProjectSymbolCompletions(originalFile, result)
                    addKeywordCompletions(result)
                }
                // Top-level keyword completion (when typing outside any expression)
                parent is ZenScriptFile || isTopLevelContext(position) -> {
                    addKeywordCompletions(result)
                    if (originalFile != null) addProjectSymbolCompletions(originalFile, result)
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

        // 4g. Project-wide symbol completions with auto-import
        private fun addProjectSymbolCompletions(
            file: ZenScriptFile,
            result: CompletionResultSet,
            typesOnly: Boolean = false
        ) {
            val inScope = ZenScriptResolveUtil.collectVariantElements(file)
                .mapNotNullTo(HashSet()) { it.name }

            val projectSymbols = ZenScriptResolveUtil.collectProjectExportedSymbols(file, inScope)
            LOG.warn("ZenScript project completion: projectSymbols count = ${projectSymbols.size}")

            for ((element, path) in projectSymbols) {
                if (typesOnly && element !is ZenScriptStructDeclaration && element !is ZenScriptEnumDeclaration) continue
                val name = element.name ?: continue
                val fileName = path.substringAfterLast("/")
                val lookup = when (element) {
                    is ZenScriptFnDeclaration ->
                        LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Function)
                            .withTailText("()  $fileName", true)
                    is ZenScriptStructDeclaration ->
                        LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Class)
                            .withTailText("  $fileName", true)
                    is ZenScriptEnumDeclaration ->
                        LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Enum)
                            .withTailText("  $fileName", true)
                    is ZenScriptVarDeclaration ->
                        LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Variable)
                            .withTailText("  $fileName", true)
                    else -> LookupElementBuilder.create(name).withTailText("  $fileName", true)
                }.withInsertHandler { context, _ ->
                    addImportIfMissing(
                        context.file as? ZenScriptFile ?: return@withInsertHandler,
                        name, path
                    )
                }
                result.addElement(lookup)
            }
        }

        private fun addImportIfMissing(file: ZenScriptFile, symbolName: String, path: String) {
            // Skip if already imported
            for (child in file.children) {
                if (child is ZenScriptImportStatement) {
                    val stmtPath = child.getPath() ?: continue
                    if (stmtPath == path) {
                        for (sym in child.getImportSymbols()) {
                            if (sym.getOriginalName() == symbolName) return
                        }
                    }
                }
            }

            // Find insertion point: after the last import statement, or at top
            var insertOffset = 0
            var hasImports = false
            for (child in file.children) {
                if (child is ZenScriptImportStatement) {
                    insertOffset = child.textRange.endOffset
                    hasImports = true
                }
            }

            val importLine = "import { $symbolName } from \"$path\""
            val project = file.project
            WriteCommandAction.runWriteCommandAction(project, "Add import", null, Runnable {
                val document = PsiDocumentManager.getInstance(project).getDocument(file)
                if (document != null) {
                    if (!hasImports) {
                        document.insertString(0, "$importLine\n")
                    } else {
                        document.insertString(insertOffset, "\n$importLine")
                    }
                    PsiDocumentManager.getInstance(project).commitDocument(document)
                }
            }, file)
        }

        // 4d. Keyword completions
        private fun addKeywordCompletions(result: CompletionResultSet) {
            for (keyword in KEYWORDS) {
                result.addElement(
                    LookupElementBuilder.create(keyword).bold()
                )
            }
        }

        // Import symbol completions: symbols exported from the target file
        private fun addImportSymbolCompletions(
            importStmt: ZenScriptImportStatement,
            contextFile: ZenScriptFile?,
            result: CompletionResultSet
        ) {
            val path = importStmt.getPath() ?: return
            // Use originalFile as context so resolveImportPath can find the directory via virtualFile
            val context: PsiElement = contextFile ?: importStmt
            val targetFile = ZenScriptResolveUtil.resolveImportPath(context, path) ?: return
            val alreadyImported = importStmt.getImportSymbols().mapNotNullTo(HashSet()) { it.getOriginalName() }
            for (child in targetFile.children) {
                if (child is ZenScriptNamedElement) {
                    val name = child.name ?: continue
                    if (name in alreadyImported) continue
                    val lookup = when (child) {
                        is ZenScriptFnDeclaration -> LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Function).withTailText("()", true)
                        is ZenScriptStructDeclaration -> LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Class)
                        is ZenScriptEnumDeclaration -> LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Enum)
                        is ZenScriptVarDeclaration -> LookupElementBuilder.create(name)
                            .withIcon(AllIcons.Nodes.Variable)
                        else -> LookupElementBuilder.create(name)
                    }
                    result.addElement(lookup)
                }
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
        private fun addImportPathCompletions(
            importPath: ZenScriptImportPath,
            originalFile: ZenScriptFile?,
            result: CompletionResultSet
        ) {
            val currentVFile = originalFile?.virtualFile ?: return
            val zsFiles = ZenScriptResolveUtil.collectProjectZsFiles(currentVFile, importPath.project)
            for ((_, relativePath) in zsFiles) {
                result.addElement(
                    LookupElementBuilder.create(relativePath)
                        .withIcon(AllIcons.FileTypes.Any_type)
                        .withInsertHandler { ctx, _ ->
                            // Replace the entire content between the quotes
                            val docText = ctx.document.charsSequence
                            var openQuote = ctx.startOffset - 1
                            while (openQuote >= 0 && docText[openQuote] != '"') openQuote--
                            var closeQuote = ctx.tailOffset
                            while (closeQuote < docText.length && docText[closeQuote] != '"') closeQuote++
                            if (openQuote >= 0 && closeQuote < docText.length) {
                                ctx.document.replaceString(openQuote + 1, closeQuote, relativePath)
                                ctx.editor.caretModel.moveToOffset(openQuote + 1 + relativePath.length)
                            }
                        }
                )
            }
        }
    }
}
