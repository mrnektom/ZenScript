const std = @import("std");
const zsm = @import("../ast/zs_module.zig");
const ast = @import("../ast/ast_node.zig");
const sig = @import("symbol_signature.zig");
const sts = @import("symbol_table_stack.zig");
const Symbol = @import("symbol.zig");
const AnalyzeError = @import("AnalazeError.zig");
const SymbolTable = sts.SymbolTable;
const Self = @This();

tableStack: *sts,
errors: *std.ArrayList(AnalyzeError),
allocator: std.mem.Allocator,
module: zsm.ZSModule,

const Error = error{} || std.mem.Allocator.Error;

pub const AnalyzeResult = struct {
    exports: SymbolTable,
    errors: []AnalyzeError,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.errors);
        self.exports.deinit();
    }
};

pub fn analyze(module: zsm.ZSModule, allocator: std.mem.Allocator) !AnalyzeResult {
    var errors = try std.ArrayList(AnalyzeError).initCapacity(allocator, 1);
    defer errors.deinit(allocator);
    var tableStack = try sts.create(allocator);
    defer tableStack.deinit();
    var analyzer = Self{
        .tableStack = &tableStack,
        .errors = &errors,
        .allocator = allocator,
        .module = module,
    };
    var table = SymbolTable.init(allocator);
    try tableStack.enterScope(&table);
    try analyzer.analyzeModule(module);
    _ = try tableStack.exitScope();

    return .{
        .exports = table,
        .errors = try allocator.dupe(AnalyzeError, errors.items),
    };
}

fn analyzeModule(self: *Self, module: zsm.ZSModule) !void {
    for (module.ast) |node| {
        if (try self.analyzeNode(node)) |symbol| {
            try self.tableStack.put(symbol);
        }
    }
}

fn analyzeNode(self: *Self, node: ast.ZSAstNode) !?Symbol {
    return switch (node) {
        .stmt => try self.analyzeStmt(node.stmt),
        .expr => b: {
            _ = try self.analyzeExpr(node.expr);
            break :b null;
        },
    };
}

fn analyzeStmt(self: *Self, stmt: ast.stmt.ZSStmt) !?Symbol {
    return switch (stmt) {
        .variable => try self.analyzeVariable(stmt.variable),
        .function => try self.analyzeFunction(stmt.function),
    };
}

fn analyzeExpr(self: *Self, expr: ast.expr.ZSExpr) !Symbol.ZSType {
    // std.debug.print("{}\n", .{});
    return switch (expr) {
        .number => Symbol.ZSType.number,
        .string => Symbol.ZSType.string,
        .call => self.analyzeCall(expr.call),
        .reference => self.analyzeReference(expr.reference),
    };
}

fn analyzeVariable(self: *Self, variable: ast.stmt.ZSVar) !Symbol {
    const stype = try self.analyzeExpr(variable.expr);
    return .{ .name = variable.name, .assignable = variable.type == .Let, .signature = stype };
}

fn analyzeFunction(self: *Self, function: ast.stmt.ZSFn) !Symbol {
    const ret = try self.analyzeType(&function.ret);
    const args = try self.analyzeFnArgs(function.args);
    return .{
        .name = function.name,
        .assignable = false,
        .signature = Symbol.ZSType{
            .function = .{
                .ret = &ret,
                .args = args,
            },
        },
    };
}

fn analyzeType(self: *Self, ret: *const ?ast.ZSType) !Symbol.ZSType {
    _ = self;
    if (ret.*) |r| {
        return switch (r) {
            .reference => .unknown,
        };
    }
    return .unknown;
}

fn analyzeBuiltin(self: *Self, builtin: ast.ZSBuiltin) !Symbol.ZSType {
    _ = self;
    return switch (builtin) {
        .number => Symbol.ZSType.number,
    };
}

fn analyzeFnArgs(self: *Self, args: []ast.stmt.ZSFn.Arg) ![]Symbol.sig.ZSFnArg {
    _ = self;
    _ = args;

    return &[_]Symbol.sig.ZSFnArg{};
}

fn analyzeCall(self: *Self, call: ast.expr.ZSCall) Error!Symbol.ZSType {
    const subjectType = try self.analyzeExpr(call.subject.*);
    return switch (subjectType) {
        .function => subjectType.function.ret.*,
        .unknown => Symbol.ZSType.unknown,
        else => blk: {
            try self.recordError(call, "Subject is not a function");
            break :blk Symbol.ZSType.unknown;
        },
    };
}

fn analyzeReference(self: *Self, ref: ast.expr.ZSReference) !Symbol.ZSType {
    if (self.tableStack.get(ref.name)) |sym| {
        return sym.signature;
    }
    try self.recordError(ref, "Reference not found");
    return Symbol.ZSType.unknown;
}

fn recordError(
    self: *Self,
    expr: anytype,
    message: []const u8,
) Error!void {
    const root = @import("ZenScript");
    const startPos = expr.startPos;
    const endPos = expr.endPos;
    try self.errors.append(self.allocator, .{
        .message = message,
        .filename = self.module.filename,
        .start = startPos,
        .end = endPos,
        .codeLine = root.SourceHelpers.computeSourceLine(self.module.source, startPos),
        .lineNumber = root.SourceHelpers.computeLineNumber(self.module.source, startPos),
        .lineCol = root.SourceHelpers.computeLineOffset(self.module.source, startPos),
    });
}
