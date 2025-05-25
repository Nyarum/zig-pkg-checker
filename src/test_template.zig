const std = @import("std");
const TemplateEngine = @import("src/template_engine.zig").TemplateEngine;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const engine = TemplateEngine.init(allocator);

    // Test data similar to what the stats page receives
    const TestActivity = struct {
        package_name: []const u8,
        zig_version: []const u8,
        build_status: []const u8,
        timestamp: []const u8,
    };

    const TestData = struct {
        recent_activity: []const TestActivity,
    };

    const test_data = TestData{
        .recent_activity = &[_]TestActivity{
            .{
                .package_name = "test-package",
                .zig_version = "0.14.0",
                .build_status = "success",
                .timestamp = "2024-01-01",
            },
            .{
                .package_name = "test-package2",
                .zig_version = "0.13.0",
                .build_status = "failed",
                .timestamp = "2024-01-02",
            },
        },
    };

    const template_content =
        \\{{#each recent_activity}}
        \\Package: {{package_name}}
        \\Status: {{build_status}}
        \\{{#if (eq build_status "success")}}
        \\SUCCESS ICON
        \\{{else}}
        \\FAILED ICON
        \\{{/if}}
        \\---
        \\{{/each}}
    ;

    const result = engine.renderTemplate(template_content, test_data) catch |err| {
        std.log.err("Template rendering failed: {}", .{err});
        return;
    };
    defer allocator.free(result);

    std.log.info("Template result:\n{s}", .{result});
}
