#!/bin/bash
# test_privileged.sh - Test the container discovery script with privileged access
# This script should be run as root or with sudo

echo "=========================================="
echo "Container Discovery Script - Privileged Test"
echo "=========================================="
echo ""

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This test should be run as root or with sudo"
    echo "Usage: sudo ./test_privileged.sh"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY_SCRIPT="$SCRIPT_DIR/GuestDetails_Container.sh"

# Check if discovery script exists
if [ ! -f "$DISCOVERY_SCRIPT" ]; then
    echo "ERROR: Discovery script not found at $DISCOVERY_SCRIPT"
    exit 1
fi

echo "Running discovery script as $(whoami) (UID: $(id -u))..."
echo ""

# Run the discovery script
sh "$DISCOVERY_SCRIPT"
exit_code=$?

echo ""
echo "=========================================="
echo "Test Results"
echo "=========================================="
echo "Exit code: $exit_code"

# Check if output files were created
if [ -f "$SCRIPT_DIR/output.json" ]; then
    echo "✓ output.json created"
    file_size=$(stat -f%z "$SCRIPT_DIR/output.json" 2>/dev/null || stat -c%s "$SCRIPT_DIR/output.json")
    echo "  File size: $file_size bytes"
else
    echo "✗ output.json NOT created"
fi

if [ -f "$SCRIPT_DIR/error.txt" ]; then
    echo "✓ error.txt created"
    error_count=$(wc -l < "$SCRIPT_DIR/error.txt")
    echo "  Error count: $error_count"
    if [ "$error_count" -gt 0 ]; then
        echo "  Errors:"
        cat "$SCRIPT_DIR/error.txt"
    fi
else
    echo "✗ error.txt NOT created"
fi

if [ -f "$SCRIPT_DIR/debug.txt" ]; then
    echo "✓ debug.txt created"
    debug_lines=$(wc -l < "$SCRIPT_DIR/debug.txt")
    echo "  Debug lines: $debug_lines"
else
    echo "✗ debug.txt NOT created"
fi

echo ""
echo "=========================================="
echo "JSON Validation"
echo "=========================================="

# Validate JSON if jq is available
if command -v jq >/dev/null 2>&1; then
    echo "Validating JSON with jq..."
    if jq . "$SCRIPT_DIR/output.json" > /dev/null 2>&1; then
        echo "✓ JSON is valid"

        # Extract key information
        schema_version=$(jq -r '.armResources[0].properties.schema_version' "$SCRIPT_DIR/output.json" 2>/dev/null)
        runtime_count=$(jq '.armResources[0].properties.container_runtimes | length' "$SCRIPT_DIR/output.json" 2>/dev/null)
        orch_count=$(jq '.armResources[0].properties.orchestrators | length' "$SCRIPT_DIR/output.json" 2>/dev/null)

        echo "  Schema version: $schema_version"
        echo "  Runtimes detected: $runtime_count"
        echo "  Orchestrators detected: $orch_count"

        # Show runtime names
        if [ "$runtime_count" -gt 0 ]; then
            echo "  Runtime names:"
            jq -r '.armResources[0].properties.container_runtimes[].name' "$SCRIPT_DIR/output.json" 2>/dev/null | sed 's/^/    - /'
        fi

        # Show orchestrator names
        if [ "$orch_count" -gt 0 ]; then
            echo "  Orchestrator names:"
            jq -r '.armResources[0].properties.orchestrators[].name' "$SCRIPT_DIR/output.json" 2>/dev/null | sed 's/^/    - /'
        fi
    else
        echo "✗ JSON is INVALID"
        echo "First error:"
        jq . "$SCRIPT_DIR/output.json" 2>&1 | head -n 5
    fi
else
    echo "jq not available, skipping JSON validation"
    echo "Checking if file is valid JSON with basic parsing..."
    if python3 -c "import json; json.load(open('$SCRIPT_DIR/output.json'))" 2>/dev/null; then
        echo "✓ JSON appears to be valid (python check)"
    elif python -c "import json; json.load(open('$SCRIPT_DIR/output.json'))" 2>/dev/null; then
        echo "✓ JSON appears to be valid (python check)"
    else
        echo "✗ JSON validation failed"
    fi
fi

echo ""
echo "=========================================="
echo "Test completed"
echo "=========================================="

exit $exit_code
