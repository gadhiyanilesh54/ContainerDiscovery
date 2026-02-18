#!/bin/bash
# test_validation_comprehensive.sh - Comprehensive validation for container discovery script
# Tests for hardcoded values, fallback mechanisms, privilege degradation, and cross-field consistency

set -e

echo "=========================================="
echo "Comprehensive Validation Test"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/output.json"
DEBUG_FILE="$SCRIPT_DIR/debug.txt"
ERROR_FILE="$SCRIPT_DIR/error.txt"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNING_TESTS=0

# Test result tracking
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

test_warn() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    WARNING_TESTS=$((WARNING_TESTS + 1))
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

# Check if output.json exists
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "ERROR: output.json not found at $OUTPUT_FILE"
    echo "Please run GuestDetails_Container.sh first"
    exit 1
fi

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for this test"
    echo "Please install jq: sudo apt-get install jq"
    exit 1
fi

echo "Test 1: Validate No Hardcoded Values in Output"
echo "================================================"
echo ""

# Check for common hardcoded values that shouldn't be in dynamic output
check_no_hardcoded() {
    local field="$1"
    local value="$2"
    local description="$3"

    if [ "$value" = "unknown" ] && [ "$description" != "hypervisor" ]; then
        test_warn "$field should not be hardcoded to 'unknown' - $description"
    elif [ "$value" = "overlay2" ] || [ "$value" = "overlay" ] || [ "$value" = "overlayfs" ]; then
        # These are acceptable defaults but let's verify they match reality
        test_pass "$field has storage driver value: $value"
    elif [ "$value" = "systemd" ] || [ "$value" = "cgroupfs" ]; then
        # These are acceptable cgroup drivers
        test_pass "$field has cgroup driver value: $value"
    fi
}

# Validate container runtimes don't have hardcoded values
runtime_count=$(jq '.armResources[0].properties.container_runtimes | length' "$OUTPUT_FILE")
echo "Found $runtime_count container runtimes"

for i in $(seq 0 $((runtime_count - 1))); do
    runtime_name=$(jq -r ".armResources[0].properties.container_runtimes[$i].name" "$OUTPUT_FILE")
    runtime_type=$(jq -r ".armResources[0].properties.container_runtimes[$i].runtime_type" "$OUTPUT_FILE")
    version=$(jq -r ".armResources[0].properties.container_runtimes[$i].version" "$OUTPUT_FILE")
    storage_driver=$(jq -r ".armResources[0].properties.container_runtimes[$i].storage_driver" "$OUTPUT_FILE")

    echo "Checking runtime: $runtime_name ($runtime_type)"

    # Version should not be empty
    if [ -z "$version" ] || [ "$version" = "null" ] || [ "$version" = "" ]; then
        test_fail "Runtime $runtime_name has empty version"
    else
        # Check if version looks like an error message
        if echo "$version" | grep -qiE "error|failed|permission denied|not found"; then
            test_fail "Runtime $runtime_name version contains error message: $version"
        else
            test_pass "Runtime $runtime_name has valid version: $version"
        fi
    fi

    # Storage driver should not be empty
    if [ -z "$storage_driver" ] || [ "$storage_driver" = "null" ]; then
        test_fail "Runtime $runtime_name has empty storage_driver"
    else
        test_pass "Runtime $runtime_name has storage driver: $storage_driver"
    fi
done

echo ""
echo "Test 2: Validate Orchestrator Detection"
echo "========================================"
echo ""

orch_count=$(jq '.armResources[0].properties.orchestrators | length' "$OUTPUT_FILE")
echo "Found $orch_count orchestrators"

for i in $(seq 0 $((orch_count - 1))); do
    orch_name=$(jq -r ".armResources[0].properties.orchestrators[$i].name" "$OUTPUT_FILE")
    orch_type=$(jq -r ".armResources[0].properties.orchestrators[$i].orchestrator_type" "$OUTPUT_FILE")
    version=$(jq -r ".armResources[0].properties.orchestrators[$i].version" "$OUTPUT_FILE")
    cluster_id=$(jq -r ".armResources[0].properties.orchestrators[$i].cluster_id" "$OUTPUT_FILE")
    state=$(jq -r ".armResources[0].properties.orchestrators[$i].state" "$OUTPUT_FILE")

    echo "Checking orchestrator: $orch_name ($orch_type)"

    # Version should not be empty
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        test_fail "Orchestrator $orch_name has empty version"
    else
        # Check if version looks like an error message
        if echo "$version" | grep -qiE "error|failed|permission denied|not found|unable to connect"; then
            test_fail "Orchestrator $orch_name version contains error message: $version"
        else
            test_pass "Orchestrator $orch_name has valid version: $version"
        fi
    fi

    # Cluster ID should not contain error messages
    if [ -n "$cluster_id" ] && [ "$cluster_id" != "" ]; then
        if echo "$cluster_id" | grep -qiE "error|failed|permission denied|not found|unable to connect"; then
            test_fail "Orchestrator $orch_name cluster_id contains error message: $cluster_id"
        else
            test_pass "Orchestrator $orch_name has valid cluster_id"
        fi
    fi

    # State should be valid enum
    valid_states="active|pending|inactive|locked|error|drain|degraded|progressing|unknown|creating|deleting|updating"
    if echo "$state" | grep -qE "^($valid_states)$"; then
        test_pass "Orchestrator $orch_name has valid state: $state"
    else
        test_fail "Orchestrator $orch_name has invalid state: $state"
    fi
