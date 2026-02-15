const std = @import("std");
const Tokenizer = @import("tokens/Tokenizer.zig");
const Token = @import("tokens/ZSToken.zig");
const zsm = @import("ast/zs_module.zig");
const ast = @import("ast/ast_node.zig");
const ZSAstNode = ast.ZSAstNode;
const VarType = ast.VarType;
const ZSModule = zsm.ZSModule;
const Self = @This();

tokenizer: Tokenizer,
peekedToken: ?Token,
allocator: std.mem.Allocator,

const Error = error{
    UnexpectedTokenType,
    UnexpectedToken,
} || Tokenizer.Error || std.mem.Allocator.Error;

pub fn create(tokenizer: Tokenizer, allocator: std.mem.Allocator) !Self {
    return .{
        .tokenizer = tokenizer,
        .peekedToken = null,
        .allocator = allocator,
    };
}

pub fn parse(self: *Self, allocator: std.mem.Allocator) !ZSModule {
    var astNodes = try std.ArrayList(ZSAstNode).initCapacity(allocator, 5);
    defer astNodes.deinit(allocator);

    const deps = try allocator.alloc(zsm.ZSModuleDep, 0);

    while (true) {
        const node = self.nextNode() catch |err| break try self.printError(err);
        if (node) |n| {
            try astNodes.append(allocator, n);
        } else break;
    }

    const astItems = try allocator.alloc(ZSAstNode, astNodes.items.len);
    @memcpy(astItems, astNodes.items);

    return .{
        .ast = astItems,
        .deps = deps,
    };
}

fn nextNode(self: *Self) !?ZSAstNode {
    if (!self.tokenizer.hasNext()) return null;
    const stmt = self.nextStmt() catch |err| {
        if (try self.nextExpr()) |e| {
            return ZSAstNode{ .expr = e };
        }
        return err;
    };
    if (stmt) |s| {
        return ZSAstNode{ .stmt = s };
    } else return Error.UnknownToken;
}

fn nextStmt(self: *Self) !?ast.stmt.ZSStmt {
    if (!self.tokenizer.hasNext()) return null;
    if (try self.nextVar()) |v| return ast.stmt.ZSStmt{ .variable = v };
    return Error.UnknownToken;
}

fn nextExpr(self: *Self) Error!?ast.expr.ZSExpr {
    const expr = blk: {
        if (try self.nextNumber()) |n| break :blk ast.expr.ZSExpr{ .number = n };
        if (try self.nextReference()) |r| break :blk ast.expr.ZSExpr{ .reference = r };
        if (try self.nextString()) |s| break :blk ast.expr.ZSExpr{ .string = s };
        return null;
    };

    if (try self.nextCall(expr)) |call| {
        return ast.expr.ZSExpr{ .call = call };
    } else {
        return expr;
    }

    return Error.UnknownToken;
}

fn nextVar(self: *Self) Error!?ast.stmt.ZSVar {
    const varType = block: {
        if (try self.checkToken("const")) break :block VarType.Const;
        if (try self.checkToken("let")) break :block VarType.Let;
        return null;
    };
    self.shiftToken();
    const name = try self.nextIdent() orelse return Error.UnexpectedEndOfInput;
    try self.expectToken("=");
    const expr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;

    return ast.stmt.ZSVar{ .type = varType, .name = name, .expr = expr };
}

fn nextCall(self: *Self, subject: ast.expr.ZSExpr) Error!?ast.expr.ZSCall {
    if (!try self.checkToken("(")) return null;
    self.shiftToken();
    var args = try std.ArrayList(ast.expr.ZSExpr).initCapacity(self.allocator, 5);
    defer args.deinit(self.allocator);
    while (try self.nextExpr()) |arg| {
        try args.append(self.allocator, arg);
        if (try self.checkToken(",")) {
            self.shiftToken();
            continue;
        }
        break;
    }
    try self.expectToken(")");
    const expr = try self.allocator.alloc(ast.expr.ZSExpr, 1);
    expr[0] = subject;
    return ast.expr.ZSCall{ .subject = &expr[0], .arguments = try self.allocator.dupe(ast.expr.ZSExpr, args.items) };
}

fn nextReference(self: *Self) !?ast.expr.ZSReference {
    if (!self.checkIndent()) return null;
    const name = try self.nextIdent() orelse return null;
    return ast.expr.ZSReference{ .name = name };
}

fn checkIndent(self: *Self) bool {
    const token = self.peekToken() catch return false;
    return token.type == .ident;
}

fn nextIdent(self: *Self) !?[]const u8 {
    const token = try self.peekToken();

    if (token.type != .ident) return Error.UnexpectedTokenType;
    self.shiftToken();
    return token.value;
}

fn nextNumber(self: *Self) Error!?ast.expr.ZSNumber {
    const token = try self.peekToken();
    if (token.type != .numeric) return null;
    self.shiftToken();
    return ast.expr.ZSNumber{ .value = token.value };
}

fn nextString(self: *Self) !?ast.expr.ZSString {
    const token = try self.peekToken();
    if (token.type != .string) return null;
    self.shiftToken();
    const value = blk: {
        if (std.mem.startsWith(u8, token.value, "\"") and std.mem.endsWith(u8, token.value, "\"")) {
            break :blk token.value[1..(token.value.len - 1)];
        }

        return Error.UnexpectedToken;
    };

    const result = ast.expr.ZSString{ .value = value };
    return result;
}

fn peekToken(self: *Self) Error!Token {
    if (self.peekedToken) |token| return token;
    const token = try self.tokenizer.next() orelse return Error.UnexpectedEndOfInput;
    self.peekedToken = token;
    return token;
}

fn shiftToken(self: *Self) void {
    self.peekedToken = null;
}

fn expectToken(self: *Self, value: []const u8) !void {
    const token = try self.peekToken();
    if (!std.mem.eql(u8, token.value, value)) return Error.UnexpectedToken;
    self.shiftToken();
}

fn checkToken(self: *Self, value: []const u8) !bool {
    const token = try self.peekToken();
    return std.mem.eql(u8, token.value, value);
}

fn printError(self: *Self, err: Error) Error!void {
    switch (err) {
        Error.UnknownToken, Error.UnexpectedToken => {
            const token = self.peekedToken;
            const tokenValue = if (token) |t| t.value else "eof";
            std.debug.print("Unknown token \"{s}\"\n", .{tokenValue});

            return err;
        },

        else => return err,
    }
}
