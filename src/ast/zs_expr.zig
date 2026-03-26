const std = @import("std");
pub const ZSCall = @import("zs_call.zig");
const ast_node = @import("ast_node.zig");

const ZSExprType = enum {
    number,
    string,
    boolean,
    call,
    reference,
    if_expr,
    binary,
    block,
    return_expr,
};

pub const ZSExpr = union(ZSExprType) {
    number: ZSNumber,
    string: ZSString,
    boolean: ZSBoolean,
    call: ZSCall,
    reference: ZSReference,
    if_expr: ZSIfExpr,
    binary: ZSBinary,
    block: ZSBlock,
    return_expr: ZSReturn,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .call => self.call.deinit(allocator),
            .string => self.string.deinit(allocator),
            .if_expr => self.if_expr.deinit(allocator),
            .binary => self.binary.deinit(allocator),
            .block => self.block.deinit(allocator),
            .return_expr => self.return_expr.deinit(allocator),
            .number, .boolean, .reference => {},
        }
    }

    pub fn start(self: *const @This()) usize {
        return switch (self.*) {
            .number => self.number.startPos,
            .string => self.string.startPos,
            .boolean => self.boolean.startPos,
            .call => self.call.startPos,
            .reference => self.reference.startPos,
            .if_expr => self.if_expr.startPos,
            .binary => self.binary.startPos,
            .block => self.block.startPos,
            .return_expr => self.return_expr.startPos,
        };
    }

    pub fn end(self: *const @This()) usize {
        return switch (self.*) {
            .number => self.number.endPos,
            .string => self.string.endPos,
            .boolean => self.boolean.endPos,
            .call => self.call.endPos,
            .reference => self.reference.endPos,
            .if_expr => self.if_expr.endPos,
            .binary => self.binary.endPos,
            .block => self.block.endPos,
            .return_expr => self.return_expr.endPos,
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