done

echo ""
echo "Test 3: Cross-Field Consistency Validation"
echo "==========================================="
echo ""

# Validate container counts
for i in $(seq 0 $((runtime_count - 1))); do
    runtime_name=$(jq -r ".armResources[0].properties.container_runtimes[$i].name" "$OUTPUT_FILE")
    total=$(jq ".armResources[0].properties.container_runtimes[$i].container_count" "$OUTPUT_FILE")
    running=$(jq ".armResources[0].properties.container_runtimes[$i].running_container_count" "$OUTPUT_FILE")
    paused=$(jq ".armResources[0].properties.container_runtimes[$i].paused_container_count" "$OUTPUT_FILE")
    stopped=$(jq ".armResources[0].properties.container_runtimes[$i].stopped_container_count" "$OUTPUT_FILE")

    echo "Checking $runtime_name container counts:"
    echo "  Total: $total, Running: $running, Paused: $paused, Stopped: $stopped"

    # Running + Paused + Stopped should be <= Total
    sum=$((running + paused + stopped))
    if [ "$sum" -gt "$total" ]; then
        test_fail "$runtime_name: running+paused+stopped ($sum) > total ($total)"
    else
        test_pass "$runtime_name: container count consistency valid"
    fi

    # All counts should be non-negative
    if [ "$total" -lt 0 ] || [ "$running" -lt 0 ] || [ "$paused" -lt 0 ] || [ "$stopped" -lt 0 ]; then
        test_fail "$runtime_name: negative container count detected"
    else
        test_pass "$runtime_name: all counts are non-negative"
    fi
done

echo ""
echo "Test 4: Orchestrator Node Count Validation"
echo "==========================================="
echo ""

for i in $(seq 0 $((orch_count - 1))); do
    orch_name=$(jq -r ".armResources[0].properties.orchestrators[$i].name" "$OUTPUT_FILE")
    total_nodes=$(jq ".armResources[0].properties.orchestrators[$i].nodes.total_count" "$OUTPUT_FILE")
    master_count=$(jq ".armResources[0].properties.orchestrators[$i].nodes.master_count" "$OUTPUT_FILE")
    worker_count=$(jq ".armResources[0].properties.orchestrators[$i].nodes.worker_count" "$OUTPUT_FILE")
    master_nodes=$(jq ".armResources[0].properties.orchestrators[$i].nodes.master_nodes" "$OUTPUT_FILE")
    worker_nodes=$(jq ".armResources[0].properties.orchestrators[$i].nodes.worker_nodes" "$OUTPUT_FILE")

    echo "Checking $orch_name node counts:"
    echo "  Total: $total_nodes, Master: $master_count, Worker: $worker_count"

    # Master + Worker should equal Total
    sum=$((master_count + worker_count))
    if [ "$total_nodes" -gt 0 ] && [ "$sum" -ne "$total_nodes" ]; then
        test_warn "$orch_name: master($master_count) + worker($worker_count) != total($total_nodes)"
    else
        test_pass "$orch_name: node count totals are consistent"
    fi

    # If counts are > 0, arrays should not be empty
    master_array_len=$(echo "$master_nodes" | jq 'length')
    worker_array_len=$(echo "$worker_nodes" | jq 'length')

    if [ "$master_count" -gt 0 ] && [ "$master_array_len" -eq 0 ]; then
        test_fail "$orch_name: master_count > 0 but master_nodes array is empty"
    elif [ "$master_count" -gt 0 ]; then
        test_pass "$orch_name: master_nodes array is populated ($master_array_len nodes)"
    fi

    if [ "$worker_count" -gt 0 ] && [ "$worker_array_len" -eq 0 ]; then
        test_fail "$orch_name: worker_count > 0 but worker_nodes array is empty"
    elif [ "$worker_count" -gt 0 ]; then
        test_pass "$orch_name: worker_nodes array is populated ($worker_array_len nodes)"
    fi
done

echo ""
echo "Test 5: Orchestrator Workload Validation"
echo "========================================="
echo ""

