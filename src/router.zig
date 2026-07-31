//! Allocation-free route matching.

const std = @import("std");

pub const max_params = 8;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Params = struct {
    items: [max_params]Param = undefined,
    len: usize = 0,

    pub fn get(self: Params, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }
};

pub fn Match(comptime Route: type) type {
    return struct {
        route: *const Route,
        params: Params,
    };
}

pub fn Result(comptime Route: type) type {
    return union(enum) {
        matched: Match(Route),
        method_not_allowed,
        not_found,
    };
}

/// Route values need `method: std.http.Method` and `pattern: []const u8`
/// fields. A `:name` segment captures one non-empty segment. A final `*name`
/// segment captures the remaining non-empty path.
pub fn match(comptime Route: type, routes: []const Route, method: std.http.Method, path: []const u8) Result(Route) {
    var path_exists = false;
    for (routes) |*route| {
        const params = matchPattern(route.pattern, path) orelse continue;
        path_exists = true;
        if (route.method == method) return .{ .matched = .{ .route = route, .params = params } };
    }
    return if (path_exists) .method_not_allowed else .not_found;
}

pub fn matchPattern(pattern_raw: []const u8, path_raw: []const u8) ?Params {
    if (!validPattern(pattern_raw) or !validPath(path_raw)) return null;
    const pattern = normalized(pattern_raw);
    const path = normalized(path_raw);
    if (std.mem.eql(u8, pattern, "/") or std.mem.eql(u8, path, "/")) {
        return if (std.mem.eql(u8, pattern, path)) Params{} else null;
    }

    var patterns = std.mem.splitScalar(u8, pattern[1..], '/');
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    var params = Params{};
    while (patterns.next()) |expected| {
        if (expected.len > 1 and expected[0] == '*') {
            const consumed = path.len - parts.rest().len;
            const remaining = std.mem.trim(u8, path[consumed..], "/");
            if (remaining.len == 0 or params.len == max_params or patterns.next() != null) return null;
            params.items[params.len] = .{ .name = expected[1..], .value = remaining };
            params.len += 1;
            return params;
        }
        const actual = parts.next() orelse return null;
        if (expected.len > 1 and expected[0] == ':') {
            if (actual.len == 0 or params.len == max_params) return null;
            params.items[params.len] = .{ .name = expected[1..], .value = actual };
            params.len += 1;
        } else if (!std.mem.eql(u8, expected, actual)) {
            return null;
        }
    }
    return if (parts.next() == null) params else null;
}

fn normalized(path: []const u8) []const u8 {
    if (path.len > 1) return std.mem.trimEnd(u8, path, "/");
    return path;
}

fn validPattern(pattern: []const u8) bool {
    if (!validPath(pattern)) return false;
    var segments = std.mem.splitScalar(u8, normalized(pattern), '/');
    _ = segments.next();
    while (segments.next()) |segment| {
        if (segment.len == 1 and (segment[0] == ':' or segment[0] == '*')) return false;
        if (segment.len > 1 and segment[0] == '*' and segments.rest().len != 0) return false;
    }
    return true;
}

fn validPath(path: []const u8) bool {
    return path.len > 0 and path[0] == '/' and
        std.mem.indexOfAny(u8, path, "?#\r\n\x00\\") == null and
        std.mem.indexOf(u8, path, "//") == null;
}

test "router distinguishes matches method misses and unknown paths" {
    const Route = struct { method: std.http.Method, pattern: []const u8, id: u8 };
    const routes = [_]Route{
        .{ .method = .GET, .pattern = "/apps", .id = 1 },
        .{ .method = .GET, .pattern = "/apps/:name/deploys", .id = 2 },
        .{ .method = .POST, .pattern = "/apps/:name/deploys", .id = 3 },
    };
    try std.testing.expectEqual(@as(u8, 1), match(Route, &routes, .GET, "/apps").matched.route.id);
    const dynamic = match(Route, &routes, .POST, "/apps/cloudio/deploys/").matched;
    try std.testing.expectEqual(@as(u8, 3), dynamic.route.id);
    try std.testing.expectEqualStrings("cloudio", dynamic.params.get("name").?);
    try std.testing.expect(match(Route, &routes, .DELETE, "/apps/cloudio/deploys") == .method_not_allowed);
    try std.testing.expect(match(Route, &routes, .GET, "/unknown") == .not_found);
}

test "wildcards are final bounded captures" {
    const params = matchPattern("/assets/*path", "/assets/css/app.css").?;
    try std.testing.expectEqualStrings("css/app.css", params.get("path").?);
    try std.testing.expect(matchPattern("/assets/*path/more", "/assets/a/more") == null);
    try std.testing.expect(matchPattern("/assets/*path", "/assets") == null);
}

test "route paths reject ambiguous separators queries and backslashes" {
    try std.testing.expect(matchPattern("/a/:id", "/a/1?x=2") == null);
    try std.testing.expect(matchPattern("/a/:id", "/a//1") == null);
    try std.testing.expect(matchPattern("/a/:id", "/a\\1") == null);
    try std.testing.expect(matchPattern("/", "/") != null);
}
