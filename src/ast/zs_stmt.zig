const std = @import("std");
pub const ZSVar = @import("zs_stmt_var.zig");

pub const VarType = ZSVar.VariableType;

pub const ZSStmtType = enum { variable };

pub const ZSStmt = union(ZSStmtType) {
    variable: ZSVar,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .variable => self.variable.deinit(allocator),
        }
    }
};
