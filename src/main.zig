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
const Dir = tardy.Dir;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const FsDir = http.FsDir;

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("zig_pkg_checker_lib");
const build_system = @import("build_system.zig");
const template_engine = @import("template_engine.zig");

var db: sqlite.Database = undefined;
var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var allocator: Allocator = undefined;
var build_sys: build_system.BuildSystem = undefined;
var global_runtime: ?*Runtime = null;

// Template data structures
const PackageTemplateData = struct {
    packages: []Package,

    const Package = struct {
        name: []const u8,
        author: []const u8,
        description: []const u8,
        url: []const u8,
        license: ?[]const u8,
        last_updated: []const u8,
        build_results: []BuildResult,

        const BuildResult = struct {
            zig_version: []const u8,
            build_status: []const u8, // "success", "failed", "pending"
        };
    };
};

// Template rendering helpers
fn renderTemplate(ctx: *const Context, template_name: []const u8) !Respond {
    return renderTemplateWithData(ctx, template_name, struct {}{});
}

fn renderTemplateWithData(ctx: *const Context, template_name: []const u8, data: anytype) !Respond {
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

    // Initialize template engine
    const engine = template_engine.TemplateEngine.init(ctx.allocator);

    log.debug("renderTemplateWithData: About to render template with {} packages", .{if (@TypeOf(data) == PackageTemplateData) data.packages.len else 0});

    // Render the content template with data
    const rendered_content = engine.renderTemplate(template_content, data) catch |err| {
        log.err("Failed to render template content {s}: {}", .{ template_name, err });
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Template rendering error",
        });
    };
    defer ctx.allocator.free(rendered_content);

    log.debug("renderTemplateWithData: Template rendered successfully, content length: {}", .{rendered_content.len});

    // Find the placeholder in base template
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
    const total_size = before_placeholder.len + rendered_content.len + after_placeholder.len;

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
    @memcpy(rendered[pos .. pos + rendered_content.len], rendered_content);
    pos += rendered_content.len;
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
    log.debug("packages_handler: Starting to fetch packages from database", .{});

    // Fetch packages from database
    const packages_data = fetchPackagesForTemplate(ctx.allocator) catch |err| {
        log.err("Failed to fetch packages for template: {}", .{err});
        // Return template with empty data on error
        return renderTemplateWithData(ctx, "packages.html", PackageTemplateData{ .packages = &[_]PackageTemplateData.Package{} });
    };
    defer freePackagesTemplateData(ctx.allocator, packages_data);

    log.debug("packages_handler: Fetched {} packages from database", .{packages_data.packages.len});

    // Log each package for debugging
    for (packages_data.packages, 0..) |package, i| {
        log.debug("Package {}: name='{s}', author='{s}', description='{s}', build_results_count={}", .{ i, package.name, package.author, package.description, package.build_results.len });

        for (package.build_results, 0..) |result, j| {
            log.debug("  Build result {}: zig_version='{s}', status='{s}'", .{ j, result.zig_version, result.build_status });
        }
    }

    return renderTemplateWithData(ctx, "packages.html", packages_data);
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

// GitHub repository information structure
const GitHubRepoInfo = struct {
    name: []const u8,
    author: []const u8,
    description: ?[]const u8,
    license: ?[]const u8,
    language: ?[]const u8,
    url: []const u8,
};

