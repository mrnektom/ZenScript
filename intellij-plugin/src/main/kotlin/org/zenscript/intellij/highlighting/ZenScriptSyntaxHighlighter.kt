package org.zenscript.intellij.highlighting

import com.intellij.lexer.Lexer
import com.intellij.openapi.editor.DefaultLanguageHighlighterColors
import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.openapi.editor.colors.TextAttributesKey.createTextAttributesKey
import com.intellij.openapi.fileTypes.SyntaxHighlighterBase
import com.intellij.psi.tree.IElementType
import org.zenscript.intellij.lexer.ZenScriptLexer
import org.zenscript.intellij.psi.ZenScriptTokenSets
import org.zenscript.intellij.psi.ZenScriptTokenTypes

class ZenScriptSyntaxHighlighter : SyntaxHighlighterBase() {
    companion object {
        val KEYWORD = createTextAttributesKey("ZENSCRIPT_KEYWORD", DefaultLanguageHighlighterColors.KEYWORD)
        val NUMBER = createTextAttributesKey("ZENSCRIPT_NUMBER", DefaultLanguageHighlighterColors.NUMBER)
        val STRING = createTextAttributesKey("ZENSCRIPT_STRING", DefaultLanguageHighlighterColors.STRING)
        val LINE_COMMENT = createTextAttributesKey("ZENSCRIPT_LINE_COMMENT", DefaultLanguageHighlighterColors.LINE_COMMENT)
        val OPERATION_SIGN = createTextAttributesKey("ZENSCRIPT_OPERATION_SIGN", DefaultLanguageHighlighterColors.OPERATION_SIGN)
        val PARENTHESES = createTextAttributesKey("ZENSCRIPT_PARENTHESES", DefaultLanguageHighlighterColors.PARENTHESES)
        val BRACES = createTextAttributesKey("ZENSCRIPT_BRACES", DefaultLanguageHighlighterColors.BRACES)
        val BRACKETS = createTextAttributesKey("ZENSCRIPT_BRACKETS", DefaultLanguageHighlighterColors.BRACKETS)
        val COMMA = createTextAttributesKey("ZENSCRIPT_COMMA", DefaultLanguageHighlighterColors.COMMA)
        val SEMICOLON = createTextAttributesKey("ZENSCRIPT_SEMICOLON", DefaultLanguageHighlighterColors.SEMICOLON)
        val IDENTIFIER = createTextAttributesKey("ZENSCRIPT_IDENTIFIER", DefaultLanguageHighlighterColors.IDENTIFIER)
        val FUNCTION_NAME = createTextAttributesKey("ZENSCRIPT_FUNCTION_NAME", DefaultLanguageHighlighterColors.FUNCTION_DECLARATION)
        val FUNCTION_CALL = createTextAttributesKey("ZENSCRIPT_FUNCTION_CALL", DefaultLanguageHighlighterColors.FUNCTION_CALL)
        val FIELD_NAME = createTextAttributesKey("ZENSCRIPT_FIELD_NAME", DefaultLanguageHighlighterColors.INSTANCE_FIELD)
        val BAD_CHARACTER = createTextAttributesKey("ZENSCRIPT_BAD_CHARACTER", DefaultLanguageHighlighterColors.INVALID_STRING_ESCAPE)

        private val KEYWORD_KEYS = arrayOf(KEYWORD)
        private val NUMBER_KEYS = arrayOf(NUMBER)
        private val STRING_KEYS = arrayOf(STRING)
        private val COMMENT_KEYS = arrayOf(LINE_COMMENT)
        private val OPERATOR_KEYS = arrayOf(OPERATION_SIGN)
        private val PAREN_KEYS = arrayOf(PARENTHESES)
        private val BRACE_KEYS = arrayOf(BRACES)
        private val BRACKET_KEYS = arrayOf(BRACKETS)
        private val COMMA_KEYS = arrayOf(COMMA)
        private val SEMICOLON_KEYS = arrayOf(SEMICOLON)
        private val IDENTIFIER_KEYS = arrayOf(IDENTIFIER)
        private val BAD_CHAR_KEYS = arrayOf(BAD_CHARACTER)
        private val EMPTY_KEYS = emptyArray<TextAttributesKey>()
    }

    override fun getHighlightingLexer(): Lexer = ZenScriptLexer()

    override fun getTokenHighlights(tokenType: IElementType): Array<TextAttributesKey> = when {
        ZenScriptTokenSets.KEYWORDS.contains(tokenType) -> KEYWORD_KEYS
        ZenScriptTokenSets.OPERATORS.contains(tokenType) -> OPERATOR_KEYS
        tokenType == ZenScriptTokenTypes.NUMBER_LITERAL -> NUMBER_KEYS
        tokenType == ZenScriptTokenTypes.STRING_LITERAL || tokenType == ZenScriptTokenTypes.CHAR_LITERAL -> STRING_KEYS
        tokenType == ZenScriptTokenTypes.LINE_COMMENT -> COMMENT_KEYS
        tokenType == ZenScriptTokenTypes.LPAREN || tokenType == ZenScriptTokenTypes.RPAREN -> PAREN_KEYS
        tokenType == ZenScriptTokenTypes.LBRACE || tokenType == ZenScriptTokenTypes.RBRACE -> BRACE_KEYS
        tokenType == ZenScriptTokenTypes.LBRACKET || tokenType == ZenScriptTokenTypes.RBRACKET -> BRACKET_KEYS
        tokenType == ZenScriptTokenTypes.COMMA -> COMMA_KEYS
        tokenType == ZenScriptTokenTypes.SEMICOLON -> SEMICOLON_KEYS
        tokenType == ZenScriptTokenTypes.IDENTIFIER -> IDENTIFIER_KEYS
        tokenType == ZenScriptTokenTypes.BAD_CHARACTER -> BAD_CHAR_KEYS
        else -> EMPTY_KEYS
    }
}
