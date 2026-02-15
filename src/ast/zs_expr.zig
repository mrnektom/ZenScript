const std = @import("std");
pub const ZSCall = @import("zs_call.zig");

const ZSExprType = enum {
    number,
    string,
    call,
    reference,
};

pub const ZSExpr = union(ZSExprType) {
    number: ZSNumber,
    string: ZSString,
    call: ZSCall,
    reference: ZSReference,
    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        std.debug.print("Deinit: {s}\n", .{@typeName(@This())});
        switch (self.*) {
            .call => self.call.deinit(allocator),
            .string, .number, .reference => {},
        }
    }
};

pub const ZSNumber = struct { value: []const u8 };
pub const ZSString = struct { value: []const u8 };
pub const ZSReference = struct { name: []const u8 };
