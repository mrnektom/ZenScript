const std = @import("std");
pub const ZSVar = @import("zs_stmt_var.zig");
pub const ZSFn = @import("zs_stmt_fn.zig");
pub const ZSReassign = @import("zs_stmt_reassign.zig");
pub const ZSStruct = @import("zs_stmt_struct.zig");
pub const ZSEnum = @import("zs_stmt_enum.zig");

pub const VarType = ZSVar.VariableType;

pub const ZSStmtType = enum {
    variable,
    function,
    reassign,
    struct_decl,
    enum_decl,
};

pub const ZSStmt = union(ZSStmtType) {
    variable: ZSVar,
    function: ZSFn,
    reassign: ZSReassign,
    struct_decl: ZSStruct,
    enum_decl: ZSEnum,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .variable => self.variable.deinit(allocator),
            .function => {
                if (self.function.body) |*b| {
                    b.deinit(allocator);
                }
                for (self.function.args) |*arg| {
                    if (arg.type) |*t| {
                        t.deinit(allocator);
                    }
                }
                if (self.function.ret) |*r| {
                    r.deinit(allocator);
                }
                allocator.free(self.function.args);
                allocator.free(self.function.type_params);
            },
            .reassign => self.reassign.deinit(allocator),
            .struct_decl => self.struct_decl.deinit(allocator),
            .enum_decl => self.enum_decl.deinit(allocator),
        }
    }
};

pub const Modifiers = struct {
    external: ?Modifier,
    exported: ?Modifier,
};

pub const Modifier = struct { start: usize, end: usize };
