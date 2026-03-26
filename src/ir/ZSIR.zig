const std = @import("std");
const ZSIRType = enum { assign, call, fn_decl };

pub const ZSIRInstructions = struct {
    instructions: []ZSIR,
    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.instructions) |value| value.deinit(allocator);
        allocator.free(self.instructions);
    }
};

pub const ZSIR = union(ZSIRType) {
    assign: ZSIRAssign,
    call: ZSIRCall,
    fn_decl: ZSIRFnDecl,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assign => {
                self.assign.deinit(allocator);
            },
            .call => self.call.deinit(allocator),
            .fn_decl => self.fn_decl.deinit(allocator),
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.io.Writer, // The writer to write the output to
    ) !void {
        switch (self) {
            .assign => try writer.print("{f}", .{self.assign}),
            .call => try writer.print("{f}", .{self.call}),
            .fn_decl => {},
        }
    }
};

const ZSIRValueType = enum { number, string };
pub const ZSIRValue = union(ZSIRValueType) {
    number: i32,
    string: [:0]const u8,

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
        allocator.free(self.resultName);
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

pub const ZSIRFnDecl = struct {
    name: []const u8,
    argTypes: []const []const u8,
    retType: []const u8,
    external: bool,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.argTypes);
    }
};
