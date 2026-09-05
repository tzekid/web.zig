const std = @import("std");

const ModuleSpec = struct {
    name: []const u8,
    path: []const u8,
    imports: []const []const u8 = &.{},
};

const modules = [_]ModuleSpec{
    .{ .name = "web_html", .path = "src/html.zig" },
    .{ .name = "web_request", .path = "src/request.zig" },
    .{ .name = "web_response", .path = "src/response.zig" },
    .{ .name = "web_router", .path = "src/router.zig" },
    .{ .name = "web_assets", .path = "src/assets.zig" },
    .{ .name = "web_cache", .path = "src/cache.zig" },
    .{ .name = "web_security_headers", .path = "src/security_headers.zig" },
    .{ .name = "web_server", .path = "src/server.zig" },
    .{ .name = "web_htmx", .path = "src/htmx.zig" },
    .{ .name = "web_testing", .path = "src/testing.zig" },
    .{ .name = "web_app", .path = "src/app.zig", .imports = &.{ "web_server", "web_router" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run all module tests");

    for (modules) |spec| {
        const module = b.addModule(spec.name, .{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        });
        for (spec.imports) |name| module.addImport(name, b.modules.get(name).?);
        // The optional lifecycle is Linux-specific; other modules remain portable.
        if (std.mem.eql(u8, spec.name, "web_app") and target.result.os.tag != .linux) continue;
        const module_tests = b.addTest(.{
            .root_module = module,
        });
        const run_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_tests.step);
    }

    const html_release_fast = b.createModule(.{
        .root_source_file = b.path("tests/html_releasefast.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "web_html", .module = b.createModule(.{ .root_source_file = b.path("src/html.zig"), .target = target, .optimize = .ReleaseFast }) }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = html_release_fast })).step);

    const journeys_step = b.step("journeys", "Run concurrent HTTP keep-alive acceptance (Linux)");
    if (target.result.os.tag == .linux) {
        const journey = b.createModule(.{
            .root_source_file = b.path("tests/concurrent.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "web_app", .module = b.modules.get("web_app").? }},
        });
        journeys_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = journey })).step);
    }

    const consumer_command = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    consumer_command.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    consumer_command.setCwd(b.path("tests/consumer"));
    const consumer_step = b.step("consumer", "Build the external path consumer");
    consumer_step.dependOn(&consumer_command.step);
}
