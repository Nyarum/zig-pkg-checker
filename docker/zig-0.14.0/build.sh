#!/bin/bash

set -e

# Enable bash debug mode for more detailed script execution logging
set -x

# Install jq if not available (for JSON processing)
if ! command -v jq &> /dev/null; then
    echo "Installing jq for JSON processing..."
    apk add --no-cache jq
fi


# Debug: Show initial environment
echo "=== DEBUG: Initial Environment ==="
echo "PWD: $(pwd)"
echo "USER: $(whoami)"
echo "HOME: $HOME"
echo "PATH: $PATH"
echo "Architecture: $(uname -m)"
echo "OS: $(uname -a)"
echo "Available disk space:"
df -h
echo "Available memory:"
free -h 2>/dev/null || cat /proc/meminfo | head -5
echo "====================================="

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
    ls -la /workspace/ 2>/dev/null || echo "No workspace directory"
    echo "Cleaning up..."
    cd /
    rm -rf /workspace/*
}

trap cleanup EXIT

BUILD_LOG=""
ERROR_LOG=""

try_build() {
    ls -la
    
    echo "Cloning repository..."
    
    # Clone the repository with timeout
    echo "=== DEBUG: Starting git clone ==="
    timeout 300s git clone --depth 1 --verbose "$REPO_URL" package 2>&1 | tee -a clone.log || {
        ERROR_LOG="Failed to clone repository: $(cat clone.log)"
        update_result "failed" "null" "$ERROR_LOG" "$BUILD_LOG"
        echo "=== DEBUG: Clone failed ==="
        cat clone.log
        echo "========================="
        return 1
    }
    
    echo "=== DEBUG: Clone completed, examining repository ==="
    ls -la package/
    echo "====================================================="
    
    cd package
    
    # Check if build.zig exists
    if [ ! -f "build.zig" ]; then
        ERROR_LOG="No build.zig file found in repository"
        update_result "failed" "null" "$ERROR_LOG" "$BUILD_LOG"
        echo "=== DEBUG: No build.zig found ==="
        echo "Files in repository root:"
        ls -la
        echo "============================="
        return 1
    fi
    
    # Debug: Check for zig.zon file
    if [ -f "build.zig.zon" ]; then
        echo "=== DEBUG: Found build.zig.zon ==="
        echo "build.zig.zon content:"
        cat build.zig.zon
        echo "==========================="
    fi

    echo "Running zig build..."
    
    # Try building with retry mechanism to handle cache/network issues
    BUILD_ATTEMPTS=0
    MAX_ATTEMPTS=3
    BUILD_SUCCESS=false
    
    # First attempt
    echo "=== DEBUG: Build attempt 1/3 ==="
    timeout 600s zig build --summary all --verbose 2>&1 | tee build.log
    ZIG_EXIT_CODE=${PIPESTATUS[0]}
    
    if [ $ZIG_EXIT_CODE -eq 0 ]; then
        BUILD_SUCCESS=true
        echo "Build succeeded on first attempt"
    else
        echo "First build attempt failed with exit code: $ZIG_EXIT_CODE"
        
        # Check if this is a cache-related error and clear cache if needed
        if grep -q "failed to check cache" build.log || grep -q "file_hash FileNotFound" build.log; then
            echo "Cache error detected, clearing cache before retry..."
            rm -rf "$ZIG_GLOBAL_CACHE_DIR" || true
            rm -rf zig-cache || true
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" || true
        fi
        
        # Second attempt
        echo "=== DEBUG: Build attempt 2/3 ==="
        timeout 600s zig build --summary all --verbose 2>&1 | tee build.log
        ZIG_EXIT_CODE=${PIPESTATUS[0]}
        
        if [ $ZIG_EXIT_CODE -eq 0 ]; then
            BUILD_SUCCESS=true
            echo "Build succeeded on second attempt"
        else
            echo "Second build attempt failed with exit code: $ZIG_EXIT_CODE"
            
            # If still failing with cache errors, try one more time with cache cleared
            if grep -q "failed to check cache" build.log || grep -q "file_hash FileNotFound" build.log; then
                echo "Cache error detected again, clearing cache completely..."
                rm -rf "$ZIG_GLOBAL_CACHE_DIR" || true
                rm -rf zig-cache || true
                mkdir -p "$ZIG_GLOBAL_CACHE_DIR" || true
            fi
            
            # Third attempt
            echo "=== DEBUG: Build attempt 3/3 ==="
            timeout 600s zig build --summary all --verbose 2>&1 | tee build.log
            ZIG_EXIT_CODE=${PIPESTATUS[0]}
            
            if [ $ZIG_EXIT_CODE -eq 0 ]; then
                BUILD_SUCCESS=true
                echo "Build succeeded on third attempt"
            else
                BUILD_EXIT_CODE=$ZIG_EXIT_CODE
                echo "All build attempts failed"
            fi
        fi
    fi

    echo $BUILD_SUCCESS
    
    if [ "$BUILD_SUCCESS" = false ]; then
        BUILD_EXIT_CODE=1
        BUILD_LOG=$(cat build.log 2>/dev/null || echo "No build log available")
    else
        BUILD_EXIT_CODE=0
        BUILD_LOG=$(cat build.log 2>/dev/null || echo "Build successful")
    fi

    
    # Enhanced error detection: Check both exit code and build log content
    BUILD_FAILED=false
    
    # Check exit code first
    if [ $BUILD_EXIT_CODE -ne 0 ]; then
        BUILD_FAILED=true
        echo "Build failed with exit code: $BUILD_EXIT_CODE"
    fi
    
    # Check for various error patterns in build log, even if exit code was 0
    # But exclude cache-related errors that can be retried
    if grep -q "error:" build.log && ! grep -q "failed to check cache" build.log; then
        BUILD_FAILED=true
        echo "Found 'error:' in build log"
    elif grep -q "failed to check cache" build.log; then
        echo "Found cache error - this can be retried"
        BUILD_FAILED=true
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
    
    # Debug: Pre-test state
    echo "=== DEBUG: Pre-test State ==="
    echo "Checking for test targets:"
    timeout 30s zig build --help 2>&1 | grep -i test || echo "No test-related targets found"
    echo "========================"
    
    # Try to run tests if they exist
    echo "Running tests..."
    TEST_STATUS="null"
    
    echo "=== DEBUG: Starting zig build test ==="
    timeout 300s zig build test --summary all --verbose 2>&1 | tee test.log && {
        TEST_STATUS='"success"'
        echo "Tests passed!"
    } || {
        # Debug: Analyze test failure
        echo "=== DEBUG: Test Log Analysis ==="
        echo "Test log content:"
        cat test.log
        echo "=========================="
        
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

echo "=== DEBUG: Final Result ==="
echo "Build process completed. Result saved to $RESULT_FILE"
cat "$RESULT_FILE" 
echo "=========================" 