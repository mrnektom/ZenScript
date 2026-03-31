package org.zenscript.intellij.lexer

import com.intellij.lexer.LexerBase
import com.intellij.psi.tree.IElementType
import org.zenscript.intellij.psi.ZenScriptTokenTypes

class ZenScriptLexer : LexerBase() {
    private var buffer: CharSequence = ""
    private var startOffset = 0
    private var endOffset = 0
    private var tokenStart = 0
    private var tokenEnd = 0
    private var tokenType: IElementType? = null

    override fun start(buffer: CharSequence, startOffset: Int, endOffset: Int, initialState: Int) {
        this.buffer = buffer
        this.startOffset = startOffset
        this.endOffset = endOffset
        this.tokenStart = startOffset
        this.tokenEnd = startOffset
        advance()
    }

    override fun getState(): Int = 0
    override fun getTokenType(): IElementType? = tokenType
    override fun getTokenStart(): Int = tokenStart
    override fun getTokenEnd(): Int = tokenEnd
    override fun getBufferSequence(): CharSequence = buffer
    override fun getBufferEnd(): Int = endOffset

    override fun advance() {
        tokenStart = tokenEnd
        if (tokenStart >= endOffset) {
            tokenType = null
            return
        }

        val c = buffer[tokenStart]

        when {
            c.isWhitespace() -> lexWhitespace()
            c == '/' && peek(1) == '/' -> lexLineComment()
            c == '"' -> lexString()
            c == '\'' -> lexChar()
            c.isDigit() -> lexNumber()
            c.isLetter() || c == '_' -> lexIdentifierOrKeyword()
            else -> lexOperatorOrPunctuation()
        }
    }

    private fun peek(offset: Int): Char? {
        val pos = tokenStart + offset
        return if (pos < endOffset) buffer[pos] else null
    }

    private fun lexWhitespace() {
        var pos = tokenStart
        while (pos < endOffset && buffer[pos].isWhitespace()) pos++
        tokenEnd = pos
        tokenType = ZenScriptTokenTypes.WHITE_SPACE
    }

    private fun lexLineComment() {
        var pos = tokenStart + 2
        while (pos < endOffset && buffer[pos] != '\n') pos++
        tokenEnd = pos
        tokenType = ZenScriptTokenTypes.LINE_COMMENT
    }

    private fun lexString() {
        var pos = tokenStart + 1
        while (pos < endOffset) {
            val ch = buffer[pos]
            if (ch == '\n') break // unclosed string — stop at newline
            if (ch == '\\' && pos + 1 < endOffset) {
                pos += 2
                continue
            }
            if (ch == '"') {
                pos++
                break
            }
            pos++
        }
        tokenEnd = pos
        tokenType = ZenScriptTokenTypes.STRING_LITERAL
    }

    private fun lexChar() {
        var pos = tokenStart + 1
        while (pos < endOffset) {
            val ch = buffer[pos]
            if (ch == '\n') break // unclosed char — stop at newline
            if (ch == '\\' && pos + 1 < endOffset) {
                pos += 2
                continue
            }
            if (ch == '\'') {
                pos++
                break
            }
            pos++
        }
        tokenEnd = pos
        tokenType = ZenScriptTokenTypes.CHAR_LITERAL
    }

    private fun lexNumber() {
        var pos = tokenStart
        while (pos < endOffset && buffer[pos].isDigit()) pos++
        if (pos < endOffset && buffer[pos] == '.' && pos + 1 < endOffset && buffer[pos + 1].isDigit()) {
            pos++
            while (pos < endOffset && buffer[pos].isDigit()) pos++
        }
        tokenEnd = pos
        tokenType = ZenScriptTokenTypes.NUMBER_LITERAL
    }

    private fun lexIdentifierOrKeyword() {
        var pos = tokenStart
        while (pos < endOffset && (buffer[pos].isLetterOrDigit() || buffer[pos] == '_')) pos++
        tokenEnd = pos
        val word = buffer.subSequence(tokenStart, tokenEnd).toString()
        tokenType = ZenScriptTokenTypes.KEYWORD_MAP[word] ?: ZenScriptTokenTypes.IDENTIFIER
    }

    private fun lexOperatorOrPunctuation() {
        val c = buffer[tokenStart]
        val next = peek(1)

        when (c) {
            '+' -> single(ZenScriptTokenTypes.PLUS)
            '*' -> single(ZenScriptTokenTypes.STAR)
            '%' -> single(ZenScriptTokenTypes.PERCENT)
            '.' -> single(ZenScriptTokenTypes.DOT)
            ',' -> single(ZenScriptTokenTypes.COMMA)
            ':' -> single(ZenScriptTokenTypes.COLON)
            ';' -> single(ZenScriptTokenTypes.SEMICOLON)
            '(' -> single(ZenScriptTokenTypes.LPAREN)
            ')' -> single(ZenScriptTokenTypes.RPAREN)
            '{' -> single(ZenScriptTokenTypes.LBRACE)
            '}' -> single(ZenScriptTokenTypes.RBRACE)
            '[' -> single(ZenScriptTokenTypes.LBRACKET)
            ']' -> single(ZenScriptTokenTypes.RBRACKET)
            '-' -> if (next == '>') double(ZenScriptTokenTypes.ARROW) else single(ZenScriptTokenTypes.MINUS)
            '=' -> if (next == '=') double(ZenScriptTokenTypes.EQ_EQ) else single(ZenScriptTokenTypes.EQ)
            '!' -> if (next == '=') double(ZenScriptTokenTypes.BANG_EQ) else single(ZenScriptTokenTypes.BANG)
            '<' -> if (next == '=') double(ZenScriptTokenTypes.LT_EQ) else single(ZenScriptTokenTypes.LT)
            '>' -> if (next == '=') double(ZenScriptTokenTypes.GT_EQ) else single(ZenScriptTokenTypes.GT)
            '&' -> if (next == '&') double(ZenScriptTokenTypes.AND_AND) else single(ZenScriptTokenTypes.BAD_CHARACTER)
            '|' -> if (next == '|') double(ZenScriptTokenTypes.OR_OR) else single(ZenScriptTokenTypes.BAD_CHARACTER)
            '/' -> single(ZenScriptTokenTypes.SLASH)
            else -> single(ZenScriptTokenTypes.BAD_CHARACTER)
        }
    }

    private fun single(type: IElementType) {
        tokenEnd = tokenStart + 1
        tokenType = type
    }

    private fun double(type: IElementType) {
        tokenEnd = tokenStart + 2
        tokenType = type
    }
}
