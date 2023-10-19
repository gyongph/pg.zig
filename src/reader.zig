const std = @import("std");
const lib = @import("lib.zig");

const Conn = lib.Conn;
const Allocator = std.mem.Allocator;

// to everyone else, this is our reader
pub const Reader = ReaderT(std.net.Stream);

// generic just for testing within this file
fn ReaderT(comptime T: type) type {
	return struct {
		allocator: Allocator,

		// exists for the lifetime of the reader, but normally references this, but
		// for messages that don't fit, we'll allocate memory dynamically and
		// eventually revert back to buf.
		static: []u8,

		// buffer to read into
		buf: []u8,

		// start within buf of the next message
		start: usize = 0,

		// position in buf that we have valid data up to
		pos: usize = 0,

		stream: T,

		const Self = @This();

		pub fn init(allocator: Allocator, size: usize, stream: T) !Self {
			const static = try allocator.alloc(u8, size);
			return .{
				.buf = static,
				.stream = stream,
				.static = static,
				.allocator = allocator,
			};
		}

		pub fn deinit(self: Self) void {
			const allocator = self.allocator;
			if (self.static.ptr != self.buf.ptr) {
				allocator.free(self.buf);
			}
			allocator.free(self.static);
		}

		pub fn next(self: *Self) !Message {
			return self.buffered(self.pos) orelse self.read();
		}

		fn read(self: *Self) !Message {
			if (self.static.ptr != self.buf.ptr) {
				// Our previous read used a dynamic buffer. When we use a dynamic buffer
				// we're reading exactly 1 message, so we know we haven't overread into
				// the next message. We can free the dynamic buffer, and reuse the whole
				// of our static buffer
				self.allocator.free(self.buf);
				self.pos = 0;
				self.start = 0;
				self.buf = self.static;
			}

			const stream = self.stream;
			// const spare = buf.len - pos; // how much space we have left in our buffer

			// Every PG message has 1 type byte followed by a 4 byte length prefix.
			// Since the length prefix includes itself (but not the type byte) the
			// minimum possible length is 4. We use 0 to denote "unknown".
			var buf = self.buf;
			var pos = self.pos;
			var message_length: usize = 0;

			while (true) {
				if (message_length == 0) {
					// we don't yet know the length of this message

					const start = self.start;

					// how much of the next message we have
					const current_length = pos - start;

					// we have enough data to figure the message length
					if (current_length > 4) {
						// + 1 for the type byte
						message_length = std.mem.readIntBig(u32, buf[start+1..start+5][0..4]) + 1;

						if (message_length > buf.len) {
							// our static buffer is too small
							const dyn = try self.allocator.alloc(u8, message_length);
							@memcpy(dyn[0..current_length], buf[start..pos]);
							self.start = 0;
							pos = current_length;
							buf = dyn;
							self.buf = dyn;
						} else if (message_length > buf.len - start)  {
							// our static buffer is big enough, but not from where we're currently starting
							std.mem.copyForwards(u8, buf[0..current_length], buf[start..pos]);
							pos = current_length;
							self.start = 0;
						}
					} else if (buf.len - start < 5) {
						// we don't even have enough space to read the 5 byte header
						std.mem.copyForwards(u8, buf[0..current_length], buf[start..pos]);
						pos = current_length;
						self.start = 0;
					}
				}

				const n = try stream.read(buf[pos..]);
				if (n == 0) {
					return error.Closed;
				}
				pos += n;
				if (self.buffered(pos)) |msg| {
					return msg;
				}
			}
		}

		// checks and consume if we already have a message buffered
		fn buffered(self: *Self, pos: usize) ?Message {
			const start = self.start;
			const available = pos - start;

			// we always need at least 5 bytes, 1 for the type and 4 for the length
			if (available < 5) {
				return null;
			}
			const buf = self.buf;

			const len_end = start+5;
			const len = std.mem.readIntBig(u32, buf[start+1..len_end][0..4]);

			// +1 because the first byte, the message type, isn't included in the length
			if (available < len+1) {
				return null;
			}

			// -4 because the len includes the 4 byte length header itself
			const end = len_end + len - 4;

			// how much extra data we already have
			const extra = pos - end;
			if (extra == 0) {
				// we have no more data in the buffer, reset everything to the start
				// so that we have the full buffer for future messages
				self.pos = 0;
				self.start = 0;
			} else {
				self.pos = pos;
				self.start = end;
			}

			return .{
				.type = buf[start],
				.data = buf[len_end..end],
			};
		}
	};
}

pub const Message = struct {
	type: u8,
	data: []const u8,
};

