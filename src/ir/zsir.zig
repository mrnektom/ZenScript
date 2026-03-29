const std = @import("std");
const ZSIRType = enum { assign, store, call, fn_decl, fn_def, ret, branch, compare, arith, loop, module_init, struct_init, field_access, ptr_op, deref_op, array_init, index_access, index_store, enum_init, match_expr, enum_decl };

pub const ZSIRInstructions = struct {
    instructions: []ZSIR,
    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.instructions) |value| value.deinit(allocator);
        allocator.free(self.instructions);
    }
};

pub const ZSIR = union(ZSIRType) {
    assign: ZSIRAssign,
    store: ZSIRStore,
    call: ZSIRCall,
    fn_decl: ZSIRFnDecl,
    fn_def: ZSIRFnDef,
    ret: ZSIRRet,
    branch: ZSIRBranch,
    compare: ZSIRCompare,
    arith: ZSIRArith,
    loop: ZSIRLoop,
    module_init: ZSIRModuleInit,
    struct_init: ZSIRStructInit,
    field_access: ZSIRFieldAccess,
    ptr_op: ZSIRPtrOp,
    deref_op: ZSIRDerefOp,
    array_init: ZSIRArrayInit,
    index_access: ZSIRIndexAccess,
    index_store: ZSIRIndexStore,
    enum_init: ZSIREnumInit,
    match_expr: ZSIRMatch,
    enum_decl: ZSIREnumDecl,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assign => self.assign.deinit(allocator),
            .store => self.store.deinit(allocator),
            .call => self.call.deinit(allocator),
            .fn_decl => self.fn_decl.deinit(allocator),
            .fn_def => self.fn_def.deinit(allocator),
            .ret => self.ret.deinit(allocator),
            .branch => self.branch.deinit(allocator),
            .compare => self.compare.deinit(allocator),
            .arith => self.arith.deinit(allocator),
            .loop => self.loop.deinit(allocator),
            .module_init => self.module_init.deinit(allocator),
            .struct_init => self.struct_init.deinit(allocator),
            .field_access => self.field_access.deinit(allocator),
            .ptr_op => self.ptr_op.deinit(allocator),
            .deref_op => self.deref_op.deinit(allocator),
            .array_init => self.array_init.deinit(allocator),
            .index_access => self.index_access.deinit(allocator),
            .index_store => self.index_store.deinit(allocator),
            .enum_init => self.enum_init.deinit(allocator),
            .match_expr => self.match_expr.deinit(allocator),
            .enum_decl => self.enum_decl.deinit(allocator),
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.io.Writer,
    ) !void {
        switch (self) {
            .assign => try writer.print("{f}", .{self.assign}),
            .call => try writer.print("{f}", .{self.call}),
            .store, .fn_decl, .fn_def, .ret, .branch, .compare, .arith, .loop, .module_init, .struct_init, .field_access, .ptr_op, .deref_op, .array_init, .index_access, .index_store, .enum_init, .match_expr, .enum_decl => {},
        }
    }
};

const ZSIRValueType = enum { number, string, boolean, char };
pub const ZSIRValue = union(ZSIRValueType) {
    number: i32,
    string: [:0]const u8,
    boolean: bool,
    char: u8,

    pub fn format(
        self: @This(),
        writer: *std.io.Writer,
    ) !void {
        const value = switch (self) {
            .number => self.number,
            .string => self.string,
            .char, .boolean => return,
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

pub const ZSIRStore = struct {
    target: []const u8,
    value: []const u8,

    pub fn deinit(_: *const @This(), _: std.mem.Allocator) void {}
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
        allocator.free(self.name);
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
        allocator.free(self.name);
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

pub const ZSIRArith = struct {
    resultName: []const u8,
    lhs: []const u8,
    rhs: []const u8,
    op: []const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
    }
};

pub const ZSIRLoop = struct {
    condition: []ZSIR,
    conditionName: []const u8,
    body: []ZSIR,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.condition) |inst| inst.deinit(allocator);
        allocator.free(self.condition);
        for (self.body) |inst| inst.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const ZSIRModuleInit = struct {
    name: []const u8,

    pub fn deinit(_: *const @This(), _: std.mem.Allocator) void {}
};

pub const ZSIRFieldValue = struct {
    name: []const u8,
    value: []const u8,
};

pub const ZSIRStructInit = struct {
    resultName: []const u8,
    structName: []const u8,
    fields: []ZSIRFieldValue,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
        allocator.free(self.fields);
    }
};

pub const ZSIRFieldAccess = struct {
    resultName: []const u8,
    subject: []const u8,
    field: []const u8,
    fieldIndex: u32,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
    }
};

pub const ZSIRPtrOp = struct {
    resultName: []const u8,
    operand: []const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
    }
};

pub const ZSIRDerefOp = struct {
    resultName: []const u8,
    operand: []const u8,
    pointeeType: []const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
    }
};

pub const ZSIRArrayInit = struct {
    resultName: []const u8,
    elementType: []const u8,
    elements: []const []const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
        allocator.free(self.elements);
    }
};

pub const ZSIRIndexAccess = struct {
    resultName: []const u8,
    subject: []const u8,
    index: []const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
    }
};

pub const ZSIRIndexStore = struct {
    subject: []const u8,
    index: []const u8,
    value: []const u8,

    pub fn deinit(_: *const @This(), _: std.mem.Allocator) void {}
};

pub const ZSIREnumInit = struct {
    resultName: []const u8,
    enumName: []const u8,
    variantTag: u32,
    payload: ?[]const u8,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.resultName);
    }
};

pub const ZSIRMatchArm = struct {
    variantTag: u32,
    binding: ?[]const u8,
    body: []ZSIR,
    resultName: ?[]const u8,
};

pub const ZSIRMatch = struct {
    resultName: ?[]const u8,
    subject: []const u8,
    enumName: []const u8,
    arms: []ZSIRMatchArm,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        if (self.resultName) |n| allocator.free(n);
        for (self.arms) |arm| {
            if (arm.binding) |b| allocator.free(b);
            for (arm.body) |inst| inst.deinit(allocator);
            allocator.free(arm.body);
        }
        allocator.free(self.arms);
    }
};

pub const ZSIREnumVariantDef = struct {
    name: []const u8,
    tag: u32,
    payloadType: ?[]const u8,
};

pub const ZSIREnumDecl = struct {
    name: []const u8,
    variants: []ZSIREnumVariantDef,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.variants);
    }
};
