pub const sig = @import("symbol_signature.zig");
pub const ZSType = sig.ZSType;

name: []const u8,
assignable: bool,
signature: ZSType,