fn handleFormSubmission(ctx: *const Context) !Respond {
    var url: ?[]const u8 = null;

    if (ctx.request.method) |method| {
        if (method == .GET) {
            // Parse query parameters from URI
            if (ctx.request.uri) |uri| {
                if (std.mem.indexOf(u8, uri, "?")) |query_start| {
                    const query = uri[query_start + 1 ..];
                    url = extractUrlParam(ctx.allocator, query, "url");
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
            url = extractUrlParam(ctx.allocator, body, "url");
        }
    }

    // Validate required field
    if (url == null) {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.HTML, .body = 
            \\<html><body>
            \\<h1>Error</h1>
            \\<p>Missing required field: url</p>
            \\<a href="/submit">Go back</a>
            \\</body></html>
        });
    }

    log.info("Package submission for URL: '{s}'", .{url.?});

    // Fetch repository information from GitHub
    const repo_info = fetchGitHubRepoInfo(ctx.allocator, url.?) catch |err| {
        log.err("Failed to fetch GitHub repository info for {s}: {}", .{ url.?, err });
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.HTML, .body = 
            \\<html><body>
            \\<h1>Error</h1>
            \\<p>Failed to fetch repository information from GitHub. Please ensure the URL is correct and the repository is public.</p>
            \\<a href="/submit">Go back</a>
            \\</body></html>
        });
    };
    defer freeGitHubRepoInfo(ctx.allocator, repo_info);

    // Add debug logs for the fetched data
    log.debug("Fetched repository details:", .{});
    log.debug("  Name: '{s}'", .{repo_info.name});
    log.debug("  URL: '{s}'", .{repo_info.url});
    log.debug("  Description: '{s}'", .{repo_info.description orelse "null"});
    log.debug("  Author: '{s}'", .{repo_info.author});
    log.debug("  License: '{s}'", .{repo_info.license orelse "null"});

    // Insert package into database
    const insert_query = "INSERT INTO packages (name, url, description, author, license) VALUES (:name, :url, :description, :author, :license)";
    log.debug("Executing SQL: {s}", .{insert_query});

    db.exec(insert_query, .{
        .name = sqlite.text(repo_info.name),
        .url = sqlite.text(repo_info.url),
        .description = sqlite.text(repo_info.description orelse ""),
        .author = sqlite.text(repo_info.author),
        .license = if (repo_info.license) |lic| sqlite.text(lic) else null,
    }) catch |err| {
        log.err("Database insertion failed with error: {}", .{err});
        log.err("Failed query: {s}", .{insert_query});
        log.err("Parameters: name='{s}', url='{s}', description='{s}', author='{s}', license='{s}'", .{ repo_info.name, repo_info.url, repo_info.description orelse "null", repo_info.author, repo_info.license orelse "null" });

        // Check if this is a constraint violation (package already exists)
        if (err == error.SQLITE_CONSTRAINT) {
            return ctx.response.apply(.{ .status = .Conflict, .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Package already exists. A package with this name or URL has already been submitted."
                \\}
            });
        }

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

    id_stmt.bind(.{ .name = sqlite.text(repo_info.name) }) catch |err| {
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
        startPackageBuildsWithRuntime(rt, package_id, repo_info.name, repo_info.url) catch |err| {
            log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
            // Don't fail the request, builds can be retried later
        };
    } else {
        // Fallback to synchronous builds without Runtime
        log.warn("No Runtime available, falling back to synchronous builds for package {d}", .{package_id});
        build_sys.startPackageBuilds(package_id, repo_info.name, repo_info.url) catch |err| {
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
        \\<p><strong>License:</strong> {s}</p>
        \\<p><strong>Package ID:</strong> {d}</p>
        \\<p>Build process has been started for all Zig versions.</p>
        \\<p><a href="/packages">View all packages</a> | <a href="/submit">Submit another package</a></p>
        \\</body></html>
    , .{ repo_info.name, repo_info.url, repo_info.description orelse "No description", repo_info.author, repo_info.license orelse "No license", package_id });

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

// Test handler for debugging routes
fn test_handler(ctx: *const Context, _: void) !Respond {
    const path = ctx.request.uri orelse "/";
    log.info("test_handler: Received request for path: '{s}'", .{path});

    const response_body = try std.fmt.allocPrint(ctx.allocator,
        \\<html><body>
        \\<h1>Test Handler</h1>
        \\<p>Received request for: {s}</p>
        \\</body></html>
    , .{path});

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = response_body,
    });
}

// Static file serving is now handled by FsDir middleware

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

fn api_github_info_handler(ctx: *const Context, _: void) !Respond {
    if (ctx.request.method) |method| {
        if (method == .POST) {
            return api_get_github_info(ctx);
        }
    }

    return ctx.response.apply(.{
        .status = .@"Method Not Allowed",
        .mime = http.Mime.TEXT,
        .body = "Method not allowed",
    });
}

