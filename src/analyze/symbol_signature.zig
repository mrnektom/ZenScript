pub const ZSTType = enum { number, string, unknown, function };
pub const ZSType = union(ZSTType) {
    number,
    string,
    unknown,
    function: ZSFunction,
};

pub const ZSFunction = struct {
    ret: *const ZSType,
    args: []ZSFnArg,
};

pub const ZSFnArg = struct { name: []const u8, type: ZSType };
