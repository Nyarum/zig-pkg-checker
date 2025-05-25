const std = @import("std");
const log = std.log.scoped(.build_system);
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const lib = @import("zig_pkg_checker_lib");

const zzz = @import("zzz");
const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

pub const BuildError = error{
    DockerNotFound,
    BuildFailed,
    InvalidPackageUrl,
    DatabaseError,
    AllocationError,
    ProcessFailed,
    TardyError,
    OutOfMemory,
};

pub const ZigVersion = enum {
    master,
    @"0.14.0",
    @"0.13.0",
    @"0.12.0",

    pub fn toString(self: ZigVersion) []const u8 {
        return switch (self) {
            .master => "master",
            .@"0.14.0" => "0.14.0",
            .@"0.13.0" => "0.13.0",
            .@"0.12.0" => "0.12.0",
        };
    }

    pub fn dockerImage(self: ZigVersion) []const u8 {
        return switch (self) {
            .master => "zig-checker:master",
            .@"0.14.0" => "zig-checker:0.14.0",
            .@"0.13.0" => "zig-checker:0.13.0",
            .@"0.12.0" => "zig-checker:0.12.0",
        };
    }
};

pub const BuildResult = struct {
    build_id: []const u8,
    package_name: []const u8,
    repo_url: []const u8,
    zig_version: []const u8,
    start_time: []const u8,
    build_status: []const u8, // "success", "failed", "pending"
    test_status: ?[]const u8, // "success", "failed", "no_tests", null
    error_log: []const u8,
    build_log: []const u8,
    end_time: ?[]const u8,

    pub fn deinit(self: *BuildResult, allocator: Allocator) void {
        allocator.free(self.build_id);
        allocator.free(self.package_name);
        allocator.free(self.repo_url);
        allocator.free(self.zig_version);
        allocator.free(self.start_time);
        allocator.free(self.build_status);
        if (self.test_status) |ts| allocator.free(ts);
        allocator.free(self.error_log);
        allocator.free(self.build_log);
        if (self.end_time) |et| allocator.free(et);
    }

    /// Free BuildResult array allocated with main allocator
    pub fn deinitArray(results: []BuildResult, allocator: Allocator) void {
        for (results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(results);
    }

    /// Free BuildResult array allocated with arena - no individual cleanup needed
    pub fn deinitArenaArray(results: []BuildResult, arena: *std.heap.ArenaAllocator) void {
        _ = results; // Individual strings don't need freeing with arena
        arena.deinit(); // This frees everything at once
    }
};

/// Database-safe string storage for SQLite operations
/// Ensures strings remain valid for the lifetime of database operations
const DbStringStorage = struct {
    allocator: Allocator,
    strings: std.ArrayList([]u8),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .strings = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit();
    }

    /// Store a string copy that will remain valid until deinit
    pub fn store(self: *Self, str: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, str);
        try self.strings.append(copy);
        return copy;
    }
};

/// Task context for multi-version build execution
const MultiVersionBuildTask = struct {
    parent_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    db: *sqlite.Database,
    package_id: i64,
    package_name: []const u8,
    repo_url: []const u8,
    versions: []const ZigVersion,

    pub fn init(parent_allocator: Allocator, db: *sqlite.Database, package_id: i64, package_name: []const u8, repo_url: []const u8, versions: []const ZigVersion) !MultiVersionBuildTask {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();

        // Allocate copies in the arena
        const arena_allocator = arena.allocator();
        const package_name_copy = try arena_allocator.dupe(u8, package_name);
        const repo_url_copy = try arena_allocator.dupe(u8, repo_url);

        return MultiVersionBuildTask{
            .parent_allocator = parent_allocator,
            .arena = arena,
            .db = db,
            .package_id = package_id,
            .package_name = package_name_copy,
            .repo_url = repo_url_copy,
            .versions = versions,
        };
    }

    pub fn deinit(self: *MultiVersionBuildTask) void {
        self.arena.deinit();
    }
};

/// Task context for single build execution
const BuildTask = struct {
    parent_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    build_id: []const u8,
    container_name: []const u8,
    host_result_file: []const u8,
    container_result_file: []const u8,

    pub fn init(parent_allocator: Allocator, package_id: i64, version: ZigVersion) !BuildTask {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();

        const arena_allocator = arena.allocator();

        // Generate unique build ID and container name
        const build_id = try std.fmt.allocPrint(arena_allocator, "{d}-{s}-{d}", .{
            package_id,
            version.toString(),
            std.time.timestamp(),
        });

        const container_name = try std.fmt.allocPrint(arena_allocator, "zig-pkg-checker-{s}", .{build_id});

        // Use dedicated results directory
        const host_result_file = try std.fmt.allocPrint(arena_allocator, "/tmp/zig_pkg_checker_results/build_result_{s}.json", .{build_id});
        const container_result_file = try std.fmt.allocPrint(arena_allocator, "/results/build_result_{s}.json", .{build_id});

        return BuildTask{
            .parent_allocator = parent_allocator,
            .arena = arena,
            .build_id = build_id,
            .container_name = container_name,
            .host_result_file = host_result_file,
            .container_result_file = container_result_file,
        };
    }

    pub fn deinit(self: *BuildTask) void {
        self.arena.deinit();
    }
};

