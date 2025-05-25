//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const log = std.log.scoped(.main);
const Allocator = std.mem.Allocator;

// Configure log level to ensure logging works in all build modes
pub const std_options: std.Options = .{
    .log_level = .info,
};

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

// Admin authentication system
const ADMIN_TOKEN = "zig-pkg-checker-admin-2024"; // Simple stub token
var cron_system: ?*CronSystem = null;

// Cron job system for automated tasks
const CronSystem = struct {
    allocator: Allocator,
    runtime: *Runtime,
    db: *sqlite.Database,
    build_system: *build_system.BuildSystem,
    daily_thread: ?std.Thread = null,
    build_check_thread: ?std.Thread = null,
    is_running: bool = false,

    const Self = @This();

    pub fn init(alloc: Allocator, runtime: *Runtime, database: *sqlite.Database, build_sys_ptr: *build_system.BuildSystem) !*Self {
        const self = try alloc.create(Self);
        self.* = Self{
            .allocator = alloc,
            .runtime = runtime,
            .db = database,
            .build_system = build_sys_ptr,
            .daily_thread = null,
            .build_check_thread = null,
            .is_running = false,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        if (self.is_running) return;

        log.info("Starting cron system for automated build checks", .{});

        self.is_running = true;

        // Spawn background thread for daily checks
        self.daily_thread = std.Thread.spawn(.{
            .stack_size = 2 * 1024 * 1024, // 2MB stack
        }, dailyCheckTask, .{self}) catch |err| {
            log.err("Failed to spawn daily check task: {}", .{err});
            self.is_running = false;
            return err;
        };

        // Spawn background thread for build health checks
        self.build_check_thread = std.Thread.spawn(.{
            .stack_size = 2 * 1024 * 1024, // 2MB stack
        }, buildHealthCheckTask, .{self}) catch |err| {
            log.err("Failed to spawn build health check task: {}", .{err});
            if (self.daily_thread) |thread| {
                self.is_running = false;
                thread.join();
                self.daily_thread = null;
            }
            return err;
        };

        log.info("Cron system started successfully", .{});
    }

    pub fn stop(self: *Self) void {
        if (!self.is_running) return;

        log.info("Stopping cron system", .{});

        self.is_running = false;

        if (self.daily_thread) |thread| {
            thread.join();
            self.daily_thread = null;
        }

        if (self.build_check_thread) |thread| {
            thread.join();
            self.build_check_thread = null;
        }

        log.info("Cron system stopped", .{});
    }

    // Daily task to check for packages that need builds
    fn dailyCheckTask(self: *Self) void {
        log.info("Starting daily package check task", .{});

        while (self.is_running) {
            // Sleep for 24 hours, but check every minute if we should stop
            const total_sleep_minutes = 24 * 60; // 24 hours in minutes
            var minutes_slept: u32 = 0;

            while (minutes_slept < total_sleep_minutes and self.is_running) {
                std.time.sleep(60 * std.time.ns_per_s); // Sleep 1 minute
                minutes_slept += 1;
            }

            if (!self.is_running) break;

            log.info("Executing daily package build check", .{});
            self.checkAllPackagesForBuilds() catch |err| {
                log.err("Daily package check failed: {}", .{err});
            };
        }

        log.info("Daily check task terminated", .{});
    }

    // Build health check task to detect stalled builds
    fn buildHealthCheckTask(self: *Self) void {
        log.info("Starting build health check task", .{});

        while (self.is_running) {
            // Sleep for 30 minutes, but check every minute if we should stop
            const total_sleep_minutes = 30; // 30 minutes
            var minutes_slept: u32 = 0;

            while (minutes_slept < total_sleep_minutes and self.is_running) {
                std.time.sleep(60 * std.time.ns_per_s); // Sleep 1 minute
                minutes_slept += 1;
            }

            if (!self.is_running) break;

            log.info("Executing build health check", .{});
            self.checkStalledBuilds() catch |err| {
                log.err("Build health check failed: {}", .{err});
            };
        }

        log.info("Build health check task terminated", .{});
    }

    // Check all packages for missing or outdated builds
    fn checkAllPackagesForBuilds(self: *Self) !void {
        log.info("Checking all packages for missing builds", .{});

        const PackageRow = struct {
            id: i64,
            name: sqlite.Text,
            url: sqlite.Text,
            last_updated: sqlite.Text,
        };

        const query = "SELECT id, name, url, last_updated FROM packages ORDER BY last_updated ASC";
        var stmt = self.db.prepare(struct {}, PackageRow, query) catch |err| {
            log.err("Failed to prepare packages query for daily check: {}", .{err});
            return err;
        };
        defer stmt.finalize();

        stmt.bind(.{}) catch |err| {
            log.err("Failed to bind packages query for daily check: {}", .{err});
            return err;
        };
        defer stmt.reset();

        var packages_checked: usize = 0;
        var builds_started: usize = 0;

        while (stmt.step() catch null) |pkg| {
            packages_checked += 1;

            // Check if package has builds for all Zig versions
            const missing_builds = try self.getMissingBuildsForPackage(pkg.id);
            defer self.allocator.free(missing_builds);

            if (missing_builds.len > 0) {
                log.info("Package '{s}' (ID: {d}) is missing builds for {d} Zig versions", .{ pkg.name.data, pkg.id, missing_builds.len });

                // Start builds for missing versions
                const package_name = try self.allocator.dupe(u8, pkg.name.data);
                defer self.allocator.free(package_name);
                const repo_url = try self.allocator.dupe(u8, pkg.url.data);
                defer self.allocator.free(repo_url);

                self.build_system.startPackageBuilds(pkg.id, package_name, repo_url) catch |err| {
                    log.err("Failed to start builds for package '{s}': {}", .{ pkg.name.data, err });
                    continue;
                };

                builds_started += 1;
            }
        }

        log.info("Daily check completed: {d} packages checked, {d} build processes started", .{ packages_checked, builds_started });
    }

    // Check for stalled builds (pending for too long)
    fn checkStalledBuilds(self: *Self) !void {
        log.info("Checking for stalled builds", .{});

        const StalledBuildRow = struct {
            package_id: i64,
            package_name: sqlite.Text,
            package_url: sqlite.Text,
            zig_version: sqlite.Text,
            last_checked: sqlite.Text,
        };

        // Find builds that have been pending for more than 2 hours
        const query =
            \\SELECT br.package_id, p.name as package_name, p.url as package_url, 
            \\       br.zig_version, br.last_checked
            \\FROM build_results br
            \\JOIN packages p ON br.package_id = p.id
            \\WHERE br.build_status = 'pending' 
            \\  AND datetime(br.last_checked) < datetime('now', '-2 hours')
            \\ORDER BY br.last_checked ASC
        ;

        var stmt = self.db.prepare(struct {}, StalledBuildRow, query) catch |err| {
            log.err("Failed to prepare stalled builds query: {}", .{err});
            return err;
        };
        defer stmt.finalize();

        stmt.bind(.{}) catch |err| {
            log.err("Failed to bind stalled builds query: {}", .{err});
            return err;
        };
        defer stmt.reset();

        var stalled_count: usize = 0;
        var restarted_count: usize = 0;

        while (stmt.step() catch null) |build| {
            stalled_count += 1;
            log.warn("Found stalled build: package '{s}' (ID: {d}), Zig {s}, pending since {s}", .{ build.package_name.data, build.package_id, build.zig_version.data, build.last_checked.data });

            // Restart the build
            const package_name = try self.allocator.dupe(u8, build.package_name.data);
            defer self.allocator.free(package_name);
            const repo_url = try self.allocator.dupe(u8, build.package_url.data);
            defer self.allocator.free(repo_url);

            self.build_system.startPackageBuilds(build.package_id, package_name, repo_url) catch |err| {
                log.err("Failed to restart stalled build for package '{s}': {}", .{ build.package_name.data, err });
                continue;
            };

            restarted_count += 1;
        }

        if (stalled_count > 0) {
            log.info("Stalled build check completed: {d} stalled builds found, {d} restarted", .{ stalled_count, restarted_count });
        } else {
            log.debug("No stalled builds found", .{});
        }
    }

    // Get missing build versions for a package
    fn getMissingBuildsForPackage(self: *Self, package_id: i64) ![][]const u8 {
        const all_versions = [_][]const u8{ "master", "0.14.0", "0.13.0", "0.12.0" };

        const ExistingVersionRow = struct {
            zig_version: sqlite.Text,
        };

        const query = "SELECT zig_version FROM build_results WHERE package_id = :package_id";
        var stmt = self.db.prepare(struct { package_id: i64 }, ExistingVersionRow, query) catch |err| {
            log.err("Failed to prepare existing versions query: {}", .{err});
            return &[_][]const u8{};
        };
        defer stmt.finalize();

        stmt.bind(.{ .package_id = package_id }) catch |err| {
            log.err("Failed to bind existing versions query: {}", .{err});
            return &[_][]const u8{};
        };
        defer stmt.reset();

        var existing_versions = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (existing_versions.items) |version| {
                self.allocator.free(version);
            }
            existing_versions.deinit();
        }

        while (stmt.step() catch null) |row| {
            const version = try self.allocator.dupe(u8, row.zig_version.data);
            try existing_versions.append(version);
        }

        var missing_versions = std.ArrayList([]const u8).init(self.allocator);
        defer missing_versions.deinit();

        for (all_versions) |version| {
            var found = false;
            for (existing_versions.items) |existing| {
                if (std.mem.eql(u8, version, existing)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const missing_version = try self.allocator.dupe(u8, version);
                try missing_versions.append(missing_version);
            }
        }

        return missing_versions.toOwnedSlice();
    }
};

// Admin authentication middleware
fn requireAdminAuth(ctx: *const Context) bool {
    const auth_header = ctx.request.headers.get("Authorization") orelse {
        log.debug("No Authorization header found", .{});
        return false;
    };

    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        log.debug("Authorization header does not start with 'Bearer '", .{});
        return false;
    }

    const token = auth_header["Bearer ".len..];
    const is_valid = std.mem.eql(u8, token, ADMIN_TOKEN);

    if (!is_valid) {
        log.warn("Invalid admin token provided: {s}", .{token});
    }

    return is_valid;
}

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

