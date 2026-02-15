const std = @import("std");
const ZSToken = @import("ZSToken.zig");
const TokenType = ZSToken.TokenType;

const Tokenizer = @This();

pub const Error = error{ UnknownToken, UnexpectedEndOfInput, EmptyToken };

input: []const u8,
position: usize,
line: usize,

pub fn create(input: []const u8) Tokenizer {
    return Tokenizer{ .input = input, .position = 0, .line = 0 };
}

fn peek(self: *Tokenizer) ?u8 {
    if (!self.hasNext()) return null;
    return self.input[self.position];
}

fn advance(self: *Tokenizer) ?u8 {
    const ch = self.peek();
    if (ch != null) self.pos += 1;
    return ch;
}

fn shift(self: *Tokenizer) void {
    if (self.hasNext()) self.position += 1;
}

pub fn hasNext(self: *Tokenizer) bool {
    return self.position < self.input.len;
}

fn skipWhitespace(self: *Tokenizer) void {
    while (self.peek()) |c| {
        if (!std.ascii.isWhitespace(c)) break;
        self.shift();
    }
}

fn readNumber(self: *Tokenizer) []const u8 {
    const start = self.pos;

    while (self.peek()) |c| {
        if (!std.ascii.isDigit(c)) break;
        self.shift();
    }

    return self.input[start..self.pos];
}

fn currentTokenType(self: *Tokenizer) Error!?TokenType {
    const firstChar = self.peek() orelse return null;
    return switch (firstChar) {
        '=' => .punctuation,
        '(', ')' => .punctuation,
        '"' => .string,
        else => e: {
            if (std.ascii.isDigit(firstChar)) {
                break :e TokenType.numeric;
            }
            if (std.ascii.isAlphabetic(firstChar)) {
                break :e TokenType.ident;
            }
            if (std.ascii.isWhitespace(firstChar)) {
                break :e TokenType.whitespace;
            }
            std.debug.print("Unknown token: {c}\n", .{firstChar});
            return Error.UnknownToken;
        },
    };
}

fn eatIdent(self: *Tokenizer) void {
    self.shift();

    while (self.peek()) |c| {
        if (!std.ascii.isAlphanumeric(c)) break;
        self.shift();
    }
}

fn eatNumeric(self: *Tokenizer) void {
    var hasDot = false;

    while (self.peek()) |char| {
        if (std.ascii.isDigit(char)) {
            self.shift();
        } else if (char == '.' and !hasDot) {
            hasDot = true;
            self.shift();
        } else {
            break;
        }
    }
}

fn eatString(self: *Tokenizer) !void {
    if (self.peek() == '"') self.shift();

    while (self.peek()) |c| {
        if (c == '"') {
            self.shift();
            return;
        }

        self.shift();
    }

    return Error.UnexpectedEndOfInput;
}

fn eatPunc(self: *Tokenizer) void {
    switch (self.peek() orelse return) {
        '=' => self.shift(),
        '(', ')' => self.shift(),

        else => {},
    }
}

pub fn next(self: *Tokenizer) Error!?ZSToken {
    const tokenType = try self.currentTokenType() orelse return null;
    const startPos = self.position;
    const startLine = self.line;

    switch (tokenType) {
        .eof => {},
        .ident => self.eatIdent(),
        .numeric => self.eatNumeric(),
        .string => try self.eatString(),
        .punctuation => self.eatPunc(),
        .whitespace => self.skipWhitespace(),
    }

    const endPos = self.position;
    const endLine = self.line;

    const value = self.input[startPos..endPos];

    if (value.len == 0) {
        return Error.EmptyToken;
    }

    if (tokenType == .whitespace) {
        return self.next();
    }
    return ZSToken{ .type = tokenType, .startPos = startPos, .endPos = endPos, .startLine = startLine, .endLine = endLine, .value = value };
}
