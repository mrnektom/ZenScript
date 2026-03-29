const std = @import("std");

pub const ZSTType = enum { number, boolean, char, long, short, byte, unknown, function, struct_type, pointer, array_type, enum_type };
pub const ZSType = union(ZSTType) {
    number,
    boolean,
    char,
    long,
    short,
    byte,
    unknown,
    function: ZSFunction,
    struct_type: ZSStructType,
    pointer: *const ZSType,
    array_type: ZSArrayTypeInfo,
    enum_type: ZSEnumType,
};

pub const ZSArrayTypeInfo = struct {
    element_type: *const ZSType,
    size: usize,
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

pub const ZSEnumType = struct {
    name: []const u8,
    variants: []ZSEnumVariant,
    type_args: []const ZSType,
};

pub const ZSEnumVariant = struct {
    name: []const u8,
    payload_type: ?ZSType,
    tag: u32,
};