// Home page statistics data structure
const HomeStatsData = struct {
    title: []const u8,
    total_packages: i32,
    zig_versions: i32,
    success_rate: []const u8,
    recent_packages: []RecentPackage,
    recent_builds: []RecentBuild,

    const RecentPackage = struct {
        name: []const u8,
        author: []const u8,
        created_at: []const u8,
    };

    const RecentBuild = struct {
        package_name: []const u8,
        zig_version: []const u8,
        build_status: []const u8,
    };
};

// Statistics page data structure
const StatsPageData = struct {
    title: []const u8,
    total_packages: i32,
    successful_builds: i32,
    failed_builds: i32,
    zig_versions: i32,
    compatibility_matrix: []CompatibilityRow,
    top_packages: []TopPackage,
    recent_activity: []RecentActivity,

    const CompatibilityRow = struct {
        zig_version: []const u8,
        packages_tested: i32,
        success_rate: []const u8,
        status: []const u8,
    };

    const TopPackage = struct {
        name: []const u8,
        author: []const u8,
        success_rate: []const u8,
        total_builds: i32,
    };

    const RecentActivity = struct {
        package_name: []const u8,
        zig_version: []const u8,
        build_status: []const u8,
        timestamp: []const u8,
    };
};

// Build Results page data structure
const BuildResultsPageData = struct {
    title: []const u8,
    package_name: []const u8,
    package_author: []const u8,
    package_description: ?[]const u8,
    package_license: ?[]const u8,
    package_url: []const u8,
    package_last_updated: []const u8,
    successful_builds: i32,
    failed_builds: i32,
    pending_builds: i32,
    total_builds: i32,
    build_results: []BuildResultDetail,

    const BuildResultDetail = struct {
        zig_version: []const u8,
        build_status: []const u8,
        test_status: ?[]const u8,
        error_log: ?[]const u8,
        last_checked: []const u8,
    };
};

// All Builds page data structure
const AllBuildsPageData = struct {
    title: []const u8,
    successful_builds: i32,
    failed_builds: i32,
    pending_builds: i32,
    total_builds: i32,
    build_results: []AllBuildResult,
    current_page: i32,
    total_pages: i32,
    page_numbers: []i32,

    const AllBuildResult = struct {
        package_name: []const u8,
        package_author: []const u8,
        package_description: ?[]const u8,
        zig_version: []const u8,
        build_status: []const u8,
        test_status: ?[]const u8,
        error_log: ?[]const u8,
        last_checked: []const u8,
    };
};

// Template rendering helpers
fn renderTemplate(ctx: *const Context, template_name: []const u8) !Respond {
    return renderTemplateWithTitle(ctx, template_name, getPageTitle(template_name));
}

fn renderTemplateWithTitle(ctx: *const Context, template_name: []const u8, title: []const u8) !Respond {
    const data = struct {
        title: []const u8,
    }{ .title = title };
    return renderTemplateWithData(ctx, template_name, data);
}

fn getPageTitle(template_name: []const u8) []const u8 {
    if (std.mem.eql(u8, template_name, "home.html")) return "Home";
    if (std.mem.eql(u8, template_name, "packages.html")) return "Packages";
    if (std.mem.eql(u8, template_name, "submit.html")) return "Submit Package";
    if (std.mem.eql(u8, template_name, "stats.html")) return "Statistics";
    if (std.mem.eql(u8, template_name, "api.html")) return "API Documentation";
    if (std.mem.eql(u8, template_name, "build_results.html")) return "Build Results";
    if (std.mem.eql(u8, template_name, "builds.html")) return "All Builds";
    return "Zig Package Checker";
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

    // Create data structure for base template that includes both title and content
    const base_data = struct {
        title: []const u8,
        content: []const u8,
    }{
        .title = if (@hasField(@TypeOf(data), "title")) data.title else getPageTitle(template_name),
        .content = rendered_content,
    };

    // Render the base template with the combined data
    const final_rendered = engine.renderTemplate(base_template, base_data) catch |err| {
        log.err("Failed to render base template: {}", .{err});
        return ctx.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.TEXT,
            .body = "Base template rendering error",
        });
    };

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = final_rendered,
    });
}

// Route handlers
fn home_handler(ctx: *const Context, _: void) !Respond {
    // Fetch home page statistics
    const home_data = fetchHomeStatsData(ctx.allocator) catch |err| {
        log.err("Failed to fetch home stats data: {}", .{err});
        // Return template with basic title on error
        return renderTemplateWithTitle(ctx, "home.html", "Home");
    };
    defer freeHomeStatsData(ctx.allocator, home_data);

    return renderTemplateWithData(ctx, "home.html", home_data);
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

        const error_message = switch (err) {
            error.NotZigProject =>
            \\<html><body>
            \\<h1>Error: Not a Zig Project</h1>
            \\<p>The submitted repository is not a valid Zig project. To be accepted, the repository must:</p>
            \\<ul>
            \\<li>Have Zig as the primary language, OR</li>
            \\<li>Contain a <code>build.zig</code> file in the root directory</li>
            \\</ul>
            \\<p>Please ensure your repository is a valid Zig project before submitting.</p>
            \\<a href="/submit">Go back</a>
            \\</body></html>
            ,
            else =>
            \\<html><body>
            \\<h1>Error</h1>
            \\<p>Failed to fetch repository information from GitHub. Please ensure the URL is correct and the repository is public.</p>
            \\<a href="/submit">Go back</a>
            \\</body></html>
            ,
        };

        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.HTML, .body = error_message });
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
    // Fetch statistics page data
    const stats_data = fetchStatsPageData(ctx.allocator) catch |err| {
        log.err("Failed to fetch stats page data: {}", .{err});
        // Return template with basic title on error
        return renderTemplateWithTitle(ctx, "stats.html", "Statistics");
    };
    defer freeStatsPageData(ctx.allocator, stats_data);

    return renderTemplateWithData(ctx, "stats.html", stats_data);
}

fn api_docs_handler(ctx: *const Context, _: void) !Respond {
    return renderTemplate(ctx, "api.html");
}

fn builds_handler(ctx: *const Context, _: void) !Respond {
    // Parse query parameters for filtering and pagination
    const query_string = if (ctx.request.uri) |uri| blk: {
        if (std.mem.indexOf(u8, uri, "?")) |query_start| {
            break :blk uri[query_start + 1 ..];
        } else {
            break :blk "";
        }
    } else "";

    // Extract query parameters
    const search = extractUrlParam(ctx.allocator, query_string, "search");
    defer if (search) |s| ctx.allocator.free(s);

    const zig_version = extractUrlParam(ctx.allocator, query_string, "zig_version");
    defer if (zig_version) |v| ctx.allocator.free(v);

    const status = extractUrlParam(ctx.allocator, query_string, "status");
    defer if (status) |s| ctx.allocator.free(s);

    const sort = extractUrlParam(ctx.allocator, query_string, "sort");
    defer if (sort) |s| ctx.allocator.free(s);

    const page_str = extractUrlParam(ctx.allocator, query_string, "page");
    defer if (page_str) |p| ctx.allocator.free(p);

    const limit_str = extractUrlParam(ctx.allocator, query_string, "limit");
    defer if (limit_str) |l| ctx.allocator.free(l);

    // Parse pagination parameters
    const page = if (page_str) |p| std.fmt.parseInt(i32, p, 10) catch 1 else 1;
    const limit = if (limit_str) |l| std.fmt.parseInt(i32, l, 10) catch 20 else 20;

    log.debug("builds_handler: search={s}, zig_version={s}, status={s}, sort={s}, page={d}, limit={d}", .{ if (search) |s| s else "null", if (zig_version) |v| v else "null", if (status) |s| s else "null", if (sort) |s| s else "null", page, limit });

    // Fetch builds page data
    const builds_data = fetchAllBuildsPageData(ctx.allocator, search, zig_version, status, sort, page, limit) catch |err| {
        log.err("Failed to fetch builds page data: {}", .{err});
        // Return template with basic title on error
        return renderTemplateWithTitle(ctx, "builds.html", "All Builds");
    };
    defer freeAllBuildsPageData(ctx.allocator, builds_data);

    return renderTemplateWithData(ctx, "builds.html", builds_data);
}

// Test handler for debugging routes
fn test_handler(ctx: *const Context, _: void) !Respond {
    const path = ctx.request.uri orelse "/";
    log.info("test_handler: Received request for path: '{s}'", .{path});

    // Test JSON response
    const json_response =
        \\{
        \\  "test": "success",
        \\  "path": "test",
        \\  "packages": [
        \\    {"id": 1, "name": "test-package", "author": "test-author"}
        \\  ]
        \\}
    ;

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = json_response,
    });
}

