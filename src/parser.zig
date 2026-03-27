const std = @import("std");
const Tokenizer = @import("tokens/tokenizer.zig");
const Token = @import("tokens/zs_token.zig");
const zsm = @import("ast/zs_module.zig");
const ast = @import("ast/ast_node.zig");
const ZSAstNode = ast.ZSAstNode;
const VarType = ast.VarType;
const ZSModule = zsm.ZSModule;
const Self = @This();

tokenizer: Tokenizer,
peekedToken: ?Token,
allocator: std.mem.Allocator,
filename: []const u8,
source: []const u8,

const Error = error{ UnexpectedTokenType, UnexpectedToken, NotShiftedToken } || Tokenizer.Error || std.mem.Allocator.Error;

pub fn create(
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    filename: []const u8,
    source: []const u8,
) !Self {
    return .{
        .tokenizer = tokenizer,
        .peekedToken = null,
        .allocator = allocator,
        .filename = filename,
        .source = source,
    };
}

pub fn parse(self: *Self, allocator: std.mem.Allocator) !ZSModule {
    var astNodes = try std.ArrayList(ZSAstNode).initCapacity(allocator, 5);
    defer astNodes.deinit(allocator);

    while (true) {
        const node = self.nextNode() catch |err| break try self.printError(err);

        if (node) |n| {
            try astNodes.append(allocator, n);
        } else break;
    }
    if (self.peekedToken) |tok| {
        std.debug.print("Token: {any}\n", .{tok});
        return Error.NotShiftedToken;
    }

    const astItems = try allocator.alloc(ZSAstNode, astNodes.items.len);
    @memcpy(astItems, astNodes.items);

    // Collect deps from import_decl nodes
    var depsList = try std.ArrayList(zsm.ZSModuleDep).initCapacity(allocator, 2);
    defer depsList.deinit(allocator);
    for (astItems) |node| {
        switch (node) {
            .import_decl => |imp| {
                try depsList.append(allocator, zsm.ZSModuleDep{
                    .path = imp.path,
                    .symbols = imp.symbols,
                });
            },
            else => {},
        }
    }

    return .{
        .ast = astItems,
        .deps = try allocator.dupe(zsm.ZSModuleDep, depsList.items),
        .filename = self.filename,
        .source = self.source,
    };
}

fn nextNode(self: *Self) !?ZSAstNode {
    if (!self.tokenizer.hasNext() and self.peekedToken == null) return null;
    if (try self.nextImport()) |imp| {
        return ZSAstNode{ .import_decl = imp };
    }
    const s = self.nextStmt() catch |err| {
        if (try self.nextExpr()) |e| {
            return ZSAstNode{ .expr = e };
        }
        return err;
    };
    if (s) |stmt| {
        return ZSAstNode{ .stmt = stmt };
    } else return Error.UnknownToken;
}

fn nextImport(self: *Self) Error!?ast.ZSImport {
    if (!self.checkToken("import")) return null;
    const startToken = try self.peekToken();
    self.shiftToken();

    try self.expectToken("{");

    var symbols = try std.ArrayList(ast.zs_import.ImportedSymbol).initCapacity(self.allocator, 4);
    defer symbols.deinit(self.allocator);

    while (true) {
        if (self.checkToken("}")) break;
        const name = try self.nextIdent();
        var alias: ?[]const u8 = null;
        if (self.checkToken("as")) {
            self.shiftToken();
            alias = try self.nextIdent();
        }
        try symbols.append(self.allocator, .{ .name = name, .alias = alias });
        if (self.checkToken(",")) {
            self.shiftToken();
            continue;
        }
        break;
    }
    try self.expectToken("}");

    // expect "from"
    const fromToken = try self.peekToken();
    if (!std.mem.eql(u8, fromToken.value, "from")) return Error.UnexpectedToken;
    self.shiftToken();

    // parse path string
    const pathToken = try self.peekToken();
    if (pathToken.type != .string) return Error.UnexpectedTokenType;
    self.shiftToken();

    // Strip quotes from path
    const rawPath = pathToken.value;
    const path = if (std.mem.startsWith(u8, rawPath, "\"") and std.mem.endsWith(u8, rawPath, "\""))
        rawPath[1 .. rawPath.len - 1]
    else
        rawPath;

    return ast.ZSImport{
        .path = path,
        .symbols = try self.allocator.dupe(ast.zs_import.ImportedSymbol, symbols.items),
        .startPos = startToken.startPos,
        .endPos = pathToken.endPos,
    };
}

