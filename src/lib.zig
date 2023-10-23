// Exposed within this library
const std = @import("std");

const reader = @import("reader.zig");
pub const types = @import("types.zig");
pub const proto = @import("proto.zig");
pub const Conn = @import("conn.zig").Conn;
pub const Pool = @import("pool.zig").Pool;
pub const SASL = @import("sasl.zig").SASL;
pub const Result = @import("result.zig").Result;

pub const Reader = reader.Reader;
pub const Message = reader.Message;

pub const testing = @import("t.zig");

const root = @import("root");
const _assert = blk: {
	if (@hasDecl(root, "pg_assert")) {
		break :blk root.pg_assert;
	}
	switch (@import("builtin").mode) {
		.ReleaseFast, .ReleaseSmall => break :blk false,
		else => break: blk true,
	}
};

pub fn assert(ok: bool) void {
	if (comptime _assert) {
		std.debug.assert(ok);
	}
}