// Build results handler for detailed package build information
fn build_results_handler(ctx: *const Context, _: void) !Respond {
    // Extract package name from captured route parameter
    const path = ctx.request.uri orelse "/";
    log.debug("build_results_handler: Received request for path: '{s}'", .{path});

    // Get package name from route parameter capture
    if (ctx.captures.len == 0) {
        log.err("build_results_handler: No captured parameters found in path: {s}", .{path});
        return ctx.response.apply(.{
            .status = .@"Bad Request",
            .mime = http.Mime.TEXT,
            .body = "Invalid package name in URL",
        });
    }

    const package_name = switch (ctx.captures[0]) {
        .string => |name| name,
        else => {
            log.err("build_results_handler: First capture is not a string: {s}", .{path});
            return ctx.response.apply(.{
                .status = .@"Bad Request",
                .mime = http.Mime.TEXT,
                .body = "Invalid package name in URL",
            });
        },
    };

    log.debug("build_results_handler: Extracted package name: '{s}'", .{package_name});

    // Fetch build results data for the package
    const build_data = fetchBuildResultsPageData(ctx.allocator, package_name) catch |err| {
        log.err("Failed to fetch build results for package '{s}': {}", .{ package_name, err });

        const error_message = switch (err) {
            error.PackageNotFound => "Package not found",
            else => "Failed to fetch build results",
        };

        return ctx.response.apply(.{
            .status = .@"Not Found",
            .mime = http.Mime.TEXT,
            .body = error_message,
        });
    };
    defer freeBuildResultsPageData(ctx.allocator, build_data);

    return renderTemplateWithData(ctx, "build_results.html", build_data);
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

        const error_message = switch (err) {
            error.NotZigProject =>
            \\{
            \\  "error": "Repository is not a valid Zig project. It must have Zig as the primary language or contain a build.zig file."
            \\}
            ,
            else =>
            \\{
            \\  "error": "Failed to fetch repository information from GitHub"
            \\}
            ,
        };

        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = error_message });
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
    // Parse query parameters
    const query_string = if (ctx.request.uri) |uri| blk: {
        if (std.mem.indexOf(u8, uri, "?")) |query_start| {
            break :blk uri[query_start + 1 ..];
        } else {
            break :blk "";
        }
    } else "";

    // Extract query parameters
    const search = extractUrlParam(ctx.allocator, query_string, "search");
    defer if (search) |s| ctx.allocator.free(s);

    const zig_version = extractUrlParam(ctx.allocator, query_string, "zig_version");
    defer if (zig_version) |v| ctx.allocator.free(v);

    const status = extractUrlParam(ctx.allocator, query_string, "status");
    defer if (status) |s| ctx.allocator.free(s);

    const license = extractUrlParam(ctx.allocator, query_string, "license");
    defer if (license) |l| ctx.allocator.free(l);

    const author = extractUrlParam(ctx.allocator, query_string, "author");
    defer if (author) |a| ctx.allocator.free(a);

    const sort = extractUrlParam(ctx.allocator, query_string, "sort");
    defer if (sort) |s| ctx.allocator.free(s);

    const page_str = extractUrlParam(ctx.allocator, query_string, "page");
    defer if (page_str) |p| ctx.allocator.free(p);

    const limit_str = extractUrlParam(ctx.allocator, query_string, "limit");
    defer if (limit_str) |l| ctx.allocator.free(l);

    // Parse pagination parameters
    const page = if (page_str) |p| std.fmt.parseInt(i32, p, 10) catch 1 else 1;
    const limit = if (limit_str) |l| std.fmt.parseInt(i32, l, 10) catch 20 else 20;
    const offset = (page - 1) * limit;

    log.debug("API packages query parameters: search={s}, zig_version={s}, status={s}, license={s}, author={s}, sort={s}, page={d}, limit={d}", .{ if (search) |s| s else "null", if (zig_version) |v| v else "null", if (status) |s| s else "null", if (license) |l| l else "null", if (author) |a| a else "null", if (sort) |s| s else "null", page, limit });

    // Build WHERE clause conditions
    var where_parts = std.ArrayList([]const u8).init(ctx.allocator);
    defer where_parts.deinit();

    // Add search condition
    if (search) |s| {
        if (s.len > 0) {
            const search_condition = try std.fmt.allocPrint(ctx.allocator, "(p.name LIKE '%{s}%' OR p.description LIKE '%{s}%' OR p.author LIKE '%{s}%')", .{ s, s, s });
            try where_parts.append(search_condition);
        }
    }

    // Add license filter
    if (license) |l| {
        if (l.len > 0) {
            // Handle both short names (MIT) and full names (MIT License)
            const license_condition = if (std.mem.eql(u8, l, "MIT"))
                try std.fmt.allocPrint(ctx.allocator, "(p.license = 'MIT' OR p.license = 'MIT License')", .{})
            else if (std.mem.eql(u8, l, "Apache-2.0"))
                try std.fmt.allocPrint(ctx.allocator, "(p.license = 'Apache-2.0' OR p.license = 'Apache License 2.0')", .{})
            else if (std.mem.eql(u8, l, "GPL-3.0"))
                try std.fmt.allocPrint(ctx.allocator, "(p.license = 'GPL-3.0' OR p.license = 'GNU General Public License v3.0')", .{})
            else if (std.mem.eql(u8, l, "BSD-3-Clause"))
                try std.fmt.allocPrint(ctx.allocator, "(p.license = 'BSD-3-Clause' OR p.license = 'BSD 3-Clause \"New\" or \"Revised\" License')", .{})
            else if (std.mem.eql(u8, l, "ISC"))
                try std.fmt.allocPrint(ctx.allocator, "(p.license = 'ISC' OR p.license = 'ISC License')", .{})
            else if (std.mem.eql(u8, l, "Unlicense"))
                try std.fmt.allocPrint(ctx.allocator, "(p.license = 'Unlicense' OR p.license = 'The Unlicense')", .{})
            else if (std.mem.eql(u8, l, "MPL-2.0"))
                try std.fmt.allocPrint(ctx.allocator, "(p.license = 'MPL-2.0' OR p.license = 'Mozilla Public License 2.0')", .{})
            else
                try std.fmt.allocPrint(ctx.allocator, "p.license = '{s}'", .{l});
            try where_parts.append(license_condition);
        }
    }

    // Add author filter
    if (author) |a| {
        if (a.len > 0) {
            const author_condition = try std.fmt.allocPrint(ctx.allocator, "p.author = '{s}'", .{a});
            try where_parts.append(author_condition);
        }
    }

    // Determine if we need to join with build_results
    var needs_build_join = false;
    if (zig_version) |v| {
        if (v.len > 0) {
            const version_condition = try std.fmt.allocPrint(ctx.allocator, "br.zig_version = '{s}'", .{v});
            try where_parts.append(version_condition);
            needs_build_join = true;
        }
    }

    if (status) |s| {
        if (s.len > 0) {
            const status_condition = try std.fmt.allocPrint(ctx.allocator, "br.build_status = '{s}'", .{s});
            try where_parts.append(status_condition);
            needs_build_join = true;
        }
    }

    // Build ORDER BY clause
    const order_clause = if (sort) |s| blk: {
        if (std.mem.eql(u8, s, "name")) {
            break :blk "ORDER BY p.name ASC";
        } else if (std.mem.eql(u8, s, "updated")) {
            break :blk "ORDER BY p.created_at DESC";
        } else if (std.mem.eql(u8, s, "author")) {
            break :blk "ORDER BY p.author ASC";
        } else {
            break :blk "ORDER BY p.created_at DESC";
        }
    } else "ORDER BY p.created_at DESC";

    // Build WHERE clause
    var where_clause = std.ArrayList(u8).init(ctx.allocator);
    defer where_clause.deinit();

    if (where_parts.items.len > 0) {
        try where_clause.appendSlice(" WHERE ");
        for (where_parts.items, 0..) |part, i| {
            if (i > 0) try where_clause.appendSlice(" AND ");
            try where_clause.appendSlice(part);
        }
    }

    // Build count query
    const count_query = if (needs_build_join)
        try std.fmt.allocPrint(ctx.allocator, "SELECT COUNT(DISTINCT p.id) as count FROM packages p JOIN build_results br ON p.id = br.package_id{s}", .{where_clause.items})
    else
        try std.fmt.allocPrint(ctx.allocator, "SELECT COUNT(*) as count FROM packages p{s}", .{where_clause.items});
    defer ctx.allocator.free(count_query);

    // Execute count query
    const CountResult = struct { count: i64 };
    const count_stmt = db.prepare(struct {}, CountResult, count_query) catch |err| {
        log.err("Failed to prepare count query: {}", .{err});
        log.err("Count query: {s}", .{count_query});
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

    // Build main query
    const main_query = if (needs_build_join)
        try std.fmt.allocPrint(ctx.allocator, "SELECT DISTINCT p.id, p.name, p.url, p.description, p.author, p.license, p.created_at FROM packages p JOIN build_results br ON p.id = br.package_id{s} {s} LIMIT {d} OFFSET {d}", .{ where_clause.items, order_clause, limit, offset })
    else
        try std.fmt.allocPrint(ctx.allocator, "SELECT p.id, p.name, p.url, p.description, p.author, p.license, p.created_at FROM packages p{s} {s} LIMIT {d} OFFSET {d}", .{ where_clause.items, order_clause, limit, offset });
    defer ctx.allocator.free(main_query);

    log.debug("API packages main query: {s}", .{main_query});

    // Execute main query
    const PackageResult = struct { id: i64, name: sqlite.Text, url: sqlite.Text, description: ?sqlite.Text, author: ?sqlite.Text, license: ?sqlite.Text, created_at: sqlite.Text };

    const packages_stmt = db.prepare(struct {}, PackageResult, main_query) catch |err| {
        log.err("Failed to prepare packages query: {}", .{err});
        log.err("Main query: {s}", .{main_query});
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

    // Build JSON response manually
    var response = std.ArrayList(u8).init(ctx.allocator);
    errdefer response.deinit();

    const response_writer = response.writer();
    try response_writer.print("{{\"packages\":[", .{});

    var first = true;
    while (packages_stmt.step() catch null) |pkg| {
        if (!first) try response_writer.writeAll(",");
        first = false;

        try response_writer.print("{{\"id\":{d},\"name\":\"{s}\",\"url\":\"{s}\"", .{ pkg.id, pkg.name.data, pkg.url.data });

        if (pkg.description) |desc| {
            // Escape JSON string
            const escaped_desc = try escapeJsonString(ctx.allocator, desc.data);
            defer ctx.allocator.free(escaped_desc);
            try response_writer.print(",\"description\":\"{s}\"", .{escaped_desc});
        } else {
            try response_writer.writeAll(",\"description\":null");
        }

        if (pkg.author) |auth| {
            const escaped_author = try escapeJsonString(ctx.allocator, auth.data);
            defer ctx.allocator.free(escaped_author);
            try response_writer.print(",\"author\":\"{s}\"", .{escaped_author});
        } else {
            try response_writer.writeAll(",\"author\":null");
        }

        if (pkg.license) |lic| {
            const escaped_license = try escapeJsonString(ctx.allocator, lic.data);
            defer ctx.allocator.free(escaped_license);
            try response_writer.print(",\"license\":\"{s}\"", .{escaped_license});
        } else {
            try response_writer.writeAll(",\"license\":null");
        }

        try response_writer.print(",\"created_at\":\"{s}\"", .{pkg.created_at.data});

        // Add build results
        try response_writer.writeAll(",\"build_results\":[");

        // Fetch build results for this package
        const BuildResultRow = struct { zig_version: sqlite.Text, build_status: sqlite.Text };
        const build_query = "SELECT zig_version, build_status FROM build_results WHERE package_id = :package_id ORDER BY zig_version";

        const build_stmt = db.prepare(struct { package_id: i64 }, BuildResultRow, build_query) catch |err| {
            log.err("Failed to prepare build results query for package {d}: {}", .{ pkg.id, err });
            try response_writer.writeAll("]");
            try response_writer.writeAll("}");
            continue;
        };
        defer build_stmt.finalize();

        build_stmt.bind(.{ .package_id = pkg.id }) catch |err| {
            log.err("Failed to bind build results query for package {d}: {}", .{ pkg.id, err });
            try response_writer.writeAll("]");
            try response_writer.writeAll("}");
            continue;
        };
        defer build_stmt.reset();

        var build_first = true;
        while (build_stmt.step() catch null) |build_result| {
            if (!build_first) try response_writer.writeAll(",");
            build_first = false;

            try response_writer.print("{{\"zig_version\":\"{s}\",\"build_status\":\"{s}\"}}", .{ build_result.zig_version.data, build_result.build_status.data });
        }

        try response_writer.writeAll("]}");
    }

    try response_writer.print("],\"total\":{d},\"page\":{d},\"limit\":{d}}}", .{ count, page, limit });

    // Free allocated where clause parts
    for (where_parts.items) |part| {
        ctx.allocator.free(part);
    }

    // Transfer ownership of the response to the framework
    const response_body = try response.toOwnedSlice();
    return ctx.response.apply(.{ .status = .OK, .mime = http.Mime.JSON, .body = response_body });
}

// Helper function to escape JSON strings
fn escapeJsonString(alloc: Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(alloc);
    defer result.deinit();

    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice("\\\""),
            '\\' => try result.appendSlice("\\\\"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => try result.append(char),
        }
    }

    return result.toOwnedSlice();
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

        const error_message = switch (err) {
            error.NotZigProject =>
            \\{
            \\  "error": "Repository is not a valid Zig project. It must have Zig as the primary language or contain a build.zig file."
            \\}
            ,
            else =>
            \\{
            \\  "error": "Failed to fetch repository information from GitHub"
            \\}
            ,
        };

        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = error_message });
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

    log.debug("Parsed repo info - name: '{s}', owner: '{s}', description: '{s}', license: '{s}', language: '{s}'", .{ name, owner_name, description orelse "null", license orelse "null", language orelse "null" });

    // Validate that this is a Zig project
    const is_zig_project = try validateZigProject(alloc, owner, repo, language);
    if (!is_zig_project) {
        log.warn("Repository {s}/{s} is not a valid Zig project", .{ owner, repo });
        return error.NotZigProject;
    }

    log.debug("Repository validated as Zig project", .{});

    return GitHubRepoInfo{
        .name = name,
        .author = owner_name,
        .description = description,
        .license = license,
        .language = language,
        .url = try alloc.dupe(u8, github_url),
    };
}

