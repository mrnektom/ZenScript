package org.zenscript.intellij.parser

import com.intellij.extapi.psi.ASTWrapperPsiElement
import com.intellij.lang.ASTNode
import com.intellij.lang.ParserDefinition
import com.intellij.lang.PsiParser
import com.intellij.lexer.Lexer
import com.intellij.openapi.project.Project
import com.intellij.psi.FileViewProvider
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.tree.IFileElementType
import com.intellij.psi.tree.TokenSet
import org.zenscript.intellij.ZenScriptFile
import org.zenscript.intellij.ZenScriptLanguage
import org.zenscript.intellij.lexer.ZenScriptLexer
import org.zenscript.intellij.psi.*

class ZenScriptParserDefinition : ParserDefinition {
    companion object {
        val FILE = IFileElementType(ZenScriptLanguage)
    }

    override fun createLexer(project: Project?): Lexer = ZenScriptLexer()
    override fun createParser(project: Project?): PsiParser = ZenScriptParser()
    override fun getFileNodeType(): IFileElementType = FILE
    override fun getCommentTokens(): TokenSet = ZenScriptTokenSets.COMMENTS
    override fun getStringLiteralElements(): TokenSet = ZenScriptTokenSets.STRINGS
    override fun getWhitespaceTokens(): TokenSet = ZenScriptTokenSets.WHITE_SPACES

    override fun createElement(node: ASTNode): PsiElement = when (node.elementType) {
        ZenScriptElementTypes.VAR_DECLARATION -> ZenScriptVarDeclaration(node)
        ZenScriptElementTypes.FN_DECLARATION -> ZenScriptFnDeclaration(node)
        ZenScriptElementTypes.STRUCT_DECLARATION -> ZenScriptStructDeclaration(node)
        ZenScriptElementTypes.ENUM_DECLARATION -> ZenScriptEnumDeclaration(node)
        ZenScriptElementTypes.ENUM_VARIANT -> ZenScriptEnumVariant(node)
        ZenScriptElementTypes.STRUCT_FIELD -> ZenScriptStructField(node)
        ZenScriptElementTypes.PARAMETER -> ZenScriptParameter(node)
        ZenScriptElementTypes.REFERENCE_EXPRESSION -> ZenScriptReferenceExpression(node)
        ZenScriptElementTypes.TYPE_REFERENCE -> ZenScriptTypeReferenceElement(node)
        ZenScriptElementTypes.IMPORT_STATEMENT -> ZenScriptImportStatement(node)
        ZenScriptElementTypes.EXPORT_FROM_STATEMENT -> ZenScriptExportFromStatement(node)
        ZenScriptElementTypes.USE_STATEMENT -> ZenScriptUseStatement(node)
        ZenScriptElementTypes.IMPORT_SYMBOL -> ZenScriptImportSymbol(node)
        ZenScriptElementTypes.IMPORT_PATH -> ZenScriptImportPath(node)
        ZenScriptElementTypes.RETURN_STATEMENT -> ZenScriptReturnStatement(node)
        else -> ASTWrapperPsiElement(node)
    }

    override fun createFile(viewProvider: FileViewProvider): PsiFile = ZenScriptFile(viewProvider)
}
