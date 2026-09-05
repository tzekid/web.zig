const std = @import("std");
const html = @import("web_html");

test "invalid attribute names reject without partial output when assertions are disabled" {
    var storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try writer.writeAll("<input");
    for ([_][]const u8{ "x onclick", "x=", "\"x", "x>", "" }) |name| {
        try std.testing.expectError(error.InvalidAttributeName, html.optionalAttribute(&writer, name, "value"));
        try std.testing.expectEqualStrings("<input", writer.buffered());
        try std.testing.expectError(error.InvalidAttributeName, html.booleanAttribute(&writer, name, true));
        try std.testing.expectEqualStrings("<input", writer.buffered());
    }
}
