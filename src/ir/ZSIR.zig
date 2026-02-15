const std = @import("std");
const ZSIRType = enum { assign, call };

pub const ZSIR = union(ZSIRType) {
    assign: ZSIRAssign,
    call: ZSIRCall,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        std.debug.print("Deinit: {s}\n", .{@typeName(@This())});
        switch (self.*) {
            .assign => {
                self.assign.deinit(allocator);
            },
            .call => self.call.deinit(allocator),
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.io.Writer, // The writer to write the output to
    ) !void {
        switch (self) {
            .assign => try writer.print("{f}", .{self.assign}),
            .call => try writer.print("{f}", .{self.call}),
        }
    }
};

const ZSIRValueType = enum { number, string };
pub const ZSIRValue = union(ZSIRValueType) {
    number: []const u8,
    string: []const u8,

    pub fn format(
        self: @This(),
        writer: *std.io.Writer,
    ) !void {
        const value = switch (self) {
            .number => self.number,
            .string => self.string,
        };
        try writer.print("{s}", .{value});
    }
};

pub const ZSIRAssign = struct {
    varName: []const u8,
    value: ZSIRValue,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        std.debug.print("Deinit: {s}\n", .{@typeName(@This())});
        allocator.free(self.varName);
    }

    pub fn format(
        self: @This(),
        writer: *std.io.Writer,
    ) !void {
        try writer.print("{s} = {f}", .{ self.varName, self.value });
    }
};

pub const ZSIRCall = struct {
    resultName: []const u8,
    fnName: []const u8,
    argNames: [][]const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        std.debug.print("Deinit: {s}\n", .{@typeName(@This())});
        allocator.free(self.resultName);
        // allocator.free(self.fnName);
        allocator.free(self.argNames);
    }

    pub fn format(
        self: @This(),
        writer: *std.io.Writer,
    ) !void {
        try writer.print("{s} = {s}(", .{ self.resultName, self.fnName });
        for (self.argNames, 0..) |argname, index| {
            try writer.print("{s}", .{argname});
            if (index < self.argNames.len - 1) try writer.print("{s}", .{argname});
        }
        try writer.print(")", .{});
    }
};
