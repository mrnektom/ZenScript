const std = @import("std");
pub const expr = @import("zs_expr.zig");
pub const stmt = @import("zs_stmt.zig");

pub const VarType = stmt.VarType;

const ZSAstType = enum {
    stmt,
    expr,
};

pub const ZSAstNode = union(ZSAstType) {
    stmt: stmt.ZSStmt,
    expr: expr.ZSExpr,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        std.debug.print("Deinit: {s}\n", .{@typeName(@This())});
        switch (self.*) {
            .expr => self.expr.deinit(allocator),
            .stmt => self.stmt.deinit(allocator),
        }
    }
};