fn api_get_github_info(ctx: *const Context) !Respond {
    // Read request body
    const body = ctx.request.body orelse {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Request body is required"
            \\}
        });
    };

    log.debug("Received GitHub info request: {s}", .{body});

    // Extract URL from JSON request
    const url = extractJsonField(ctx.allocator, body, "url") orelse {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Missing required field: url"
            \\}
        });
    };
    defer ctx.allocator.free(url);

    // Validate GitHub URL
    if (!isValidGitHubUrl(url)) {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Invalid GitHub URL format"
            \\}
        });
    }

    // Fetch repository information from GitHub
    const repo_info = fetchGitHubRepoInfo(ctx.allocator, url) catch |err| {
        log.err("Failed to fetch GitHub repository info for {s}: {}", .{ url, err });
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to fetch repository information from GitHub"
            \\}
        });
    };
    defer freeGitHubRepoInfo(ctx.allocator, repo_info);

    // Build JSON response
    const response_body = try std.fmt.allocPrint(ctx.allocator,
        \\{{
        \\  "name": "{s}",
        \\  "author": "{s}",
        \\  "description": "{s}",
        \\  "license": "{s}",
        \\  "language": "{s}",
        \\  "url": "{s}"
        \\}}
    , .{ repo_info.name, repo_info.author, repo_info.description orelse "", repo_info.license orelse "", repo_info.language orelse "", repo_info.url });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = response_body,
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

    // Extract URL from JSON request
    const url = extractJsonField(ctx.allocator, body, "url") orelse {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Missing required field: url"
            \\}
        });
    };
    defer ctx.allocator.free(url);

    log.info("Package submission for URL: '{s}'", .{url});

    // Fetch repository information from GitHub
    const repo_info = fetchGitHubRepoInfo(ctx.allocator, url) catch |err| {
        log.err("Failed to fetch GitHub repository info for {s}: {}", .{ url, err });
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Failed to fetch repository information from GitHub"
            \\}
        });
    };
    defer freeGitHubRepoInfo(ctx.allocator, repo_info);

    // Add debug logs for the fetched data
    log.debug("API fetched repository details:", .{});
    log.debug("  Name: '{s}'", .{repo_info.name});
    log.debug("  URL: '{s}'", .{repo_info.url});
    log.debug("  Description: '{s}'", .{repo_info.description orelse "null"});
    log.debug("  Author: '{s}'", .{repo_info.author});
    log.debug("  License: '{s}'", .{repo_info.license orelse "null"});

    // Insert package into database
    const insert_query = "INSERT INTO packages (name, url, description, author, license) VALUES (:name, :url, :description, :author, :license)";
    log.debug("Executing SQL: {s}", .{insert_query});

    db.exec(insert_query, .{
        .name = sqlite.text(repo_info.name),
        .url = sqlite.text(repo_info.url),
        .description = sqlite.text(repo_info.description orelse ""),
        .author = sqlite.text(repo_info.author),
        .license = if (repo_info.license) |lic| sqlite.text(lic) else null,
    }) catch |err| {
        log.err("Database insertion failed with error: {}", .{err});
        log.err("Failed query: {s}", .{insert_query});
        log.err("Parameters: name='{s}', url='{s}', description='{s}', author='{s}', license='{s}'", .{ repo_info.name, repo_info.url, repo_info.description orelse "null", repo_info.author, repo_info.license orelse "null" });

        // Check if this is a constraint violation (package already exists)
        if (err == error.SQLITE_CONSTRAINT) {
            return ctx.response.apply(.{ .status = .Conflict, .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Package already exists. A package with this name or URL has already been submitted."
                \\}
            });
        }

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

    id_stmt.bind(.{ .name = sqlite.text(repo_info.name) }) catch |err| {
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
        startPackageBuildsWithRuntime(rt, package_id, repo_info.name, repo_info.url) catch |err| {
            log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
            // Don't fail the request, builds can be retried later
        };
    } else {
        // Fallback to synchronous builds without Runtime
        log.warn("No Runtime available, falling back to synchronous builds for package {d}", .{package_id});
        build_sys.startPackageBuilds(package_id, repo_info.name, repo_info.url) catch |err| {
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
        \\  "author": "{s}",
        \\  "status": "Build started for all Zig versions"
        \\}}
    , .{ package_id, repo_info.name, repo_info.author });

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

// Helper function to validate GitHub URLs
fn isValidGitHubUrl(url: []const u8) bool {
    const github_pattern = "https://github.com/";
    if (!std.mem.startsWith(u8, url, github_pattern)) return false;

    const path = url[github_pattern.len..];

    // Should have format: owner/repo or owner/repo/
    const slash_count = std.mem.count(u8, path, "/");
    if (slash_count < 1 or slash_count > 2) return false;

    // If there are 2 slashes, the last one should be at the end
    if (slash_count == 2 and !std.mem.endsWith(u8, path, "/")) return false;

    return true;
}