fn nextStmt(self: *Self) !?ast.stmt.ZSStmt {
    if (!self.tokenizer.hasNext() and self.peekedToken == null) return null;
    const modifiers = try self.nextModifiers();
    if (try self.nextVar(modifiers)) |v| return ast.stmt.ZSStmt{ .variable = v };
    if (try self.nextFn(modifiers)) |f| return ast.stmt.ZSStmt{ .function = f };
    if (try self.nextReassign()) |r| return ast.stmt.ZSStmt{ .reassign = r };
    return Error.UnknownToken;
}

fn nextReassign(self: *Self) Error!?ast.stmt.ZSReassign {
    // Save state for backtracking
    const savedPeeked = self.peekedToken;
    const savedPos = self.tokenizer.position;
    const savedLine = self.tokenizer.line;

    // Check for non-keyword ident
    const token = self.peekToken() catch return null;
    if (token.type != .ident) return null;
    if (isKeyword(token.value)) return null;

    const name = token.value;
    self.shiftToken();

    // Check for '='
    if (self.checkToken("=")) {
        self.shiftToken();
        const expr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
        return ast.stmt.ZSReassign{ .name = name, .expr = expr };
    }

    // Backtrack — not a reassignment
    self.peekedToken = savedPeeked;
    self.tokenizer.position = savedPos;
    self.tokenizer.line = savedLine;
    return null;
}

fn isKeyword(value: []const u8) bool {
    const keywords = [_][]const u8{ "if", "return", "else", "let", "const", "fn", "external", "true", "false", "import", "export", "from", "as" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, value, kw)) return true;
    }
    return false;
}

fn nextExpr(self: *Self) Error!?ast.expr.ZSExpr {
    const expr = blk: {
        if (try self.nextIfExpr()) |e| break :blk ast.expr.ZSExpr{ .if_expr = e };
        if (try self.nextReturn()) |r| break :blk ast.expr.ZSExpr{ .return_expr = r };
        if (try self.nextBlock()) |b| break :blk ast.expr.ZSExpr{ .block = b };
        if (try self.nextNumber()) |n| break :blk ast.expr.ZSExpr{ .number = n };
        if (try self.nextBoolean()) |b| break :blk ast.expr.ZSExpr{ .boolean = b };
        if (try self.nextReference()) |r| break :blk ast.expr.ZSExpr{ .reference = r };
        if (try self.nextString()) |s| break :blk ast.expr.ZSExpr{ .string = s };
        return null;
    };

    // Check for call
    if (try self.nextCall(expr)) |call| {
        const callExpr = ast.expr.ZSExpr{ .call = call };
        // Check for binary op after call
        if (try self.nextBinaryRhs(callExpr)) |bin| {
            return ast.expr.ZSExpr{ .binary = bin };
        }
        return callExpr;
    }

    // Check for binary op (==, !=)
    if (try self.nextBinaryRhs(expr)) |bin| {
        return ast.expr.ZSExpr{ .binary = bin };
    }

    return expr;
}

fn nextBinaryRhs(self: *Self, lhs: ast.expr.ZSExpr) Error!?ast.expr.ZSBinary {
    const op = blk: {
        if (self.checkToken("==")) break :blk "==";
        if (self.checkToken("!=")) break :blk "!=";
        return null;
    };
    self.shiftToken();
    const rhs = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;

    const lhsPtr = try self.allocator.create(ast.expr.ZSExpr);
    lhsPtr.* = lhs;
    const rhsPtr = try self.allocator.create(ast.expr.ZSExpr);
    rhsPtr.* = rhs;

    return ast.expr.ZSBinary{
        .lhs = lhsPtr,
        .op = op,
        .rhs = rhsPtr,
        .startPos = lhs.start(),
        .endPos = rhs.end(),
    };
}