const t = lib.testing;
test "Reader: next" {
	const R = ReaderT(*t.Stream);
	var s = t.Stream.init();
	defer s.deinit();

	{
		s.reset();
		s.add(&[_]u8{8, 0, 0, 0, 4});
		var reader = R.init(t.allocator, 10, s) catch unreachable;
		defer reader.deinit();
		const msg = try reader.next();
		try t.expectEqual(8, msg.type);
		try t.expectSlice(u8, &[_]u8{}, msg.data);
	}

	{
		s.reset();
		s.add(&[_]u8{1, 0, 0, 0, 5, 2});
		var reader = R.init(t.allocator, 10, s) catch unreachable;
		defer reader.deinit();
		const msg = try reader.next();
		try t.expectEqual(1, msg.type);
		try t.expectSlice(u8, &[_]u8{2}, msg.data);
	}

	{
		s.reset();
		s.add(&[_]u8{1, 0, 0, 0, 9, 1, 2, 3, 4, 19});
		var reader = R.init(t.allocator, 10, s) catch unreachable;
		defer reader.deinit();
		const msg = try reader.next();
		try t.expectEqual(1, msg.type);
		try t.expectSlice(u8, &[_]u8{1, 2, 3, 4, 19}, msg.data);
		// optimization, resets pos to 0 since we read an exact message
		try t.expectEqual(0, reader.pos);
	}

	{
		// partial 2nd message, but closed without all the data
		s.reset();
		s.add(&[_]u8{1, 0, 0, 0, 9, 1, 2, 3, 4, 19, 2});
		var reader = R.init(t.allocator, 10, s) catch unreachable;
		defer reader.deinit();
		const msg = try reader.next();
		try t.expectEqual(1, msg.type);
		try t.expectSlice(u8, &[_]u8{1, 2, 3, 4, 19}, msg.data);
		try t.expectError(error.Closed, reader.next());
	}

	{
		// 2 full messages, 2nd message has no data
		s.reset();
		s.add(&[_]u8{99, 0, 0, 0, 6, 200, 201, 2, 0, 0, 0, 4});
		var reader = R.init(t.allocator, 20, s) catch unreachable;
		defer reader.deinit();

		const msg1 = try reader.next();
		try t.expectEqual(99, msg1.type);
		try t.expectSlice(u8, &[_]u8{200, 201}, msg1.data);

		const msg2 = try reader.next();
		try t.expectEqual(2, msg2.type);
		try t.expectSlice(u8, &[_]u8{}, msg2.data);
	}

	{
		// 2 full messages, 2nd message has data
		s.reset();
		s.add(&[_]u8{99, 0, 0, 0, 6, 200, 201, 3, 0, 0, 0, 7, 1, 8, 2});
		var reader = R.init(t.allocator, 20, s) catch unreachable;
		defer reader.deinit();

		const msg1 = try reader.next();
		try t.expectEqual(99, msg1.type);
		try t.expectSlice(u8, &[_]u8{200, 201}, msg1.data);

		const msg2 = try reader.next();
		try t.expectEqual(3, msg2.type);
		try t.expectSlice(u8, &[_]u8{1, 8, 2}, msg2.data);
	}

	{
		// 2 full messages, split across packets
		s.reset();
		s.add(&[_]u8{91, 0, 0, 0, 6, 200, 22, 4, 0, 0, 0, 5});
		var reader = R.init(t.allocator, 20, s) catch unreachable;
		defer reader.deinit();

		const msg1 = try reader.next();
		try t.expectEqual(91, msg1.type);
		try t.expectSlice(u8, &[_]u8{200, 22}, msg1.data);

		s.add(&[_]u8{73});
		const msg2 = try reader.next();
		try t.expectEqual(4, msg2.type);
		try t.expectSlice(u8, &[_]u8{73}, msg2.data);
	}

	{
		// not enough room in buffer for header of 2nd message
		s.reset();
		s.add(&[_]u8{17, 0, 0, 0, 4, 5});
		var reader = R.init(t.allocator, 8, s) catch unreachable;
		defer reader.deinit();

		const msg1 = try reader.next();
		try t.expectEqual(17, msg1.type);
		try t.expectSlice(u8, &[_]u8{}, msg1.data);

		s.add(&[_]u8{0, 0, 0, 6, 10, 12});
		const msg2 = try reader.next();
		try t.expectEqual(5, msg2.type);
		try t.expectSlice(u8, &[_]u8{10, 12}, msg2.data);
	}

	{
		// not enough room in buffer for header of 2nd message across multiple callss
		s.reset();
		s.add(&[_]u8{17, 0, 0, 0, 5, 1, 200});
		var reader = R.init(t.allocator, 8, s) catch unreachable;
		defer reader.deinit();

		const msg1 = try reader.next();
		try t.expectEqual(17, msg1.type);
		try t.expectSlice(u8, &[_]u8{1}, msg1.data);

		s.add(&[_]u8{0, 0});
		s.add(&[_]u8{0});
		s.add(&[_]u8{7, 10, 12, 14});
		const msg2 = try reader.next();
		try t.expectEqual(200, msg2.type);
		try t.expectSlice(u8, &[_]u8{10, 12, 14}, msg2.data);
	}
}

