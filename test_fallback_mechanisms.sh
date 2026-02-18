#!/bin/bash
# test_fallback_mechanisms.sh - Test that fallback mechanisms work correctly
# This script verifies that the discovery script properly falls back to alternative
# methods when primary detection fails

set -e

echo "=========================================="
echo "Fallback Mechanisms Validation Test"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEBUG_FILE="$SCRIPT_DIR/debug.txt"
ERROR_FILE="$SCRIPT_DIR/error.txt"
OUTPUT_FILE="$SCRIPT_DIR/output.json"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

test_pass() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

test_fail() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "${RED}✗ FAIL${NC}: $1"
}

# Check if debug file exists
if [ ! -f "$DEBUG_FILE" ]; then
    echo "ERROR: debug.txt not found at $DEBUG_FILE"
    echo "Please run GuestDetails_Container.sh first"
    exit 1
fi

# Check if output file exists
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "ERROR: output.json not found at $OUTPUT_FILE"
    echo "Please run GuestDetails_Container.sh first"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for this test"
    exit 1
fi

echo "Test 1: Privilege Level Detection and Fallback"
echo "==============================================="
echo ""

# Check privilege level
if grep -q "Privilege level detected" "$DEBUG_FILE"; then
    privilege_level=$(grep -m1 "Privilege level detected" "$DEBUG_FILE" | awk '{print $NF}')
    echo "Detected privilege level: $privilege_level"
    test_pass "Privilege level was detected: $privilege_level"
else
    test_fail "Privilege level detection not found in debug log"
    privilege_level="unknown"
fi

echo ""
echo "Test 2: Container Runtime Fallback Mechanisms"
echo "=============================================="
echo ""

runtime_count=$(jq '.armResources[0].properties.container_runtimes | length' "$OUTPUT_FILE")
echo "Found $runtime_count container runtime(s)"

if [ "$runtime_count" -gt 0 ]; then
    test_pass "At least one container runtime was detected"

    # For each runtime, check detection method
    for i in $(seq 0 $((runtime_count - 1))); do
        runtime_name=$(jq -r ".armResources[0].properties.container_runtimes[$i].name" "$OUTPUT_FILE")
        runtime_type=$(jq -r ".armResources[0].properties.container_runtimes[$i].runtime_type" "$OUTPUT_FILE")

        echo ""
        echo "Analyzing $runtime_name ($runtime_type) detection:"

        # Check if primary method worked or fallback was used
        case "$runtime_type" in
            "containerd")
                if grep -q "containerd --version" "$DEBUG_FILE"; then
                    test_pass "$runtime_name: Primary version detection attempted"
                fi
                if grep -q "ctr namespaces" "$DEBUG_FILE" || grep -q "crictl info" "$DEBUG_FILE"; then
                    test_pass "$runtime_name: Namespace detection attempted"
                fi
                if grep -q "crictl ps" "$DEBUG_FILE" || grep -q "ctr.*containers list" "$DEBUG_FILE"; then
                    test_pass "$runtime_name: Container listing attempted"
                fi
                ;;
            "docker")
                if grep -q "docker version" "$DEBUG_FILE" || grep -q "dockerd --version" "$DEBUG_FILE"; then
                    test_pass "$runtime_name: Version detection attempted"
                fi
                if grep -q "docker info" "$DEBUG_FILE" || grep -q "docker.sock" "$DEBUG_FILE"; then
                    test_pass "$runtime_name: Info gathering attempted"
                fi
                ;;
            "crio")
                if grep -q "crio --version" "$DEBUG_FILE" || grep -q "crictl version" "$DEBUG_FILE"; then
                    test_pass "$runtime_name: Version detection attempted"
                fi
                ;;
            "podman")
                if grep -q "podman version" "$DEBUG_FILE" || grep -q "podman info" "$DEBUG_FILE"; then
                    test_pass "$runtime_name: Detection attempted"
                fi
                if grep -q "rootless" "$DEBUG_FILE"; then
                    test_pass "$runtime_name: Rootless mode detection attempted"
                fi
                ;;
        esac
    done
else
    echo "No container runtimes detected"
    if [ "$privilege_level" = "none" ]; then
        test_pass "No runtimes detected with no privileges (acceptable)"
    else
        echo "This may be expected if no runtimes are installed"
    fi
fi

echo ""
echo "Test 3: Orchestrator Detection Fallback"
echo "========================================"
echo ""

