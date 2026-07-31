const std = @import("std");

const ModuleSpec = struct {
    name: []const u8,
    path: []const u8,
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
        const module_tests = b.addTest(.{
            .root_module = module,
        });
        const run_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_tests.step);
    }

    const first_view_module = b.createModule(.{
        .root_source_file = b.path("tests/first_view.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "web_html", .module = b.modules.get("web_html").? },
            .{ .name = "web_htmx", .module = b.modules.get("web_htmx").? },
            .{ .name = "web_testing", .module = b.modules.get("web_testing").? },
        },
    });
    const first_view_tests = b.addTest(.{ .root_module = first_view_module });
    test_step.dependOn(&b.addRunArtifact(first_view_tests).step);

    const consumer_command = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    consumer_command.setCwd(b.path("tests/consumer"));
    const consumer_step = b.step("consumer", "Build the external path consumer");
    consumer_step.dependOn(&consumer_command.step);
}
