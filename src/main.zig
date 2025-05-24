//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const log = std.log.scoped(.main);
const Allocator = std.mem.Allocator;

const zzz = @import("zzz");
const http = zzz.HTTP;
const sqlite = @import("sqlite");

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("zig_pkg_checker_lib");

var db: sqlite.Database = undefined;
var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var allocator: Allocator = undefined;

// Template rendering helpers
fn renderTemplate(ctx: *const Context, template_name: []const u8) !Respond {
    // Read base template using the context's arena allocator
    const base_template = std.fs.cwd().readFileAlloc(ctx.allocator, "templates/base.html", 8192 * 4) catch |err| {
        log.err("Failed to read base template: {}", .{err});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Template error",
        });
    };

    // Build the template file path
    const template_path = std.fmt.allocPrint(ctx.allocator, "templates/{s}", .{template_name}) catch |err| {
        log.err("Failed to allocate template path: {}", .{err});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Template path allocation error",
        });
    };

    // Read the specific template content
    const template_content = std.fs.cwd().readFileAlloc(ctx.allocator, template_path, 8192 * 4) catch |err| {
        log.err("Failed to read template {s}: {}", .{ template_name, err });
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Template not found",
        });
    };

    // Find the placeholder
    const placeholder = "{{content}}";
    const placeholder_index = std.mem.indexOf(u8, base_template, placeholder) orelse {
        log.err("Template placeholder not found", .{});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Template placeholder error",
        });
    };

    // Calculate size needed
    const before_placeholder = base_template[0..placeholder_index];
    const after_placeholder = base_template[placeholder_index + placeholder.len ..];
    const total_size = before_placeholder.len + template_content.len + after_placeholder.len;

    // Allocate buffer for the result using the context's arena allocator
    const rendered = ctx.allocator.alloc(u8, total_size) catch |err| {
        log.err("Failed to allocate template buffer: {}", .{err});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Template allocation error",
        });
    };

    // Copy parts manually
    var pos: usize = 0;
    @memcpy(rendered[pos .. pos + before_placeholder.len], before_placeholder);
    pos += before_placeholder.len;
    @memcpy(rendered[pos .. pos + template_content.len], template_content);
    pos += template_content.len;
    @memcpy(rendered[pos .. pos + after_placeholder.len], after_placeholder);

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = rendered,
    });
}

// Route handlers
fn home_handler(ctx: *const Context, _: void) !Respond {
    return renderTemplate(ctx, "home.html");
}

fn packages_handler(ctx: *const Context, _: void) !Respond {
    return renderTemplate(ctx, "packages.html");
}

fn submit_handler(ctx: *const Context, _: void) !Respond {
    return renderTemplate(ctx, "submit.html");
}

fn stats_handler(ctx: *const Context, _: void) !Respond {
    return renderTemplate(ctx, "stats.html");
}

fn api_docs_handler(ctx: *const Context, _: void) !Respond {
    return renderTemplate(ctx, "api.html");
}

fn static_handler(ctx: *const Context, _: void) !Respond {
    const path = ctx.request.uri orelse "/";

    // Security check: don't allow path traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        return ctx.response.apply(.{
            .status = .@"Bad Request",
            .mime = http.Mime.TEXT,
            .body = "Invalid path",
        });
    }

    // Remove leading /static/
    const file_path = path[8..]; // "/static/" is 8 characters

    // Build full path using context's arena allocator
    const full_path = std.fmt.allocPrint(ctx.allocator, "static/{s}", .{file_path}) catch {
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Memory allocation error",
        });
    };

    // Try to read the file using context's arena allocator
    const file_content = std.fs.cwd().readFileAlloc(ctx.allocator, full_path, 1024 * 1024) catch {
        return ctx.response.apply(.{
            .status = .@"Not Found",
            .mime = http.Mime.TEXT,
            .body = "File not found",
        });
    };

    // Determine MIME type
    const mime_type = if (std.mem.endsWith(u8, file_path, ".css"))
        http.Mime.CSS
    else if (std.mem.endsWith(u8, file_path, ".js"))
        http.Mime.JS
    else if (std.mem.endsWith(u8, file_path, ".png"))
        http.Mime.PNG
    else if (std.mem.endsWith(u8, file_path, ".jpg") or std.mem.endsWith(u8, file_path, ".jpeg"))
        http.Mime.JPEG
    else if (std.mem.endsWith(u8, file_path, ".svg"))
        http.Mime.SVG
    else
        http.Mime.TEXT;

    return ctx.response.apply(.{
        .status = .OK,
        .mime = mime_type,
        .body = file_content,
    });
}

