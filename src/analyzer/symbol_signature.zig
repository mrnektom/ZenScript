const std = @import("std");

pub const ZSTType = enum { number, boolean, unknown, function, struct_type, pointer };
pub const ZSType = union(ZSTType) {
    number,
    boolean,
    unknown,
    function: ZSFunction,
    struct_type: ZSStructType,
    pointer: *const ZSType,
};

pub const ZSFunction = struct {
    ret: *const ZSType,
    args: []ZSFnArg,
};

pub const ZSFnArg = struct { name: []const u8, type: ZSType };

pub const ZSStructType = struct {
    name: []const u8,
    fields: []ZSStructField,
    type_args: []const ZSType,
};

pub const ZSStructField = struct {
    name: []const u8,
    type: ZSType,
};
