pub const TokenType = enum {
    whitespace,
    ident,
    punctuation,
    numeric,
    string,
    eof,
};

type: TokenType,
value: []const u8,
startLine: usize,
endLine: usize,
startPos: usize,
endPos: usize,