// Function to validate if a repository is a Zig project
fn validateZigProject(alloc: Allocator, owner: []const u8, repo: []const u8, language: ?[]const u8) !bool {
    log.debug("Validating Zig project for {s}/{s}", .{ owner, repo });

    // Check 1: Primary language should be Zig
    var is_zig_language = false;
    if (language) |lang| {
        is_zig_language = std.mem.eql(u8, lang, "Zig");
        log.debug("Repository language: '{s}', is Zig: {}", .{ lang, is_zig_language });
    } else {
        log.debug("Repository language: null", .{});
    }

    // Check 2: Look for build.zig file in the repository
    const has_build_zig = try checkForBuildZig(alloc, owner, repo);
    log.debug("Has build.zig file: {}", .{has_build_zig});

    // A repository is considered a Zig project if:
    // - Primary language is Zig, OR
    // - It has a build.zig file (even if language detection failed or shows different language)
    const is_valid = is_zig_language or has_build_zig;

    log.debug("Zig project validation result: {} (language: {}, build.zig: {})", .{ is_valid, is_zig_language, has_build_zig });

    return is_valid;
}

// Function to check if repository has build.zig file
fn checkForBuildZig(alloc: Allocator, owner: []const u8, repo: []const u8) !bool {
    // Build GitHub API URL for contents
    const contents_url = try std.fmt.allocPrint(alloc, "https://api.github.com/repos/{s}/{s}/contents/build.zig", .{ owner, repo });
    defer alloc.free(contents_url);

    log.debug("Checking for build.zig at: {s}", .{contents_url});

    // Make HTTP request to check if build.zig exists
    const response_body = makeGitHubRequest(alloc, contents_url) catch |err| {
        // If we get an error, it likely means the file doesn't exist
        log.debug("build.zig check failed: {}", .{err});
        return false;
    };
    defer alloc.free(response_body);

    // If we got a successful response, the file exists
    log.debug("build.zig file found in repository", .{});
    return true;
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

// Helper function to extract package name from URL path
fn extractPackageNameFromPath(alloc: Allocator, path: []const u8) ?[]const u8 {
    log.debug("extractPackageNameFromPath: Parsing path: '{s}'", .{path});

    // Handle paths like /packages/{name}/builds or /builds/{name}
    if (std.mem.startsWith(u8, path, "/packages/")) {
        const after_packages = path["/packages/".len..];
        if (std.mem.indexOf(u8, after_packages, "/builds")) |builds_pos| {
            const package_name = after_packages[0..builds_pos];
            if (package_name.len > 0) {
                return alloc.dupe(u8, package_name) catch null;
            }
        }
    } else if (std.mem.startsWith(u8, path, "/builds/")) {
        const after_builds = path["/builds/".len..];
        // Find the end of the package name (either end of string or next slash)
        const end_pos = std.mem.indexOf(u8, after_builds, "/") orelse after_builds.len;
        const package_name = after_builds[0..end_pos];
        if (package_name.len > 0) {
            return alloc.dupe(u8, package_name) catch null;
        }
    }

    log.debug("extractPackageNameFromPath: Could not extract package name from path", .{});
    return null;
}

// Function to fetch build results page data for a specific package
fn fetchBuildResultsPageData(alloc: Allocator, package_name: []const u8) !BuildResultsPageData {
    log.debug("fetchBuildResultsPageData: Fetching data for package '{s}'", .{package_name});

    // First, get the package information
    const PackageRow = struct {
        id: i64,
        name: sqlite.Text,
        url: sqlite.Text,
        description: ?sqlite.Text,
        author: ?sqlite.Text,
        license: ?sqlite.Text,
        last_updated: sqlite.Text,
    };

    const package_query = "SELECT id, name, url, description, author, license, last_updated FROM packages WHERE name = :name";
    var package_stmt = db.prepare(struct { name: sqlite.Text }, PackageRow, package_query) catch |err| {
        log.err("Failed to prepare package query: {}", .{err});
        return error.DatabaseError;
    };
    defer package_stmt.finalize();

    package_stmt.bind(.{ .name = sqlite.text(package_name) }) catch |err| {
        log.err("Failed to bind package query: {}", .{err});
        return error.DatabaseError;
    };
    defer package_stmt.reset();

    const package_info = package_stmt.step() catch |err| {
        log.err("Failed to execute package query: {}", .{err});
        return error.DatabaseError;
    } orelse {
        log.err("Package '{s}' not found", .{package_name});
        return error.PackageNotFound;
    };

    log.debug("fetchBuildResultsPageData: Found package with ID {}", .{package_info.id});

    // Fetch detailed build results for this package
    const build_results = fetchDetailedBuildResults(alloc, package_info.id) catch |err| {
        log.err("Failed to fetch detailed build results: {}", .{err});
        return error.DatabaseError;
    };

    // Calculate build statistics
    var successful_builds: i32 = 0;
    var failed_builds: i32 = 0;
    var pending_builds: i32 = 0;

    for (build_results) |result| {
        if (std.mem.eql(u8, result.build_status, "success")) {
            successful_builds += 1;
        } else if (std.mem.eql(u8, result.build_status, "failed")) {
            failed_builds += 1;
        } else if (std.mem.eql(u8, result.build_status, "pending")) {
            pending_builds += 1;
        }
    }

    const total_builds = successful_builds + failed_builds + pending_builds;

    return BuildResultsPageData{
        .title = try std.fmt.allocPrint(alloc, "Build Results - {s}", .{package_name}),
        .package_name = try alloc.dupe(u8, package_info.name.data),
        .package_author = if (package_info.author) |auth| try alloc.dupe(u8, auth.data) else try alloc.dupe(u8, "Unknown"),
        .package_description = if (package_info.description) |desc| try alloc.dupe(u8, desc.data) else null,
        .package_license = if (package_info.license) |lic| try alloc.dupe(u8, lic.data) else null,
        .package_url = try alloc.dupe(u8, package_info.url.data),
        .package_last_updated = try alloc.dupe(u8, package_info.last_updated.data),
        .successful_builds = successful_builds,
        .failed_builds = failed_builds,
        .pending_builds = pending_builds,
        .total_builds = total_builds,
        .build_results = build_results,
    };
}

// Function to fetch detailed build results with error logs
fn fetchDetailedBuildResults(alloc: Allocator, package_id: i64) ![]BuildResultsPageData.BuildResultDetail {
    log.debug("fetchDetailedBuildResults: Fetching detailed build results for package {}", .{package_id});

    const DetailedBuildResultRow = struct {
        zig_version: sqlite.Text,
        build_status: sqlite.Text,
        test_status: ?sqlite.Text,
        error_log: ?sqlite.Text,
        last_checked: sqlite.Text,
    };

    const build_query =
        \\SELECT zig_version, build_status, test_status, error_log, last_checked 
        \\FROM build_results 
        \\WHERE package_id = :package_id 
        \\ORDER BY 
        \\  CASE zig_version 
        \\    WHEN 'master' THEN 1 
        \\    WHEN '0.14.0' THEN 2 
        \\    WHEN '0.13.0' THEN 3 
        \\    WHEN '0.12.0' THEN 4 
        \\    ELSE 5 
        \\  END
    ;

    var build_stmt = db.prepare(struct { package_id: i64 }, DetailedBuildResultRow, build_query) catch |err| {
        log.err("Failed to prepare detailed build results query: {}", .{err});
        return error.DatabaseError;
    };
    defer build_stmt.finalize();

    build_stmt.bind(.{ .package_id = package_id }) catch |err| {
        log.err("Failed to bind detailed build results query: {}", .{err});
        return error.DatabaseError;
    };
    defer build_stmt.reset();

    var build_results = std.ArrayList(BuildResultsPageData.BuildResultDetail).init(alloc);
    defer build_results.deinit();

    while (build_stmt.step() catch null) |result| {
        const build_result = BuildResultsPageData.BuildResultDetail{
            .zig_version = try alloc.dupe(u8, result.zig_version.data),
            .build_status = try alloc.dupe(u8, result.build_status.data),
            .test_status = if (result.test_status) |ts| try alloc.dupe(u8, ts.data) else null,
            .error_log = if (result.error_log) |el| try alloc.dupe(u8, el.data) else null,
            .last_checked = try alloc.dupe(u8, result.last_checked.data),
        };

        try build_results.append(build_result);
    }

    log.debug("fetchDetailedBuildResults: Found {} detailed build results", .{build_results.items.len});

    return try build_results.toOwnedSlice();
}

// Function to free BuildResultsPageData
fn freeBuildResultsPageData(alloc: Allocator, data: BuildResultsPageData) void {
    alloc.free(data.title);
    alloc.free(data.package_name);
    alloc.free(data.package_author);
    if (data.package_description) |desc| alloc.free(desc);
    if (data.package_license) |lic| alloc.free(lic);
    alloc.free(data.package_url);
    alloc.free(data.package_last_updated);

    for (data.build_results) |result| {
        alloc.free(result.zig_version);
        alloc.free(result.build_status);
        if (result.test_status) |ts| alloc.free(ts);
        if (result.error_log) |el| alloc.free(el);
        alloc.free(result.last_checked);
    }
    alloc.free(data.build_results);
}

// Function to fetch all builds page data with filtering and pagination
fn fetchAllBuildsPageData(alloc: Allocator, search: ?[]const u8, zig_version: ?[]const u8, status: ?[]const u8, sort: ?[]const u8, page: i32, limit: i32) !AllBuildsPageData {
    log.debug("fetchAllBuildsPageData: Fetching builds with filters - search={s}, zig_version={s}, status={s}, sort={s}, page={d}, limit={d}", .{ if (search) |s| s else "null", if (zig_version) |v| v else "null", if (status) |s| s else "null", if (sort) |s| s else "null", page, limit });

    const offset = (page - 1) * limit;

    // Build WHERE clause
    var where_parts = std.ArrayList([]const u8).init(alloc);
    defer where_parts.deinit();
    defer for (where_parts.items) |part| alloc.free(part);

    if (search) |s| {
        if (s.len > 0) {
            const search_condition = try std.fmt.allocPrint(alloc, "p.name LIKE '%{s}%'", .{s});
            try where_parts.append(search_condition);
        }
    }

    if (zig_version) |v| {
        if (v.len > 0) {
            const version_condition = try std.fmt.allocPrint(alloc, "br.zig_version = '{s}'", .{v});
            try where_parts.append(version_condition);
        }
    }

    if (status) |s| {
        if (s.len > 0) {
            const status_condition = try std.fmt.allocPrint(alloc, "br.build_status = '{s}'", .{s});
            try where_parts.append(status_condition);
        }
    }

    var where_clause = std.ArrayList(u8).init(alloc);
    defer where_clause.deinit();

    if (where_parts.items.len > 0) {
        try where_clause.appendSlice(" WHERE ");
        for (where_parts.items, 0..) |part, i| {
            if (i > 0) try where_clause.appendSlice(" AND ");
            try where_clause.appendSlice(part);
        }
    }

    // Build ORDER BY clause
    const order_clause = if (sort) |s| blk: {
        if (std.mem.eql(u8, s, "last_checked_asc")) {
            break :blk " ORDER BY br.last_checked ASC";
        } else if (std.mem.eql(u8, s, "package_name_asc")) {
            break :blk " ORDER BY p.name ASC";
        } else if (std.mem.eql(u8, s, "package_name_desc")) {
            break :blk " ORDER BY p.name DESC";
        } else if (std.mem.eql(u8, s, "zig_version_desc")) {
            break :blk " ORDER BY CASE br.zig_version WHEN 'master' THEN 1 WHEN '0.14.0' THEN 2 WHEN '0.13.0' THEN 3 WHEN '0.12.0' THEN 4 ELSE 5 END";
        } else {
            break :blk " ORDER BY br.last_checked DESC";
        }
    } else " ORDER BY br.last_checked DESC";

    // Get total count for pagination
    const count_query = try std.fmt.allocPrint(alloc, "SELECT COUNT(*) as count FROM build_results br JOIN packages p ON br.package_id = p.id{s}", .{where_clause.items});
    defer alloc.free(count_query);

    const CountResult = struct { count: i64 };
    var count_stmt = db.prepare(struct {}, CountResult, count_query) catch |err| {
        log.err("Failed to prepare count query: {}", .{err});
        return error.DatabaseError;
    };
    defer count_stmt.finalize();

    count_stmt.bind(.{}) catch |err| {
        log.err("Failed to bind count query: {}", .{err});
        return error.DatabaseError;
    };
    defer count_stmt.reset();

    const total_count = if (count_stmt.step() catch null) |result| result.count else 0;

    // Calculate pagination
    const total_pages = @as(i32, @intCast(@divTrunc(total_count + @as(i64, @intCast(limit)) - 1, @as(i64, @intCast(limit)))));
    const page_numbers = try generatePageNumbers(alloc, page, total_pages);

    // Get build statistics
    const build_counts = fetchBuildCounts() catch .{ .successful = 0, .failed = 0 };
    const pending_count = fetchPendingBuildsCount() catch 0;

    // Fetch build results
    const AllBuildResultRow = struct {
        package_name: sqlite.Text,
        package_author: ?sqlite.Text,
        package_description: ?sqlite.Text,
        zig_version: sqlite.Text,
        build_status: sqlite.Text,
        test_status: ?sqlite.Text,
        error_log: ?sqlite.Text,
        last_checked: sqlite.Text,
    };

    const main_query = try std.fmt.allocPrint(alloc,
        \\SELECT p.name as package_name, p.author as package_author, p.description as package_description,
        \\       br.zig_version, br.build_status, br.test_status, br.error_log, br.last_checked
        \\FROM build_results br 
        \\JOIN packages p ON br.package_id = p.id{s}{s}
        \\LIMIT {d} OFFSET {d}
    , .{ where_clause.items, order_clause, limit, offset });
    defer alloc.free(main_query);

    var main_stmt = db.prepare(struct {}, AllBuildResultRow, main_query) catch |err| {
        log.err("Failed to prepare main query: {}", .{err});
        return error.DatabaseError;
    };
    defer main_stmt.finalize();

    main_stmt.bind(.{}) catch |err| {
        log.err("Failed to bind main query: {}", .{err});
        return error.DatabaseError;
    };
    defer main_stmt.reset();

    var build_results = std.ArrayList(AllBuildsPageData.AllBuildResult).init(alloc);
    defer build_results.deinit();

    while (main_stmt.step() catch null) |row| {
        const build_result = AllBuildsPageData.AllBuildResult{
            .package_name = try alloc.dupe(u8, row.package_name.data),
            .package_author = if (row.package_author) |auth| try alloc.dupe(u8, auth.data) else try alloc.dupe(u8, "Unknown"),
            .package_description = if (row.package_description) |desc| try alloc.dupe(u8, desc.data) else null,
            .zig_version = try alloc.dupe(u8, row.zig_version.data),
            .build_status = try alloc.dupe(u8, row.build_status.data),
            .test_status = if (row.test_status) |ts| try alloc.dupe(u8, ts.data) else null,
            .error_log = if (row.error_log) |el| try alloc.dupe(u8, el.data) else null,
            .last_checked = try alloc.dupe(u8, row.last_checked.data),
        };

        try build_results.append(build_result);
    }

    log.debug("fetchAllBuildsPageData: Found {} build results", .{build_results.items.len});

    return AllBuildsPageData{
        .title = "All Builds",
        .successful_builds = build_counts.successful,
        .failed_builds = build_counts.failed,
        .pending_builds = pending_count,
        .total_builds = build_counts.successful + build_counts.failed + pending_count,
        .build_results = try build_results.toOwnedSlice(),
        .current_page = page,
        .total_pages = total_pages,
        .page_numbers = page_numbers,
    };
}

// Function to free AllBuildsPageData
fn freeAllBuildsPageData(alloc: Allocator, data: AllBuildsPageData) void {
    for (data.build_results) |result| {
        alloc.free(result.package_name);
        alloc.free(result.package_author);
        if (result.package_description) |desc| alloc.free(desc);
        alloc.free(result.zig_version);
        alloc.free(result.build_status);
        if (result.test_status) |ts| alloc.free(ts);
        if (result.error_log) |el| alloc.free(el);
        alloc.free(result.last_checked);
    }
    alloc.free(data.build_results);
    alloc.free(data.page_numbers);
}

// Helper function to fetch pending builds count
fn fetchPendingBuildsCount() !i32 {
    const CountRow = struct { count: i64 };
    const query = "SELECT COUNT(*) as count FROM build_results WHERE build_status = 'pending'";

    var stmt = db.prepare(struct {}, CountRow, query) catch return 0;
    defer stmt.finalize();

    stmt.bind(.{}) catch return 0;
    defer stmt.reset();

    if (stmt.step() catch null) |row| {
        return @intCast(row.count);
    }
    return 0;
}

// Helper function to generate page numbers for pagination
fn generatePageNumbers(alloc: Allocator, current_page: i32, total_pages: i32) ![]i32 {
    if (total_pages <= 1) {
        return &[_]i32{};
    }

    var page_numbers = std.ArrayList(i32).init(alloc);
    defer page_numbers.deinit();

    // Show up to 5 page numbers around current page
    const max_pages_to_show = 5;
    var start_page = @max(1, current_page - max_pages_to_show / 2);
    const end_page = @min(total_pages, start_page + max_pages_to_show - 1);

    // Adjust start_page if we're near the end
    if (end_page - start_page + 1 < max_pages_to_show) {
        start_page = @max(1, end_page - max_pages_to_show + 1);
    }

    var page = start_page;
    while (page <= end_page) : (page += 1) {
        try page_numbers.append(page);
    }

    return try page_numbers.toOwnedSlice();
}

fn fetchHomeStatsData(alloc: Allocator) !HomeStatsData {
    log.debug("fetchHomeStatsData: Starting to fetch home page statistics", .{});

    // Get total packages count
    const total_packages = fetchTotalPackagesCount() catch 0;

    // Get success rate
    const success_rate = calculateOverallSuccessRate(alloc) catch "N/A";

    // Get recent packages
    const recent_packages = fetchRecentPackages(alloc) catch &[_]HomeStatsData.RecentPackage{};

    // Get recent builds
    const recent_builds = fetchRecentBuilds(alloc) catch &[_]HomeStatsData.RecentBuild{};

    return HomeStatsData{
        .title = "Home",
        .total_packages = total_packages,
        .zig_versions = 4, // Fixed: master, 0.14.0, 0.13.0, 0.12.0
        .success_rate = success_rate,
        .recent_packages = recent_packages,
        .recent_builds = recent_builds,
    };
}

fn fetchStatsPageData(alloc: Allocator) !StatsPageData {
    log.debug("fetchStatsPageData: Starting to fetch statistics page data", .{});

    // Get basic counts
    const total_packages = fetchTotalPackagesCount() catch 0;
    const build_counts = fetchBuildCounts() catch .{ .successful = 0, .failed = 0 };

    // Get compatibility matrix
    const compatibility_matrix = fetchCompatibilityMatrix(alloc) catch &[_]StatsPageData.CompatibilityRow{};

    // Get top packages
    const top_packages = fetchTopPackages(alloc) catch &[_]StatsPageData.TopPackage{};

    // Get recent activity
    const recent_activity = fetchRecentActivity(alloc) catch &[_]StatsPageData.RecentActivity{};

    return StatsPageData{
        .title = "Statistics",
        .total_packages = total_packages,
        .successful_builds = build_counts.successful,
        .failed_builds = build_counts.failed,
        .zig_versions = 4,
        .compatibility_matrix = compatibility_matrix,
        .top_packages = top_packages,
        .recent_activity = recent_activity,
    };
}

fn fetchTotalPackagesCount() !i32 {
    const CountRow = struct { count: i64 };
    const query = "SELECT COUNT(*) as count FROM packages";

    var stmt = db.prepare(struct {}, CountRow, query) catch return 0;
    defer stmt.finalize();

    stmt.bind(.{}) catch return 0;
    defer stmt.reset();

    if (stmt.step() catch null) |row| {
        return @intCast(row.count);
    }
    return 0;
}

const BuildCounts = struct {
    successful: i32,
    failed: i32,
};

fn fetchBuildCounts() !BuildCounts {
    const CountRow = struct {
        successful: i64,
        failed: i64,
    };

    const query =
        \\SELECT 
        \\  SUM(CASE WHEN build_status = 'success' THEN 1 ELSE 0 END) as successful,
        \\  SUM(CASE WHEN build_status = 'failed' THEN 1 ELSE 0 END) as failed
        \\FROM build_results
    ;

    var stmt = db.prepare(struct {}, CountRow, query) catch return BuildCounts{ .successful = 0, .failed = 0 };
    defer stmt.finalize();

    stmt.bind(.{}) catch return BuildCounts{ .successful = 0, .failed = 0 };
    defer stmt.reset();

    if (stmt.step() catch null) |row| {
        return BuildCounts{
            .successful = @intCast(row.successful),
            .failed = @intCast(row.failed),
        };
    }
    return BuildCounts{ .successful = 0, .failed = 0 };
}

fn calculateOverallSuccessRate(alloc: Allocator) ![]const u8 {
    const counts = fetchBuildCounts() catch return alloc.dupe(u8, "N/A");
    const total = counts.successful + counts.failed;

    if (total == 0) {
        return alloc.dupe(u8, "N/A");
    }

    const rate = (@as(f64, @floatFromInt(counts.successful)) / @as(f64, @floatFromInt(total))) * 100.0;
    return std.fmt.allocPrint(alloc, "{d:.1}%", .{rate});
}

fn fetchRecentPackages(alloc: Allocator) ![]HomeStatsData.RecentPackage {
    const PackageRow = struct {
        name: sqlite.Text,
        author: ?sqlite.Text,
        created_at: sqlite.Text,
    };

    const query = "SELECT name, author, created_at FROM packages ORDER BY created_at DESC LIMIT 5";

    var stmt = db.prepare(struct {}, PackageRow, query) catch return &[_]HomeStatsData.RecentPackage{};
    defer stmt.finalize();

    stmt.bind(.{}) catch return &[_]HomeStatsData.RecentPackage{};
    defer stmt.reset();

    var packages = std.ArrayList(HomeStatsData.RecentPackage).init(alloc);
    defer packages.deinit();

    while (stmt.step() catch null) |row| {
        const package = HomeStatsData.RecentPackage{
            .name = alloc.dupe(u8, row.name.data) catch continue,
            .author = if (row.author) |auth| alloc.dupe(u8, auth.data) catch "Unknown" else "Unknown",
            .created_at = alloc.dupe(u8, row.created_at.data) catch continue,
        };
        packages.append(package) catch continue;
    }

    return packages.toOwnedSlice() catch &[_]HomeStatsData.RecentPackage{};
}

fn fetchRecentBuilds(alloc: Allocator) ![]HomeStatsData.RecentBuild {
    const BuildRow = struct {
        package_name: sqlite.Text,
        zig_version: sqlite.Text,
        build_status: sqlite.Text,
    };

    const query =
        \\SELECT p.name as package_name, br.zig_version, br.build_status 
        \\FROM build_results br 
        \\JOIN packages p ON br.package_id = p.id 
        \\ORDER BY br.last_checked DESC LIMIT 5
    ;

    var stmt = db.prepare(struct {}, BuildRow, query) catch return &[_]HomeStatsData.RecentBuild{};
    defer stmt.finalize();

    stmt.bind(.{}) catch return &[_]HomeStatsData.RecentBuild{};
    defer stmt.reset();

    var builds = std.ArrayList(HomeStatsData.RecentBuild).init(alloc);
    defer builds.deinit();

    while (stmt.step() catch null) |row| {
        const build = HomeStatsData.RecentBuild{
            .package_name = alloc.dupe(u8, row.package_name.data) catch continue,
            .zig_version = alloc.dupe(u8, row.zig_version.data) catch continue,
            .build_status = alloc.dupe(u8, row.build_status.data) catch continue,
        };
        builds.append(build) catch continue;
    }

    return builds.toOwnedSlice() catch &[_]HomeStatsData.RecentBuild{};
}

fn fetchCompatibilityMatrix(alloc: Allocator) ![]StatsPageData.CompatibilityRow {
    const zig_versions = [_][]const u8{ "master", "0.14.0", "0.13.0", "0.12.0" };
    const statuses = [_][]const u8{ "Latest", "Stable", "Previous", "Legacy" };

    var matrix = std.ArrayList(StatsPageData.CompatibilityRow).init(alloc);
    defer matrix.deinit();

    for (zig_versions, 0..) |version, i| {
        const stats = fetchVersionStats(alloc, version) catch .{ .packages_tested = 0, .success_rate = "N/A" };

        const row = StatsPageData.CompatibilityRow{
            .zig_version = alloc.dupe(u8, version) catch continue,
            .packages_tested = stats.packages_tested,
            .success_rate = stats.success_rate,
            .status = alloc.dupe(u8, statuses[i]) catch continue,
        };
        matrix.append(row) catch continue;
    }

    return matrix.toOwnedSlice() catch &[_]StatsPageData.CompatibilityRow{};
}

const VersionStats = struct {
    packages_tested: i32,
    success_rate: []const u8,
};

fn fetchVersionStats(alloc: Allocator, zig_version: []const u8) !VersionStats {
    const StatsRow = struct {
        total: i64,
        successful: i64,
    };

    const query =
        \\SELECT 
        \\  COUNT(*) as total,
        \\  SUM(CASE WHEN build_status = 'success' THEN 1 ELSE 0 END) as successful
        \\FROM build_results WHERE zig_version = :version
    ;

    var stmt = db.prepare(struct { version: sqlite.Text }, StatsRow, query) catch {
        return VersionStats{ .packages_tested = 0, .success_rate = alloc.dupe(u8, "N/A") catch "N/A" };
    };
    defer stmt.finalize();

    stmt.bind(.{ .version = sqlite.text(zig_version) }) catch {
        return VersionStats{ .packages_tested = 0, .success_rate = alloc.dupe(u8, "N/A") catch "N/A" };
    };
    defer stmt.reset();

    if (stmt.step() catch null) |row| {
        const total = @as(i32, @intCast(row.total));
        if (total == 0) {
            return VersionStats{ .packages_tested = 0, .success_rate = alloc.dupe(u8, "N/A") catch "N/A" };
        }

        const rate = (@as(f64, @floatFromInt(row.successful)) / @as(f64, @floatFromInt(row.total))) * 100.0;
        const success_rate = std.fmt.allocPrint(alloc, "{d:.1}%", .{rate}) catch "N/A";

        return VersionStats{ .packages_tested = total, .success_rate = success_rate };
    }

    return VersionStats{ .packages_tested = 0, .success_rate = alloc.dupe(u8, "N/A") catch "N/A" };
}

fn fetchTopPackages(alloc: Allocator) ![]StatsPageData.TopPackage {
    const PackageRow = struct {
        name: sqlite.Text,
        author: ?sqlite.Text,
        total_builds: i64,
        successful_builds: i64,
    };

    const query =
        \\SELECT p.name, p.author, 
        \\  COUNT(br.id) as total_builds,
        \\  SUM(CASE WHEN br.build_status = 'success' THEN 1 ELSE 0 END) as successful_builds
        \\FROM packages p 
        \\LEFT JOIN build_results br ON p.id = br.package_id 
        \\GROUP BY p.id, p.name, p.author 
        \\HAVING total_builds > 0
        \\ORDER BY (successful_builds * 1.0 / total_builds) DESC, total_builds DESC 
        \\LIMIT 10
    ;

    var stmt = db.prepare(struct {}, PackageRow, query) catch return &[_]StatsPageData.TopPackage{};
    defer stmt.finalize();

    stmt.bind(.{}) catch return &[_]StatsPageData.TopPackage{};
    defer stmt.reset();

    var packages = std.ArrayList(StatsPageData.TopPackage).init(alloc);
    defer packages.deinit();

    while (stmt.step() catch null) |row| {
        const total = @as(f64, @floatFromInt(row.total_builds));
        const successful = @as(f64, @floatFromInt(row.successful_builds));
        const rate = if (total > 0) (successful / total) * 100.0 else 0.0;

        const package = StatsPageData.TopPackage{
            .name = alloc.dupe(u8, row.name.data) catch continue,
            .author = if (row.author) |auth| alloc.dupe(u8, auth.data) catch "Unknown" else "Unknown",
            .success_rate = std.fmt.allocPrint(alloc, "{d:.1}%", .{rate}) catch continue,
            .total_builds = @intCast(row.total_builds),
        };
        packages.append(package) catch continue;
    }

    return packages.toOwnedSlice() catch &[_]StatsPageData.TopPackage{};
}

fn fetchRecentActivity(alloc: Allocator) ![]StatsPageData.RecentActivity {
    const ActivityRow = struct {
        package_name: sqlite.Text,
        zig_version: sqlite.Text,
        build_status: sqlite.Text,
        last_checked: sqlite.Text,
    };

    const query =
        \\SELECT p.name as package_name, br.zig_version, br.build_status, br.last_checked
        \\FROM build_results br 
        \\JOIN packages p ON br.package_id = p.id 
        \\ORDER BY br.last_checked DESC LIMIT 10
    ;

    var stmt = db.prepare(struct {}, ActivityRow, query) catch return &[_]StatsPageData.RecentActivity{};
    defer stmt.finalize();

    stmt.bind(.{}) catch return &[_]StatsPageData.RecentActivity{};
    defer stmt.reset();

    var activities = std.ArrayList(StatsPageData.RecentActivity).init(alloc);
    defer activities.deinit();

    while (stmt.step() catch null) |row| {
        const activity = StatsPageData.RecentActivity{
            .package_name = alloc.dupe(u8, row.package_name.data) catch continue,
            .zig_version = alloc.dupe(u8, row.zig_version.data) catch continue,
            .build_status = alloc.dupe(u8, row.build_status.data) catch continue,
            .timestamp = alloc.dupe(u8, row.last_checked.data) catch continue,
        };
        activities.append(activity) catch continue;
    }

    return activities.toOwnedSlice() catch &[_]StatsPageData.RecentActivity{};
}

fn freeHomeStatsData(alloc: Allocator, data: HomeStatsData) void {
    alloc.free(data.success_rate);

    for (data.recent_packages) |pkg| {
        alloc.free(pkg.name);
        alloc.free(pkg.author);
        alloc.free(pkg.created_at);
    }
    alloc.free(data.recent_packages);

    for (data.recent_builds) |build| {
        alloc.free(build.package_name);
        alloc.free(build.zig_version);
        alloc.free(build.build_status);
    }
    alloc.free(data.recent_builds);
}

fn freeStatsPageData(alloc: Allocator, data: StatsPageData) void {
    for (data.compatibility_matrix) |row| {
        alloc.free(row.zig_version);
        alloc.free(row.success_rate);
        alloc.free(row.status);
    }
    alloc.free(data.compatibility_matrix);

    for (data.top_packages) |pkg| {
        alloc.free(pkg.name);
        alloc.free(pkg.author);
        alloc.free(pkg.success_rate);
    }
    alloc.free(data.top_packages);

    for (data.recent_activity) |activity| {
        alloc.free(activity.package_name);
        alloc.free(activity.zig_version);
        alloc.free(activity.build_status);
        alloc.free(activity.timestamp);
    }
    alloc.free(data.recent_activity);
}

pub fn main() !void {
    log.info("Starting zig-pkg-checker application...", .{});

    gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();
    log.info("Memory allocator initialized", .{});

    // Initialize database
    log.info("Initializing database...", .{});
    initializeDatabase() catch |err| {
        log.err("Database initialization failed: {}", .{err});
        return;
    };
    defer db.close();
    log.info("Database initialization completed", .{});

    // Initialize build system
    log.info("Initializing Tardy runtime...", .{});
    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();
    log.info("Tardy runtime initialized", .{});

    log.info("Initializing build system...", .{});
    build_sys = build_system.BuildSystem.init(allocator, &db, &t);
    defer build_sys.deinit();
    log.info("Build system initialized", .{});

    // Check if Docker is available
    log.info("Starting Docker availability check...", .{});
    const docker_available = build_sys.checkDockerAvailable() catch |err| blk: {
        log.warn("Docker check failed: {}. Build system will be disabled.", .{err});
        break :blk false;
    };

    if (docker_available) {
        log.info("Docker is available. Build system ready.", .{});
    } else {
        log.warn("Docker not available. Build system disabled.", .{});
    }
    log.info("Docker check phase completed", .{});

    const host = "127.0.0.1";
    const port = 3001;
    log.info("Server configuration: host={s}, port={}", .{ host, port });

    // Create static directory for serving files
    log.info("Opening static directory...", .{});
    const static_dir = Dir.from_std(try std.fs.cwd().openDir("static", .{}));
    log.info("Static directory opened", .{});

    log.info("Initializing router...", .{});
    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, home_handler).layer(),
        Route.init("/packages").get({}, packages_handler).layer(),
        Route.init("/submit").get({}, submit_handler).post({}, submit_handler).layer(),
        Route.init("/stats").get({}, stats_handler).layer(),
        Route.init("/builds").get({}, builds_handler).layer(),
        Route.init("/api").get({}, api_docs_handler).layer(),
        Route.init("/packages/%s/builds").get({}, build_results_handler).layer(),
        Route.init("/builds/%s").get({}, build_results_handler).layer(),
        FsDir.serve("/static", static_dir),
        Route.init("/api/health").get({}, api_health_handler).layer(),
        Route.init("/api/github-info").post({}, api_github_info_handler).layer(),
        Route.init("/api/packages").get({}, api_get_packages).post({}, api_create_package).layer(),
        // Admin API endpoints (require authentication)
        Route.init("/admin/trigger-build").post({}, admin_trigger_build_handler).layer(),
        Route.init("/admin/check-builds").post({}, admin_check_builds_handler).layer(),
        Route.init("/admin/status").get({}, admin_status_handler).layer(),
        Route.init("/test").get({}, test_handler).layer(),
    }, .{});
    defer router.deinit(allocator);
    log.info("Router initialized with all routes", .{});

    // create socket for tardy
    log.info("Creating socket...", .{});
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    log.info("Socket created, binding...", .{});
    try socket.bind();
    log.info("Socket bound, starting to listen...", .{});
    try socket.listen(4096);
    log.info("Socket listening on port {}", .{port});

    log.info("Server listening on http://{s}:{}", .{ host, port });
    log.info("Available endpoints:", .{});
    log.info("  - GET /            - Welcome page", .{});
    log.info("  - GET /packages    - Package listing", .{});
    log.info("  - GET /submit      - Submit package", .{});
    log.info("  - GET /stats       - Package statistics", .{});
    log.info("  - GET /builds      - All build results", .{});
    log.info("  - GET /api         - API documentation", .{});
    log.info("  - GET /packages/{{name}}/builds - Build results for package", .{});
    log.info("  - GET /builds/{{name}} - Build results for package (alternative)", .{});
    log.info("  - GET /api/health  - Health check", .{});
    log.info("  - POST /api/github-info - Get GitHub repository info", .{});
    log.info("  - GET /api/packages - List packages", .{});
    log.info("  - POST /api/packages - Submit package", .{});
    log.info("  - POST /admin/trigger-build - Manually trigger builds (admin only)", .{});
    log.info("  - POST /admin/check-builds - Check for stalled builds (admin only)", .{});
    log.info("  - GET /admin/status - System status (admin only)", .{});
    log.info("  - GET /test        - Test handler", .{});
    log.info("", .{});
    log.info("Admin token: {s}", .{ADMIN_TOKEN});
    log.info("Use 'Authorization: Bearer {s}' header for admin endpoints", .{ADMIN_TOKEN});

    // Cleanup old build artifacts on startup
    if (docker_available) {
        log.info("Cleaning up old build artifacts...", .{});
        build_sys.cleanup() catch |err| {
            log.warn("Failed to cleanup old build artifacts: {}", .{err});
        };
        log.info("Build artifacts cleanup completed", .{});
    }

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    log.info("Starting Tardy entry point...", .{});
    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                // Set global runtime for use by handlers
                global_runtime = rt;
                log.info("Runtime context set for build system", .{});

                // Initialize cron system for automated tasks
                cron_system = CronSystem.init(allocator, rt, &db, &build_sys) catch |err| blk: {
                    log.err("Failed to initialize cron system: {}", .{err});
                    break :blk null;
                };

                if (cron_system) |cron| {
                    cron.start() catch |err| {
                        log.err("Failed to start cron system: {}", .{err});
                        cron.deinit();
                        cron_system = null;
                    };
                } else {
                    log.warn("Cron system not available - automated build checks disabled", .{});
                }

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

    // Cleanup cron system after server stops
    if (cron_system) |cron| {
        log.info("Shutting down cron system", .{});
        cron.deinit();
        cron_system = null;
    }
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

