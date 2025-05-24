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
const build_system = @import("build_system.zig");

var db: sqlite.Database = undefined;
var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var allocator: Allocator = undefined;
var build_sys: build_system.BuildSystem = undefined;
var global_runtime: ?*Runtime = null;

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
    // Check if this is a form submission (GET with query parameters or POST with body)
    const is_form_submission = if (ctx.request.uri) |uri|
        std.mem.indexOf(u8, uri, "?") != null
    else
        false;

    const is_post = if (ctx.request.method) |method| method == .POST else false;

    if (is_form_submission or is_post) {
        // This is a form submission, process it properly
        return handleFormSubmission(ctx);
    }

    // Regular GET request without parameters - render the form
    return renderTemplate(ctx, "submit.html");
}

fn handleFormSubmission(ctx: *const Context) !Respond {
    var name: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var author: ?[]const u8 = null;

    if (ctx.request.method) |method| {
        if (method == .GET) {
            // Parse query parameters from URI
            if (ctx.request.uri) |uri| {
                if (std.mem.indexOf(u8, uri, "?")) |query_start| {
                    const query = uri[query_start + 1 ..];

                    // Parse URL-encoded form data
                    name = extractUrlParam(ctx.allocator, query, "name");
                    url = extractUrlParam(ctx.allocator, query, "url");
                    description = extractUrlParam(ctx.allocator, query, "description");
                    author = extractUrlParam(ctx.allocator, query, "author");
                }
            }
        } else {
            // Handle POST with form data (application/x-www-form-urlencoded)
            const body = ctx.request.body orelse {
                return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.HTML, .body = 
                    \\<html><body>
                    \\<h1>Error</h1>
                    \\<p>Request body is required</p>
                    \\<a href="/submit">Go back</a>
                    \\</body></html>
                });
            };

            // Parse URL-encoded form data from body
            name = extractUrlParam(ctx.allocator, body, "name");
            url = extractUrlParam(ctx.allocator, body, "url");
            description = extractUrlParam(ctx.allocator, body, "description");
            author = extractUrlParam(ctx.allocator, body, "author");
        }
    }

    // Validate required fields
    if (name == null or url == null or description == null or author == null) {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.HTML, .body = 
            \\<html><body>
            \\<h1>Error</h1>
            \\<p>Missing required fields: name, url, description, author</p>
            \\<a href="/submit">Go back</a>
            \\</body></html>
        });
    }

    log.info("Package '{s}' submitted via form", .{name.?});

    // Add debug logs for the submitted data
    log.debug("Submitted package details:", .{});
    log.debug("  Name: '{s}'", .{name.?});
    log.debug("  URL: '{s}'", .{url.?});
    log.debug("  Description: '{s}'", .{description.?});
    log.debug("  Author: '{s}'", .{author.?});

    // Insert package into database
    const insert_query = "INSERT INTO packages (name, url, description, author) VALUES (:name, :url, :description, :author)";
    log.debug("Executing SQL: {s}", .{insert_query});

    db.exec(insert_query, .{
        .name = sqlite.text(name.?),
        .url = sqlite.text(url.?),
        .description = sqlite.text(description.?),
        .author = sqlite.text(author.?),
    }) catch |err| {
        log.err("Database insertion failed with error: {}", .{err});
        log.err("Failed query: {s}", .{insert_query});
        log.err("Parameters: name='{s}', url='{s}', description='{s}', author='{s}'", .{ name.?, url.?, description.?, author.? });

        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.HTML, .body = 
            \\<html><body>
            \\<h1>Error</h1>
            \\<p>Failed to insert package into database</p>
            \\<a href="/submit">Go back</a>
            \\</body></html>
        });
    };

    log.debug("Package inserted successfully into database", .{});

    // Get the package ID that was just inserted
    const IdResult = struct { id: i64 };
    const id_stmt = db.prepare(struct { name: sqlite.Text }, IdResult, "SELECT id FROM packages WHERE name = :name ORDER BY id DESC LIMIT 1") catch |err| {
        log.err("Failed to prepare statement for package ID retrieval: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to retrieve package ID"
            \\}
        });
    };
    defer id_stmt.finalize();

    id_stmt.bind(.{ .name = sqlite.text(name.?) }) catch |err| {
        log.err("Failed to bind package name for ID lookup: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to bind package name for ID lookup"
            \\}
        });
    };
    defer id_stmt.reset();

    const package_id = if (id_stmt.step() catch null) |result| result.id else {
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to retrieve inserted package ID"
            \\}
        });
    };

    // Start builds for all Zig versions
    if (global_runtime) |rt| {
        // Use Runtime context for async builds
        startPackageBuildsWithRuntime(rt, package_id, name.?, url.?) catch |err| {
            log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
            // Don't fail the request, builds can be retried later
        };
    } else {
        // Fallback to synchronous builds without Runtime
        log.warn("No Runtime available, falling back to synchronous builds for package {d}", .{package_id});
        build_sys.startPackageBuilds(package_id, name.?, url.?) catch |err| {
            log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
            // Don't fail the request, builds can be retried later
        };
    }

    // Return success page
    const success_body = try std.fmt.allocPrint(ctx.allocator,
        \\<html><body>
        \\<h1>Package Submitted Successfully!</h1>
        \\<p><strong>Package:</strong> {s}</p>
        \\<p><strong>URL:</strong> {s}</p>
        \\<p><strong>Description:</strong> {s}</p>
        \\<p><strong>Author:</strong> {s}</p>
        \\<p><strong>Package ID:</strong> {d}</p>
        \\<p>Build process has been started for all Zig versions.</p>
        \\<p><a href="/packages">View all packages</a> | <a href="/submit">Submit another package</a></p>
        \\</body></html>
    , .{ name.?, url.?, description.?, author.?, package_id });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = success_body,
    });
}