fn nextIfExpr(self: *Self) Error!?ast.expr.ZSIfExpr {
    if (!(self.checkToken("if"))) return null;
    const ifToken = try self.peekToken();
    const startPos = ifToken.startPos;
    self.shiftToken();

    // Optional parens around condition
    const hasParen = self.checkToken("(");
    if (hasParen) self.shiftToken();

    const condition = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    const condPtr = try self.allocator.create(ast.expr.ZSExpr);
    condPtr.* = condition;

    if (hasParen) try self.expectToken(")");

    // Then branch: block or expression
    const thenExpr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    const thenPtr = try self.allocator.create(ast.expr.ZSExpr);
    thenPtr.* = thenExpr;

    // Optional else branch
    var elseBranch: ?*ast.expr.ZSExpr = null;
    var endPos = thenExpr.end();
    if (self.checkToken("else")) {
        self.shiftToken();
        const elseExpr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
        const elsePtr = try self.allocator.create(ast.expr.ZSExpr);
        elsePtr.* = elseExpr;
        elseBranch = elsePtr;
        endPos = elseExpr.end();
    }

    return ast.expr.ZSIfExpr{
        .condition = condPtr,
        .then_branch = thenPtr,
        .else_branch = elseBranch,
        .startPos = startPos,
        .endPos = endPos,
    };
}

fn nextReturn(self: *Self) Error!?ast.expr.ZSReturn {
    if (!(self.checkToken("return"))) return null;
    const retToken = try self.peekToken();
    const startPos = retToken.startPos;
    self.shiftToken();

    // Optional value — but don't consume } or else
    var value: ?*ast.expr.ZSExpr = null;
    var endPos = retToken.endPos;
    if (!isBlockTerminator(self)) {
        if (try self.nextExpr()) |expr| {
            const ptr = try self.allocator.create(ast.expr.ZSExpr);
            ptr.* = expr;
            value = ptr;
            endPos = expr.end();
        }
    }

    return ast.expr.ZSReturn{
        .value = value,
        .startPos = startPos,
        .endPos = endPos,
    };
}

fn isBlockTerminator(self: *Self) bool {
    const tok = self.peekToken() catch return true;
    if (std.mem.eql(u8, tok.value, "}")) return true;
    if (std.mem.eql(u8, tok.value, "else")) return true;
    return false;
}

fn nextBlock(self: *Self) Error!?ast.expr.ZSBlock {
    if (!(self.checkToken("{"))) return null;
    const startToken = try self.peekToken();
    const startPos = startToken.startPos;
    self.shiftToken();

    var nodes = try std.ArrayList(ZSAstNode).initCapacity(self.allocator, 4);
    defer nodes.deinit(self.allocator);

    while (true) {
        if (self.checkToken("}")) break;
        const node = try self.nextNode() orelse return Error.UnexpectedEndOfInput;
        try nodes.append(self.allocator, node);
    }

    const endToken = try self.peekToken();
    const endPos = endToken.endPos;
    try self.expectToken("}");

    return ast.expr.ZSBlock{
        .stmts = try self.allocator.dupe(ZSAstNode, nodes.items),
        .startPos = startPos,
        .endPos = endPos,
    };
}

fn nextVar(self: *Self, modifiers: ast.stmt.Modifiers) Error!?ast.stmt.ZSVar {
    const varType = block: {
        if (self.checkToken("const")) break :block VarType.Const;
        if (self.checkToken("let")) break :block VarType.Let;
        return null;
    };
    self.shiftToken();
    const name = try self.nextIdent();
    try self.expectToken("=");
    const expr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;

    return ast.stmt.ZSVar{ .type = varType, .name = name, .expr = expr, .modifiers = modifiers };
}

