const std = @import("std");
const root = @import("ZenScript");
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
source: []const u8,
startLine: usize,
endLine: usize,
startPos: usize,
endPos: usize,

pub fn format(self: *const @This(), writer: *std.io.Writer) !void {
    const line = root.SourceHelpers.computeSourceLine(self.source, self.startPos);
    try writer.print("{s}", .{line});
}
