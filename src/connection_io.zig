//! A cumulative socket-wait budget; handler work between calls is excluded.
const Connection = @This();
const std = @import("std");

io: std.Io,
stream: std.Io.net.Stream,
timeout_ms: u64,
remaining: ?std.Io.Duration,
reader: std.Io.Reader,
writer: std.Io.Writer,

pub fn init(io: std.Io, stream: std.Io.net.Stream, timeout_ms: u64, read_buffer: []u8, write_buffer: []u8) Connection {
    return .{
        .io = io,
        .stream = stream,
        .timeout_ms = timeout_ms,
        .remaining = budget(timeout_ms),
        .reader = .{ .vtable = &.{ .stream = read }, .buffer = read_buffer, .seek = 0, .end = 0 },
        .writer = .{ .vtable = &.{ .drain = write }, .buffer = write_buffer },
    };
}

fn budget(timeout_ms: u64) ?std.Io.Duration {
    return if (timeout_ms == 0) null else .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms };
}

pub fn resetBudget(self: *Connection) void {
    self.remaining = budget(self.timeout_ms);
}

fn deadline(self: *Connection, started: std.Io.Clock.Timestamp) ?std.Io.Clock.Timestamp {
    return if (self.remaining) |remaining| started.addDuration(.{ .raw = remaining, .clock = .awake }) else null;
}

fn charge(self: *Connection, started: std.Io.Clock.Timestamp) void {
    if (self.remaining) |*remaining| remaining.nanoseconds -= started.untilNow(self.io).raw.nanoseconds;
}

/// The idle wait has its own bound; it does not consume the request I/O budget.
pub fn waitReadable(self: *Connection) bool {
    self.wait(std.posix.POLL.IN, self.deadline(.now(self.io, .awake))) catch return false;
    return true;
}

fn wait(self: *Connection, events: i16, until: ?std.Io.Clock.Timestamp) error{NetworkTimeout}!void {
    var fds = [_]std.posix.pollfd{.{ .fd = self.stream.socket.handle, .events = events, .revents = 0 }};
    while (true) {
        const remaining: i32 = if (until) |end| ms: {
            const ns = end.durationFromNow(self.io).raw.nanoseconds;
            if (ns <= 0) return error.NetworkTimeout;
            break :ms @intCast(@min(@divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32) - 1));
        } else -1;
        const rc = std.os.linux.poll(&fds, fds.len, remaining);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => if (rc > 0) return else return error.NetworkTimeout,
            .INTR => continue,
            else => return error.NetworkTimeout,
        }
    }
}

fn read(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *Connection = @alignCast(@fieldParentPtr("reader", reader));
    const data = limit.slice(try writer.writableSliceGreedy(1));
    if (data.len == 0) return 0;
    const started: std.Io.Clock.Timestamp = .now(self.io, .awake);
    defer self.charge(started);
    const until = self.deadline(started);
    while (true) {
        self.wait(std.posix.POLL.IN, until) catch return error.ReadFailed;
        const rc = std.os.linux.recvfrom(self.stream.socket.handle, data.ptr, data.len, std.os.linux.MSG.DONTWAIT, null, null);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.EndOfStream;
                const n: usize = @intCast(rc);
                writer.advance(n);
                return n;
            },
            .INTR, .AGAIN => continue,
            else => return error.ReadFailed,
        }
    }
}

fn write(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *Connection = @alignCast(@fieldParentPtr("writer", writer));
    const bytes = bytes: {
        if (writer.end != 0) break :bytes writer.buffered();
        for (data[0 .. data.len - @intFromBool(splat == 0)]) |part| {
            if (part.len != 0) break :bytes part;
        }
        return 0;
    };
    const started: std.Io.Clock.Timestamp = .now(self.io, .awake);
    defer self.charge(started);
    const until = self.deadline(started);
    while (true) {
        self.wait(std.posix.POLL.OUT, until) catch return error.WriteFailed;
        // Poll readiness alone cannot bound a blocking send. Keep the
        // syscall nonblocking and recheck the same deadline on retry.
        const rc = std.os.linux.sendto(self.stream.socket.handle, bytes.ptr, bytes.len, std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL, null, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                return writer.consume(@intCast(rc));
            },
            .INTR, .AGAIN => continue,
            else => return error.WriteFailed,
        }
    }
}

test "handler time is excluded and a non-reading peer cannot hold a write" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buffer: [128]u8 = undefined;
    var write_buffer: [128]u8 = undefined;
    var connection = Connection.init(io, stream, 200, &read_buffer, &write_buffer);
    try std.testing.expectEqual(@as(usize, 1), std.os.linux.sendto(client.socket.handle, "a", 1, std.os.linux.MSG.NOSIGNAL, null, 0));
    try std.testing.expectEqual(@as(u8, 'a'), try connection.reader.takeByte());
    // More than the entire network budget passes inside a simulated handler.
    try std.Io.sleep(io, .fromMilliseconds(300), .awake);
    try connection.writer.writeAll("b");
    try connection.writer.flush();
    var response: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), std.os.linux.recvfrom(client.socket.handle, &response, 1, std.os.linux.MSG.DONTWAIT, null, null));
    try std.testing.expectEqual(@as(u8, 'b'), response[0]);

    // Constrain the actual socket, then send past its capacity with no reader.
    const buffer_size: c_int = 4096;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, @ptrCast(&buffer_size), @sizeOf(c_int)));
    const payload = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const Watchdog = struct {
        fn run(test_io: std.Io, fd: std.posix.fd_t) void {
            std.Io.sleep(test_io, .fromMilliseconds(2000), .awake) catch {};
            _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.RDWR);
        }
    };
    // A regression to blocking send must fail promptly, not hang the suite.
    const watchdog = try std.Thread.spawn(.{}, Watchdog.run, .{ io, stream.socket.handle });
    defer watchdog.join();
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    try std.testing.expectError(error.WriteFailed, connection.writer.writeAll(payload));
    try std.testing.expect(started.untilNow(io).raw.toMilliseconds() < 1000);
}
