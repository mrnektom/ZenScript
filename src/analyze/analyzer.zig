const std = @import("std");
const zsm = @import("../ast/zs_module.zig");
const ast = @import("../ast/ast_node.zig");
const Symbol = @import("symbol.zig");
const sts = @import("symbol_table_stack.zig");
const SymbolTable = sts.SymbolTable;
const Self = @This();

tableStack: *sts,

pub const AnalyzeResult = struct {
    exports: []Symbol,
};

pub fn analyze(module: zsm.ZSModule, allocator: std.mem.Allocator) !SymbolTable {
    var tableStack = try sts.create(allocator);
    defer tableStack.deinit();
    var analyzer = Self{ .tableStack = &tableStack };
    var table = SymbolTable.init(allocator);
    try tableStack.enterScope(&table);
    try analyzer.analyzeModule(module);
    _ = try tableStack.exitScope();

    return table;
}

fn analyzeModule(self: *Self, module: zsm.ZSModule) !void {
    for (module.ast) |node| {
        if (self.analyzeNode(node)) |symbol| {
            try self.tableStack.put(symbol);
        }
    }
}

fn analyzeNode(self: *Self, node: ast.ZSAstNode) ?Symbol {
    return switch (node) {
        .stmt => self.analyzeStmt(node.stmt),
        .expr => b: {
            _ = self.analyzeExpr(node.expr);
            break :b null;
        },
    };
}

fn analyzeStmt(self: *Self, stmt: ast.stmt.ZSStmt) ?Symbol {
    return switch (stmt) {
        .variable => self.analyzeVariable(stmt.variable),
    };
}

fn analyzeExpr(self: *Self, expr: ast.expr.ZSExpr) Symbol.ZSType {
    // std.debug.print("{}\n", .{});
    return switch (expr) {
        .number => Symbol.ZSType.number,
        .string => Symbol.ZSType.string,
        .call => self.analyzeCall(expr.call),
        .reference => self.analyzeReference(expr.reference),
    };
}

fn analyzeVariable(self: *Self, variable: ast.stmt.ZSVar) Symbol {
    const stype = self.analyzeExpr(variable.expr);
    return .{ .name = variable.name, .assignable = variable.type == .Let, .signature = stype };
}

fn analyzeCall(self: *Self, call: ast.expr.ZSCall) Symbol.ZSType {
    const subjectType = self.analyzeExpr(call.subject.*);

    return subjectType;
}

fn analyzeReference(self: *Self, ref: ast.expr.ZSReference) Symbol.ZSType {
    if (self.tableStack.get(ref.name)) |sym| {
        return sym.signature;
    }

    return Symbol.ZSType.unknown;
}
