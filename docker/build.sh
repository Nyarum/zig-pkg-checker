#!/bin/bash

set -e

# Install jq if not available (for JSON processing)
if ! command -v jq &> /dev/null; then
    echo "Installing jq for JSON processing..."
    apt-get update && apt-get install -y jq
fi

# Get environment variables
REPO_URL="${REPO_URL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
BUILD_ID="${BUILD_ID:-}"
RESULT_FILE="${RESULT_FILE:-/tmp/build_result.json}"

if [ -z "$REPO_URL" ]; then
    echo "Error: REPO_URL environment variable is required"
    exit 1
fi

# Initialize result object
ZIG_VERSION=$(zig version)
START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Build started for $PACKAGE_NAME (ID: $BUILD_ID)"
echo "Zig version: $ZIG_VERSION"
echo "Repository: $REPO_URL"

# Create result JSON structure
cat > "$RESULT_FILE" << EOF
{
  "build_id": "$BUILD_ID",
  "package_name": "$PACKAGE_NAME",
  "repo_url": "$REPO_URL",
  "zig_version": "$ZIG_VERSION",
  "start_time": "$START_TIME",
  "build_status": "failed",
  "test_status": null,
  "error_log": "",
  "build_log": "",
  "end_time": null
}
EOF

# Function to update result file
update_result() {
    local status="$1"
    local test_status="$2"
    local error_log="$3"
    local build_log="$4"
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat > "$RESULT_FILE" << EOF
{
  "build_id": "$BUILD_ID",
  "package_name": "$PACKAGE_NAME",
  "repo_url": "$REPO_URL",
  "zig_version": "$ZIG_VERSION",
  "start_time": "$START_TIME",
  "build_status": "$status",
  "test_status": $test_status,
  "error_log": $(echo "$error_log" | jq -R -s .),
  "build_log": $(echo "$build_log" | jq -R -s .),
  "end_time": "$end_time"
}
EOF
}

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    cd /
    rm -rf /workspace/*
}

trap cleanup EXIT

BUILD_LOG=""
ERROR_LOG=""

try_build() {
    echo "Cloning repository..."
    
    # Clone the repository with timeout
    timeout 300s git clone --depth 1 "$REPO_URL" package 2>&1 | tee -a clone.log || {
        ERROR_LOG="Failed to clone repository: $(cat clone.log)"
        update_result "failed" "null" "$ERROR_LOG" "$BUILD_LOG"
        echo "Clone failed"
        return 1
    }
    
    cd package
    
    # Check if build.zig exists
    if [ ! -f "build.zig" ]; then
        ERROR_LOG="No build.zig file found in repository"
        update_result "failed" "null" "$ERROR_LOG" "$BUILD_LOG"
        echo "No build.zig found"
        return 1
    fi
    
    echo "Running zig build..."
    
    # Try to build with timeout - capture exit code separately
    BUILD_EXIT_CODE=0
    timeout 600s zig build 2>&1 | tee build.log || BUILD_EXIT_CODE=$?
    
    BUILD_LOG=$(cat build.log)
    
    # Enhanced error detection: Check both exit code and build log content
    BUILD_FAILED=false
    
    # Check exit code first
    if [ $BUILD_EXIT_CODE -ne 0 ]; then
        BUILD_FAILED=true
        echo "Build failed with exit code: $BUILD_EXIT_CODE"
    fi
    
    # Check for various error patterns in build log, even if exit code was 0
    if grep -q "error:" build.log; then
        BUILD_FAILED=true
        echo "Found 'error:' in build log"
    fi
    
    if grep -q "Build Summary:.*failed" build.log; then
        BUILD_FAILED=true
        echo "Found build failures in Build Summary"
    fi
    
    if grep -q "the following build command failed with exit code" build.log; then
        BUILD_FAILED=true
        echo "Found build command failure in log"
    fi
    
    if grep -q "the following command terminated unexpectedly" build.log; then
        BUILD_FAILED=true
        echo "Found unexpected command termination in log"
    fi
    
    if grep -q "build.zig.zon:.*error:" build.log; then
        BUILD_FAILED=true
        echo "Found build.zig.zon syntax error"
    fi
    
    if grep -q "@compileError" build.log; then
        BUILD_FAILED=true
        echo "Found compile error directive"
    fi
    
    # Count the number of error occurrences - many errors usually indicate failure
    ERROR_COUNT=$(grep -c "error:" build.log 2>/dev/null || echo "0")
    if [ "$ERROR_COUNT" -ge 2 ]; then
        BUILD_FAILED=true
        echo "Found $ERROR_COUNT errors in build log"
    fi
    
    if [ "$BUILD_FAILED" = true ]; then
        ERROR_LOG="Build failed: $BUILD_LOG"
        update_result "failed" "null" "$ERROR_LOG" "$BUILD_LOG"
        echo "Build failed based on log analysis"
        return 1
    fi
    
    echo "Build successful!"
    
    # Try to run tests if they exist
    echo "Running tests..."
    TEST_STATUS="null"
    
    timeout 300s zig build test 2>&1 | tee test.log && {
        TEST_STATUS='"success"'
        echo "Tests passed!"
    } || {
        # Check if tests actually exist or if it's just no tests defined
        if grep -q "no tests to run" test.log; then
            TEST_STATUS='"no_tests"'
            echo "No tests found"
        else
            TEST_STATUS='"failed"'
            ERROR_LOG="Tests failed: $(cat test.log)"
            echo "Tests failed"
        fi
    }
    
    # Update with success
    update_result "success" "$TEST_STATUS" "$ERROR_LOG" "$BUILD_LOG"
    echo "Build completed successfully!"
    return 0
}

# Run the build
try_build

echo "Build process completed. Result saved to $RESULT_FILE"
cat "$RESULT_FILE" 