fn nextFn(self: *Self, modifiers: ast.stmt.Modifiers) Error!?ast.stmt.ZSFn {
    if (!self.checkToken("fn")) return null;
    self.shiftToken();
    const name = try self.nextIdent();
    try self.expectToken("(");
    var args = try std.ArrayList(ast.stmt.ZSFn.Arg).initCapacity(self.allocator, 1);
    defer args.deinit(self.allocator);

    // Handle empty arg list
    if (!(self.checkToken(")"))) {
        while (true) {
            const argName = try self.nextIdent();
            const ty = try self.nextType();
            const arg = ast.stmt.ZSFn.Arg{ .name = argName, .type = ty };
            try args.append(self.allocator, arg);

            if (self.checkToken(",")) {
                self.shiftToken();
                continue;
            }

            break;
        }
    }
    try self.expectToken(")");

    const ret = try self.nextType();

    // Parse body: expression body (= expr), block body ({ ... }), or no body
    var body: ?ast.expr.ZSExpr = null;
    if (self.checkToken("=")) {
        self.shiftToken();
        body = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    } else if (self.checkToken("{")) {
        if (try self.nextBlock()) |blk| {
            body = ast.expr.ZSExpr{ .block = blk };
        }
    }

    return ast.stmt.ZSFn{
        .name = name,
        .modifiers = modifiers,
        .args = try self.allocator.dupe(ast.stmt.ZSFn.Arg, args.items),
        .ret = ret,
        .body = body,
    };
}

fn nextType(self: *Self) !?ast.ZSType {
    if (!self.checkToken(":")) return null;
    self.shiftToken();

    const typeName = try self.nextIdent();

    return ast.ZSType{ .reference = typeName };
}

fn nextModifiers(self: *Self) Error!ast.stmt.Modifiers {
    var external: ?ast.stmt.Modifier = null;
    var exported: ?ast.stmt.Modifier = null;
    while (true) {
        const token = try self.peekToken();
        if (std.mem.eql(u8, token.value, "external")) {
            if (external) |_| break;
            external = ast.stmt.Modifier{ .start = token.startPos, .end = token.endPos };
            self.shiftToken();
        } else if (std.mem.eql(u8, token.value, "export")) {
            if (exported) |_| break;
            exported = ast.stmt.Modifier{ .start = token.startPos, .end = token.endPos };
            self.shiftToken();
        } else {
            break;
        }
    }
    return ast.stmt.Modifiers{ .external = external, .exported = exported };
}

fn nextCall(self: *Self, subject: ast.expr.ZSExpr) Error!?ast.expr.ZSCall {
    if (!self.checkToken("(")) return null;
    self.shiftToken();
    var args = try std.ArrayList(ast.expr.ZSExpr).initCapacity(self.allocator, 5);
    defer args.deinit(self.allocator);
    while (try self.nextExpr()) |arg| {
        try args.append(self.allocator, arg);
        if (self.checkToken(",")) {
            self.shiftToken();
            continue;
        }
        break;
    }
    const start = subject.start();
    const end = (try self.peekToken()).endPos;
    try self.expectToken(")");
    const expr = try self.allocator.alloc(ast.expr.ZSExpr, 1);
    expr[0] = subject;
    return ast.expr.ZSCall{
        .subject = &expr[0],
        .arguments = try self.allocator.dupe(ast.expr.ZSExpr, args.items),
        .startPos = start,
        .endPos = end,
    };
}

fn nextBoolean(self: *Self) Error!?ast.expr.ZSBoolean {
    const token = self.peekToken() catch return null;
    if (token.type != .ident) return null;
    if (std.mem.eql(u8, token.value, "true")) {
        self.shiftToken();
        return ast.expr.ZSBoolean{ .value = true, .startPos = token.startPos, .endPos = token.endPos };
    }
    if (std.mem.eql(u8, token.value, "false")) {
        self.shiftToken();
        return ast.expr.ZSBoolean{ .value = false, .startPos = token.startPos, .endPos = token.endPos };
    }
    return null;
}

fn nextReference(self: *Self) !?ast.expr.ZSReference {
    if (!self.checkIndent()) return null;
    const token = try self.peekToken();
    if (token.type != .ident) return Error.UnexpectedTokenType;
    // Don't consume keywords that are handled elsewhere
    if (isKeyword(token.value)) {
        return null;
    }
    self.shiftToken();
    const name = token.value;
    return ast.expr.ZSReference{
        .name = name,
        .startPos = token.startPos,
        .endPos = token.endPos,
    };
}

fn checkIndent(self: *Self) bool {
    const token = self.peekToken() catch return false;
    return token.type == .ident;
}

