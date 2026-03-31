const std = @import("std");
pub const ZSCall = @import("zs_call.zig");
const ast_node = @import("ast_node.zig");

const ZSExprType = enum {
    number,
    string,
    char,
    boolean,
    call,
    reference,
    if_expr,
    while_expr,
    for_expr,
    binary,
    unary,
    block,
    return_expr,
    break_expr,
    continue_expr,
    struct_init,
    field_access,
    array_literal,
    index_access,
    enum_init,
    match_expr,
};

pub const ZSExpr = union(ZSExprType) {
    number: ZSNumber,
    string: ZSString,
    char: ZSChar,
    boolean: ZSBoolean,
    call: ZSCall,
    reference: ZSReference,
    if_expr: ZSIfExpr,
    while_expr: ZSWhileExpr,
    for_expr: ZSForExpr,
    binary: ZSBinary,
    unary: ZSUnary,
    block: ZSBlock,
    return_expr: ZSReturn,
    break_expr: ZSBreak,
    continue_expr: ZSContinue,
    struct_init: ZSStructInit,
    field_access: ZSFieldAccess,
    array_literal: ZSArrayLiteral,
    index_access: ZSIndexAccess,
    enum_init: ZSEnumInit,
    match_expr: ZSMatchExpr,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .call => self.call.deinit(allocator),
            .string => self.string.deinit(allocator),
            .if_expr => self.if_expr.deinit(allocator),
            .while_expr => self.while_expr.deinit(allocator),
            .for_expr => self.for_expr.deinit(allocator),
            .binary => self.binary.deinit(allocator),
            .unary => self.unary.deinit(allocator),
            .block => self.block.deinit(allocator),
            .return_expr => self.return_expr.deinit(allocator),
            .struct_init => self.struct_init.deinit(allocator),
            .field_access => self.field_access.deinit(allocator),
            .array_literal => self.array_literal.deinit(allocator),
            .index_access => self.index_access.deinit(allocator),
            .enum_init => self.enum_init.deinit(allocator),
            .match_expr => self.match_expr.deinit(allocator),
            .number => self.number.deinit(allocator),
            .char, .boolean, .reference, .break_expr, .continue_expr => {},
        }
    }

    pub const CloneError = error{UnsupportedClone} || std.mem.Allocator.Error;

    pub fn clone(self: ZSExpr, allocator: std.mem.Allocator) CloneError!ZSExpr {
        return switch (self) {
            .number, .char, .boolean, .reference, .break_expr, .continue_expr => self,
            .string => |s| {
                const duped = try allocator.dupeZ(u8, s.value);
                return ZSExpr{ .string = .{ .value = duped, .startPos = s.startPos, .endPos = s.endPos } };
            },
            else => CloneError.UnsupportedClone,
        };
    }

    pub fn start(self: *const @This()) usize {
        return switch (self.*) {
            .number => self.number.startPos,
            .string => self.string.startPos,
            .char => self.char.startPos,
            .boolean => self.boolean.startPos,
            .call => self.call.startPos,
            .reference => self.reference.startPos,
            .if_expr => self.if_expr.startPos,
            .while_expr => self.while_expr.startPos,
            .for_expr => self.for_expr.startPos,
            .binary => self.binary.startPos,
            .unary => self.unary.startPos,
            .block => self.block.startPos,
            .return_expr => self.return_expr.startPos,
            .break_expr => self.break_expr.startPos,
            .continue_expr => self.continue_expr.startPos,
            .struct_init => self.struct_init.startPos,
            .field_access => self.field_access.startPos,
            .array_literal => self.array_literal.startPos,
            .index_access => self.index_access.startPos,
            .enum_init => self.enum_init.startPos,
            .match_expr => self.match_expr.startPos,
        };
    }

    pub fn end(self: *const @This()) usize {
        return switch (self.*) {
            .number => self.number.endPos,
            .string => self.string.endPos,
            .char => self.char.endPos,
            .boolean => self.boolean.endPos,
            .call => self.call.endPos,
            .reference => self.reference.endPos,
            .if_expr => self.if_expr.endPos,
            .while_expr => self.while_expr.endPos,
            .for_expr => self.for_expr.endPos,
            .binary => self.binary.endPos,
            .unary => self.unary.endPos,
            .block => self.block.endPos,
            .return_expr => self.return_expr.endPos,
            .break_expr => self.break_expr.endPos,
            .continue_expr => self.continue_expr.endPos,
            .struct_init => self.struct_init.endPos,
            .field_access => self.field_access.endPos,
            .array_literal => self.array_literal.endPos,
            .index_access => self.index_access.endPos,
            .enum_init => self.enum_init.endPos,
            .match_expr => self.match_expr.endPos,
        };
    }
};

