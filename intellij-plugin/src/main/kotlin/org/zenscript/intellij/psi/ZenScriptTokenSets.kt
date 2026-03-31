package org.zenscript.intellij.psi

import com.intellij.psi.tree.TokenSet

object ZenScriptTokenSets {
    @JvmField val KEYWORDS = TokenSet.create(
        ZenScriptTokenTypes.LET, ZenScriptTokenTypes.CONST, ZenScriptTokenTypes.FN,
        ZenScriptTokenTypes.IF, ZenScriptTokenTypes.ELSE, ZenScriptTokenTypes.WHILE,
        ZenScriptTokenTypes.FOR, ZenScriptTokenTypes.BREAK, ZenScriptTokenTypes.CONTINUE,
        ZenScriptTokenTypes.RETURN, ZenScriptTokenTypes.MATCH, ZenScriptTokenTypes.STRUCT,
        ZenScriptTokenTypes.ENUM, ZenScriptTokenTypes.EXTERNAL, ZenScriptTokenTypes.IMPORT,
        ZenScriptTokenTypes.EXPORT, ZenScriptTokenTypes.FROM, ZenScriptTokenTypes.AS,
        ZenScriptTokenTypes.USE, ZenScriptTokenTypes.TRUE, ZenScriptTokenTypes.FALSE,
        ZenScriptTokenTypes.CHAR_KW, ZenScriptTokenTypes.PUB
    )

    @JvmField val OPERATORS = TokenSet.create(
        ZenScriptTokenTypes.PLUS, ZenScriptTokenTypes.MINUS, ZenScriptTokenTypes.STAR,
        ZenScriptTokenTypes.SLASH, ZenScriptTokenTypes.PERCENT,
        ZenScriptTokenTypes.EQ_EQ, ZenScriptTokenTypes.BANG_EQ,
        ZenScriptTokenTypes.LT_EQ, ZenScriptTokenTypes.GT_EQ,
        ZenScriptTokenTypes.LT, ZenScriptTokenTypes.GT,
        ZenScriptTokenTypes.EQ, ZenScriptTokenTypes.AND_AND, ZenScriptTokenTypes.OR_OR,
        ZenScriptTokenTypes.BANG, ZenScriptTokenTypes.ARROW, ZenScriptTokenTypes.DOT
    )

    @JvmField val STRINGS = TokenSet.create(ZenScriptTokenTypes.STRING_LITERAL)
    @JvmField val COMMENTS = TokenSet.create(ZenScriptTokenTypes.LINE_COMMENT)
    @JvmField val WHITE_SPACES = TokenSet.create(ZenScriptTokenTypes.WHITE_SPACE)
}

object ZenScriptTokenTypes {
    // Keywords
    @JvmField val LET = ZenScriptTokenType("LET")
    @JvmField val CONST = ZenScriptTokenType("CONST")
    @JvmField val FN = ZenScriptTokenType("FN")
    @JvmField val IF = ZenScriptTokenType("IF")
    @JvmField val ELSE = ZenScriptTokenType("ELSE")
    @JvmField val WHILE = ZenScriptTokenType("WHILE")
    @JvmField val FOR = ZenScriptTokenType("FOR")
    @JvmField val BREAK = ZenScriptTokenType("BREAK")
    @JvmField val CONTINUE = ZenScriptTokenType("CONTINUE")
    @JvmField val RETURN = ZenScriptTokenType("RETURN")
    @JvmField val MATCH = ZenScriptTokenType("MATCH")
    @JvmField val STRUCT = ZenScriptTokenType("STRUCT")
    @JvmField val ENUM = ZenScriptTokenType("ENUM")
    @JvmField val EXTERNAL = ZenScriptTokenType("EXTERNAL")
    @JvmField val IMPORT = ZenScriptTokenType("IMPORT")
    @JvmField val EXPORT = ZenScriptTokenType("EXPORT")
    @JvmField val FROM = ZenScriptTokenType("FROM")
    @JvmField val AS = ZenScriptTokenType("AS")
    @JvmField val USE = ZenScriptTokenType("USE")
    @JvmField val TRUE = ZenScriptTokenType("TRUE")
    @JvmField val FALSE = ZenScriptTokenType("FALSE")
    @JvmField val CHAR_KW = ZenScriptTokenType("CHAR_KW")
    @JvmField val PUB = ZenScriptTokenType("PUB")

