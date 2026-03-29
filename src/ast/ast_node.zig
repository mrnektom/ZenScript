const std = @import("std");
pub const expr = @import("zs_expr.zig");
pub const stmt = @import("zs_stmt.zig");
pub const type_notation = @import("zs_type_notation.zig");
pub const zs_import = @import("zs_import.zig");
pub const zs_export_from = @import("zs_export_from.zig");

pub const VarType = stmt.VarType;

pub const ZSType = type_notation.ZSType;
pub const ZSBuiltin = type_notation.BuiltinType;
pub const ZSImport = zs_import;
pub const ZSExportFrom = zs_export_from;

const ZSAstType = enum {
    stmt,
    expr,
    import_decl,
    export_from,
};

pub const ZSAstNode = union(ZSAstType) {
    stmt: stmt.ZSStmt,
    expr: expr.ZSExpr,
    import_decl: ZSImport,
    export_from: ZSExportFrom,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .expr => self.expr.deinit(allocator),
            .stmt => self.stmt.deinit(allocator),
            .import_decl => self.import_decl.deinit(allocator),
            .export_from => self.export_from.deinit(allocator),
        }
    }
};