// Admin API endpoints (require authentication)

// Admin endpoint to manually trigger builds for a specific package
fn admin_trigger_build_handler(ctx: *const Context, _: void) !Respond {
    // Check admin authentication
    if (!requireAdminAuth(ctx)) {
        return ctx.response.apply(.{ .status = .Unauthorized, .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Unauthorized. Admin token required.",
            \\  "message": "Include 'Authorization: Bearer <token>' header with valid admin token."
            \\}
        });
    }

    if (ctx.request.method) |method| {
        if (method != .POST) {
            return ctx.response.apply(.{ .status = .@"Method Not Allowed", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Method not allowed. Use POST."
                \\}
            });
        }
    }

    // Read request body
    const body = ctx.request.body orelse {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Request body is required",
            \\  "expected": "{ \"package_id\": number } or { \"package_name\": \"string\" }"
            \\}
        });
    };

    log.info("Admin build trigger request: {s}", .{body});

    // Extract package identifier from JSON request
    const package_id_str = extractJsonField(ctx.allocator, body, "package_id");
    defer if (package_id_str) |s| ctx.allocator.free(s);

    const package_name = extractJsonField(ctx.allocator, body, "package_name");
    defer if (package_name) |s| ctx.allocator.free(s);

    if (package_id_str == null and package_name == null) {
        return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Either 'package_id' or 'package_name' is required"
            \\}
        });
    }

    // Get package information
    var package_id: i64 = 0;
    var pkg_name: []const u8 = "";
    var pkg_url: []const u8 = "";

    if (package_id_str) |id_str| {
        package_id = std.fmt.parseInt(i64, id_str, 10) catch {
            return ctx.response.apply(.{ .status = .@"Bad Request", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Invalid package_id format. Must be a number."
                \\}
            });
        };
    } else if (package_name) |name| {
        // Look up package by name
        const PackageRow = struct {
            id: i64,
            name: sqlite.Text,
            url: sqlite.Text,
        };

        const query = "SELECT id, name, url FROM packages WHERE name = :name";
        var stmt = db.prepare(struct { name: sqlite.Text }, PackageRow, query) catch |err| {
            log.err("Failed to prepare package lookup query: {}", .{err});
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Database query failed"
                \\}
            });
        };
        defer stmt.finalize();

        stmt.bind(.{ .name = sqlite.text(name) }) catch |err| {
            log.err("Failed to bind package name: {}", .{err});
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Database query failed"
                \\}
            });
        };
        defer stmt.reset();

        const package_info = stmt.step() catch |err| {
            log.err("Failed to execute package lookup: {}", .{err});
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Database query failed"
                \\}
            });
        } orelse {
            return ctx.response.apply(.{ .status = .@"Not Found", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Package not found"
                \\}
            });
        };

        package_id = package_info.id;
        pkg_name = try ctx.allocator.dupe(u8, package_info.name.data);
        pkg_url = try ctx.allocator.dupe(u8, package_info.url.data);
    }

    // If we only have package_id, look up the name and URL
    if (pkg_name.len == 0) {
        const PackageRow = struct {
            name: sqlite.Text,
            url: sqlite.Text,
        };

        const query = "SELECT name, url FROM packages WHERE id = :id";
        var stmt = db.prepare(struct { id: i64 }, PackageRow, query) catch |err| {
            log.err("Failed to prepare package info query: {}", .{err});
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Database query failed"
                \\}
            });
        };
        defer stmt.finalize();

        stmt.bind(.{ .id = package_id }) catch |err| {
            log.err("Failed to bind package ID: {}", .{err});
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Database query failed"
                \\}
            });
        };
        defer stmt.reset();

        const package_info = stmt.step() catch |err| {
            log.err("Failed to execute package info query: {}", .{err});
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Database query failed"
                \\}
            });
        } orelse {
            return ctx.response.apply(.{ .status = .@"Not Found", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Package not found"
                \\}
            });
        };

        pkg_name = try ctx.allocator.dupe(u8, package_info.name.data);
        pkg_url = try ctx.allocator.dupe(u8, package_info.url.data);
    }

    defer if (pkg_name.len > 0) ctx.allocator.free(pkg_name);
    defer if (pkg_url.len > 0) ctx.allocator.free(pkg_url);

    log.info("Admin triggering build for package '{s}' (ID: {d})", .{ pkg_name, package_id });

    // Start builds for all Zig versions
    if (global_runtime) |rt| {
        startPackageBuildsWithRuntime(rt, package_id, pkg_name, pkg_url) catch |err| {
            log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Failed to start build process"
                \\}
            });
        };
    } else {
        build_sys.startPackageBuilds(package_id, pkg_name, pkg_url) catch |err| {
            log.err("Failed to start builds for package {d}: {}", .{ package_id, err });
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Failed to start build process"
                \\}
            });
        };
    }

    const response_body = try std.fmt.allocPrint(ctx.allocator,
        \\{{
        \\  "message": "Build triggered successfully",
        \\  "package_id": {d},
        \\  "package_name": "{s}",
        \\  "status": "Build started for all Zig versions"
        \\}}
    , .{ package_id, pkg_name });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = response_body,
    });
}

