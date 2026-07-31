const web_html = @import("web_html");
const web_router = @import("web_router");
const std = @import("std");

pub fn main() !void {
    var storage: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try web_html.documentStart(&writer, .{ .title = "Consumer" });
    try writer.writeAll("<main>");
    try web_html.text(&writer, "Useful on the first response");
    try writer.writeAll("</main>");
    try web_html.documentEnd(&writer);
    _ = web_router.package_is_initialized;
}