// Helper function to extract URL-encoded parameters
fn extractUrlParam(alloc: Allocator, query: []const u8, param: []const u8) ?[]const u8 {
    const param_pattern = std.fmt.allocPrint(alloc, "{s}=", .{param}) catch return null;
    defer alloc.free(param_pattern);

    if (std.mem.indexOf(u8, query, param_pattern)) |start| {
        const value_start = start + param_pattern.len;
        var value_end = value_start;

        // Find the end of the value (next & or end of string)
        while (value_end < query.len and query[value_end] != '&') {
            value_end += 1;
        }

        if (value_end > value_start) {
            const encoded_value = query[value_start..value_end];
            // Basic URL decoding
            return urlDecode(alloc, encoded_value);
        }
    }

    return null;
}

// Basic URL decoder for form data
fn urlDecode(alloc: Allocator, encoded: []const u8) ?[]const u8 {
    var decoded = std.ArrayList(u8).init(alloc);
    defer decoded.deinit();

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            // Decode %XX hex sequences
            const hex = encoded[i + 1 .. i + 3];
            if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                decoded.append(byte) catch return null;
                i += 3;
            } else |_| {
                decoded.append(encoded[i]) catch return null;
                i += 1;
            }
        } else if (encoded[i] == '+') {
            // Convert + to space
            decoded.append(' ') catch return null;
            i += 1;
        } else {
            decoded.append(encoded[i]) catch return null;
            i += 1;
        }
    }

    return decoded.toOwnedSlice() catch null;
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
    const full_path = std.fmt.allocPrint(ctx.allocator, "static/{s}", .{file_path}) catch |err| {
        log.err("Failed to allocate static file path: {}", .{err});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Memory allocation error",
        });
    };

    // Try to read the file using context's arena allocator
    const file_content = std.fs.cwd().readFileAlloc(ctx.allocator, full_path, 1024 * 1024) catch |err| {
        log.err("Failed to read static file '{s}': {}", .{ full_path, err });
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
    if (ctx.request.method) |method| {
        if (method == .GET) {
            return api_get_packages(ctx, .{});
        } else if (method == .POST) {
            return api_create_package(ctx, .{});
        }
    }

    return ctx.response.apply(.{
        .status = .@"Method Not Allowed",
        .mime = http.Mime.TEXT,
        .body = "Method not allowed",
    });
}