// Function to fetch GitHub repository information
fn fetchGitHubRepoInfo(alloc: Allocator, github_url: []const u8) !GitHubRepoInfo {
    log.debug("Fetching GitHub repo info for: {s}", .{github_url});

    // Extract owner and repo name from URL
    const github_prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, github_url, github_prefix)) {
        return error.InvalidUrl;
    }

    var path = github_url[github_prefix.len..];
    if (std.mem.endsWith(u8, path, "/")) {
        path = path[0 .. path.len - 1];
    }

    const slash_pos = std.mem.indexOf(u8, path, "/") orelse return error.InvalidUrl;
    const owner = path[0..slash_pos];
    const repo = path[slash_pos + 1 ..];

    log.debug("Extracted owner: '{s}', repo: '{s}'", .{ owner, repo });

    // Build GitHub API URL
    const api_url = try std.fmt.allocPrint(alloc, "https://api.github.com/repos/{s}/{s}", .{ owner, repo });
    defer alloc.free(api_url);

    log.debug("GitHub API URL: {s}", .{api_url});

    // Make HTTP request to GitHub API
    const response_body = makeGitHubRequest(alloc, api_url) catch |err| {
        log.err("Failed to make GitHub API request: {}", .{err});
        return err;
    };
    defer alloc.free(response_body);

    log.debug("GitHub API response received, length: {}", .{response_body.len});

    // Parse the JSON response and extract fields
    const name = extractJsonField(alloc, response_body, "name") orelse return error.ParseError;
    const description = extractJsonField(alloc, response_body, "description");
    const language = extractJsonField(alloc, response_body, "language");

    // Get owner information
    const owner_name = extractOwnerFromResponse(alloc, response_body) orelse return error.ParseError;

    // Get license information
    const license = extractLicenseFromResponse(alloc, response_body);

    log.debug("Parsed repo info - name: '{s}', owner: '{s}', description: '{s}', license: '{s}'", .{ name, owner_name, description orelse "null", license orelse "null" });

    return GitHubRepoInfo{
        .name = name,
        .author = owner_name,
        .description = description,
        .license = license,
        .language = language,
        .url = try alloc.dupe(u8, github_url),
    };
}

// Helper function to make HTTP requests to GitHub API
fn makeGitHubRequest(alloc: Allocator, url: []const u8) ![]u8 {
    log.debug("Making HTTP request to: {s}", .{url});

    // Initialize HTTP client
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    // Parse the URL
    const uri = std.Uri.parse(url) catch |err| {
        log.err("Failed to parse URL: {}", .{err});
        return error.InvalidUrl;
    };

    // Prepare headers for GitHub API
    var headers = std.ArrayList(std.http.Header).init(alloc);
    defer headers.deinit();

    try headers.append(.{ .name = "User-Agent", .value = "zig-pkg-checker/1.0" });
    try headers.append(.{ .name = "Accept", .value = "application/vnd.github.v3+json" });

    // Prepare response storage
    var response_body = std.ArrayList(u8).init(alloc);
    defer response_body.deinit();

    // Make the request using fetch
    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .extra_headers = headers.items,
        .response_storage = .{ .dynamic = &response_body },
        .max_append_size = 1024 * 1024, // 1MB limit
    }) catch |err| {
        log.err("Failed to make HTTP request: {}", .{err});
        return err;
    };

    if (result.status != .ok) {
        log.err("GitHub API returned status: {}", .{result.status});
        return error.HttpError;
    }

    log.debug("HTTP response received, length: {}", .{response_body.items.len});

    // Return a copy of the response body
    return alloc.dupe(u8, response_body.items);
}

// Helper function to extract owner from GitHub API response
fn extractOwnerFromResponse(alloc: Allocator, response: []const u8) ?[]const u8 {
    // Look for "owner":{"login":"username",...}
    const owner_start = std.mem.indexOf(u8, response, "\"owner\":") orelse return null;
    const login_start = std.mem.indexOf(u8, response[owner_start..], "\"login\":") orelse return null;
    const quote_start = owner_start + login_start + 8; // Skip "login":

    // Find the opening quote
    var i = quote_start;
    while (i < response.len and response[i] != '"') i += 1;
    if (i >= response.len) return null;

    i += 1; // Skip opening quote
    const value_start = i;

    // Find closing quote
    while (i < response.len and response[i] != '"') {
        if (response[i] == '\\') i += 1; // Skip escaped characters
        i += 1;
    }

    if (i < response.len) {
        return alloc.dupe(u8, response[value_start..i]) catch null;
    }

    return null;
}