pub const ZSNumber = struct {
    value: []const u8,
    startPos: usize,
    endPos: usize,
    allocated: bool = false,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        if (self.allocated) {
            allocator.free(self.value);
        }
    }
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
pub const ZSBoolean = struct {
    value: bool,
    startPos: usize,
    endPos: usize,
};

pub const ZSIfExpr = struct {
    condition: *ZSExpr,
    then_branch: *ZSExpr,
    else_branch: ?*ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        allocator.destroy(self.condition);
        self.then_branch.deinit(allocator);
        allocator.destroy(self.then_branch);
        if (self.else_branch) |eb| {
            eb.deinit(allocator);
            allocator.destroy(eb);
        }
    }
};

pub const ZSWhileExpr = struct {
    condition: *ZSExpr,
    body: *ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        allocator.destroy(self.condition);
        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};

pub const ZSBinary = struct {
    lhs: *ZSExpr,
    op: []const u8,
    rhs: *ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.lhs.deinit(allocator);
        allocator.destroy(self.lhs);
        self.rhs.deinit(allocator);
        allocator.destroy(self.rhs);
    }
};

pub const ZSBlock = struct {
    stmts: []ast_node.ZSAstNode,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.stmts) |node| {
            node.deinit(allocator);
        }
        allocator.free(self.stmts);
    }
};

pub const ZSReturn = struct {
    value: ?*ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        if (self.value) |v| {
            v.deinit(allocator);
            allocator.destroy(v);
        }
    }
};

pub const ZSFieldInit = struct {
    name: []const u8,
    value: ZSExpr,
};

pub const ZSStructInit = struct {
    name: []const u8,
    field_values: []ZSFieldInit,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.field_values) |*fv| {
            fv.value.deinit(allocator);
        }
        allocator.free(self.field_values);
    }
};

pub const ZSFieldAccess = struct {
    subject: *ZSExpr,
    field: []const u8,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.subject.deinit(allocator);
        allocator.destroy(self.subject);
    }
};

pub const ZSChar = struct {
    value: u8,
    startPos: usize,
    endPos: usize,
};

pub const ZSArrayLiteral = struct {
    elements: []ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.elements) |*elem| {
            elem.deinit(allocator);
        }
        allocator.free(self.elements);
    }
};

pub const ZSIndexAccess = struct {
    subject: *ZSExpr,
    index: *ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.subject.deinit(allocator);
        allocator.destroy(self.subject);
        self.index.deinit(allocator);
        allocator.destroy(self.index);
    }
};

pub const ZSEnumInit = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    payload: ?*ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        if (self.payload) |p| {
            p.deinit(allocator);
            allocator.destroy(p);
        }
    }
};

pub const ZSEnumVariantPattern = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    binding: ?[]const u8,
};

pub const ZSStructFieldPattern = struct {
    name: []const u8,
    binding_name: ?[]const u8,
    value_pattern: ?*ZSMatchArmPattern,
};

pub const ZSStructDestructurePattern = struct {
    struct_name: []const u8,
    fields: []ZSStructFieldPattern,
};

pub const ZSMatchArmPattern = union(enum) {
    enum_variant: ZSEnumVariantPattern,
    number_literal: []const u8,
    boolean_literal: bool,
    char_literal: u8,
    string_literal: []const u8,
    struct_destructure: ZSStructDestructurePattern,
};

pub const ZSMatchArm = struct {
    pattern: ZSMatchArmPattern,
    body: *ZSExpr,
};

pub const ZSMatchExpr = struct {
    subject: *ZSExpr,
    arms: []ZSMatchArm,
    has_else: bool = false,
    else_body: ?*ZSExpr = null,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.subject.deinit(allocator);
        allocator.destroy(self.subject);
        for (self.arms) |*arm| {
            arm.body.deinit(allocator);
            allocator.destroy(arm.body);
        }
        allocator.free(self.arms);
        if (self.else_body) |eb| {
            eb.deinit(allocator);
            allocator.destroy(eb);
        }
    }
};

pub const ZSBreak = struct {
    startPos: usize,
    endPos: usize,
};

pub const ZSContinue = struct {
    startPos: usize,
    endPos: usize,
};

pub const ZSForExpr = struct {
    init: *ast_node.ZSAstNode,
    condition: *ZSExpr,
    step: *ast_node.ZSAstNode,
    body: *ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.init.deinit(allocator);
        allocator.destroy(self.init);
        self.condition.deinit(allocator);
        allocator.destroy(self.condition);
        self.step.deinit(allocator);
        allocator.destroy(self.step);
        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};

pub const ZSUnary = struct {
    op: []const u8,
    operand: *ZSExpr,
    startPos: usize,
    endPos: usize,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.operand.deinit(allocator);
        allocator.destroy(self.operand);
    }
};