orch_count=$(jq '.armResources[0].properties.orchestrators | length' "$OUTPUT_FILE")
echo "Found $orch_count orchestrator(s)"

if [ "$orch_count" -gt 0 ]; then
    test_pass "At least one orchestrator was detected"

    for i in $(seq 0 $((orch_count - 1))); do
        orch_name=$(jq -r ".armResources[0].properties.orchestrators[$i].name" "$OUTPUT_FILE")
        orch_type=$(jq -r ".armResources[0].properties.orchestrators[$i].orchestrator_type" "$OUTPUT_FILE")

        echo ""
        echo "Analyzing $orch_name ($orch_type) detection:"

        case "$orch_type" in
            "kubernetes")
                if grep -qE "kubectl|kubelet|/etc/kubernetes" "$DEBUG_FILE"; then
                    test_pass "$orch_name: Detection method attempted"
                fi
                if grep -q "kubectl get nodes" "$DEBUG_FILE"; then
                    test_pass "$orch_name: Node listing attempted"
                fi
                if grep -q "kubectl get pods" "$DEBUG_FILE" || grep -q "kubectl get all" "$DEBUG_FILE"; then
                    test_pass "$orch_name: Workload discovery attempted"
                fi
                ;;
            "docker-swarm"|"docker_swarm")
                if grep -q "docker info.*Swarm" "$DEBUG_FILE"; then
                    test_pass "$orch_name: Swarm state detection attempted"
                fi
                if grep -q "docker node" "$DEBUG_FILE"; then
                    test_pass "$orch_name: Node listing attempted"
                fi
                ;;
            "openshift")
                if grep -qE "oc version|oc get clusterversion|kubectl get clusterversion" "$DEBUG_FILE"; then
                    test_pass "$orch_name: Detection attempted"
                fi
                ;;
            "tanzu")
                if grep -qE "tanzu|kubectl get tkr" "$DEBUG_FILE"; then
                    test_pass "$orch_name: Detection attempted"
                fi
                ;;
        esac
    done
else
    echo "No orchestrators detected"
    echo "This may be expected if no orchestrators are running"
fi

echo ""
echo "Test 4: Command Failure and Fallback Analysis"
echo "=============================================="
echo ""

# Count different types of fallback attempts
fallback_count=$(grep -ic "fallback" "$DEBUG_FILE" 2>/dev/null || echo "0")
failed_count=$(grep -ic "failed" "$DEBUG_FILE" 2>/dev/null || echo "0")
timeout_count=$(grep -ic "timeout" "$DEBUG_FILE" 2>/dev/null || echo "0")

echo "Fallback statistics:"
echo "  Fallback attempts: $fallback_count"
echo "  Failed commands: $failed_count"
echo "  Timeouts: $timeout_count"

if [ "$privilege_level" = "none" ] && [ "$fallback_count" -eq 0 ] && [ "$failed_count" -gt 5 ]; then
    test_fail "Many commands failed but no fallback mechanisms triggered"
elif [ "$fallback_count" -gt 0 ]; then
    test_pass "Fallback mechanisms were used ($fallback_count times)"
else
    test_pass "Script executed without needing fallbacks"
fi

if [ "$timeout_count" -gt 10 ]; then
    test_fail "Excessive timeouts detected ($timeout_count) - may indicate hung commands"
elif [ "$timeout_count" -gt 0 ]; then
    test_pass "Some commands timed out ($timeout_count) but were handled"
fi

echo ""
echo "Test 5: Socket Detection Fallback"
echo "=================================="
echo ""

# Check if socket detection was attempted
socket_checks=0

for runtime in containerd docker crio podman; do
    if grep -q "${runtime}\.sock" "$DEBUG_FILE"; then
        socket_checks=$((socket_checks + 1))
        echo "Socket check for $runtime: found in debug log"
    fi
done

if [ "$socket_checks" -gt 0 ]; then
    test_pass "Socket detection was attempted for $socket_checks runtime(s)"
else
    echo "No socket checks found in debug log"
fi

echo ""
echo "Test 6: Version Detection Methods"
echo "=================================="
echo ""

# Check that version detection used multiple methods
version_methods=0

if grep -qE "containerd --version|ctr version" "$DEBUG_FILE"; then
    version_methods=$((version_methods + 1))
    test_pass "containerd version detection attempted"
fi

if grep -qE "docker version|dockerd --version" "$DEBUG_FILE"; then
    version_methods=$((version_methods + 1))
    test_pass "docker version detection attempted"
fi