// Admin endpoint to check for stalled builds and restart them
fn admin_check_builds_handler(ctx: *const Context, _: void) !Respond {
    // Check admin authentication
    if (!requireAdminAuth(ctx)) {
        return ctx.response.apply(.{ .status = .Unauthorized, .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Unauthorized. Admin token required.",
            \\  "message": "Include 'Authorization: Bearer <token>' header with valid admin token."
            \\}
        });
    }

    if (ctx.request.method) |method| {
        if (method != .POST) {
            return ctx.response.apply(.{ .status = .@"Method Not Allowed", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Method not allowed. Use POST."
                \\}
            });
        }
    }

    log.info("Admin triggered build health check", .{});

    if (cron_system) |cron| {
        // Manually trigger the stalled build check
        cron.checkStalledBuilds() catch |err| {
            log.err("Admin build check failed: {}", .{err});
            return ctx.response.apply(.{ .status = .@"Internal Server Error", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Build health check failed"
                \\}
            });
        };

        return ctx.response.apply(.{ .status = .OK, .mime = http.Mime.JSON, .body = 
            \\{
            \\  "message": "Build health check completed successfully",
            \\  "status": "Stalled builds have been identified and restarted"
            \\}
        });
    } else {
        return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Cron system not available"
            \\}
        });
    }
}

