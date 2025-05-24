#!/bin/bash

# Test script for package submission
set -e

SERVER_URL="http://localhost:3000"

echo "Testing Zig Package Checker Build System"
echo "=========================================="

# Check if server is running
echo "1. Checking if server is running..."
if curl -s "${SERVER_URL}/api/health" > /dev/null; then
    echo "✅ Server is running"
else
    echo "❌ Server is not running. Please start with 'make run-docker'"
    exit 1
fi

# Submit a test package
echo ""
echo "2. Submitting test package..."
RESPONSE=$(curl -s -X POST "${SERVER_URL}/api/packages" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "zig-test-package",
        "url": "https://github.com/ziglang/zig",
        "description": "Test package for build system verification",
        "author": "test-user",
        "license": "MIT"
    }')

echo "Response: $RESPONSE"

if echo "$RESPONSE" | grep -q "Package submitted successfully"; then
    echo "✅ Package submitted successfully"
else
    echo "❌ Package submission failed"
    exit 1
fi

# Wait a moment for builds to start
echo ""
echo "3. Waiting for builds to start..."
sleep 5

# Check package list
echo ""
echo "4. Checking package list..."
PACKAGES=$(curl -s "${SERVER_URL}/api/packages")
echo "Packages response:"
echo "$PACKAGES" | python3 -m json.tool 2>/dev/null || echo "$PACKAGES"

echo ""
echo "5. Build system test completed!"
echo ""
echo "You can monitor build progress by:"
echo "- Visiting ${SERVER_URL}/packages in your browser"
echo "- Checking Docker containers: docker ps"
echo "- Viewing logs: docker logs <container-name>"
echo ""
echo "Note: Builds may take several minutes to complete." 