// API handlers
fn api_health_handler(ctx: *const Context, _: void) !Respond {
    return ctx.response.apply(.{ .status = .OK, .mime = http.Mime.JSON, .body = 
        \\{
        \\  "status": "healthy",
        \\  "timestamp": "2024-01-01T00:00:00Z",
        \\  "database": "connected",
        \\  "version": "1.0.0"
        \\}
    });
}

fn api_packages_handler(ctx: *const Context, _: void) !Respond {
    if (std.mem.eql(u8, ctx.request.method.raw, "GET")) {
        return api_get_packages(ctx, .{});
    } else if (std.mem.eql(u8, ctx.request.method.raw, "POST")) {
        return api_create_package(ctx, .{});
    } else {
        return ctx.response.apply(.{
            .status = .@"Method Not Allowed",
            .mime = http.Mime.TEXT,
            .body = "Method not allowed",
        });
    }
}

fn api_get_packages(ctx: *const Context, _: void) !Respond {
    // For now, return empty array
    return ctx.response.apply(.{ .status = .OK, .mime = http.Mime.JSON, .body = 
        \\{
        \\  "packages": [],
        \\  "total": 0,
        \\  "page": 1,
        \\  "limit": 20
        \\}
    });
}

fn api_create_package(ctx: *const Context, _: void) !Respond {
    // For now, just return success
    return ctx.response.apply(.{ .status = .Created, .mime = http.Mime.JSON, .body = 
        \\{
        \\  "message": "Package submitted successfully",
        \\  "id": 1
        \\}
    });
}

fn initializeDatabase() !void {
    db = sqlite.Database.open(.{ .path = "zig_pkg_checker.db" }) catch |err| {
        log.err("Failed to open database: {}", .{err});
        return err;
    };

    lib.db.initDatabase(&db) catch |err| {
        log.err("Failed to initialize database schema: {}", .{err});
        return err;
    };

    log.info("Database initialized successfully", .{});
}

pub fn main() !void {
    gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    // Initialize database
    initializeDatabase() catch |err| {
        log.err("Database initialization failed: {}", .{err});
        return;
    };
    defer db.close();

    const host = "127.0.0.1";
    const port = 3000;

    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, home_handler).layer(),
        Route.init("/packages").get({}, packages_handler).layer(),
        Route.init("/submit").get({}, submit_handler).layer(),
        Route.init("/stats").get({}, stats_handler).layer(),
        Route.init("/api").get({}, api_docs_handler).layer(),
        Route.init("/static/*").get({}, static_handler).layer(),
        Route.init("/api/health").get({}, api_health_handler).layer(),
        Route.init("/api/packages").get({}, api_get_packages).post({}, api_create_package).layer(),
    }, .{});
    defer router.deinit(allocator);

    // create socket for tardy
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    log.info("Server listening on http://{s}:{}", .{ host, port });
    log.info("Available endpoints:", .{});
    log.info("  - GET /            - Welcome page", .{});
    log.info("  - GET /packages    - Package listing", .{});
    log.info("  - GET /submit      - Submit package", .{});
    log.info("  - GET /stats       - Package statistics", .{});
    log.info("  - GET /api         - API documentation", .{});
    log.info("  - GET /api/health  - Health check", .{});
    log.info("  - GET /api/packages - List packages", .{});
    log.info("  - POST /api/packages - Submit package", .{});

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                    .keepalive_count_max = null,
                    .connection_count_max = 1024,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}

test "basic add functionality" {
    const result = lib.add(100, 50);
    try std.testing.expect(result == 150);
}

test "fuzz example" {
    const TestContext = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(TestContext{}, TestContext.testOne, .{});
}
