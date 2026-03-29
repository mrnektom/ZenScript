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

const Error = error{ UnexpectedTokenType, UnexpectedToken, NotShiftedToken, UnsupportedClone } || Tokenizer.Error || std.mem.Allocator.Error;

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
            .export_from => |ef| {
                try depsList.append(allocator, zsm.ZSModuleDep{
                    .path = ef.path,
                    .symbols = ef.symbols,
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
    if (try self.nextExportFrom()) |ef| {
        return ZSAstNode{ .export_from = ef };
    }
    if (try self.nextUse()) |u| {
        return ZSAstNode{ .use_decl = u };
    }
    const s = self.nextStmt() catch |err| {
        if (try self.nextExpr()) |e| {
            return ZSAstNode{ .expr = e };
        }
        return err;
    };
    if (s) |stmt| {
        return ZSAstNode{ .stmt = stmt };
    } else return null;
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

fn nextExportFrom(self: *Self) Error!?ast.ZSExportFrom {
    // Must be `export` followed by `{`
    if (!self.checkToken("export")) return null;

    // Save state for backtracking
    const savedPeeked = self.peekedToken;
    const savedPos = self.tokenizer.position;
    const savedLine = self.tokenizer.line;

    const startToken = try self.peekToken();
    self.shiftToken(); // consume `export`

    if (!self.checkToken("{")) {
        // Backtrack — this is `export fn/let/...`, not `export { ... } from`
        self.peekedToken = savedPeeked;
        self.tokenizer.position = savedPos;
        self.tokenizer.line = savedLine;
        return null;
    }
    self.shiftToken(); // consume `{`

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

    return ast.ZSExportFrom{
        .path = path,
        .symbols = try self.allocator.dupe(ast.zs_import.ImportedSymbol, symbols.items),
        .startPos = startToken.startPos,
        .endPos = pathToken.endPos,
    };
}

fn nextStmt(self: *Self) !?ast.stmt.ZSStmt {
    if (!self.tokenizer.hasNext() and self.peekedToken == null) return null;
    const modifiers = try self.nextModifiers();
    if (try self.nextStruct(modifiers)) |s| return ast.stmt.ZSStmt{ .struct_decl = s };
    if (try self.nextEnum(modifiers)) |e| return ast.stmt.ZSStmt{ .enum_decl = e };
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

    // Check for indexed assignment: name[index] = expr
    if (self.checkToken("[")) {
        self.shiftToken(); // consume '['
        const indexExpr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
        try self.expectToken("]");
        if (self.checkToken("=")) {
            self.shiftToken();
            const expr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
            return ast.stmt.ZSReassign{ .target = .{ .index = .{ .subject_name = name, .index = indexExpr } }, .expr = expr };
        }
        // Backtrack
        self.peekedToken = savedPeeked;
        self.tokenizer.position = savedPos;
        self.tokenizer.line = savedLine;
        return null;
    }

    // Check for '='
    if (self.checkToken("=")) {
        self.shiftToken();
        const expr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
        return ast.stmt.ZSReassign{ .target = .{ .name = name }, .expr = expr };
    }

    // Backtrack — not a reassignment
    self.peekedToken = savedPeeked;
    self.tokenizer.position = savedPos;
    self.tokenizer.line = savedLine;
    return null;
}

fn isKeyword(value: []const u8) bool {
    const keywords = [_][]const u8{ "if", "while", "for", "break", "continue", "return", "else", "let", "const", "fn", "struct", "enum", "match", "use", "external", "true", "false", "import", "export", "from", "as", "char" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, value, kw)) return true;
    }
    return false;
}

fn nextExpr(self: *Self) Error!?ast.expr.ZSExpr {
    var expr = blk: {
        if (try self.nextMatchExpr()) |m| break :blk ast.expr.ZSExpr{ .match_expr = m };
        if (try self.nextIfExpr()) |e| break :blk ast.expr.ZSExpr{ .if_expr = e };
        if (try self.nextWhileExpr()) |e| break :blk ast.expr.ZSExpr{ .while_expr = e };
        if (try self.nextForExpr()) |e| break :blk ast.expr.ZSExpr{ .for_expr = e };
        if (try self.nextBreak()) |b| break :blk ast.expr.ZSExpr{ .break_expr = b };
        if (try self.nextContinue()) |c| break :blk ast.expr.ZSExpr{ .continue_expr = c };
        if (try self.nextReturn()) |r| break :blk ast.expr.ZSExpr{ .return_expr = r };
        if (try self.nextBlock()) |b| break :blk ast.expr.ZSExpr{ .block = b };
        if (try self.nextUnaryNot()) |u| break :blk ast.expr.ZSExpr{ .unary = u };
        if (try self.nextArrayLiteral()) |a| break :blk ast.expr.ZSExpr{ .array_literal = a };
        if (try self.nextNegativeNumber()) |n| break :blk ast.expr.ZSExpr{ .number = n };
        if (try self.nextNumber()) |n| break :blk ast.expr.ZSExpr{ .number = n };
        if (try self.nextCharLiteral()) |c| break :blk ast.expr.ZSExpr{ .char = c };
        if (try self.nextBoolean()) |b| break :blk ast.expr.ZSExpr{ .boolean = b };
        if (try self.nextReference()) |r| {
            // Check for struct init: Name { field: value, ... }
            if (try self.nextStructInit(r)) |si| break :blk ast.expr.ZSExpr{ .struct_init = si };
            break :blk ast.expr.ZSExpr{ .reference = r };
        }
        if (try self.nextString()) |s| break :blk ast.expr.ZSExpr{ .string = s };
        return null;
    };

    // Check for field access and index access chain
    expr = try self.nextPostfixChain(expr);

    // Check for call
    if (try self.nextCall(expr)) |call| {
        var callExpr = ast.expr.ZSExpr{ .call = call };
        // Check for postfix after call
        callExpr = try self.nextPostfixChain(callExpr);
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

fn nextStructInit(self: *Self, ref: ast.expr.ZSReference) Error!?ast.expr.ZSStructInit {
    // Struct init: Name { field: value, ... }
    // To disambiguate from blocks, we check if after '{' there's 'ident :'
    if (!self.checkToken("{")) return null;

    // Save state for backtracking
    const savedPeeked = self.peekedToken;
    const savedPos = self.tokenizer.position;
    const savedLine = self.tokenizer.line;

    self.shiftToken(); // consume '{'

    // Check if this looks like a struct init (ident followed by ':')
    const firstToken = self.peekToken() catch {
        // Backtrack
        self.peekedToken = savedPeeked;
        self.tokenizer.position = savedPos;
        self.tokenizer.line = savedLine;
        return null;
    };
    if (firstToken.type != .ident or isKeyword(firstToken.value)) {
        // Backtrack — this is a block, not a struct init
        self.peekedToken = savedPeeked;
        self.tokenizer.position = savedPos;
        self.tokenizer.line = savedLine;
        return null;
    }

    // Save again for second-level peek
    const savedPeeked2 = self.peekedToken;
    const savedPos2 = self.tokenizer.position;
    const savedLine2 = self.tokenizer.line;

    self.shiftToken(); // consume ident
    const isStructInit = self.checkToken(":");
    // Backtrack the ident consumption
    self.peekedToken = savedPeeked2;
    self.tokenizer.position = savedPos2;
    self.tokenizer.line = savedLine2;

    if (!isStructInit) {
        // Backtrack — not a struct init
        self.peekedToken = savedPeeked;
        self.tokenizer.position = savedPos;
        self.tokenizer.line = savedLine;
        return null;
    }

    // Now parse the field values
    var field_values = try std.ArrayList(ast.expr.ZSFieldInit).initCapacity(self.allocator, 4);
    defer field_values.deinit(self.allocator);

    while (true) {
        if (self.checkToken("}")) break;
        const fieldName = try self.nextIdent();
        try self.expectToken(":");
        const value = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
        try field_values.append(self.allocator, .{ .name = fieldName, .value = value });
        if (self.checkToken(",")) {
            self.shiftToken();
            continue;
        }
        break;
    }

    const endToken = try self.peekToken();
    try self.expectToken("}");

    return ast.expr.ZSStructInit{
        .name = ref.name,
        .field_values = try self.allocator.dupe(ast.expr.ZSFieldInit, field_values.items),
        .startPos = ref.startPos,
        .endPos = endToken.endPos,
    };
}

fn nextPostfixChain(self: *Self, initial: ast.expr.ZSExpr) Error!ast.expr.ZSExpr {
    var current = initial;
    while (true) {
        if (self.checkToken(".")) {
            self.shiftToken();
            const fieldToken = try self.peekToken();
            if (fieldToken.type != .ident) return Error.UnexpectedTokenType;
            self.shiftToken();

            // Check if this is EnumName.Variant(...) or EnumName.Variant
            // When the subject is a simple reference, check for enum init syntax
            if (current == .reference) {
                if (self.checkToken("(")) {
                    // EnumName.Variant(payload)
                    self.shiftToken(); // consume '('
                    var payload: ?*ast.expr.ZSExpr = null;
                    var endPos = fieldToken.endPos;
                    if (!self.checkToken(")")) {
                        const payloadExpr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
                        const payloadPtr = try self.allocator.create(ast.expr.ZSExpr);
                        payloadPtr.* = payloadExpr;
                        payload = payloadPtr;
                    }
                    const closeToken = try self.peekToken();
                    endPos = closeToken.endPos;
                    try self.expectToken(")");

                    current = ast.expr.ZSExpr{ .enum_init = .{
                        .enum_name = current.reference.name,
                        .variant_name = fieldToken.value,
                        .payload = payload,
                        .startPos = current.start(),
                        .endPos = endPos,
                    } };
                    continue;
                } else {
                    // Could be EnumName.Variant (unit variant) or regular field access
                    // Parser emits enum_init with null payload; analyzer validates
                    // But we can't distinguish from field access here, so emit field_access
                    // and let the analyzer handle it
                    const subjectPtr = try self.allocator.create(ast.expr.ZSExpr);
                    subjectPtr.* = current;

                    current = ast.expr.ZSExpr{ .field_access = .{
                        .subject = subjectPtr,
                        .field = fieldToken.value,
                        .startPos = current.start(),
                        .endPos = fieldToken.endPos,
                    } };
                    continue;
                }
            }

            const subjectPtr = try self.allocator.create(ast.expr.ZSExpr);
            subjectPtr.* = current;

            current = ast.expr.ZSExpr{ .field_access = .{
                .subject = subjectPtr,
                .field = fieldToken.value,
                .startPos = current.start(),
                .endPos = fieldToken.endPos,
            } };
        } else if (self.checkToken("[")) {
            self.shiftToken(); // consume '['
            const indexExpr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
            const endToken = try self.peekToken();
            try self.expectToken("]");

            const subjectPtr = try self.allocator.create(ast.expr.ZSExpr);
            subjectPtr.* = current;
            const indexPtr = try self.allocator.create(ast.expr.ZSExpr);
            indexPtr.* = indexExpr;

            current = ast.expr.ZSExpr{ .index_access = .{
                .subject = subjectPtr,
                .index = indexPtr,
                .startPos = current.start(),
                .endPos = endToken.endPos,
            } };
        } else {
            break;
        }
    }
    return current;
}

fn nextCharLiteral(self: *Self) Error!?ast.expr.ZSChar {
    const token = self.peekToken() catch return null;
    if (token.type != .char_literal) return null;
    self.shiftToken();

    const raw = token.value; // e.g., 'a' or '\n'
    // Strip surrounding quotes
    const inner = raw[1 .. raw.len - 1];
    const value: u8 = if (inner.len == 2 and inner[0] == '\\') switch (inner[1]) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '\\' => '\\',
        '\'' => '\'',
        '0' => 0,
        else => inner[1],
    } else inner[0];

    return ast.expr.ZSChar{
        .value = value,
        .startPos = token.startPos,
        .endPos = token.endPos,
    };
}

fn nextArrayLiteral(self: *Self) Error!?ast.expr.ZSArrayLiteral {
    if (!self.checkToken("[")) return null;
    const startToken = try self.peekToken();
    self.shiftToken(); // consume '['

    var elements = try std.ArrayList(ast.expr.ZSExpr).initCapacity(self.allocator, 4);
    defer elements.deinit(self.allocator);

    // Parse first element
    if (!self.checkToken("]")) {
        const firstElem = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
        try elements.append(self.allocator, firstElem);

        // Check for [value; count] repeat syntax
        if (self.checkToken(";")) {
            self.shiftToken(); // consume ';'
            const countToken = try self.peekToken();
            if (countToken.type != .numeric) return Error.UnexpectedTokenType;
            self.shiftToken();
            const count = std.fmt.parseInt(usize, countToken.value, 10) catch return Error.UnexpectedToken;
            // Already have 1 element, duplicate count-1 more times
            var i: usize = 1;
            while (i < count) : (i += 1) {
                try elements.append(self.allocator, try firstElem.clone(self.allocator));
            }
        } else {
            // Normal comma-separated list
            while (self.checkToken(",")) {
                self.shiftToken();
                if (self.checkToken("]")) break;
                const elem = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
                try elements.append(self.allocator, elem);
            }
        }
    }

    const endToken = try self.peekToken();
    try self.expectToken("]");

    return ast.expr.ZSArrayLiteral{
        .elements = try self.allocator.dupe(ast.expr.ZSExpr, elements.items),
        .startPos = startToken.startPos,
        .endPos = endToken.endPos,
    };
}

fn nextBinaryRhs(self: *Self, lhs: ast.expr.ZSExpr) Error!?ast.expr.ZSBinary {
    const op = blk: {
        if (self.checkToken("&&")) break :blk "&&";
        if (self.checkToken("||")) break :blk "||";
        if (self.checkToken("==")) break :blk "==";
        if (self.checkToken("!=")) break :blk "!=";
        if (self.checkToken(">=")) break :blk ">=";
        if (self.checkToken("<=")) break :blk "<=";
        if (self.checkToken(">")) break :blk ">";
        if (self.checkToken("<")) break :blk "<";
        if (self.checkToken("+")) break :blk "+";
        if (self.checkToken("-")) break :blk "-";
        if (self.checkToken("*")) break :blk "*";
        if (self.checkToken("/")) break :blk "/";
        if (self.checkToken("%")) break :blk "%";
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

fn nextWhileExpr(self: *Self) Error!?ast.expr.ZSWhileExpr {
    if (!(self.checkToken("while"))) return null;
    const whileToken = try self.peekToken();
    const startPos = whileToken.startPos;
    self.shiftToken();

    // Optional parens around condition
    const hasParen = self.checkToken("(");
    if (hasParen) self.shiftToken();

    const condition = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    const condPtr = try self.allocator.create(ast.expr.ZSExpr);
    condPtr.* = condition;

    if (hasParen) try self.expectToken(")");

    // Body: block or expression
    const bodyExpr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    const bodyPtr = try self.allocator.create(ast.expr.ZSExpr);
    bodyPtr.* = bodyExpr;

    return ast.expr.ZSWhileExpr{
        .condition = condPtr,
        .body = bodyPtr,
        .startPos = startPos,
        .endPos = bodyExpr.end(),
    };
}

fn nextForExpr(self: *Self) Error!?ast.expr.ZSForExpr {
    if (!(self.checkToken("for"))) return null;
    const forToken = try self.peekToken();
    const startPos = forToken.startPos;
    self.shiftToken();

    try self.expectToken("(");

    // Init: a variable declaration (let/const)
    const modifiers = try self.nextModifiers();
    const varDecl = try self.nextVar(modifiers) orelse return Error.UnexpectedEndOfInput;
    const initNode = try self.allocator.create(ast.ZSAstNode);
    initNode.* = ast.ZSAstNode{ .stmt = ast.stmt.ZSStmt{ .variable = varDecl } };

    try self.expectToken(";");

    // Condition
    const condition = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    const condPtr = try self.allocator.create(ast.expr.ZSExpr);
    condPtr.* = condition;

    try self.expectToken(";");

    // Step: a reassignment
    const reassign = try self.nextReassign() orelse return Error.UnexpectedEndOfInput;
    const stepNode = try self.allocator.create(ast.ZSAstNode);
    stepNode.* = ast.ZSAstNode{ .stmt = ast.stmt.ZSStmt{ .reassign = reassign } };

    try self.expectToken(")");

    // Body
    const bodyExpr = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    const bodyPtr = try self.allocator.create(ast.expr.ZSExpr);
    bodyPtr.* = bodyExpr;

    return ast.expr.ZSForExpr{
        .init = initNode,
        .condition = condPtr,
        .step = stepNode,
        .body = bodyPtr,
        .startPos = startPos,
        .endPos = bodyExpr.end(),
    };
}

fn nextBreak(self: *Self) Error!?ast.expr.ZSBreak {
    if (!(self.checkToken("break"))) return null;
    const token = try self.peekToken();
    self.shiftToken();
    return ast.expr.ZSBreak{
        .startPos = token.startPos,
        .endPos = token.endPos,
    };
}

fn nextContinue(self: *Self) Error!?ast.expr.ZSContinue {
    if (!(self.checkToken("continue"))) return null;
    const token = try self.peekToken();
    self.shiftToken();
    return ast.expr.ZSContinue{
        .startPos = token.startPos,
        .endPos = token.endPos,
    };
}

fn nextUnaryNot(self: *Self) Error!?ast.expr.ZSUnary {
    if (!(self.checkToken("!"))) return null;
    const token = try self.peekToken();
    self.shiftToken();
    const operand = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    const operandPtr = try self.allocator.create(ast.expr.ZSExpr);
    operandPtr.* = operand;
    return ast.expr.ZSUnary{
        .op = "!",
        .operand = operandPtr,
        .startPos = token.startPos,
        .endPos = operand.end(),
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

fn nextStruct(self: *Self, modifiers: ast.stmt.Modifiers) Error!?ast.stmt.ZSStruct {
    if (!self.checkToken("struct")) return null;
    const startToken = try self.peekToken();
    self.shiftToken();

    const name = try self.nextIdent();

    // Parse optional type parameters: <T, U>
    var type_params = try std.ArrayList([]const u8).initCapacity(self.allocator, 2);
    defer type_params.deinit(self.allocator);
    if (self.checkToken("<")) {
        self.shiftToken();
        while (true) {
            const paramName = try self.nextIdent();
            try type_params.append(self.allocator, paramName);
            if (self.checkToken(",")) {
                self.shiftToken();
                continue;
            }
            break;
        }
        try self.expectToken(">");
    }

    try self.expectToken("{");

    var fields = try std.ArrayList(ast.stmt.ZSStruct.ZSStructField).initCapacity(self.allocator, 4);
    defer fields.deinit(self.allocator);

    while (true) {
        if (self.checkToken("}")) break;
        const fieldName = try self.nextIdent();
        try self.expectToken(":");
        const fieldType = try self.nextTypeInner();
        try fields.append(self.allocator, .{ .name = fieldName, .type = fieldType });
        if (self.checkToken(",")) {
            self.shiftToken();
            continue;
        }
        break;
    }

    const endToken = try self.peekToken();
    try self.expectToken("}");

    return ast.stmt.ZSStruct{
        .name = name,
        .type_params = try self.allocator.dupe([]const u8, type_params.items),
        .fields = try self.allocator.dupe(ast.stmt.ZSStruct.ZSStructField, fields.items),
        .modifiers = modifiers,
        .startPos = startToken.startPos,
        .endPos = endToken.endPos,
    };
}

fn nextEnum(self: *Self, modifiers: ast.stmt.Modifiers) Error!?ast.stmt.ZSEnum {
    if (!self.checkToken("enum")) return null;
    const startToken = try self.peekToken();
    self.shiftToken();

    const name = try self.nextIdent();

    // Parse optional type parameters: <T, U>
    var type_params = try std.ArrayList([]const u8).initCapacity(self.allocator, 2);
    defer type_params.deinit(self.allocator);
    if (self.checkToken("<")) {
        self.shiftToken();
        while (true) {
            const paramName = try self.nextIdent();
            try type_params.append(self.allocator, paramName);
            if (self.checkToken(",")) {
                self.shiftToken();
                continue;
            }
            break;
        }
        try self.expectToken(">");
    }

    try self.expectToken("{");

    var variants = try std.ArrayList(ast.stmt.ZSEnum.ZSEnumVariant).initCapacity(self.allocator, 4);
    defer variants.deinit(self.allocator);

    while (true) {
        if (self.checkToken("}")) break;
        const variantName = try self.nextIdent();
        var payload_type: ?ast.ZSType = null;
        if (self.checkToken("(")) {
            self.shiftToken();
            payload_type = try self.nextTypeInner();
            try self.expectToken(")");
        }
        try variants.append(self.allocator, .{ .name = variantName, .payload_type = payload_type });
        if (self.checkToken(",")) {
            self.shiftToken();
            continue;
        }
        break;
    }

    const endToken = try self.peekToken();
    try self.expectToken("}");

    return ast.stmt.ZSEnum{
        .name = name,
        .type_params = try self.allocator.dupe([]const u8, type_params.items),
        .variants = try self.allocator.dupe(ast.stmt.ZSEnum.ZSEnumVariant, variants.items),
        .modifiers = modifiers,
        .startPos = startToken.startPos,
        .endPos = endToken.endPos,
    };
}

fn nextUse(self: *Self) Error!?ast.ZSUse {
    if (!self.checkToken("use")) return null;
    const startToken = try self.peekToken();
    self.shiftToken();

    const enumName = try self.nextIdent();
    try self.expectToken(".");
    try self.expectToken("{");

    var variants = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
    defer variants.deinit(self.allocator);

    while (true) {
        if (self.checkToken("}")) break;
        const variantName = try self.nextIdent();
        try variants.append(self.allocator, variantName);
        if (self.checkToken(",")) {
            self.shiftToken();
            continue;
        }
        break;
    }

    const endToken = try self.peekToken();
    try self.expectToken("}");

    return ast.ZSUse{
        .enum_name = enumName,
        .variants = try self.allocator.dupe([]const u8, variants.items),
        .startPos = startToken.startPos,
        .endPos = endToken.endPos,
    };
}

fn nextMatchExpr(self: *Self) Error!?ast.expr.ZSMatchExpr {
    if (!self.checkToken("match")) return null;
    const startToken = try self.peekToken();
    self.shiftToken();

    const subject = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
    const subjectPtr = try self.allocator.create(ast.expr.ZSExpr);
    subjectPtr.* = subject;

    try self.expectToken("{");

    var arms = try std.ArrayList(ast.expr.ZSMatchArm).initCapacity(self.allocator, 4);
    defer arms.deinit(self.allocator);

    while (true) {
        if (self.checkToken("}")) break;

        // Parse pattern: EnumName.VariantName or EnumName.VariantName(binding)
        const enumName = try self.nextIdent();
        try self.expectToken(".");
        const variantName = try self.nextIdent();

        var binding: ?[]const u8 = null;
        if (self.checkToken("(")) {
            self.shiftToken();
            binding = try self.nextIdent();
            try self.expectToken(")");
        }

        try self.expectToken("->");

        const body = try self.nextExpr() orelse return Error.UnexpectedEndOfInput;
        const bodyPtr = try self.allocator.create(ast.expr.ZSExpr);
        bodyPtr.* = body;

        try arms.append(self.allocator, .{
            .enum_name = enumName,
            .variant_name = variantName,
            .binding = binding,
            .body = bodyPtr,
        });

        if (self.checkToken(",")) {
            self.shiftToken();
            continue;
        }
        break;
    }

    const endToken = try self.peekToken();
    try self.expectToken("}");

    return ast.expr.ZSMatchExpr{
        .subject = subjectPtr,
        .arms = try self.allocator.dupe(ast.expr.ZSMatchArm, arms.items),
        .startPos = startToken.startPos,
        .endPos = endToken.endPos,
    };
}

fn nextType(self: *Self) !?ast.ZSType {
    if (!self.checkToken(":")) return null;
    self.shiftToken();

    return try self.nextTypeInner();
}

fn nextTypeInner(self: *Self) !ast.ZSType {
    // Check for array type: [elementType]
    if (self.checkToken("[")) {
        self.shiftToken(); // consume '['
        const elemType = try self.nextTypeInner();
        try self.expectToken("]");
        const elemPtr = try self.allocator.create(ast.type_notation.ZSType);
        elemPtr.* = elemType;
        return ast.ZSType{ .array = .{ .element_type = elemPtr } };
    }

    const typeName = try self.nextIdent();

    // Check for generic type args: Name<T, U>
    if (self.checkToken("<")) {
        self.shiftToken();
        var type_args = try std.ArrayList(ast.type_notation.ZSType).initCapacity(self.allocator, 2);
        defer type_args.deinit(self.allocator);

        while (true) {
            const arg = try self.nextTypeInner();
            try type_args.append(self.allocator, arg);
            if (self.checkToken(",")) {
                self.shiftToken();
                continue;
            }
            break;
        }
        try self.expectToken(">");

        return ast.ZSType{ .generic = .{
            .name = typeName,
            .type_args = try self.allocator.dupe(ast.type_notation.ZSType, type_args.items),
        } };
    }

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

fn nextNegativeNumber(self: *Self) Error!?ast.expr.ZSNumber {
    const token = try self.peekToken();
    if (token.type != .punctuation or !std.mem.eql(u8, token.value, "-")) return null;

    // Save state in case the next token is not numeric
    const savedPeeked = self.peekedToken;
    const savedPos = self.tokenizer.position;
    const savedLine = self.tokenizer.line;

    self.shiftToken(); // consume "-"
    const next = try self.peekToken();
    if (next.type != .numeric) {
        // Backtrack
        self.peekedToken = savedPeeked;
        self.tokenizer.position = savedPos;
        self.tokenizer.line = savedLine;
        return null;
    }
    self.shiftToken(); // consume the number

    const negValue = try std.fmt.allocPrint(self.allocator, "-{s}", .{next.value});
    return ast.expr.ZSNumber{
        .value = negValue,
        .startPos = token.startPos,
        .endPos = next.endPos,
        .allocated = true,
    };
}

fn nextString(self: *Self) !?ast.expr.ZSString {
    const token = try self.peekToken();
    if (token.type != .string) return null;
    self.shiftToken();
    const value: [:0]const u8 = blk: {
        if (std.mem.startsWith(u8, token.value, "\"") and std.mem.endsWith(u8, token.value, "\"")) {
            const slice = token.value[1..(token.value.len - 1)];
            // Process escape sequences
            var buf = try std.ArrayList(u8).initCapacity(self.allocator, slice.len);
            defer buf.deinit(self.allocator);
            var i: usize = 0;
            while (i < slice.len) {
                if (slice[i] == '\\' and i + 1 < slice.len) {
                    switch (slice[i + 1]) {
                        'n' => try buf.append(self.allocator, '\n'),
                        't' => try buf.append(self.allocator, '\t'),
                        'r' => try buf.append(self.allocator, '\r'),
                        '\\' => try buf.append(self.allocator, '\\'),
                        '"' => try buf.append(self.allocator, '"'),
                        '0' => try buf.append(self.allocator, 0),
                        else => {
                            try buf.append(self.allocator, slice[i]);
                            try buf.append(self.allocator, slice[i + 1]);
                        },
                    }
                    i += 2;
                } else {
                    try buf.append(self.allocator, slice[i]);
                    i += 1;
                }
            }
            const cStr = try self.allocator.allocSentinel(u8, buf.items.len, 0);
            @memcpy(cStr, buf.items);
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
    try std.testing.expectEqualStrings("int", f.args[0].type.?.typeName());
    try std.testing.expectEqualStrings("void", f.ret.?.typeName());
    try std.testing.expect(f.modifiers.external == null);
    try std.testing.expect(f.body == null);
}

test "parse external function" {
    const allocator = std.testing.allocator;
    const module = try testParse("external fn print(msg: String): void");
    defer module.deinit(allocator);
    const f = module.ast[0].stmt.function;
    try std.testing.expectEqualStrings("print", f.name);
    try std.testing.expectEqualStrings("msg", f.args[0].name);
    try std.testing.expectEqualStrings("String", f.args[0].type.?.typeName());
    try std.testing.expectEqualStrings("void", f.ret.?.typeName());
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
    try std.testing.expectEqualStrings("number", f.ret.?.typeName());
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

test "parse struct declaration" {
    const allocator = std.testing.allocator;
    const module = try testParse("struct Point { x: number, y: number }");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), module.ast.len);
    const sd = module.ast[0].stmt.struct_decl;
    try std.testing.expectEqualStrings("Point", sd.name);
    try std.testing.expectEqual(@as(usize, 0), sd.type_params.len);
    try std.testing.expectEqual(@as(usize, 2), sd.fields.len);
    try std.testing.expectEqualStrings("x", sd.fields[0].name);
    try std.testing.expectEqualStrings("number", sd.fields[0].type.typeName());
    try std.testing.expectEqualStrings("y", sd.fields[1].name);
    try std.testing.expectEqualStrings("number", sd.fields[1].type.typeName());
}

test "parse generic struct declaration" {
    const allocator = std.testing.allocator;
    const module = try testParse("struct Pair<T, U> { first: T, second: U }");
    defer module.deinit(allocator);
    const sd = module.ast[0].stmt.struct_decl;
    try std.testing.expectEqualStrings("Pair", sd.name);
    try std.testing.expectEqual(@as(usize, 2), sd.type_params.len);
    try std.testing.expectEqualStrings("T", sd.type_params[0]);
    try std.testing.expectEqualStrings("U", sd.type_params[1]);
    try std.testing.expectEqual(@as(usize, 2), sd.fields.len);
    try std.testing.expectEqualStrings("first", sd.fields[0].name);
    try std.testing.expectEqualStrings("T", sd.fields[0].type.typeName());
    try std.testing.expectEqualStrings("second", sd.fields[1].name);
    try std.testing.expectEqualStrings("U", sd.fields[1].type.typeName());
}

test "parse struct init expression" {
    const allocator = std.testing.allocator;
    const module = try testParse("struct Point { x: number, y: number } let p = Point { x: 10, y: 20 }");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), module.ast.len);
    const si = module.ast[1].stmt.variable.expr.struct_init;
    try std.testing.expectEqualStrings("Point", si.name);
    try std.testing.expectEqual(@as(usize, 2), si.field_values.len);
    try std.testing.expectEqualStrings("x", si.field_values[0].name);
    try std.testing.expectEqualStrings("10", si.field_values[0].value.number.value);
    try std.testing.expectEqualStrings("y", si.field_values[1].name);
    try std.testing.expectEqualStrings("20", si.field_values[1].value.number.value);
}

test "parse field access" {
    const allocator = std.testing.allocator;
    const module = try testParse("struct Point { x: number, y: number } let p = Point { x: 10, y: 20 } let v = p.x");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), module.ast.len);
    const fa = module.ast[2].stmt.variable.expr.field_access;
    try std.testing.expectEqualStrings("x", fa.field);
    try std.testing.expectEqualStrings("p", fa.subject.reference.name);
}

test "parse export from statement" {
    const allocator = std.testing.allocator;
    const module = try testParse("export { String, add as sum } from \"./lib.zs\"");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), module.ast.len);
    const ef = module.ast[0].export_from;
    try std.testing.expectEqualStrings("./lib.zs", ef.path);
    try std.testing.expectEqual(@as(usize, 2), ef.symbols.len);
    try std.testing.expectEqualStrings("String", ef.symbols[0].name);
    try std.testing.expect(ef.symbols[0].alias == null);
    try std.testing.expectEqualStrings("add", ef.symbols[1].name);
    try std.testing.expectEqualStrings("sum", ef.symbols[1].alias.?);
    // Should produce a dependency
    try std.testing.expectEqual(@as(usize, 1), module.deps.len);
    try std.testing.expectEqualStrings("./lib.zs", module.deps[0].path);
}

test "parse export from does not interfere with export fn" {
    const allocator = std.testing.allocator;
    const module = try testParse("export fn add(a: number): number = a");
    defer module.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), module.ast.len);
    const f = module.ast[0].stmt.function;
    try std.testing.expectEqualStrings("add", f.name);
    try std.testing.expect(f.modifiers.exported != null);
}

test "parse generic type annotation" {
    const allocator = std.testing.allocator;
    const module = try testParse("fn foo(x: Pointer<number>): Pair<number, String>");
    defer module.deinit(allocator);
    const f = module.ast[0].stmt.function;
    // Arg type: Pointer<number>
    const argType = f.args[0].type.?;
    try std.testing.expectEqual(ast.type_notation.ZSTypeType.generic, @as(ast.type_notation.ZSTypeType, argType));
    try std.testing.expectEqualStrings("Pointer", argType.generic.name);
    try std.testing.expectEqual(@as(usize, 1), argType.generic.type_args.len);
    try std.testing.expectEqualStrings("number", argType.generic.type_args[0].typeName());
    // Ret type: Pair<number, String>
    const retType = f.ret.?;
    try std.testing.expectEqual(ast.type_notation.ZSTypeType.generic, @as(ast.type_notation.ZSTypeType, retType));
    try std.testing.expectEqualStrings("Pair", retType.generic.name);
    try std.testing.expectEqual(@as(usize, 2), retType.generic.type_args.len);
    try std.testing.expectEqualStrings("number", retType.generic.type_args[0].typeName());
    try std.testing.expectEqualStrings("String", retType.generic.type_args[1].typeName());
}