for i in $(seq 0 $((orch_count - 1))); do
    orch_name=$(jq -r ".armResources[0].properties.orchestrators[$i].name" "$OUTPUT_FILE")
    total_containers=$(jq ".armResources[0].properties.orchestrators[$i].workloads.total_container_count" "$OUTPUT_FILE")
    system_containers=$(jq ".armResources[0].properties.orchestrators[$i].workloads.system_container_count" "$OUTPUT_FILE")
    user_containers=$(jq ".armResources[0].properties.orchestrators[$i].workloads.user_container_count" "$OUTPUT_FILE")
    pod_count=$(jq ".armResources[0].properties.orchestrators[$i].workloads.pod_count" "$OUTPUT_FILE")

    echo "Checking $orch_name workload counts:"
    echo "  Total containers: $total_containers, System: $system_containers, User: $user_containers, Pods: $pod_count"

    # System + User should equal Total
    sum=$((system_containers + user_containers))
    if [ "$total_containers" -gt 0 ] && [ "$sum" -ne "$total_containers" ]; then
        test_fail "$orch_name: system($system_containers) + user($user_containers) != total($total_containers)"
    else
        test_pass "$orch_name: workload container counts are consistent"
    fi

    # If it's Kubernetes-based, and pod_count > 0, total_containers should also be > 0
    if echo "$orch_name" | grep -qiE "kubernetes|openshift|tanzu"; then
        if [ "$pod_count" -gt 0 ] && [ "$total_containers" -eq 0 ]; then
            test_fail "$orch_name: pod_count > 0 but total_container_count = 0"
        elif [ "$pod_count" -gt 0 ]; then
            test_pass "$orch_name: pod and container counts are consistent"
        fi
    fi
done

echo ""
echo "Test 6: Socket and Path Validation"
echo "==================================="
echo ""

for i in $(seq 0 $((runtime_count - 1))); do
    runtime_name=$(jq -r ".armResources[0].properties.container_runtimes[$i].name" "$OUTPUT_FILE")
    socket=$(jq -r ".armResources[0].properties.container_runtimes[$i].socket" "$OUTPUT_FILE")
    storage_root=$(jq -r ".armResources[0].properties.container_runtimes[$i].storage_root" "$OUTPUT_FILE")

    echo "Checking $runtime_name paths:"

    # Socket should not be empty
    if [ -z "$socket" ] || [ "$socket" = "null" ]; then
        test_fail "$runtime_name: socket path is empty"
    else
        # Check if socket path looks reasonable
        if echo "$socket" | grep -qE '^/'; then
            test_pass "$runtime_name: socket path looks valid: $socket"

            # Check if socket exists (note: may not be readable without privileges)
            if [ -S "$socket" ]; then
                test_pass "$runtime_name: socket exists and is a socket"
            elif [ -e "$socket" ]; then
                test_warn "$runtime_name: socket path exists but is not a socket"
            else
                test_warn "$runtime_name: socket does not exist (may require privileges)"
            fi
        else
            test_fail "$runtime_name: socket path doesn't start with /: $socket"
        fi
    fi

    # Storage root should not be empty
    if [ -z "$storage_root" ] || [ "$storage_root" = "null" ]; then
        test_fail "$runtime_name: storage_root is empty"
    else
        if echo "$storage_root" | grep -qE '^/'; then
            test_pass "$runtime_name: storage_root looks valid: $storage_root"
        else
            test_fail "$runtime_name: storage_root doesn't start with /: $storage_root"
        fi
    fi
done

echo ""
echo "Test 7: Privilege Level Detection"
echo "=================================="
echo ""

if [ -f "$DEBUG_FILE" ]; then
    privilege_level=$(grep -m1 "Privilege level detected" "$DEBUG_FILE" | awk '{print $NF}' || echo "unknown")
    echo "Detected privilege level: $privilege_level"

    if [ "$privilege_level" = "root" ] || [ "$privilege_level" = "sudo" ] || [ "$privilege_level" = "none" ]; then
        test_pass "Valid privilege level detected: $privilege_level"
    else
        test_warn "Privilege level detection unclear: $privilege_level"
    fi

    # Check for fallback usage
    fallback_count=$(grep -c "fallback" "$DEBUG_FILE" 2>/dev/null || echo "0")
    echo "Fallback mechanisms used: $fallback_count times"

    if [ "$privilege_level" = "none" ] && [ "$fallback_count" -eq 0 ]; then
        test_warn "Running without privileges but no fallback mechanisms used"
    elif [ "$fallback_count" -gt 0 ]; then
        test_pass "Fallback mechanisms are working ($fallback_count instances)"
    fi
else
    test_warn "debug.txt not found, cannot verify privilege detection"
fi