fn nextIdent(self: *Self) ![]const u8 {
    const token = try self.peekToken();

    if (token.type != .ident) return Error.UnexpectedTokenType;
    self.shiftToken();
    return token.value;
}

fn nextNumber(self: *Self) Error!?ast.expr.ZSNumber {
    const token = try self.peekToken();
    if (token.type != .numeric) return null;
    self.shiftToken();
    return ast.expr.ZSNumber{
        .value = token.value,
        .startPos = token.startPos,
        .endPos = token.endPos,
    };
}

fn nextString(self: *Self) !?ast.expr.ZSString {
    const token = try self.peekToken();
    if (token.type != .string) return null;
    self.shiftToken();
    const value: [:0]const u8 = blk: {
        if (std.mem.startsWith(u8, token.value, "\"") and std.mem.endsWith(u8, token.value, "\"")) {
            const slice = token.value[1..(token.value.len - 1)];
            const cStr = try self.allocator.dupeZ(u8, slice);
            break :blk cStr;
        }

        return Error.UnexpectedToken;
    };

    const result = ast.expr.ZSString{
        .value = value,
        .startPos = token.startPos,
        .endPos = token.endPos,
    };
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

fn checkToken(self: *Self, value: []const u8) bool {
    const token = self.peekToken() catch return false;
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

// --- Tests ---

fn testParse(source: []const u8) !ZSModule {
    const allocator = std.testing.allocator;
    const tokenizer = Tokenizer.create(source);
    var parser = try Self.create(allocator, tokenizer, "test.zs", source);
    return try parser.parse(allocator);
}

test "parse empty input" {
    const allocator = std.testing.allocator;
    const module = try testParse("");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), module.ast.len);
}

test "parse let variable with number" {
    const allocator = std.testing.allocator;
    const module = try testParse("let x = 10");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), module.ast.len);
    const node = module.ast[0];
    const v = node.stmt.variable;
    try std.testing.expectEqual(VarType.Let, v.type);
    try std.testing.expectEqualStrings("x", v.name);
    try std.testing.expectEqualStrings("10", v.expr.number.value);
}

test "parse const variable" {
    const allocator = std.testing.allocator;
    const module = try testParse("const y = 42");
    defer module.deinit(allocator);
    const v = module.ast[0].stmt.variable;
    try std.testing.expectEqual(VarType.Const, v.type);
    try std.testing.expectEqualStrings("y", v.name);
    try std.testing.expectEqualStrings("42", v.expr.number.value);
}

test "parse variable with string" {
    const allocator = std.testing.allocator;
    const module = try testParse("let s = \"hello\"");
    defer module.deinit(allocator);
    const v = module.ast[0].stmt.variable;
    try std.testing.expectEqual(VarType.Let, v.type);
    try std.testing.expectEqualStrings("s", v.name);
    try std.testing.expectEqualStrings("hello", v.expr.string.value);
}

test "parse function declaration" {
    const allocator = std.testing.allocator;
    const module = try testParse("fn foo(x: int): void");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), module.ast.len);
    const f = module.ast[0].stmt.function;
    try std.testing.expectEqualStrings("foo", f.name);
    try std.testing.expectEqual(@as(usize, 1), f.args.len);
    try std.testing.expectEqualStrings("x", f.args[0].name);
    try std.testing.expectEqualStrings("int", f.args[0].type.?.reference);
    try std.testing.expectEqualStrings("void", f.ret.?.reference);
    try std.testing.expect(f.modifiers.external == null);
    try std.testing.expect(f.body == null);
}

test "parse external function" {
    const allocator = std.testing.allocator;
    const module = try testParse("external fn print(msg: string): void");
    defer module.deinit(allocator);
    const f = module.ast[0].stmt.function;
    try std.testing.expectEqualStrings("print", f.name);
    try std.testing.expectEqualStrings("msg", f.args[0].name);
    try std.testing.expectEqualStrings("string", f.args[0].type.?.reference);
    try std.testing.expectEqualStrings("void", f.ret.?.reference);
    try std.testing.expect(f.modifiers.external != null);
    try std.testing.expect(f.body == null);
}