// simulates message fragmentations
test "Reader: fuzz" {
	const R = ReaderT(*t.Stream);

	var r = t.getRandom();
	const random = r.random();

	const messages = [_]u8{
		1, 0, 0, 0, 4,
		2, 0, 0, 0, 5, 1,
		3, 0, 0, 0, 6, 1, 2,
		4, 0, 0, 0, 24, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
		5, 0, 0, 0, 8, 1, 2, 3, 4,
		6, 0, 0, 0, 9, 1, 2, 3, 4, 5,
		7, 0, 0, 0, 10, 1, 2, 3, 4, 5, 6,
		8, 0, 0, 0, 11, 1, 2, 3, 4, 5, 6, 7,
	};

	for (0..200) |_| {
		var s = t.Stream.init();
		defer s.deinit();
		var reader = R.init(t.allocator, 12, s) catch unreachable;
		defer reader.deinit();

		var buf: []const u8 = messages[0..];
		while (buf.len > 0) {
			const l = random.uintAtMost(usize, buf.len - 1) + 1;
			s.add(buf[0..l]);
			buf = buf[l..];
		}

		{
			const msg = try reader.next();
			try t.expectEqual(1, msg.type);
			try t.expectSlice(u8, &[_]u8{}, msg.data);
		}

		{
			const msg = try reader.next();
			try t.expectEqual(2, msg.type);
			try t.expectSlice(u8, &[_]u8{1}, msg.data);
		}

		{
			const msg = try reader.next();
			try t.expectEqual(3, msg.type);
			try t.expectSlice(u8, &[_]u8{1, 2}, msg.data);
		}

		{
			const msg = try reader.next();
			try t.expectEqual(4, msg.type);
			try t.expectSlice(u8, &[_]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}, msg.data);
		}

		{
			const msg = try reader.next();
			try t.expectEqual(5, msg.type);
			try t.expectSlice(u8, &[_]u8{1, 2, 3, 4}, msg.data);
		}

		{
			const msg = try reader.next();
			try t.expectEqual(6, msg.type);
			try t.expectSlice(u8, &[_]u8{1, 2, 3, 4, 5}, msg.data);
		}

		{
			const msg = try reader.next();
			try t.expectEqual(7, msg.type);
			try t.expectSlice(u8, &[_]u8{1, 2, 3, 4, 5, 6}, msg.data);
		}

		{
			const msg = try reader.next();
			try t.expectEqual(8, msg.type);
			try t.expectSlice(u8, &[_]u8{1, 2, 3, 4, 5, 6, 7}, msg.data);
		}

		try t.expectError(error.Closed, reader.next());
	}
}

test "Reader: dynamic" {
	const R = ReaderT(*t.Stream);
	var s = t.Stream.init();
	defer s.deinit();

	{
		//  message bigger than static buffer
		s.add(&[_]u8{200, 0, 0, 0, 14, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10});
		var reader = R.init(t.allocator, 10, s) catch unreachable;
		defer reader.deinit();
		const msg = try reader.next();
		try t.expectEqual(200, msg.type);
		try t.expectSlice(u8, &.{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, msg.data);
	}

	{
		//  2nd message bigger than static buffer
		s.add(&[_]u8{199, 0, 0, 0, 6, 9, 8, 200, 0, 0, 0, 14, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10});
		var reader = R.init(t.allocator, 10, s) catch unreachable;
		defer reader.deinit();

		const msg1 = try reader.next();
		try t.expectEqual(199, msg1.type);
		try t.expectSlice(u8, &.{9, 8}, msg1.data);

		const msg2 = try reader.next();
		try t.expectEqual(200, msg2.type);
		try t.expectSlice(u8, &.{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, msg2.data);
	}

	{
		// middle message bigger than static
		s.add(&[_]u8{199, 0, 0, 0, 6, 9, 8, 200, 0, 0, 0, 14, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 198, 0, 0, 0, 5, 1});
		var reader = R.init(t.allocator, 10, s) catch unreachable;
		defer reader.deinit();

		const msg1 = try reader.next();
		try t.expectEqual(199, msg1.type);
		try t.expectSlice(u8, &.{9, 8}, msg1.data);

		const msg2 = try reader.next();
		try t.expectEqual(200, msg2.type);
		try t.expectSlice(u8, &.{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, msg2.data);

		const msg3 = try reader.next();
		try t.expectEqual(198, msg3.type);
		try t.expectSlice(u8, &.{1}, msg3.data);
	}
}