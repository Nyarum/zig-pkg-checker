# Zig Package Checker

A comprehensive build system and compatibility checker for Zig packages across multiple Zig versions. This system automatically fetches packages from URLs, builds them with different Zig versions using Docker containers, and provides detailed compatibility reports.

## Features

- 🐳 **Docker-based builds** - Isolated build environments for each Zig version
- 🔄 **Multi-version testing** - Automatic testing across Zig master, 0.14.0, 0.13.0, and 0.12.0
- 📊 **Build result tracking** - Detailed success/failure reports with error logs
- 🌐 **Web interface** - Submit packages and view results through a web UI
- 🚀 **REST API** - Programmatic access to submit packages and query results
- 📦 **Package management** - Track package metadata, authors, and licenses

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/) (latest version)
- [Docker](https://www.docker.com/) (for build system)
- Git

### Setup

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd zig-pkg-checker
   ```

2. **Build Docker images for all Zig versions:**
   ```bash
   make docker-build
   ```

3. **Build and run the application:**
   ```bash
   make run-docker
   ```

The server will start on `http://localhost:3000`

## Architecture

### Build System Flow

1. **Package Submission** - User submits a package via web UI or API
2. **Database Storage** - Package metadata is stored in SQLite database
3. **Build Initiation** - Build jobs are started for all Zig versions simultaneously
4. **Docker Execution** - Each Zig version runs in its own Docker container
5. **Result Collection** - Build results are collected and stored in database
6. **Result Display** - Results are displayed in web UI with compatibility matrix

### Docker Containers

Each Zig version has its own Docker container:

- `zig-checker:master` - Latest Zig development version
- `zig-checker:0.14.0` - Zig 0.14.0 stable
- `zig-checker:0.13.0` - Zig 0.13.0
- `zig-checker:0.12.0` - Zig 0.12.0

### Build Process

For each package and Zig version combination:

1. **Clone** - Package repository is cloned into container
2. **Build** - `zig build` is executed with timeout
3. **Test** - `zig build test` is executed if tests exist
4. **Result** - Build status, test status, and logs are captured
5. **Cleanup** - Container and temporary files are cleaned up

## API Endpoints

### Submit Package
```http
POST /api/packages
Content-Type: application/json

{
  "name": "my-package",
  "url": "https://github.com/user/repo",
  "description": "A sample Zig package",
  "author": "author-name",
  "license": "MIT"
}
```

### List Packages
```http
GET /api/packages
```

Returns packages with build results:
```json
{
  "packages": [
    {
      "id": 1,
      "name": "my-package",
      "url": "https://github.com/user/repo",
      "description": "A sample Zig package",
      "author": "author-name",
      "license": "MIT",
      "created_at": "2024-01-01T00:00:00Z",
      "last_updated": "2024-01-01T00:00:00Z",
      "popularity_score": 0,
      "build_results": [
        {
          "zig_version": "master",
          "build_status": "success",
          "test_status": "success",
          "last_checked": "2024-01-01T00:00:00Z"
        },
        {
          "zig_version": "0.14.0",
          "build_status": "failed",
          "test_status": null,
          "last_checked": "2024-01-01T00:00:00Z"
        }
      ]
    }
  ],
  "total": 1,
  "page": 1,
  "limit": 20
}
```

### Health Check
```http
GET /api/health
```

## Web Interface

Visit `http://localhost:3000` to access the web interface:

- **Home** (`/`) - Overview and statistics
- **Packages** (`/packages`) - Browse submitted packages and their build status
- **Submit** (`/submit`) - Submit a new package for testing
- **Stats** (`/stats`) - Compatibility statistics and trends
- **API Docs** (`/api`) - API documentation

## Development

### Commands

```bash
# Build the application
make build

# Run tests
make test

# Build Docker images
make docker-build

# Clean up
make clean

# Clean Docker artifacts
make docker-clean

# Full cleanup
make clean-all

# Show help
make help
```

### Database Schema

The application uses SQLite with the following tables:

- **packages** - Package metadata (name, URL, description, author, etc.)
- **build_results** - Build results for each package/Zig version combination
- **issues** - Tracked issues and compatibility problems

### Build System Configuration

Build system settings can be configured in `src/build_system.zig`:

- Container resource limits (memory, CPU)
- Build timeouts
- Supported Zig versions
- Docker image names

## Security

- Build containers run with no network access during builds
- Resource limits prevent runaway builds
- Temporary files are automatically cleaned up
- No persistent storage in build containers

## Troubleshooting

### Docker Issues
```bash
# Check Docker is running
docker --version

# Rebuild images if corrupted
make docker-clean
make docker-build

# Check container logs
docker logs <container-name>
```

### Build Failures
- Check package has valid `build.zig` file
- Ensure repository is publicly accessible
- Review error logs in web interface
- Check Docker container resource limits

### Database Issues
- Database file is created automatically in project root
- Delete `zig_pkg_checker.db` to reset database
- Check file permissions for SQLite database

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

[Add your license here] 