pub const BuildSystem = struct {
    allocator: Allocator,
    db: *sqlite.Database,
    tardy_instance: *Tardy,
    runtime: ?*Runtime,
    db_mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: Allocator, db: *sqlite.Database, tardy_instance: *Tardy) Self {
        return Self{
            .allocator = allocator,
            .db = db,
            .tardy_instance = tardy_instance,
            .runtime = null,
            .db_mutex = std.Thread.Mutex{},
        };
    }

    pub fn setRuntime(self: *Self, runtime: *Runtime) void {
        self.runtime = runtime;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Nothing to cleanup for now
    }

    /// Check if Docker is available - simplified version without reading output
    pub fn checkDockerAvailable(self: *Self) BuildError!bool {
        log.info("Checking Docker availability...", .{});

        // Use the simple Child.run approach but with limited output
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "docker", "--version" },
            .max_output_bytes = 1024, // Small buffer to avoid hanging
        }) catch |err| {
            log.err("Failed to execute 'docker --version' command: {}", .{err});
            return BuildError.DockerNotFound;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        log.debug("Docker command completed, processing result...", .{});

        const success = result.term == .Exited and result.term.Exited == 0;
        if (!success) {
            log.err("Docker command failed - exit code: {}, stderr: {s}", .{ result.term, result.stderr });
        } else {
            log.debug("Docker is available - stdout length: {}", .{result.stdout.len});
        }

        log.info("Docker availability check completed: {}", .{success});
        return success;
    }

    /// Build Docker images for all Zig versions
    pub fn buildDockerImages(self: *Self) BuildError!void {
        const versions = [_]ZigVersion{ .master, .@"0.14.0", .@"0.13.0", .@"0.12.0" };

        // Use single arena for all image builds to reduce allocation overhead
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        for (versions) |version| {
            try self.buildDockerImageWithArena(arena_allocator, version);
        }
    }

    /// Build Docker image for a specific Zig version using arena allocator
    fn buildDockerImageWithArena(_: *Self, arena_allocator: Allocator, version: ZigVersion) BuildError!void {
        const version_str = version.toString();
        const docker_dir = std.fmt.allocPrint(arena_allocator, "docker/zig-{s}", .{version_str}) catch |err| {
            log.err("Failed to allocate memory for docker_dir: {}", .{err});
            return BuildError.AllocationError;
        };

        const image_name = version.dockerImage();

        log.info("Building Docker image for Zig {s}...", .{version_str});

        const result = std.process.Child.run(.{
            .allocator = arena_allocator,
            .argv = &[_][]const u8{ "docker", "build", "-t", image_name, docker_dir },
            .max_output_bytes = 50 * 1024 * 1024, // 50MB buffer for Docker build output
        }) catch |err| {
            log.err("Failed to execute docker build command for Zig {s} at {s}:{}: {}", .{ version_str, @src().file, @src().line, err });
            log.err("Command attempted: docker build -t {s} {s}", .{ image_name, docker_dir });
            return BuildError.ProcessFailed;
        };
        // No need to defer free with arena

        if (result.term != .Exited or result.term.Exited != 0) {
            log.err("Docker build failed for Zig {s} at {s}:{} - exit code: {}, stderr: {s}", .{ version_str, @src().file, @src().line, result.term, result.stderr });
            if (result.stdout.len > 0) {
                log.err("Docker build stdout: {s}", .{result.stdout});
            }
            return BuildError.BuildFailed;
        }

        log.info("Successfully built Docker image for Zig {s}", .{version_str});
    }

    /// Build Docker image for a specific Zig version
    pub fn buildDockerImage(self: *Self, version: ZigVersion) BuildError!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        try self.buildDockerImageWithArena(arena.allocator(), version);
    }

    /// Ensure Docker image exists with arena allocator, build it if it doesn't
    fn ensureDockerImageWithArena(self: *Self, arena_allocator: Allocator, version: ZigVersion) BuildError!void {
        const image_name = version.dockerImage();

        // Check if image exists
        const check_result = std.process.Child.run(.{
            .allocator = arena_allocator,
            .argv = &[_][]const u8{ "docker", "image", "inspect", image_name },
            .max_output_bytes = 1024 * 1024, // 1MB buffer for image inspect JSON output
        }) catch |err| {
            log.err("Failed to execute 'docker image inspect {s}' command: {}", .{ image_name, err });
            return BuildError.ProcessFailed;
        };
        // No need to defer free with arena

        if (check_result.term == .Exited and check_result.term.Exited == 0) {
            // Image exists, no need to build
            log.info("Docker image {s} already exists", .{image_name});
            return;
        }

        // Image doesn't exist, build it
        log.info("Docker image {s} not found (exit code: {}), building it now...", .{ image_name, check_result.term });
        if (check_result.stderr.len > 0) {
            log.debug("Docker inspect stderr: {s}", .{check_result.stderr});
        }
        try self.buildDockerImageWithArena(arena_allocator, version);
    }

    /// Ensure Docker image exists, build it if it doesn't
    fn ensureDockerImage(self: *Self, version: ZigVersion) BuildError!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        try self.ensureDockerImageWithArena(arena.allocator(), version);
    }

    /// Start builds for a package across all Zig versions
    pub fn startPackageBuilds(self: *Self, package_id: i64, package_name: []const u8, repo_url: []const u8) BuildError!void {
        const versions = [_]ZigVersion{ .master, .@"0.14.0", .@"0.13.0", .@"0.12.0" };

        // Check if Docker is available
        const docker_available = self.checkDockerAvailable() catch false;
        if (!docker_available) {
            log.err("Docker not available, cannot start builds for package {s}", .{package_name});
            return BuildError.DockerNotFound;
        }

        // Create arena for the entire operation to reduce allocation overhead
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Build Docker images on-demand (only if they don't exist)
        log.info("Ensuring Docker images are available for package {s}...", .{package_name});
        for (versions) |version| {
            self.ensureDockerImageWithArena(arena_allocator, version) catch |err| {
                log.err("Failed to ensure Docker image for Zig {s}: {}", .{ version.toString(), err });
                // Continue with other versions even if one fails
            };
        }

        // Mark all builds as pending first using main allocator instead of arena for database safety
        for (versions) |version| {
            self.markBuildPending(package_id, version.toString()) catch |err| {
                log.err("Failed to mark build as pending for Zig {s}: {}", .{ version.toString(), err });
                // Continue with other versions even if one fails
            };
        }

        // Create task context for all versions
        const task_context = MultiVersionBuildTask.init(self.allocator, self.db, package_id, package_name, repo_url, &versions) catch |err| {
            log.err("Failed to create MultiVersionBuildTask for package {s}: {}", .{ package_name, err });
            return BuildError.AllocationError;
        };

        // Spawn thread for all versions without waiting
        _ = std.Thread.spawn(.{
            .stack_size = 4 * 1024 * 1024, // 4MB stack size for Docker operations
            .allocator = self.allocator,
        }, buildMultiVersionTaskThreadFrame, .{ self, task_context }) catch |err| {
            log.err("Failed to spawn build thread for package {s} at {s}:{}: {}", .{ package_name, @src().file, @src().line, err });
            var task_copy = task_context;
            task_copy.deinit();
            return BuildError.ProcessFailed;
        };

        log.info("Started builds for {s} across {d} Zig versions in background thread", .{ package_name, versions.len });
    }

    /// Thread frame function for multi-version build tasks
    fn buildMultiVersionTaskThreadFrame(build_system: *Self, task: MultiVersionBuildTask) void {
        log.debug("Starting multi-version build task for package {d}", .{task.package_id});

        var task_context = task;
        defer {
            // Cleanup task context - this will clean up the entire arena
            task_context.deinit();
            log.debug("Multi-version build task completed and cleaned up for package {d}", .{task.package_id});
        }

        // Process each version sequentially
        for (task_context.versions) |version| {
            log.info("Processing build for {s} with Zig {s}", .{ task_context.package_name, version.toString() });

            // Execute the build using the existing build system instance with thread-safe database access
            build_system.executeBuildInDockerCore(task_context.package_id, task_context.package_name, task_context.repo_url, version) catch |err| {
                log.err("Threaded Docker build failed for package {d} with Zig {s}: {}", .{ task_context.package_id, version.toString(), err });

                // Update database with failure status using thread-safe access
                build_system.updateBuildResult(task_context.package_id, version.toString(), "failed", null, "Threaded build execution failed", "") catch |db_err| {
                    log.err("Failed to update build result after threaded failure: {}", .{db_err});
                };
                // Continue with next version even if one fails
                continue;
            };
        }
    }

    /// Core Docker build execution with main allocator for better memory management
    fn executeBuildInDockerCore(self: *Self, package_id: i64, package_name: []const u8, repo_url: []const u8, version: ZigVersion) BuildError!void {
        log.debug("Executing core Docker build for package {d}, Zig {s}", .{ package_id, version.toString() });

        // Create BuildTask to get pre-allocated strings and reduce allocation overhead
        var task = BuildTask.init(self.allocator, package_id, version) catch |err| {
            log.err("Failed to create BuildTask for package {d}, Zig {s}: {}", .{ package_id, version.toString(), err });
            return BuildError.AllocationError;
        };
        defer task.deinit();

        const build_id = task.build_id;
        const container_name = task.container_name;
        const host_result_file = task.host_result_file;
        const container_result_file = task.container_result_file;

        // Create a dedicated results directory if it doesn't exist
        const results_dir = "/tmp/zig_pkg_checker_results";
        std.fs.cwd().makeDir(results_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // Directory already exists, which is fine
            else => {
                log.err("Failed to create results directory {s}: {}", .{ results_dir, err });
                return BuildError.ProcessFailed;
            },
        };

        log.info("Executing Docker build for {s} with Zig {s} (build_id: {s})", .{ package_name, version.toString(), build_id });

        // Prepare environment variables using main allocator
        const repo_env = std.fmt.allocPrint(self.allocator, "REPO_URL={s}", .{repo_url}) catch |err| {
            log.err("Failed to allocate memory for repo_env: {}", .{err});
            return BuildError.AllocationError;
        };
        defer self.allocator.free(repo_env);

        const name_env = std.fmt.allocPrint(self.allocator, "PACKAGE_NAME={s}", .{package_name}) catch |err| {
            log.err("Failed to allocate memory for name_env: {}", .{err});
            return BuildError.AllocationError;
        };
        defer self.allocator.free(name_env);

        const id_env = std.fmt.allocPrint(self.allocator, "BUILD_ID={s}", .{build_id}) catch |err| {
            log.err("Failed to allocate memory for id_env: {}", .{err});
            return BuildError.AllocationError;
        };
        defer self.allocator.free(id_env);

        const file_env = std.fmt.allocPrint(self.allocator, "RESULT_FILE={s}", .{container_result_file}) catch |err| {
            log.err("Failed to allocate memory for file_env: {}", .{err});
            return BuildError.AllocationError;
        };
        defer self.allocator.free(file_env);

        // Mount the results directory instead of individual files
        const volume_mount = std.fmt.allocPrint(self.allocator, "{s}:/results", .{results_dir}) catch |err| {
            log.err("Failed to allocate memory for volume_mount: {}", .{err});
            return BuildError.AllocationError;
        };
        defer self.allocator.free(volume_mount);

        // Create argument array with proper memory management
        const docker_args = [_][]const u8{
            "docker",      "run",      "--rm",                "--name", container_name,
            "-e",          repo_env,   "-e",                  name_env, "-e",
            id_env,        "-e",       file_env,              "-v",     volume_mount,
            "--memory=2g", "--cpus=2", version.dockerImage(),
        };

        log.debug("Executing docker command: docker run --rm --name {s} -e {s} -e {s} -e {s} -e {s} -v {s} --memory=2g --cpus=2 {s}", .{ container_name, repo_env, name_env, id_env, file_env, volume_mount, version.dockerImage() });

        // Execute Docker container using main allocator
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &docker_args,
            .max_output_bytes = 50 * 1024 * 1024, // 50MB buffer for Docker build output
        }) catch |err| {
            log.err("Failed to execute docker run command for build {s}: {}", .{ build_id, err });
            log.err("Command attempted: docker run --rm --name {s} [env vars] {s}", .{ container_name, version.dockerImage() });
            return BuildError.ProcessFailed;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            log.err("Docker container failed for {s}: {s}", .{ build_id, result.stderr });
            log.err("Docker container stdout: {s}", .{result.stdout});
            log.err("Exit code: {}", .{result.term});
            log.err("Container name: {s}, Image: {s}", .{ container_name, version.dockerImage() });

            // Extract meaningful error from stdout which contains the actual build output
            const meaningful_error = self.extractBuildError(result.stdout, result.stderr) catch |err| blk: {
                log.err("Failed to extract build error: {}", .{err});
                // Provide fallback error message
                const fallback = if (result.stderr.len > 0) result.stderr else "Docker build failed with unknown error";
                break :blk self.allocator.dupe(u8, fallback) catch "Docker build failed with unknown error";
            };
            defer self.allocator.free(meaningful_error);

            self.updateBuildResult(package_id, version.toString(), "failed", null, meaningful_error, "") catch |db_err| {
                log.err("Failed to update build result after Docker failure: {}", .{db_err});
            };
            return BuildError.BuildFailed;
        }

        log.info("Docker container completed successfully for build {s}", .{build_id});

        // Wait a moment for the container to write the result file
        std.time.sleep(2 * std.time.ns_per_s);

        // Process the result file using the host path
        self.processBuildResultFile(package_id, version.toString(), host_result_file) catch |err| {
            log.err("Failed to process build result file: {}", .{err});
            self.updateBuildResult(package_id, version.toString(), "failed", null, "Failed to process result file", "") catch |db_err| {
                log.err("Failed to update build result after processing failure: {}", .{db_err});
            };
        };

        // Clean up result file
        std.fs.cwd().deleteFile(host_result_file) catch |err| {
            log.warn("Failed to cleanup result file {s}: {}", .{ host_result_file, err });
        };
    }

    /// Process build result file and update database using main allocator
    fn processBuildResultFile(self: *Self, package_id: i64, zig_version: []const u8, result_file: []const u8) BuildError!void {
        log.debug("Processing build result file: {s} for package {d}, Zig {s}", .{ result_file, package_id, zig_version });

        // Try to read the result file
        const file = std.fs.cwd().openFile(result_file, .{}) catch |err| {
            log.err("Failed to open build result file {s} for package {d}, Zig {s}: {}", .{ result_file, package_id, zig_version, err });
            return BuildError.ProcessFailed;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
            log.err("Failed to read build result file {s} for package {d}, Zig {s}: {}", .{ result_file, package_id, zig_version, err });
            return BuildError.ProcessFailed;
        };
        defer self.allocator.free(content);

        log.debug("Build result file content length: {d} bytes", .{content.len});
        if (content.len == 0) {
            log.warn("Build result file {s} is empty for package {d}, Zig {s}", .{ result_file, package_id, zig_version });
        }

        // Parse the JSON content (simplified parsing)
        self.processBuildResult(package_id, zig_version, content) catch |err| {
            log.err("Failed to parse build result JSON for package {d}, Zig {s}: {}", .{ package_id, zig_version, err });
            log.err("JSON content preview (first 200 chars): {s}", .{if (content.len > 200) content[0..200] else content});
            return err;
        };
    }

    /// Process build result JSON and update database using main allocator
    fn processBuildResult(self: *Self, package_id: i64, zig_version: []const u8, json_content: []const u8) BuildError!void {
        log.debug("Processing JSON content: {s}", .{json_content});
        log.info("Starting enhanced build result processing for package {d}, Zig {s}", .{ package_id, zig_version });

        // Use proper JSON parsing instead of string matching
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_content, .{ .ignore_unknown_fields = true }) catch |err| {
            log.err("Failed to parse JSON for package {d}, Zig {s}: {}", .{ package_id, zig_version, err });
            // Fallback to string parsing
            return self.processBuildResultFallback(package_id, zig_version, json_content);
        };
        defer parsed.deinit();

        // Extract strings from JSON and make defensive copies immediately
        const build_status_from_json: []const u8 = if (parsed.value.object.get("build_status")) |status_val|
            switch (status_val) {
                .string => |s| s,
                else => "failed",
            }
        else
            "failed";

        const test_status_from_json: ?[]const u8 = if (parsed.value.object.get("test_status")) |test_val|
            switch (test_val) {
                .string => |s| s,
                .null => null,
                else => null,
            }
        else
            null;

        var error_log_from_json: []const u8 = if (parsed.value.object.get("error_log")) |error_val|
            switch (error_val) {
                .string => |s| std.mem.trim(u8, s, " \t\n\r"),
                else => "",
            }
        else
            "";

        const build_log_from_json: []const u8 = if (parsed.value.object.get("build_log")) |log_val|
            switch (log_val) {
                .string => |s| std.mem.trim(u8, s, " \t\n\r"),
                else => "",
            }
        else
            "";

        // **ENHANCED ERROR DETECTION**: Analyze build_log for actual failures
        // Override build_status if we detect build errors regardless of what JSON claims
        var actual_build_status = build_status_from_json;
        var actual_test_status = test_status_from_json;
        var extracted_error: ?[]const u8 = null;
        defer if (extracted_error) |ee| self.allocator.free(ee);

        if (build_log_from_json.len > 0) {
            // Check for definitive build failure patterns
            const failure_patterns = [_][]const u8{
                "error: the following build command failed with exit code",
                "compilation terminated",
                "error: the following command terminated unexpectedly:",
                "error: the following command failed with",
                "build.zig.zon:", // Build file syntax errors
                "error: ld.lld:", // Linker errors
                "fatal:",
            };

            var has_errors = false;
            for (failure_patterns) |pattern| {
                if (std.mem.indexOf(u8, build_log_from_json, pattern)) |_| {
                    has_errors = true;
                    log.debug("Detected build failure pattern: '{s}' in build log for package {d}, Zig {s}", .{ pattern, package_id, zig_version });
                    break;
                }
            }

            // Check specifically for "Build Summary" with actual failures
            if (std.mem.indexOf(u8, build_log_from_json, "Build Summary:")) |summary_start| {
                // Look for patterns like "X/Y steps succeeded; Z failed" where Z > 0
                if (std.mem.indexOf(u8, build_log_from_json[summary_start..], " failed")) |_| {
                    has_errors = true;
                    log.debug("Detected build failures in Build Summary for package {d}, Zig {s}", .{ package_id, zig_version });
                } else {
                    // Also check for patterns like "0/Y steps succeeded" which indicates complete failure
                    if (std.mem.indexOf(u8, build_log_from_json[summary_start..], "0/")) |zero_start| {
                        if (std.mem.indexOf(u8, build_log_from_json[summary_start + zero_start ..], " steps succeeded")) |_| {
                            has_errors = true;
                            log.debug("Detected complete build failure (0 steps succeeded) in Build Summary for package {d}, Zig {s}", .{ package_id, zig_version });
                        }
                    }
                }
            }

            // Count "error:" occurrences - if many, likely build failed
            var error_count: usize = 0;
            var search_pos: usize = 0;
            while (std.mem.indexOfPos(u8, build_log_from_json, search_pos, "error:")) |pos| {
                error_count += 1;
                search_pos = pos + 6; // Length of "error:"
            }

            if (error_count >= 2) { // Multiple errors indicate build failure
                has_errors = true;
                log.debug("Detected {d} errors in build log for package {d}, Zig {s}", .{ error_count, package_id, zig_version });
            }

            // If we detected errors, override the status and extract meaningful error
            if (has_errors) {
                actual_build_status = "failed";
                // If tests were supposed to run but build failed, tests also failed
                if (test_status_from_json != null) {
                    actual_test_status = "failed";
                }

                // Extract meaningful error from build_log
                extracted_error = self.extractBuildErrorFromText(build_log_from_json) catch |err| blk: {
                    log.err("Failed to extract error from build_log: {}", .{err});
                    break :blk self.allocator.dupe(u8, "Build failed - see build log for details") catch "Build failed";
                };

                if (extracted_error) |ee| {
                    error_log_from_json = ee;
                    log.info("Overrode build status from 'success' to 'failed' for package {d}, Zig {s} due to build errors", .{ package_id, zig_version });
                } else {
                    error_log_from_json = "Build failed - multiple errors detected in build output";
                }
            }
        }

        // If build failed but error_log is still empty, try to extract error from build_log or other fields
        if (std.mem.eql(u8, actual_build_status, "failed") and error_log_from_json.len == 0) {
            if (build_log_from_json.len > 0) {
                // Try to extract meaningful error from build_log
                extracted_error = self.extractBuildErrorFromText(build_log_from_json) catch |err| blk: {
                    log.err("Failed to extract error from build_log: {}", .{err});
                    break :blk null;
                };
                if (extracted_error) |ee| {
                    error_log_from_json = ee;
                }
            } else {
                error_log_from_json = "Build failed but no error details available";
            }
        }

        // Make copies for database storage
        const build_status = self.allocator.dupe(u8, actual_build_status) catch |err| {
            log.err("Failed to allocate memory for build_status: {}", .{err});
            return BuildError.AllocationError;
        };
        defer self.allocator.free(build_status);

        const test_status = if (actual_test_status) |ts| self.allocator.dupe(u8, ts) catch |err| {
            log.err("Failed to allocate memory for test_status: {}", .{err});
            return BuildError.AllocationError;
        } else null;
        defer if (test_status) |ts| self.allocator.free(ts);

        const error_log = self.allocator.dupe(u8, error_log_from_json) catch |err| {
            log.err("Failed to allocate memory for error_log: {}", .{err});
            return BuildError.AllocationError;
        };
        defer self.allocator.free(error_log);

        const build_log = self.allocator.dupe(u8, build_log_from_json) catch |err| {
            log.err("Failed to allocate memory for build_log: {}", .{err});
            return BuildError.AllocationError;
        };
        defer self.allocator.free(build_log);

        log.debug("Final analysis - build_status: {s}, test_status: {s}, error_log: '{s}' (length: {d})", .{ build_status, if (test_status) |ts| ts else "null", error_log, error_log.len });

        try self.updateBuildResult(package_id, zig_version, build_status, test_status, error_log, build_log);
    }

    /// Fallback JSON processing using string matching with main allocator (for malformed JSON)
    fn processBuildResultFallback(self: *Self, package_id: i64, zig_version: []const u8, json_content: []const u8) BuildError!void {
        log.warn("Using fallback JSON parsing for package {d}, Zig {s}", .{ package_id, zig_version });

        const build_status: []const u8 = if (std.mem.indexOf(u8, json_content, "\"build_status\": \"success\"")) |_| "success" else "failed";

        const test_status: ?[]const u8 = if (std.mem.indexOf(u8, json_content, "\"test_status\": \"success\"")) |_|
            "success"
        else if (std.mem.indexOf(u8, json_content, "\"test_status\": \"failed\"")) |_|
            "failed"
        else if (std.mem.indexOf(u8, json_content, "\"test_status\": \"no_tests\"")) |_|
            "no_tests"
        else if (std.mem.indexOf(u8, json_content, "\"test_status\": null")) |_|
            null
        else
            null;

        // Improved error_log extraction
        const error_log: []const u8 = blk: {
            if (std.mem.indexOf(u8, json_content, "\"error_log\": \"")) |start| {
                const log_start = start + 14; // Length of "\"error_log\": \""
                // Handle empty string case
                if (json_content.len > log_start + 1 and json_content[log_start] == '"') {
                    break :blk ""; // Empty error log
                }
                // Find the closing quote, handling escaped quotes
                var pos = log_start;
                while (pos < json_content.len) {
                    if (json_content[pos] == '"' and (pos == log_start or json_content[pos - 1] != '\\')) {
                        const extracted = json_content[log_start..pos];
                        break :blk std.mem.trim(u8, extracted, " \t\n\r");
                    }
                    pos += 1;
                }
            }
            break :blk "";
        };

        const build_log = ""; // Will be extracted when proper JSON parsing is implemented

        try self.updateBuildResult(package_id, zig_version, build_status, test_status, error_log, build_log);
    }

    /// Update build result in database using main allocator with proper SQLite statement lifecycle
    fn updateBuildResult(self: *Self, package_id: i64, zig_version: []const u8, build_status: []const u8, test_status: ?[]const u8, error_log: []const u8, build_log: []const u8) BuildError!void {
        _ = build_log; // Will be used when proper JSON parsing is implemented

        log.debug("Updating build result for package {d} with Zig {s}: status={s}, test_status={s}", .{ package_id, zig_version, build_status, if (test_status) |ts| ts else "null" });

        // Lock database mutex for thread safety
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        // Create string storage to ensure strings remain valid for SQLite operation lifetime
        var db_strings = DbStringStorage.init(self.allocator);
        defer db_strings.deinit();

        // Store strings that will remain valid for the entire database operation
        const build_status_stored = db_strings.store(build_status) catch |err| {
            log.err("Failed to store build_status string: {}", .{err});
            return BuildError.AllocationError;
        };

        const test_status_stored = if (test_status) |ts| db_strings.store(ts) catch |err| {
            log.err("Failed to store test_status string: {}", .{err});
            return BuildError.AllocationError;
        } else null;

        const error_log_stored = db_strings.store(error_log) catch |err| {
            log.err("Failed to store error_log string: {}", .{err});
            return BuildError.AllocationError;
        };

        const zig_version_stored = db_strings.store(zig_version) catch |err| {
            log.err("Failed to store zig_version string: {}", .{err});
            return BuildError.AllocationError;
        };

        // Use prepared statements with proper lifecycle management
        if (test_status_stored) |ts| {
            // Update with test_status
            const UpdateParams = struct {
                build_status: sqlite.Text,
                test_status: sqlite.Text,
                error_log: sqlite.Text,
                package_id: i64,
                zig_version: sqlite.Text,
            };

            const query = "UPDATE build_results SET build_status = :build_status, test_status = :test_status, error_log = :error_log, last_checked = CURRENT_TIMESTAMP WHERE package_id = :package_id AND zig_version = :zig_version";

            var stmt = self.db.prepare(UpdateParams, void, query) catch |err| {
                log.err("Failed to prepare update statement with test_status for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
                return BuildError.DatabaseError;
            };
            defer stmt.finalize();

            stmt.bind(.{
                .build_status = sqlite.text(build_status_stored),
                .test_status = sqlite.text(ts),
                .error_log = sqlite.text(error_log_stored),
                .package_id = package_id,
                .zig_version = sqlite.text(zig_version_stored),
            }) catch |err| {
                log.err("Failed to bind parameters for update with test_status for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
                return BuildError.DatabaseError;
            };

            _ = stmt.step() catch |err| {
                log.err("Database error when updating build result with test_status for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
                log.err("SQL query: {s}", .{query});
                log.err("Parameters: build_status={s}, test_status={s}, error_log={s}, package_id={d}, zig_version={s}", .{ build_status_stored, ts, error_log_stored, package_id, zig_version_stored });
                return BuildError.DatabaseError;
            };
        } else {
            // Update without test_status (set to NULL)
            const UpdateParams = struct {
                build_status: sqlite.Text,
                error_log: sqlite.Text,
                package_id: i64,
                zig_version: sqlite.Text,
            };

            const query = "UPDATE build_results SET build_status = :build_status, test_status = NULL, error_log = :error_log, last_checked = CURRENT_TIMESTAMP WHERE package_id = :package_id AND zig_version = :zig_version";

            var stmt = self.db.prepare(UpdateParams, void, query) catch |err| {
                log.err("Failed to prepare update statement without test_status for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
                return BuildError.DatabaseError;
            };
            defer stmt.finalize();

            stmt.bind(.{
                .build_status = sqlite.text(build_status_stored),
                .error_log = sqlite.text(error_log_stored),
                .package_id = package_id,
                .zig_version = sqlite.text(zig_version_stored),
            }) catch |err| {
                log.err("Failed to bind parameters for update without test_status for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
                return BuildError.DatabaseError;
            };

            _ = stmt.step() catch |err| {
                log.err("Database error when updating build result without test_status for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
                log.err("SQL query: {s}", .{query});
                log.err("Parameters: build_status={s}, test_status=NULL, error_log={s}, package_id={d}, zig_version={s}", .{ build_status_stored, error_log_stored, package_id, zig_version_stored });
                return BuildError.DatabaseError;
            };
        }

        log.info("Updated build result for package {d} with Zig {s}: {s} (test: {s})", .{ package_id, zig_version, build_status, if (test_status) |ts| ts else "null" });

        if (error_log.len > 0) {
            log.err("Build error for package {d}: {s}", .{ package_id, error_log });
        }
    }

    /// Extract meaningful error from Docker build output using main allocator
    fn extractBuildError(self: *Self, stdout: []const u8, stderr: []const u8) BuildError![]const u8 {
        // Look for common Zig error patterns in stdout first
        const error_patterns = [_][]const u8{
            "error:",
            "Build failed",
            "unsupported zig version:",
            "compilation terminated",
            "build.zig:",
            "fatal:",
        };

        // Search for error patterns in stdout (which contains the actual build output)
        for (error_patterns) |pattern| {
            if (std.mem.indexOf(u8, stdout, pattern)) |start_pos| {
                // Extract a meaningful portion around the error
                const line_start = std.mem.lastIndexOfScalar(u8, stdout[0..start_pos], '\n') orelse 0;
                const line_end = std.mem.indexOfScalar(u8, stdout[start_pos..], '\n') orelse stdout.len - start_pos;

                // Try to get a few lines of context
                var extract_start = line_start;
                var lines_before: u8 = 0;
                while (lines_before < 2 and extract_start > 0) {
                    const prev_line = std.mem.lastIndexOfScalar(u8, stdout[0 .. extract_start - 1], '\n') orelse 0;
                    extract_start = prev_line;
                    lines_before += 1;
                }

                var extract_end = start_pos + line_end;
                var lines_after: u8 = 0;
                while (lines_after < 3 and extract_end < stdout.len) {
                    const next_line = std.mem.indexOfScalar(u8, stdout[extract_end + 1 ..], '\n') orelse break;
                    extract_end += next_line + 1;
                    lines_after += 1;
                }

                const extracted = stdout[extract_start..@min(extract_end, stdout.len)];

                // Return a copy of the extracted error
                return self.allocator.dupe(u8, std.mem.trim(u8, extracted, " \t\n\r")) catch |err| {
                    log.err("Failed to allocate memory for extracted error: {}", .{err});
                    return BuildError.AllocationError;
                };
            }
        }

        // If no specific error pattern found in stdout, check stderr
        if (stderr.len > 0) {
            return self.allocator.dupe(u8, std.mem.trim(u8, stderr, " \t\n\r")) catch |err| {
                log.err("Failed to allocate memory for stderr error: {}", .{err});
                return BuildError.AllocationError;
            };
        }

        // Fallback to a generic error message
        return self.allocator.dupe(u8, "Docker build failed with unknown error") catch |err| {
            log.err("Failed to allocate memory for fallback error: {}", .{err});
            return BuildError.AllocationError;
        };
    }

    /// Extract meaningful error from text using main allocator
    fn extractBuildErrorFromText(self: *Self, text: []const u8) BuildError![]const u8 {
        // Look for common Zig error patterns in text first
        const error_patterns = [_][]const u8{
            "error:",
            "Build failed",
            "unsupported zig version:",
            "compilation terminated",
            "build.zig:",
            "build.zig.zon:",
            "fatal:",
            "error: the following build command failed with exit code",
            "error: the following command terminated unexpectedly:",
            "error: the following command failed with",
        };

        // Search for error patterns in text (which contains the actual build output)
        for (error_patterns) |pattern| {
            if (std.mem.indexOf(u8, text, pattern)) |start_pos| {
                // This branch won't be reached now since "Build Summary:" was removed from error_patterns
                // But we handle Build Summary separately below

                // Special handling for build.zig.zon errors (syntax errors)
                if (std.mem.eql(u8, pattern, "build.zig.zon:")) {
                    // Extract the line containing the syntax error
                    const line_start = std.mem.lastIndexOfScalar(u8, text[0..start_pos], '\n') orelse 0;
                    const line_end_offset = std.mem.indexOfScalar(u8, text[start_pos..], '\n') orelse text.len - start_pos;
                    const line_end = start_pos + line_end_offset;

                    const error_line = text[line_start..line_end];
                    return self.allocator.dupe(u8, std.mem.trim(u8, error_line, " \t\n\r")) catch |err| {
                        log.err("Failed to allocate memory for build.zig.zon error: {}", .{err});
                        return BuildError.AllocationError;
                    };
                }

                // Extract a meaningful portion around the error
                const line_start = std.mem.lastIndexOfScalar(u8, text[0..start_pos], '\n') orelse 0;
                const line_end = std.mem.indexOfScalar(u8, text[start_pos..], '\n') orelse text.len - start_pos;

                // Try to get a few lines of context
                var extract_start = line_start;
                var lines_before: u8 = 0;
                while (lines_before < 2 and extract_start > 0) {
                    const prev_line = std.mem.lastIndexOfScalar(u8, text[0 .. extract_start - 1], '\n') orelse 0;
                    extract_start = prev_line;
                    lines_before += 1;
                }

                var extract_end = start_pos + line_end;
                var lines_after: u8 = 0;
                while (lines_after < 3 and extract_end < text.len) {
                    const next_line = std.mem.indexOfScalar(u8, text[extract_end + 1 ..], '\n') orelse break;
                    extract_end += next_line + 1;
                    lines_after += 1;
                }

                const extracted = text[extract_start..@min(extract_end, text.len)];

                // Return a copy of the extracted error
                return self.allocator.dupe(u8, std.mem.trim(u8, extracted, " \t\n\r")) catch |err| {
                    log.err("Failed to allocate memory for extracted error: {}", .{err});
                    return BuildError.AllocationError;
                };
            }
        }

        // Special handling for Build Summary with actual failures
        if (std.mem.indexOf(u8, text, "Build Summary:")) |summary_start| {
            // Extract the entire Build Summary section
            var summary_end = text.len;

            // Find the end of the Build Summary (usually at next major section or end)
            if (std.mem.indexOfPos(u8, text, summary_start, "\nerror: the following build command failed")) |next_section| {
                summary_end = next_section;
            }

            const summary_text = text[summary_start..summary_end];

            // Look for specific failure indicators in summary
            if (std.mem.indexOf(u8, summary_text, " failed")) |_| {
                return self.allocator.dupe(u8, std.mem.trim(u8, summary_text, " \t\n\r")) catch |err| {
                    log.err("Failed to allocate memory for Build Summary error: {}", .{err});
                    return BuildError.AllocationError;
                };
            }

            // Also check for complete failures (0/Y steps succeeded)
            if (std.mem.indexOf(u8, summary_text, "0/")) |zero_start| {
                if (std.mem.indexOf(u8, summary_text[zero_start..], " steps succeeded")) |_| {
                    return self.allocator.dupe(u8, std.mem.trim(u8, summary_text, " \t\n\r")) catch |err| {
                        log.err("Failed to allocate memory for Build Summary complete failure: {}", .{err});
                        return BuildError.AllocationError;
                    };
                }
            }
        }

        // If no specific error pattern found, look for the first occurrence of "error:" and extract context
        if (std.mem.indexOf(u8, text, "error:")) |first_error| {
            const line_start = std.mem.lastIndexOfScalar(u8, text[0..first_error], '\n') orelse 0;
            var extract_end = first_error + 200; // Get ~200 chars after first error
            if (extract_end > text.len) extract_end = text.len;

            // Try to end at a reasonable boundary (newline)
            if (std.mem.lastIndexOfScalar(u8, text[first_error..extract_end], '\n')) |last_newline| {
                extract_end = first_error + last_newline;
            }

            const extracted = text[line_start..extract_end];
            return self.allocator.dupe(u8, std.mem.trim(u8, extracted, " \t\n\r")) catch |err| {
                log.err("Failed to allocate memory for first error: {}", .{err});
                return BuildError.AllocationError;
            };
        }

        // If no error patterns found in text, return a generic error message
        return self.allocator.dupe(u8, "Build failed with unknown error") catch |err| {
            log.err("Failed to allocate memory for fallback error: {}", .{err});
            return BuildError.AllocationError;
        };
    }

    /// Mark a build as pending in the database using main allocator with proper SQLite management
    fn markBuildPending(self: *Self, package_id: i64, zig_version: []const u8) BuildError!void {
        log.debug("Marking build as pending for package {d} with Zig {s}", .{ package_id, zig_version });

        // Lock database mutex for thread safety
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        // First check if the package exists to avoid foreign key constraint issues
        const PackageCheck = struct { count: i64 };
        var check_stmt = self.db.prepare(struct { package_id: i64 }, PackageCheck, "SELECT COUNT(*) as count FROM packages WHERE id = :package_id") catch |err| {
            log.err("Failed to prepare package existence check for package {d}: {}", .{ package_id, err });
            return BuildError.DatabaseError;
        };
        defer check_stmt.finalize();

        check_stmt.bind(.{ .package_id = package_id }) catch |err| {
            log.err("Failed to bind package_id {d} for existence check: {}", .{ package_id, err });
            return BuildError.DatabaseError;
        };

        const package_exists = if (check_stmt.step() catch null) |result| result.count > 0 else false;
        if (!package_exists) {
            log.err("Package {d} does not exist, cannot mark build as pending", .{package_id});
            return BuildError.DatabaseError;
        }

        // Create string storage to ensure strings remain valid for SQLite operation lifetime
        var db_strings = DbStringStorage.init(self.allocator);
        defer db_strings.deinit();

        // Store zig_version string that will remain valid for the entire database operation
        const zig_version_stored = db_strings.store(zig_version) catch |err| {
            log.err("Failed to store zig_version string: {}", .{err});
            return BuildError.AllocationError;
        };

        // Use prepared statement for better memory safety
        const InsertParams = struct {
            package_id: i64,
            zig_version: sqlite.Text,
            build_status: sqlite.Text,
        };

        const query = "INSERT OR REPLACE INTO build_results (package_id, zig_version, build_status) VALUES (:package_id, :zig_version, :build_status)";

        var stmt = self.db.prepare(InsertParams, void, query) catch |err| {
            log.err("Failed to prepare pending build insert statement for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
            return BuildError.DatabaseError;
        };
        defer stmt.finalize();

        stmt.bind(.{
            .package_id = package_id,
            .zig_version = sqlite.text(zig_version_stored),
            .build_status = sqlite.text("pending"),
        }) catch |err| {
            log.err("Failed to bind parameters for pending build insert for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
            return BuildError.DatabaseError;
        };

        _ = stmt.step() catch |err| {
            log.err("Database error when marking build as pending for package {d} with Zig {s}: {}", .{ package_id, zig_version, err });
            log.err("SQL query: {s}", .{query});
            log.err("Parameters: package_id={d}, zig_version={s}, status=pending", .{ package_id, zig_version_stored });
            return BuildError.DatabaseError;
        };

        log.info("Marked build as pending for package {d} with Zig {s}", .{ package_id, zig_version });
    }

    /// Get build results for a package using main allocator for better memory management
    pub fn getBuildResults(self: *Self, package_id: i64) BuildError![]BuildResult {
        log.debug("Getting build results for package {d}", .{package_id});

        // Lock database mutex for thread safety
        self.db_mutex.lock();
        defer self.db_mutex.unlock();

        // Prepare query to get build results for the package
        const BuildResultRow = struct {
            build_id: sqlite.Text,
            package_name: sqlite.Text,
            repo_url: sqlite.Text,
            zig_version: sqlite.Text,
            start_time: sqlite.Text,
            build_status: sqlite.Text,
            test_status: ?sqlite.Text,
            error_log: sqlite.Text,
            build_log: sqlite.Text,
            end_time: ?sqlite.Text,
        };

        const query =
            \\SELECT 
            \\    CAST(br.package_id AS TEXT) || '-' || br.zig_version || '-' || strftime('%s', br.last_checked) as build_id,
            \\    p.name as package_name,
            \\    p.url as repo_url,
            \\    br.zig_version,
            \\    br.last_checked as start_time,
            \\    br.build_status,
            \\    br.test_status,
            \\    COALESCE(br.error_log, '') as error_log,
            \\    '' as build_log,
            \\    br.last_checked as end_time
            \\FROM build_results br
            \\JOIN packages p ON br.package_id = p.id
            \\WHERE br.package_id = ?
            \\ORDER BY br.last_checked DESC
        ;

        var stmt = self.db.prepare(struct { package_id: i64 }, BuildResultRow, query) catch |err| {
            log.err("Failed to prepare SQL statement for getting build results for package {d}: {}", .{ package_id, err });
            log.err("SQL query: {s}", .{query});
            return BuildError.DatabaseError;
        };
        defer stmt.finalize();

        stmt.bind(.{ .package_id = package_id }) catch |err| {
            log.err("Failed to bind package_id {d} to SQL statement: {}", .{ package_id, err });
            return BuildError.DatabaseError;
        };

        // Collect results into an array using main allocator
        var results = std.ArrayList(BuildResult).init(self.allocator);
        defer {
            // Cleanup results if we fail to convert to owned slice
            for (results.items) |*result| {
                result.deinit(self.allocator);
            }
            results.deinit();
        }

        var row_count: usize = 0;
        while (stmt.step() catch |err| {
            log.err("Failed to step through SQL results for package {d} at row {d}: {}", .{ package_id, row_count, err });
            return BuildError.DatabaseError;
        }) |row| {
            row_count += 1;
            log.debug("Processing build result row {d} for package {d}", .{ row_count, package_id });

            const result = BuildResult{
                .build_id = self.allocator.dupe(u8, row.build_id.data) catch |err| {
                    log.err("Failed to allocate memory for build_id (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                },
                .package_name = self.allocator.dupe(u8, row.package_name.data) catch |err| {
                    log.err("Failed to allocate memory for package_name (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                },
                .repo_url = self.allocator.dupe(u8, row.repo_url.data) catch |err| {
                    log.err("Failed to allocate memory for repo_url (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                },
                .zig_version = self.allocator.dupe(u8, row.zig_version.data) catch |err| {
                    log.err("Failed to allocate memory for zig_version (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                },
                .start_time = self.allocator.dupe(u8, row.start_time.data) catch |err| {
                    log.err("Failed to allocate memory for start_time (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                },
                .build_status = self.allocator.dupe(u8, row.build_status.data) catch |err| {
                    log.err("Failed to allocate memory for build_status (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                },
                .test_status = if (row.test_status) |ts| self.allocator.dupe(u8, ts.data) catch |err| {
                    log.err("Failed to allocate memory for test_status (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                } else null,
                .error_log = self.allocator.dupe(u8, row.error_log.data) catch |err| {
                    log.err("Failed to allocate memory for error_log (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                },
                .build_log = self.allocator.dupe(u8, row.build_log.data) catch |err| {
                    log.err("Failed to allocate memory for build_log (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                },
                .end_time = if (row.end_time) |et| self.allocator.dupe(u8, et.data) catch |err| {
                    log.err("Failed to allocate memory for end_time (row {d}, package {d}): {}", .{ row_count, package_id, err });
                    return BuildError.AllocationError;
                } else null,
            };

            results.append(result) catch |err| {
                log.err("Failed to append BuildResult to results array (row {d}, package {d}): {}", .{ row_count, package_id, err });
                result.deinit(self.allocator);
                return BuildError.AllocationError;
            };
        }

        log.info("Retrieved {d} build results for package {d}", .{ row_count, package_id });

        // Convert to owned slice and clear the cleanup defer
        const owned_results = results.toOwnedSlice() catch |err| {
            log.err("Failed to convert results array to owned slice for package {d}: {}", .{ package_id, err });
            return BuildError.AllocationError;
        };

        // Clear the defer so it doesn't clean up the successfully transferred data
        results = std.ArrayList(BuildResult).init(self.allocator);

        return owned_results;
    }

    /// Cleanup old build containers and files using main allocator for better memory management
    pub fn cleanup(self: *Self) BuildError!void {
        log.info("Starting cleanup of old build containers and files", .{});

        // Remove any stopped build containers
        const cleanup_result = std.process.Child.run(.{
            .allocator = self.allocator, // Use main allocator for process execution
            .argv = &[_][]const u8{ "docker", "container", "prune", "-f", "--filter", "label=zig-pkg-checker" },
            .max_output_bytes = 10 * 1024 * 1024, // 10MB buffer should be enough for prune output
        }) catch |err| {
            log.err("Failed to execute docker container prune command: {}", .{err});
            log.warn("Failed to cleanup Docker containers", .{});
            return;
        };
        defer self.allocator.free(cleanup_result.stdout);
        defer self.allocator.free(cleanup_result.stderr);

        if (cleanup_result.term != .Exited or cleanup_result.term.Exited != 0) {
            log.warn("Docker container prune completed with warnings - exit code: {}, stderr: {s}", .{ cleanup_result.term, cleanup_result.stderr });
        } else {
            log.info("Docker container cleanup completed successfully", .{});
            if (cleanup_result.stdout.len > 0) {
                log.debug("Docker prune stdout: {s}", .{cleanup_result.stdout});
            }
        }

        // Clean up old result files from the dedicated results directory
        const results_dir = "/tmp/zig_pkg_checker_results";
        var results_dir_handle = std.fs.cwd().openDir(results_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                log.debug("Results directory {s} does not exist, skipping cleanup", .{results_dir});
            } else {
                log.err("Failed to open results directory {s} for cleanup: {}", .{ results_dir, err });
            }
            return;
        };
        defer results_dir_handle.close();

        var results_iterator = results_dir_handle.iterate();
        var deleted_count: usize = 0;
        while (results_iterator.next() catch |err| {
            log.err("Failed to iterate through results directory {s} at {s}:{}: {}", .{ results_dir, @src().file, @src().line, err });
            return;
        }) |entry| {
            if (std.mem.startsWith(u8, entry.name, "build_result_") and std.mem.endsWith(u8, entry.name, ".json")) {
                results_dir_handle.deleteFile(entry.name) catch |err| {
                    log.warn("Failed to delete result file {s}: {}", .{ entry.name, err });
                    continue;
                };
                deleted_count += 1;
                log.debug("Deleted old result file: {s}", .{entry.name});
            }
        }

        // Also clean up any old individual result files in /tmp (legacy cleanup)
        var tmp_dir = std.fs.cwd().openDir("/tmp", .{ .iterate = true }) catch |err| {
            log.err("Failed to open /tmp directory for legacy cleanup: {}", .{err});
            return;
        };
        defer tmp_dir.close();

        var tmp_iterator = tmp_dir.iterate();
        while (tmp_iterator.next() catch |err| {
            log.err("Failed to iterate through /tmp directory at {s}:{}: {}", .{ @src().file, @src().line, err });
            return;
        }) |entry| {
            if (std.mem.startsWith(u8, entry.name, "build_result_") and std.mem.endsWith(u8, entry.name, ".json")) {
                tmp_dir.deleteFile(entry.name) catch |err| {
                    log.warn("Failed to delete legacy result file {s}: {}", .{ entry.name, err });
                    continue;
                };
                deleted_count += 1;
                log.debug("Deleted old legacy result file: {s}", .{entry.name});
            }
        }

        log.info("Cleanup completed: deleted {d} old result files", .{deleted_count});
    }
};
