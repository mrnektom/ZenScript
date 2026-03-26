const ZSTypeType = enum { reference };
pub const ZSType = union(ZSTypeType) { reference: []const u8 };