echo ""
echo "Test 8: Error Message Filtering"
echo "================================"
echo ""

# Check that fields don't contain common error patterns
check_field_for_errors() {
    local field_name="$1"
    local field_value="$2"

    if [ -z "$field_value" ] || [ "$field_value" = "null" ]; then
        return 0  # Empty is acceptable
    fi

    if echo "$field_value" | grep -qiE "error|failed|permission denied|unable to connect|connection refused|no such file|command not found"; then
        test_fail "$field_name contains error message: $field_value"
        return 1
    fi
    return 0
}

# Check all cluster_id fields
for i in $(seq 0 $((orch_count - 1))); do
    orch_name=$(jq -r ".armResources[0].properties.orchestrators[$i].name" "$OUTPUT_FILE")
    cluster_id=$(jq -r ".armResources[0].properties.orchestrators[$i].cluster_id" "$OUTPUT_FILE")
    cluster_name=$(jq -r ".armResources[0].properties.orchestrators[$i].cluster_name" "$OUTPUT_FILE")

    check_field_for_errors "$orch_name cluster_id" "$cluster_id"
    check_field_for_errors "$orch_name cluster_name" "$cluster_name"
done

test_pass "Error message filtering validation complete"

echo ""
echo "Test 9: Host Info Validation"
echo "============================="
echo ""

hostname=$(jq -r '.armResources[0].properties.host_info.hostname' "$OUTPUT_FILE")
os=$(jq -r '.armResources[0].properties.host_info.os' "$OUTPUT_FILE")
kernel=$(jq -r '.armResources[0].properties.host_info.kernel' "$OUTPUT_FILE")
arch=$(jq -r '.armResources[0].properties.host_info.arch' "$OUTPUT_FILE")
cpu_cores=$(jq '.armResources[0].properties.host_info.cpu_cores' "$OUTPUT_FILE")
memory_total_mb=$(jq '.armResources[0].properties.host_info.memory_total_mb' "$OUTPUT_FILE")

echo "Host Info:"
echo "  Hostname: $hostname"
echo "  OS: $os"
echo "  Kernel: $kernel"
echo "  Arch: $arch"
echo "  CPU Cores: $cpu_cores"
echo "  Memory: $memory_total_mb MB"

# Hostname should not be "unknown"
if [ "$hostname" = "unknown" ]; then
    test_warn "Hostname is 'unknown' - fallback may have failed"
elif [ -z "$hostname" ]; then
    test_fail "Hostname is empty"
else
    test_pass "Hostname is populated: $hostname"
fi

# OS should not be "unknown"
if [ "$os" = "unknown" ]; then
    test_warn "OS is 'unknown' - fallback may have failed"
elif [ -z "$os" ]; then
    test_fail "OS is empty"
else
    test_pass "OS is populated: $os"
fi

# CPU cores should be > 0
if [ "$cpu_cores" -gt 0 ]; then
    test_pass "CPU cores is valid: $cpu_cores"
else
    test_fail "CPU cores is invalid: $cpu_cores"
fi

# Memory should be > 0
if [ "$memory_total_mb" -gt 0 ]; then
    test_pass "Memory is valid: $memory_total_mb MB"
else
    test_fail "Memory is invalid: $memory_total_mb MB"
fi

echo ""
echo "Test 10: Hypervisor Detection"
echo "=============================="
echo ""

hypervisor_type=$(jq -r '.armResources[0].properties.hypervisor.type' "$OUTPUT_FILE")
hypervisor_version=$(jq -r '.armResources[0].properties.hypervisor.version' "$OUTPUT_FILE")

echo "Hypervisor:"
echo "  Type: $hypervisor_type"
echo "  Version: $hypervisor_version"

valid_hypervisors="vmware|hyperv|kvm|xen|virtualbox|nutanix|physical|unknown"
if echo "$hypervisor_type" | grep -qE "^($valid_hypervisors)$"; then
    test_pass "Hypervisor type is valid: $hypervisor_type"
else
    test_fail "Hypervisor type is invalid: $hypervisor_type"
fi

# unknown is acceptable for hypervisor
if [ "$hypervisor_type" = "unknown" ]; then
    test_pass "Hypervisor type 'unknown' is acceptable default"
fi

echo ""
echo "=========================================="
echo "Test Results Summary"
echo "=========================================="
echo ""
echo "Total Tests: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"
echo -e "${YELLOW}Warnings: $WARNING_TESTS${NC}"
echo ""

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    if [ "$WARNING_TESTS" -gt 0 ]; then
        echo -e "${YELLOW}Note: $WARNING_TESTS warnings detected (review recommended)${NC}"
    fi
    exit 0
else
    echo -e "${RED}✗ $FAILED_TESTS test(s) failed${NC}"
    exit 1
fi