// Admin endpoint to get system status
fn admin_status_handler(ctx: *const Context, _: void) !Respond {
    // Check admin authentication
    if (!requireAdminAuth(ctx)) {
        return ctx.response.apply(.{ .status = .Unauthorized, .mime = http.Mime.JSON, .body = 
            \\{
            \\  "error": "Unauthorized. Admin token required.",
            \\  "message": "Include 'Authorization: Bearer <token>' header with valid admin token."
            \\}
        });
    }

    if (ctx.request.method) |method| {
        if (method != .GET) {
            return ctx.response.apply(.{ .status = .@"Method Not Allowed", .mime = http.Mime.JSON, .body = 
                \\{
                \\  "error": "Method not allowed. Use GET."
                \\}
            });
        }
    }

    // Get system statistics
    const total_packages = fetchTotalPackagesCount() catch 0;
    const build_counts = fetchBuildCounts() catch .{ .successful = 0, .failed = 0 };
    const pending_count = fetchPendingBuildsCount() catch 0;

    // Check Docker availability
    const docker_available = build_sys.checkDockerAvailable() catch false;

    // Check cron system status
    const cron_running = if (cron_system) |cron| cron.is_running else false;

    const response_body = try std.fmt.allocPrint(ctx.allocator,
        \\{{
        \\  "status": "ok",
        \\  "timestamp": "{d}",
        \\  "system": {{
        \\    "docker_available": {s},
        \\    "cron_system_running": {s},
        \\    "runtime_available": {s}
        \\  }},
        \\  "statistics": {{
        \\    "total_packages": {d},
        \\    "successful_builds": {d},
        \\    "failed_builds": {d},
        \\    "pending_builds": {d},
        \\    "total_builds": {d}
        \\  }},
        \\  "admin_token": "Active"
        \\}}
    , .{ std.time.timestamp(), if (docker_available) "true" else "false", if (cron_running) "true" else "false", if (global_runtime != null) "true" else "false", total_packages, build_counts.successful, build_counts.failed, pending_count, build_counts.successful + build_counts.failed + pending_count });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = response_body,
    });
}