test "parse number expression" {
    const allocator = std.testing.allocator;
    const module = try testParse("let a = 99");
    defer module.deinit(allocator);
    try std.testing.expectEqualStrings("99", module.ast[0].stmt.variable.expr.number.value);
}

test "parse string expression" {
    const allocator = std.testing.allocator;
    const module = try testParse("let b = \"world\"");
    defer module.deinit(allocator);
    try std.testing.expectEqualStrings("world", module.ast[0].stmt.variable.expr.string.value);
}

test "parse multiple statements" {
    const allocator = std.testing.allocator;
    const module = try testParse("let a = 1 let b = 2");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), module.ast.len);
    try std.testing.expectEqualStrings("a", module.ast[0].stmt.variable.name);
    try std.testing.expectEqualStrings("b", module.ast[1].stmt.variable.name);
}

test "parse function call expression" {
    const allocator = std.testing.allocator;
    const module = try testParse("let r = foo(1, 2)");
    defer module.deinit(allocator);
    const expr = module.ast[0].stmt.variable.expr;
    const call = expr.call;
    try std.testing.expectEqualStrings("foo", call.subject.reference.name);
    try std.testing.expectEqual(@as(usize, 2), call.arguments.len);
    try std.testing.expectEqualStrings("1", call.arguments[0].number.value);
    try std.testing.expectEqualStrings("2", call.arguments[1].number.value);
}

test "parse function with expression body" {
    const allocator = std.testing.allocator;
    const module = try testParse("fn get_ten(): number = 10");
    defer module.deinit(allocator);
    const f = module.ast[0].stmt.function;
    try std.testing.expectEqualStrings("get_ten", f.name);
    try std.testing.expectEqual(@as(usize, 0), f.args.len);
    try std.testing.expectEqualStrings("number", f.ret.?.reference);
    try std.testing.expect(f.body != null);
    try std.testing.expectEqualStrings("10", f.body.?.number.value);
}

test "parse function with block body" {
    const allocator = std.testing.allocator;
    const module = try testParse("fn foo(a: number): number { return a }");
    defer module.deinit(allocator);
    const f = module.ast[0].stmt.function;
    try std.testing.expectEqualStrings("foo", f.name);
    try std.testing.expect(f.body != null);
    const blk = f.body.?.block;
    try std.testing.expectEqual(@as(usize, 1), blk.stmts.len);
}

test "parse if else expression" {
    const allocator = std.testing.allocator;
    const module = try testParse("fn check(a: number): number { if a == 10 { return 1 } else { return 0 } }");
    defer module.deinit(allocator);
    const f = module.ast[0].stmt.function;
    try std.testing.expect(f.body != null);
}

test "parse import statement" {
    const allocator = std.testing.allocator;
    const module = try testParse("import { x, add as sum } from \"./lib.zs\"");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), module.ast.len);
    const imp = module.ast[0].import_decl;
    try std.testing.expectEqualStrings("./lib.zs", imp.path);
    try std.testing.expectEqual(@as(usize, 2), imp.symbols.len);
    try std.testing.expectEqualStrings("x", imp.symbols[0].name);
    try std.testing.expect(imp.symbols[0].alias == null);
    try std.testing.expectEqualStrings("add", imp.symbols[1].name);
    try std.testing.expectEqualStrings("sum", imp.symbols[1].alias.?);
    // Should produce a dependency
    try std.testing.expectEqual(@as(usize, 1), module.deps.len);
    try std.testing.expectEqualStrings("./lib.zs", module.deps[0].path);
}

test "parse export let" {
    const allocator = std.testing.allocator;
    const module = try testParse("export let x = 10");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), module.ast.len);
    const v = module.ast[0].stmt.variable;
    try std.testing.expectEqualStrings("x", v.name);
    try std.testing.expect(v.modifiers.exported != null);
}

test "parse export fn" {
    const allocator = std.testing.allocator;
    const module = try testParse("export fn add(a: number, b: number): number = a");
    defer module.deinit(allocator);
    const f = module.ast[0].stmt.function;
    try std.testing.expectEqualStrings("add", f.name);
    try std.testing.expect(f.modifiers.exported != null);
    try std.testing.expect(f.modifiers.external == null);
}
