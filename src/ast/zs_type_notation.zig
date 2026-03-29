const std = @import("std");

pub const ZSTypeType = enum { reference, generic };

pub const ZSType = union(ZSTypeType) {
    reference: []const u8,
    generic: ZSGenericType,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .generic => |g| g.deinit(allocator),
            .reference => {},
        }
    }

    /// Returns the base type name (reference name or generic base name).
    pub fn typeName(self: @This()) []const u8 {
        return switch (self) {
            .reference => |ref| ref,
            .generic => |g| g.name,
        };
    }
};

pub const ZSGenericType = struct {
    name: []const u8,
    type_args: []ZSType,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.type_args) |*arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.type_args);
    }
};

pub const BuiltinType = enum { number };
