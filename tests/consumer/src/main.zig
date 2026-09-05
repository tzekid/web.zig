const web_html = @import("web_html");
const web_router = @import("web_router");
const std = @import("std");

pub fn main() !void {
    var storage: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try web_html.documentStart(&writer, .{ .title = "Consumer" });
    try writer.writeAll("<main>");
    try web_html.text(&writer, "<unsafe & text>");
    try writer.writeAll("</main>");
    try web_html.documentEnd(&writer);
    if (std.mem.indexOf(u8, writer.buffered(), "&lt;unsafe &amp; text&gt;") == null) return error.EscapingFailed;
    const Route = struct { method: std.http.Method, pattern: []const u8 };
    const routes = [_]Route{.{ .method = .GET, .pattern = "/items/:id" }};
    const matched = web_router.match(Route, &routes, .GET, "/items/42").matched;
    if (!std.mem.eql(u8, matched.params.get("id").?, "42")) return error.RouteParameterLost;
    if (web_router.match(Route, &routes, .POST, "/items/42") != .method_not_allowed) return error.MethodNotRejected;
}
