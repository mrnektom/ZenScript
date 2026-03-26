const std = @import("std");
pub const ZSVar = @import("zs_stmt_var.zig");
pub const ZSFn = @import("zs_stmt_fn.zig");
pub const ZSReassign = @import("zs_stmt_reassign.zig");

pub const VarType = ZSVar.VariableType;

pub const ZSStmtType = enum {
    variable,
    function,
    reassign,
};

pub const ZSStmt = union(ZSStmtType) {
    variable: ZSVar,
    function: ZSFn,
    reassign: ZSReassign,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .variable => self.variable.deinit(allocator),
            .function => {
                if (self.function.body) |*b| {
                    b.deinit(allocator);
                }
                allocator.free(self.function.args);
            },
            .reassign => self.reassign.deinit(allocator),
        }
    }
};

pub const Modifiers = struct {
    external: ?Modifier,
};

pub const Modifier = struct { start: usize, end: usize };
