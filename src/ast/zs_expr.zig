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
        switch (self.*) {
            .call => self.call.deinit(allocator),
            .string => self.string.deinit(allocator),
            .number, .reference => {},
        }
    }

    pub fn start(self: *const @This()) usize {
        return switch (self.*) {
            .number => self.number.startPos,
            .string => self.string.startPos,
            .call => self.call.startPos,
            .reference => self.reference.startPos,
        };
    }

    pub fn end(self: *const @This()) usize {
        return switch (self.*) {
            .number => self.number.endPos,
            .string => self.string.endPos,
            .call => self.call.endPos,
            .reference => self.reference.endPos,
        };
    }
};

pub const ZSNumber = struct {
    value: []const u8,
    startPos: usize,
    endPos: usize,
};
pub const ZSString = struct {
    value: [:0]const u8,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};
pub const ZSReference = struct {
    name: []const u8,
    startPos: usize,
    endPos: usize,
};