// Helper function to extract license from GitHub API response
fn extractLicenseFromResponse(alloc: Allocator, response: []const u8) ?[]const u8 {
    // Look for "license":{"name":"MIT License",...} or "license":null
    const license_start = std.mem.indexOf(u8, response, "\"license\":") orelse return null;
    const value_start = license_start + 10; // Skip "license":

    // Skip whitespace
    var i = value_start;
    while (i < response.len and (response[i] == ' ' or response[i] == '\t')) i += 1;

    if (i < response.len and response[i] == 'n') {
        // Check if it's "null"
        if (std.mem.startsWith(u8, response[i..], "null")) {
            return null;
        }
    }

    if (i < response.len and response[i] == '{') {
        // Look for "name" field in license object
        const name_start = std.mem.indexOf(u8, response[i..], "\"name\":") orelse return null;
        const name_field_start = i + name_start + 7; // Skip "name":

        // Skip whitespace and find opening quote
        var j = name_field_start;
        while (j < response.len and (response[j] == ' ' or response[j] == '\t')) j += 1;

        if (j < response.len and response[j] == '"') {
            j += 1; // Skip opening quote
            const license_name_start = j;

            // Find closing quote
            while (j < response.len and response[j] != '"') {
                if (response[j] == '\\') j += 1; // Skip escaped characters
                j += 1;
            }

            if (j < response.len) {
                return alloc.dupe(u8, response[license_name_start..j]) catch null;
            }
        }
    }

    return null;
}