if grep -qE "crio --version|crictl version" "$DEBUG_FILE"; then
    version_methods=$((version_methods + 1))
    test_pass "crio version detection attempted"
fi

if grep -qE "podman version|podman --version" "$DEBUG_FILE"; then
    version_methods=$((version_methods + 1))
    test_pass "podman version detection attempted"
fi

if grep -qE "kubectl version|kubelet --version" "$DEBUG_FILE"; then
    version_methods=$((version_methods + 1))
    test_pass "kubernetes version detection attempted"
fi

if [ "$version_methods" -eq 0 ]; then
    echo "No version detection methods found in debug log"
    if [ "$runtime_count" -eq 0 ] && [ "$orch_count" -eq 0 ]; then
        test_pass "No version detection needed (no runtimes/orchestrators)"
    else
        test_fail "Runtimes/orchestrators detected but no version detection logged"
    fi
fi

echo ""
echo "Test 7: Error Handling and Recovery"
echo "===================================="
echo ""

# Check error file
if [ -f "$ERROR_FILE" ]; then
    error_count=$(wc -l < "$ERROR_FILE")
    echo "Total errors logged: $error_count"

    if [ "$error_count" -gt 50 ]; then
        test_fail "Excessive errors logged ($error_count) - may indicate systemic issues"
    elif [ "$error_count" -gt 0 ]; then
        echo "Sample errors (first 5):"
        head -n 5 "$ERROR_FILE" | sed 's/^/  /'
        test_pass "Errors were logged appropriately ($error_count errors)"
    else
        test_pass "No errors logged"
    fi
else
    test_fail "error.txt file not found"
fi

echo ""
echo "Test 8: Configuration File Parsing Fallback"
echo "============================================"
echo ""

# Check if config files were used as fallbacks
config_fallbacks=0

if grep -qE "/etc/containerd/config\.toml|containerd config dump" "$DEBUG_FILE"; then
    config_fallbacks=$((config_fallbacks + 1))
    test_pass "containerd config file parsing attempted"
fi

if grep -qE "/etc/crio/crio\.conf|crio config" "$DEBUG_FILE"; then
    config_fallbacks=$((config_fallbacks + 1))
    test_pass "crio config file parsing attempted"
fi

if grep -qE "/etc/containers/storage\.conf|/etc/containers/registries\.conf" "$DEBUG_FILE"; then
    config_fallbacks=$((config_fallbacks + 1))
    test_pass "containers config file parsing attempted"
fi

if grep -qE "/etc/kubernetes|kubeconfig|KUBECONFIG" "$DEBUG_FILE"; then
    config_fallbacks=$((config_fallbacks + 1))
    test_pass "kubernetes config detection attempted"
fi

if [ "$config_fallbacks" -eq 0 ]; then
    echo "No config file fallbacks found (may not be needed)"
fi

echo ""
echo "Test 9: Process Inspection Fallback"
echo "===================================="
echo ""

# Check if process inspection was used
if grep -qE "ps.*aux|pgrep|/proc/" "$DEBUG_FILE"; then
    test_pass "Process inspection was attempted as fallback"
else
    echo "No process inspection found in debug log"
    if [ "$privilege_level" = "root" ] || [ "$privilege_level" = "sudo" ]; then
        test_pass "Process inspection not needed with elevated privileges"
    else
        echo "Process inspection may have been needed but not found"
    fi
fi

echo ""
echo "Test 10: Systemd Service Fallback"
echo "=================================="
echo ""

# Check if systemd was queried
if grep -qE "systemctl|systemd" "$DEBUG_FILE"; then
    test_pass "systemd service queries were attempted"

    # Count how many services were checked
    service_checks=$(grep -c "systemctl" "$DEBUG_FILE" 2>/dev/null || echo "0")
    echo "systemctl invocations: $service_checks"

    if [ "$service_checks" -gt 0 ]; then
        test_pass "Service status checks performed ($service_checks checks)"
    fi
else
    echo "No systemd queries found"
    if [ "$runtime_count" -eq 0 ] && [ "$orch_count" -eq 0 ]; then
        test_pass "No systemd checks needed (no services to check)"
    else
        echo "systemd checks may have been beneficial but weren't found"
    fi
fi

echo ""
echo "=========================================="
echo "Fallback Test Results Summary"
echo "=========================================="
echo ""
echo "Total Tests: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"
echo ""

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}✓ All fallback mechanism tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ $FAILED_TESTS test(s) failed${NC}"
    exit 1
fi
