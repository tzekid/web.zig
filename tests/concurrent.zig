//! Bounded acceptance: concurrent clients reuse their connections and validate
//! every response. Hardware-dependent throughput and RSS are not correctness gates.
const std = @import("std");
const web_app = @import("web_app");
const client_count = 4;
const requests_per_client = 20;
const response_body = "concurrent journey response";

fn onError(_: anyerror, _: []const u8) void {}
fn handler(_: u8, context: *web_app.RequestContext) anyerror!void {
    const body = try context.arena.dupe(u8, response_body);
    try context.request.respond(body, .{});
}

fn readResponse(reader: *std.Io.Reader) !void {
    var header: [1024]u8 = undefined;
    var len: usize = 0;
    while (!std.mem.endsWith(u8, header[0..len], "\r\n\r\n")) {
        if (len == header.len) return error.HeaderTooLarge;
        try reader.readSliceAll(header[len .. len + 1]);
        len += 1;
    }
    try std.testing.expect(std.mem.startsWith(u8, header[0..len], "HTTP/1.1 200 "));
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, header[0..len], "\r\n");
    const marker = "content-length: ";
    while (lines.next()) |line| {
        if (line.len >= marker.len and std.ascii.eqlIgnoreCase(line[0..marker.len], marker))
            content_length = try std.fmt.parseInt(usize, line[marker.len..], 10);
    }
    try std.testing.expectEqual(@as(?usize, response_body.len), content_length);
    var body: [response_body.len]u8 = undefined;
    try reader.readSliceAll(&body);
    try std.testing.expectEqualStrings(response_body, &body);
}

fn client(io: std.Io, port: u16) !void {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    var read_buffer: [2048]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    for (0..requests_per_client) |_| {
        try writer.interface.writeAll("GET /journey HTTP/1.1\r\nhost: t\r\n\r\n");
        try writer.interface.flush();
        try readResponse(&reader.interface);
    }
}

test "concurrent keep-alive clients receive every expected body and drain cleanly" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var app = try web_app.App.init(std.testing.allocator, io, .{ .address = .{ .ip4 = .loopback(0) }, .workers = client_count, .on_error = onError });
    defer app.deinit();
    const Runner = struct {
        fn serve(a: *web_app.App, result: *anyerror!void) void {
            result.* = a.run(u8, 0, handler);
        }
        fn request(i: std.Io, port: u16, result: *anyerror!void) void {
            result.* = client(i, port);
        }
    };
    var run_result: anyerror!void = {};
    const server = try std.Thread.spawn(.{}, Runner.serve, .{ &app, &run_result });
    var joined = false;
    defer if (!joined) {
        app.requestShutdown();
        server.join();
    };
    var attempts: usize = 0;
    while (app.boundPort() == 0) : (attempts += 1) {
        if (attempts > 5000) return error.ServerNeverBound;
        std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = std.time.ns_per_ms }, .clock = .awake } }, io) catch {};
    }
    var results: [client_count]anyerror!void = @splat({});
    var clients: [client_count]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (clients[0..started]) |thread| thread.join();
        for (0..client_count) |i| {
            clients[i] = try std.Thread.spawn(.{}, Runner.request, .{ io, app.boundPort(), &results[i] });
            started += 1;
        }
    }
    for (results) |result| try result;
    app.requestShutdown();
    server.join();
    joined = true;
    try run_result;
    try std.testing.expectEqual(@as(u64, client_count * requests_per_client), app.counters().requests);
    try std.testing.expectEqual(@as(u64, 0), app.counters().responses_5xx);
    try std.testing.expectEqual(@as(u64, 0), app.counters().forced_closes);
}
