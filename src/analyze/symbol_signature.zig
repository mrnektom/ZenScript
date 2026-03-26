pub const ZSTType = enum { number, string, boolean, unknown, function };
pub const ZSType = union(ZSTType) {
    number,
    string,
    boolean,
    unknown,
    function: ZSFunction,
};

pub const ZSFunction = struct {
    ret: *const ZSType,
    args: []ZSFnArg,
};

pub const ZSFnArg = struct { name: []const u8, type: ZSType };
