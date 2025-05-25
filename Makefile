.PHONY: build run test clean docker-build docker-clean setup

# Detect current platform for Docker builds
ARCH := $(shell uname -m)
ifeq ($(ARCH),arm64)
    PLATFORM := linux/arm64
else ifeq ($(ARCH),aarch64)
    PLATFORM := linux/arm64
else ifeq ($(ARCH),x86_64)
    PLATFORM := linux/amd64
else
    PLATFORM := linux/amd64
endif

# Default target
build:
	zig build

# Run the application
run: build
	./zig-out/bin/zig-pkg-checker

# Run tests
test:
	zig build test

# Clean build artifacts
clean:
	rm -rf zig-out .zig-cache

# Build all Docker images for different Zig versions
docker-build:
	@echo "Building Docker images for all Zig versions..."
	@echo "Detected platform: $(PLATFORM)"
	docker build --platform $(PLATFORM) -t zig-checker:master docker/zig-master/
	docker build --platform $(PLATFORM) -t zig-checker:0.14.0 docker/zig-0.14.0/
	docker build --platform $(PLATFORM) -t zig-checker:0.13.0 docker/zig-0.13.0/
	docker build --platform $(PLATFORM) -t zig-checker:0.12.0 docker/zig-0.12.0/
	@echo "All Docker images built successfully!"

# Build Docker images using docker-compose (alternative method)
docker-compose-build:
	docker-compose --profile build-only build

# Clean Docker images and containers
docker-clean:
	@echo "Cleaning up Docker images and containers..."
	-docker container prune -f --filter "label=zig-pkg-checker"
	-docker rmi zig-checker:master zig-checker:0.14.0 zig-checker:0.13.0 zig-checker:0.12.0
	-docker system prune -f
	@echo "Docker cleanup completed!"

# Setup development environment
setup: docker-build
	@echo "Setting up development environment..."
	@echo "Creating necessary directories..."
	mkdir -p /tmp/build_results
	@echo "Setup completed!"

# Full clean including Docker
clean-all: clean docker-clean

# Run the application with Docker build system ready
run-docker: setup run

# Display help
help:
	@echo "Available targets:"
	@echo "  build              - Build the Zig application"
	@echo "  run                - Run the application"
	@echo "  test               - Run tests"
	@echo "  clean              - Clean build artifacts"
	@echo "  docker-build       - Build all Docker images for Zig versions"
	@echo "  docker-compose-build - Build Docker images using docker-compose"
	@echo "  docker-clean       - Clean Docker images and containers"
	@echo "  setup              - Setup development environment with Docker"
	@echo "  run-docker         - Setup and run with Docker build system"
	@echo "  clean-all          - Clean everything including Docker"
	@echo "  help               - Show this help message"

install:
	mkdir -p libs
	git clone git@github.com:nDimensional/zig-sqlite.git libs/zig-sqlite
	cd libs/zig-sqlite && git checkout 098eee58cf62928aaf504af459855f0b8a5d5698
	git clone git@github.com:tardy-org/zzz.git libs/zzz
	cd libs/zzz && git checkout 18ec7f1129ce4d0573b7c67f011b4d05c7b195d4

dev:
	mkdir -p libs
	git clone -b 0.14.0 https://github.com/ziglang/zig.git libs/zig