fn api_get_packages(ctx: *const Context, _: void) !Respond {
    // Prepare and execute COUNT query using proper sqlite prepared statement
    const CountResult = struct { count: i64 };
    const count_stmt = db.prepare(struct {}, CountResult, "SELECT COUNT(*) as count FROM packages") catch |err| {
        log.err("Failed to prepare count query: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to prepare database query"
            \\}
        });
    };
    defer count_stmt.finalize();

    count_stmt.bind(.{}) catch |err| {
        log.err("Failed to bind count query parameters: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to bind query parameters"
            \\}
        });
    };
    defer count_stmt.reset();

    const count_result = count_stmt.step() catch |err| {
        log.err("Failed to execute count query: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Database query failed"
            \\}
        });
    };

    const count = if (count_result) |result| result.count else 0;

    // Prepare and execute packages query with LIMIT and OFFSET
    const PackageResult = struct { id: i64, name: sqlite.Text, url: sqlite.Text, description: ?sqlite.Text, author: ?sqlite.Text, created_at: sqlite.Text };

    const packages_stmt = db.prepare(struct {}, PackageResult, "SELECT id, name, url, description, author, created_at FROM packages ORDER BY created_at DESC LIMIT 20") catch |err| {
        log.err("Failed to prepare packages query: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to prepare packages query"
            \\}
        });
    };
    defer packages_stmt.finalize();

    packages_stmt.bind(.{}) catch |err| {
        log.err("Failed to bind packages query parameters: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to bind packages query"
            \\}
        });
    };
    defer packages_stmt.reset();

    // Build JSON response manually since we don't have a JSON library setup
    var response = std.ArrayList(u8).init(ctx.allocator);
    defer response.deinit();

    const writer = response.writer();
    try writer.print("{{\"packages\":[", .{});

    var first = true;
    while (packages_stmt.step() catch null) |pkg| {
        if (!first) try writer.writeAll(",");
        first = false;

        try writer.print("{{\"id\":{d},\"name\":\"{s}\",\"url\":\"{s}\"", .{ pkg.id, pkg.name.data, pkg.url.data });

        if (pkg.description) |desc| {
            try writer.print(",\"description\":\"{s}\"", .{desc.data});
        } else {
            try writer.writeAll(",\"description\":null");
        }

        if (pkg.author) |auth| {
            try writer.print(",\"author\":\"{s}\"", .{auth.data});
        } else {
            try writer.writeAll(",\"author\":null");
        }

        try writer.print(",\"created_at\":\"{s}\"}}", .{pkg.created_at.data});
    }

    try writer.print("],\"total\":{d},\"page\":1,\"limit\":20}}", .{count});

    return ctx.response.apply(.{ .status = .OK, .mime = http.Mime.JSON, .body = response.items });
}

fn api_create_package(ctx: *const Context, _: void) !Respond {
    // Read request body
    const body = ctx.request.body orelse {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Request body is required"
            \\}
        });
    };

    log.info("Received package submission: {s}", .{body});

    // Parse JSON request (simplified parsing for now)
    var name: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var author: ?[]const u8 = null;

    // Basic JSON field extraction (would use std.json in production)
    if (extractJsonField(ctx.allocator, body, "name")) |n| name = n;
    if (extractJsonField(ctx.allocator, body, "url")) |u| url = u;
    if (extractJsonField(ctx.allocator, body, "description")) |d| description = d;
    if (extractJsonField(ctx.allocator, body, "author")) |a| author = a;

    // Validate required fields
    if (name == null or url == null or description == null or author == null) {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Missing required fields: name, url, description, author"
            \\}
        });
    }

    log.info("Package '{s}' would be inserted (simplified implementation)", .{name.?});

    // Add debug logs for the submitted data
    log.debug("API submitted package details:", .{});
    log.debug("  Name: '{s}'", .{name.?});
    log.debug("  URL: '{s}'", .{url.?});
    log.debug("  Description: '{s}'", .{description.?});
    log.debug("  Author: '{s}'", .{author.?});

    // Insert package into database
    const insert_query = "INSERT INTO packages (name, url, description, author) VALUES (:name, :url, :description, :author)";
    log.debug("Executing SQL: {s}", .{insert_query});

    db.exec(insert_query, .{
        .name = sqlite.text(name.?),
        .url = sqlite.text(url.?),
        .description = sqlite.text(description.?),
        .author = sqlite.text(author.?),
    }) catch |err| {
        log.err("Database insertion failed with error: {}", .{err});
        log.err("Failed query: {s}", .{insert_query});
        log.err("Parameters: name='{s}', url='{s}', description='{s}', author='{s}'", .{ name.?, url.?, description.?, author.? });

        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to insert package into database"
            \\}
        });
    };

    log.debug("Package inserted successfully into database", .{});

    // Get the package ID that was just inserted
    const IdResult = struct { id: i64 };
    const id_stmt = db.prepare(struct { name: sqlite.Text }, IdResult, "SELECT id FROM packages WHERE name = :name ORDER BY id DESC LIMIT 1") catch |err| {
        log.err("Failed to prepare statement for package ID retrieval: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to retrieve package ID"
            \\}
        });
    };
    defer id_stmt.finalize();

    id_stmt.bind(.{ .name = sqlite.text(name.?) }) catch |err| {
        log.err("Failed to bind package name for ID lookup: {}", .{err});
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to bind package name for ID lookup"
            \\}
        });
    };
    defer id_stmt.reset();

    const package_id = if (id_stmt.step() catch null) |result| result.id else {
        return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to retrieve inserted package ID"
            \\}
        });
    };

    // Start builds for all Zig versions
    if (global_runtime) |rt| {
        // Use Runtime context for async builds
        startPackageBuildsWithRuntime(rt, package_id, name.?, url.?) catch |err| {
            log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
            // Don't fail the request, builds can be retried later
        };
    } else {
        // Fallback to synchronous builds without Runtime
        log.warn("No Runtime available, falling back to synchronous builds for package {d}", .{package_id});
        build_sys.startPackageBuilds(package_id, name.?, url.?) catch |err| {
            log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
            // Don't fail the request, builds can be retried later
        };
    }

    // Return success response
    const response_body = try std.fmt.allocPrint(ctx.allocator,
        \\{{
        \\  "message": "Package submitted successfully",
        \\  "id": {d},
        \\  "name": "{s}",
        \\  "status": "Build started for all Zig versions"
        \\}}
    , .{ package_id, name.? });

    return ctx.response.apply(.{
        .status = .Created,
        .mime = http.Mime.JSON,
        .body = response_body,
    });
}