// Helper function to free GitHubRepoInfo
fn freeGitHubRepoInfo(alloc: Allocator, info: GitHubRepoInfo) void {
    alloc.free(info.name);
    alloc.free(info.author);
    if (info.description) |desc| alloc.free(desc);
    if (info.license) |lic| alloc.free(lic);
    if (info.language) |lang| alloc.free(lang);
    alloc.free(info.url);
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

fn fetchPackagesForTemplate(alloc: Allocator) !PackageTemplateData {
    log.debug("fetchPackagesForTemplate: Starting database query for packages", .{});

    // Prepare query to get packages with their build results
    const PackageRow = struct {
        id: i64,
        name: sqlite.Text,
        url: sqlite.Text,
        description: ?sqlite.Text,
        author: ?sqlite.Text,
        license: ?sqlite.Text,
        created_at: sqlite.Text,
    };

    const packages_query = "SELECT id, name, url, description, author, license, created_at FROM packages ORDER BY created_at DESC LIMIT 50";
    log.debug("fetchPackagesForTemplate: Executing query: {s}", .{packages_query});

    var packages_stmt = db.prepare(struct {}, PackageRow, packages_query) catch |err| {
        log.err("Failed to prepare packages query: {}", .{err});
        return error.DatabaseError;
    };
    defer packages_stmt.finalize();

    packages_stmt.bind(.{}) catch |err| {
        log.err("Failed to bind packages query: {}", .{err});
        return error.DatabaseError;
    };
    defer packages_stmt.reset();

    var packages = std.ArrayList(PackageTemplateData.Package).init(alloc);
    defer packages.deinit();

    var package_count: usize = 0;
    while (packages_stmt.step() catch null) |pkg| {
        package_count += 1;
        log.debug("fetchPackagesForTemplate: Processing package {} - id={}, name='{s}', author='{s}'", .{ package_count, pkg.id, pkg.name.data, if (pkg.author) |auth| auth.data else "null" });

        // Fetch build results for this package
        const build_results = fetchBuildResultsForPackage(alloc, pkg.id) catch |err| {
            log.err("Failed to fetch build results for package {d}: {}", .{ pkg.id, err });
            &[_]PackageTemplateData.Package.BuildResult{};
        };

        log.debug("fetchPackagesForTemplate: Package {} has {} build results", .{ pkg.id, build_results.len });

        const package = PackageTemplateData.Package{
            .name = alloc.dupe(u8, pkg.name.data) catch |err| {
                log.err("Failed to duplicate package name: {}", .{err});
                continue;
            },
            .author = if (pkg.author) |auth| alloc.dupe(u8, auth.data) catch |err| {
                log.err("Failed to duplicate author name: {}", .{err});
                _ = "Unknown";
                continue;
            } else "Unknown",
            .description = if (pkg.description) |desc| alloc.dupe(u8, desc.data) catch |err| {
                log.err("Failed to duplicate description: {}", .{err});
                _ = "";
                continue;
            } else "",
            .url = alloc.dupe(u8, pkg.url.data) catch |err| {
                log.err("Failed to duplicate URL: {}", .{err});
                continue;
            },
            .license = if (pkg.license) |lic| alloc.dupe(u8, lic.data) catch null else null,
            .last_updated = alloc.dupe(u8, pkg.created_at.data) catch |err| {
                log.err("Failed to duplicate created_at: {}", .{err});
                _ = "Unknown";
                continue;
            },
            .build_results = build_results,
        };

        packages.append(package) catch |err| {
            log.err("Failed to append package to list: {}", .{err});
            continue;
        };
    }

    log.debug("fetchPackagesForTemplate: Successfully processed {} packages", .{package_count});

    const result = PackageTemplateData{
        .packages = packages.toOwnedSlice() catch return error.OutOfMemory,
    };

    log.debug("fetchPackagesForTemplate: Returning {} packages in template data", .{result.packages.len});

    return result;
}

fn fetchBuildResultsForPackage(alloc: Allocator, package_id: i64) ![]PackageTemplateData.Package.BuildResult {
    log.debug("fetchBuildResultsForPackage: Fetching build results for package {}", .{package_id});

    const BuildResultRow = struct {
        zig_version: sqlite.Text,
        build_status: sqlite.Text,
    };

    const build_query = "SELECT zig_version, build_status FROM build_results WHERE package_id = :package_id ORDER BY zig_version";
    log.debug("fetchBuildResultsForPackage: Executing query: {s} with package_id={}", .{ build_query, package_id });

    var build_stmt = db.prepare(struct { package_id: i64 }, BuildResultRow, build_query) catch |err| {
        log.err("Failed to prepare build results query: {}", .{err});
        return &[_]PackageTemplateData.Package.BuildResult{};
    };
    defer build_stmt.finalize();

    build_stmt.bind(.{ .package_id = package_id }) catch |err| {
        log.err("Failed to bind build results query: {}", .{err});
        return &[_]PackageTemplateData.Package.BuildResult{};
    };
    defer build_stmt.reset();

    var build_results = std.ArrayList(PackageTemplateData.Package.BuildResult).init(alloc);
    defer build_results.deinit();

    var result_count: usize = 0;
    while (build_stmt.step() catch null) |result| {
        result_count += 1;
        log.debug("fetchBuildResultsForPackage: Build result {} - zig_version='{s}', status='{s}'", .{ result_count, result.zig_version.data, result.build_status.data });

        const build_result = PackageTemplateData.Package.BuildResult{
            .zig_version = alloc.dupe(u8, result.zig_version.data) catch |err| {
                log.err("Failed to duplicate zig_version: {}", .{err});
                continue;
            },
            .build_status = alloc.dupe(u8, result.build_status.data) catch |err| {
                log.err("Failed to duplicate build_status: {}", .{err});
                continue;
            },
        };

        build_results.append(build_result) catch |err| {
            log.err("Failed to append build result: {}", .{err});
            continue;
        };
    }

    log.debug("fetchBuildResultsForPackage: Package {} has {} build results", .{ package_id, result_count });

    return build_results.toOwnedSlice() catch return &[_]PackageTemplateData.Package.BuildResult{};
}

fn freePackagesTemplateData(alloc: Allocator, data: PackageTemplateData) void {
    for (data.packages) |package| {
        alloc.free(package.name);
        alloc.free(package.author);
        alloc.free(package.description);
        alloc.free(package.url);
        if (package.license) |license| {
            alloc.free(license);
        }
        alloc.free(package.last_updated);

        for (package.build_results) |build_result| {
            alloc.free(build_result.zig_version);
            alloc.free(build_result.build_status);
        }
        alloc.free(package.build_results);
    }
    alloc.free(data.packages);
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

    // Create static directory for serving files
    const static_dir = Dir.from_std(try std.fs.cwd().openDir("static", .{}));

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, home_handler).layer(),
        Route.init("/packages").get({}, packages_handler).layer(),
        Route.init("/submit").get({}, submit_handler).post({}, submit_handler).layer(),
        Route.init("/stats").get({}, stats_handler).layer(),
        Route.init("/api").get({}, api_docs_handler).layer(),
        FsDir.serve("/static", static_dir),
        Route.init("/api/health").get({}, api_health_handler).layer(),
        Route.init("/api/github-info").post({}, api_github_info_handler).layer(),
        Route.init("/api/packages").get({}, api_get_packages).post({}, api_create_package).layer(),
        Route.init("/test").get({}, test_handler).layer(),
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
    log.info("  - POST /api/github-info - Get GitHub repository info", .{});
    log.info("  - GET /api/packages - List packages", .{});
    log.info("  - POST /api/packages - Submit package", .{});
    log.info("  - GET /test        - Test handler", .{});

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
