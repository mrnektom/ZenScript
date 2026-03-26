const std = @import("std");
pub const ZSVar = @import("zs_stmt_var.zig");
pub const ZSFn = @import("zs_stmt_fn.zig");

pub const VarType = ZSVar.VariableType;

pub const ZSStmtType = enum {
    variable,
    function,
};

pub const ZSStmt = union(ZSStmtType) {
    variable: ZSVar,
    function: ZSFn,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .variable => self.variable.deinit(allocator),
            .function => {
                if (self.function.body) |*b| {
                    b.deinit(allocator);
                }
                allocator.free(self.function.args);
            },
        }
    }
};

pub const Modifiers = struct {
    external: ?Modifier,
};

pub const Modifier = struct { start: usize, end: usize };