    // Literals
    @JvmField val NUMBER_LITERAL = ZenScriptTokenType("NUMBER_LITERAL")
    @JvmField val STRING_LITERAL = ZenScriptTokenType("STRING_LITERAL")
    @JvmField val CHAR_LITERAL = ZenScriptTokenType("CHAR_LITERAL")
    @JvmField val IDENTIFIER = ZenScriptTokenType("IDENTIFIER")

    // Operators
    @JvmField val PLUS = ZenScriptTokenType("PLUS")
    @JvmField val MINUS = ZenScriptTokenType("MINUS")
    @JvmField val STAR = ZenScriptTokenType("STAR")
    @JvmField val SLASH = ZenScriptTokenType("SLASH")
    @JvmField val PERCENT = ZenScriptTokenType("PERCENT")
    @JvmField val EQ = ZenScriptTokenType("EQ")
    @JvmField val EQ_EQ = ZenScriptTokenType("EQ_EQ")
    @JvmField val BANG = ZenScriptTokenType("BANG")
    @JvmField val BANG_EQ = ZenScriptTokenType("BANG_EQ")
    @JvmField val LT = ZenScriptTokenType("LT")
    @JvmField val GT = ZenScriptTokenType("GT")
    @JvmField val LT_EQ = ZenScriptTokenType("LT_EQ")
    @JvmField val GT_EQ = ZenScriptTokenType("GT_EQ")
    @JvmField val AND_AND = ZenScriptTokenType("AND_AND")
    @JvmField val OR_OR = ZenScriptTokenType("OR_OR")
    @JvmField val ARROW = ZenScriptTokenType("ARROW")
    @JvmField val DOT = ZenScriptTokenType("DOT")

    // Delimiters
    @JvmField val LPAREN = ZenScriptTokenType("LPAREN")
    @JvmField val RPAREN = ZenScriptTokenType("RPAREN")
    @JvmField val LBRACE = ZenScriptTokenType("LBRACE")
    @JvmField val RBRACE = ZenScriptTokenType("RBRACE")
    @JvmField val LBRACKET = ZenScriptTokenType("LBRACKET")
    @JvmField val RBRACKET = ZenScriptTokenType("RBRACKET")
    @JvmField val COMMA = ZenScriptTokenType("COMMA")
    @JvmField val COLON = ZenScriptTokenType("COLON")
    @JvmField val SEMICOLON = ZenScriptTokenType("SEMICOLON")

    // Special
    @JvmField val WHITE_SPACE = ZenScriptTokenType("WHITE_SPACE")
    @JvmField val LINE_COMMENT = ZenScriptTokenType("LINE_COMMENT")
    @JvmField val BAD_CHARACTER = ZenScriptTokenType("BAD_CHARACTER")

    val KEYWORD_MAP: Map<String, ZenScriptTokenType> = mapOf(
        "let" to LET, "const" to CONST, "fn" to FN,
        "if" to IF, "else" to ELSE, "while" to WHILE,
        "for" to FOR, "break" to BREAK, "continue" to CONTINUE,
        "return" to RETURN, "match" to MATCH, "struct" to STRUCT,
        "enum" to ENUM, "external" to EXTERNAL, "import" to IMPORT,
        "export" to EXPORT, "from" to FROM, "as" to AS,
        "use" to USE, "true" to TRUE, "false" to FALSE,
        "char" to CHAR_KW, "pub" to PUB
    )
}
