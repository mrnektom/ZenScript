const std = @import("std");
pub const Var = @import("zs_stmt_var.zig");

pub const VarType = Var.VariableType;

pub const ZSStmtType = enum { variable };

pub const ZSStmt = union(ZSStmtType) {
    variable: Var,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        std.debug.print("Deinit: {s}\n", .{@typeName(@This())});
        switch (self.*) {
            .variable => self.variable.deinit(allocator),
        }
    }
};