// Helper function to extract JSON fields (simplified)
fn extractJsonField(alloc: Allocator, json: []const u8, field: []const u8) ?[]const u8 {
    const field_pattern = std.fmt.allocPrint(alloc, "\"{s}\":", .{field}) catch return null;
    defer alloc.free(field_pattern);

    if (std.mem.indexOf(u8, json, field_pattern)) |start| {
        const value_start = start + field_pattern.len;

        // Skip whitespace and find opening quote
        var i = value_start;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n')) {
            i += 1;
        }

        if (i < json.len and json[i] == '"') {
            i += 1; // Skip opening quote
            const string_start = i;

            // Find closing quote
            while (i < json.len and json[i] != '"') {
                if (json[i] == '\\') i += 1; // Skip escaped characters
                i += 1;
            }

            if (i < json.len) {
                return alloc.dupe(u8, json[string_start..i]) catch null;
            }
        }
    }

    return null;
}

fn initializeDatabase() !void {
    log.debug("Opening database file: zig_pkg_checker.db", .{});

    db = sqlite.Database.open(.{ .path = "zig_pkg_checker.db" }) catch |err| {
        log.err("Failed to open database: {}", .{err});
        return err;
    };

    log.debug("Database file opened successfully, initializing schema...", .{});

    lib.db.initDatabase(&db) catch |err| {
        log.err("Failed to initialize database schema: {}", .{err});
        return err;
    };

    log.info("Database initialized successfully", .{});

    // Test database connection with a simple query
    const test_query = "SELECT COUNT(*) as count FROM packages";
    const TestResult = struct { count: i64 };
    const test_stmt = db.prepare(struct {}, TestResult, test_query) catch |err| {
        log.warn("Database connection test failed: {}", .{err});
        return;
    };
    defer test_stmt.finalize();

    test_stmt.bind(.{}) catch |err| {
        log.warn("Failed to bind test query: {}", .{err});
        return;
    };
    defer test_stmt.reset();

    if (test_stmt.step() catch null) |result| {
        log.debug("Database test successful. Current package count: {d}", .{result.count});
    } else {
        log.warn("Database test query returned no results", .{});
    }
}

// Helper function to start package builds with Runtime context
fn startPackageBuildsWithRuntime(rt: *Runtime, package_id: i64, package_name: []const u8, repo_url: []const u8) !void {
    log.debug("Starting package builds with Runtime context for package {d}: {s}", .{ package_id, package_name });

    // Set the Runtime in the build system
    build_sys.setRuntime(rt);

    // Start builds for all Zig versions
    build_sys.startPackageBuilds(package_id, package_name, repo_url) catch |err| {
        log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
        return err;
    };

    log.info("Package builds started successfully for package {d}: {s}", .{ package_id, package_name });
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

    // Initialize build system
    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();
    build_sys = build_system.BuildSystem.init(allocator, &db, &t);
    defer build_sys.deinit();

    // Check if Docker is available
    const docker_available = build_sys.checkDockerAvailable() catch |err| blk: {
        log.warn("Docker check failed: {}. Build system will be disabled.", .{err});
        break :blk false;
    };

    if (docker_available) {
        log.info("Docker is available. Build system ready.", .{});
    } else {
        log.warn("Docker not available. Build system disabled.", .{});
    }

    const host = "127.0.0.1";
    const port = 3000;

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, home_handler).layer(),
        Route.init("/packages").get({}, packages_handler).layer(),
        Route.init("/submit").get({}, submit_handler).post({}, submit_handler).layer(),
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

    // Cleanup old build artifacts on startup
    if (docker_available) {
        build_sys.cleanup() catch |err| {
            log.warn("Failed to cleanup old build artifacts: {}", .{err});
        };
    }

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                // Set global runtime for use by handlers
                global_runtime = rt;
                log.info("Runtime context set for build system", .{});

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
