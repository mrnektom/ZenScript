const std = @import("std");
const ZSIRType = enum { assign, call, fn_decl, fn_def, ret, branch, compare };

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
    fn_def: ZSIRFnDef,
    ret: ZSIRRet,
    branch: ZSIRBranch,
    compare: ZSIRCompare,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assign => self.assign.deinit(allocator),
            .call => self.call.deinit(allocator),
            .fn_decl => self.fn_decl.deinit(allocator),
            .fn_def => self.fn_def.deinit(allocator),
            .ret => self.ret.deinit(allocator),
            .branch => self.branch.deinit(allocator),
            .compare => self.compare.deinit(allocator),
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.io.Writer,
    ) !void {
        switch (self) {
            .assign => try writer.print("{f}", .{self.assign}),
            .call => try writer.print("{f}", .{self.call}),
            .fn_decl, .fn_def, .ret, .branch, .compare => {},
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

pub const ZSIRFnDef = struct {
    name: []const u8,
    argTypes: []const []const u8,
    argNames: []const []const u8,
    retType: []const u8,
    body: []ZSIR,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.body) |inst| inst.deinit(allocator);
        allocator.free(self.body);
        allocator.free(self.argTypes);
        allocator.free(self.argNames);
    }
};

pub const ZSIRRet = struct {
    value: ?[]const u8,

    pub fn deinit(_: *const @This(), _: std.mem.Allocator) void {}
};

pub const ZSIRBranch = struct {
    condition: []const u8,
    thenBody: []ZSIR,
    elseBody: []ZSIR,
    resultName: ?[]const u8,
    thenResult: ?[]const u8,
    elseResult: ?[]const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.thenBody) |inst| inst.deinit(allocator);
        allocator.free(self.thenBody);
        for (self.elseBody) |inst| inst.deinit(allocator);
        allocator.free(self.elseBody);
        if (self.resultName) |n| allocator.free(n);
    }
};

pub const ZSIRCompare = struct {
    resultName: []const u8,
    lhs: []const u8,
    rhs: []const u8,
    op: []const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
    }
};
