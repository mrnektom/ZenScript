pub const ZSTType = enum { number, string, unknown, function };
pub const ZSType = union(ZSTType) { number, string, unknown, function };

// pub const ZSFunction =
