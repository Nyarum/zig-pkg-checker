//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;
const sqlite = @import("sqlite");

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// Database models and functions for the Zig Package Checker
pub const db = struct {
    pub const Package = struct {
        id: i64,
        name: sqlite.Text,
        url: sqlite.Text,
        description: ?sqlite.Text,
        author: ?sqlite.Text,
        license: ?sqlite.Text,
        source_type: sqlite.Text,
        created_at: sqlite.Text,
        last_updated: sqlite.Text,
        popularity_score: i32,
    };

    pub const BuildResult = struct {
        id: i64,
        package_id: i64,
        zig_version: sqlite.Text,
        build_status: sqlite.Text, // 'success', 'failed', 'pending'
        test_status: ?sqlite.Text,
        error_log: ?sqlite.Text,
        last_checked: sqlite.Text,
    };

    pub const Issue = struct {
        id: i64,
        package_id: i64,
        zig_version: sqlite.Text,
        issue_url: ?sqlite.Text,
        issue_status: sqlite.Text, // 'open', 'closed', 'resolved'
        auto_created: i32, // boolean as integer
        resolved_at: ?sqlite.Text,
        created_at: sqlite.Text,
    };

    pub fn initDatabase(db_conn: *sqlite.Database) !void {
        // Create packages table
        try db_conn.exec(
            \\CREATE TABLE IF NOT EXISTS packages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    name TEXT NOT NULL UNIQUE,
            \\    url TEXT NOT NULL,
            \\    description TEXT,
            \\    author TEXT,
            \\    license TEXT,
            \\    source_type TEXT NOT NULL DEFAULT 'github',
            \\    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            \\    last_updated TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            \\    popularity_score INTEGER DEFAULT 0
            \\)
        , .{});

        // Create build_results table
        try db_conn.exec(
            \\CREATE TABLE IF NOT EXISTS build_results (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    package_id INTEGER NOT NULL,
            \\    zig_version TEXT NOT NULL,
            \\    build_status TEXT NOT NULL DEFAULT 'pending',
            \\    test_status TEXT,
            \\    error_log TEXT,
            \\    last_checked TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (package_id) REFERENCES packages (id),
            \\    UNIQUE(package_id, zig_version)
            \\)
        , .{});

        // Create issues table
        try db_conn.exec(
            \\CREATE TABLE IF NOT EXISTS issues (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    package_id INTEGER NOT NULL,
            \\    zig_version TEXT NOT NULL,
            \\    issue_url TEXT,
            \\    issue_status TEXT NOT NULL DEFAULT 'open',
            \\    auto_created INTEGER DEFAULT 0,
            \\    resolved_at TEXT,
            \\    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (package_id) REFERENCES packages (id)
            \\)
        , .{});

        // Create indexes for better performance
        try db_conn.exec("CREATE INDEX IF NOT EXISTS idx_packages_name ON packages(name)", .{});
        try db_conn.exec("CREATE INDEX IF NOT EXISTS idx_build_results_package_version ON build_results(package_id, zig_version)", .{});
        try db_conn.exec("CREATE INDEX IF NOT EXISTS idx_issues_package ON issues(package_id)", .{});
    }
};

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}

test "database models" {
    var db_conn = try sqlite.Database.open(.{});
    defer db_conn.close();

    try db.initDatabase(&db_conn);

    // Test inserting a package
    try db_conn.exec("INSERT INTO packages (name, url, description, author) VALUES (:name, :url, :description, :author)", .{
        .name = sqlite.text("test-package"),
        .url = sqlite.text("https://github.com/user/test-package"),
        .description = sqlite.text("A test package"),
        .author = sqlite.text("testuser"),
    });
}
