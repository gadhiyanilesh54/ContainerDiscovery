#!/usr/bin/env sh
# GuestDetails_Container.sh — Container & Orchestrator Discovery Script
# Schema Version: 1.0.0
# Description: Production-grade POSIX-compatible shell script to discover container runtimes
#              and orchestrators on Linux hosts with graceful privilege degradation

set +e  # Never exit on error - graceful degradation

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="${SCRIPT_DIR}/output.json"
ERROR_FILE="${SCRIPT_DIR}/error.txt"
DEBUG_FILE="${SCRIPT_DIR}/debug.txt"
TIMEOUT_CMD="timeout"
DEFAULT_TIMEOUT=10

# Initialize log files
: > "$ERROR_FILE"
: > "$DEBUG_FILE"

# Exit code
EXIT_CODE=0

# Global variables for discovered data
PRIVILEGE_LEVEL=""
RUNTIMES_DETECTED=""
ORCHESTRATORS_DETECTED=""
SEEN_CONTAINERS=""

#==============================================================================
# Utility Functions
#==============================================================================

# Logging functions
log_info() {
    echo "[INFO] $*" >&2
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [INFO] $*" >> "$DEBUG_FILE"
}

log_warn() {
    echo "[WARN] $*" >&2
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [WARN] $*" >> "$DEBUG_FILE"
}

log_error() {
    echo "[ERROR] $*" >&2
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [ERROR] $*" >> "$ERROR_FILE"
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [ERROR] $*" >> "$DEBUG_FILE"
    EXIT_CODE=1
}

log_debug() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [DEBUG] $*" >> "$DEBUG_FILE"
}

# Safe command execution with timeout
try_command() {
    cmd="$1"
    timeout_val="${2:-$DEFAULT_TIMEOUT}"

    log_debug "Executing: $cmd"

    if command -v timeout >/dev/null 2>&1; then
        result=$(timeout "$timeout_val" sh -c "$cmd" 2>/dev/null)
    else
        result=$(sh -c "$cmd" 2>/dev/null)
    fi

    if [ $? -eq 0 ] && [ -n "$result" ]; then
        echo "$result"
        return 0
    else
        log_debug "Command failed or returned empty: $cmd"
        return 1
    fi
}

# Check if running with privileges
check_privilege() {
    if [ -n "$PRIVILEGE_LEVEL" ]; then
        echo "$PRIVILEGE_LEVEL"
        return
    fi

    if [ "$(id -u)" = "0" ]; then
        PRIVILEGE_LEVEL="root"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        PRIVILEGE_LEVEL="sudo"
    else
        PRIVILEGE_LEVEL="none"
    fi

    echo "$PRIVILEGE_LEVEL"
}

# Execute command with privilege fallback
try_privileged_command() {
    cmd="$1"
    fallback_cmd="$2"

    priv_level=$(check_privilege)

    # Try privileged first
    if [ "$priv_level" = "root" ]; then
        result=$(try_command "$cmd")
    elif [ "$priv_level" = "sudo" ]; then
        result=$(try_command "sudo $cmd")
    fi

    # Fallback to unprivileged
    if [ -z "$result" ] && [ -n "$fallback_cmd" ]; then
        log_debug "Privileged command failed, trying fallback: $fallback_cmd"
        result=$(try_command "$fallback_cmd")
    fi

    echo "$result"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get PID of process
get_pid() {
    process_name="$1"
    pid=$(pgrep -o "$process_name" 2>/dev/null | head -n 1)
    echo "$pid"
}

# Get process CPU and memory usage
get_process_cpu_mem() {
    pid="$1"

    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        echo "0.0 0.0"
        return
    fi

    if [ -f "/proc/$pid/stat" ]; then
        # Read from /proc for more reliable data
        cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
        mem_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')

        if [ -n "$cpu" ] && [ -n "$mem_kb" ]; then
            mem_mb=$(echo "scale=2; $mem_kb / 1024" | bc 2>/dev/null || echo "$((mem_kb / 1024))")
            echo "$cpu $mem_mb"
            return
        fi
    fi

    echo "0.0 0.0"
}

# Escape string for JSON
json_escape() {
    if [ -z "$1" ]; then
        echo ""
        return
    fi
    # Escape backslashes, quotes, newlines, tabs
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r' | sed 's/	/\\t/g'
}

# Build JSON object from key-value pairs
json_build_object() {
    result="{"
    first=true

    while [ $# -gt 0 ]; do
        key="$1"
        value="$2"
        shift 2

        if [ "$first" = true ]; then
            first=false
        else
            result="$result,"
        fi

        # Check if value is already JSON (starts with { [ or is boolean)
        case "$value" in
            \{*|\[*)
                result="$result\"$key\":$value"
                ;;
            true|false|null)
                result="$result\"$key\":$value"
                ;;
            "")
                # Empty string
                result="$result\"$key\":\"\""
                ;;
            *[!0-9.]*)
                # String value (contains non-numeric characters)
                result="$result\"$key\":\"$(json_escape "$value")\""
                ;;
            *.*.*)
                # Version string (multiple dots like 1.2.3)
                result="$result\"$key\":\"$value\""
                ;;
            *.*[0-9])
                # Likely a version or float - check if it has more than one dot
                dot_count=$(echo "$value" | tr -cd '.' | wc -c)
                if [ "$dot_count" -gt 1 ]; then
                    # Version string
                    result="$result\"$key\":\"$value\""
                else
                    # Float number
                    result="$result\"$key\":$value"
                fi
                ;;
            *)
                # Integer number
                result="$result\"$key\":$value"
                ;;
        esac
    done

    result="$result}"
    echo "$result"
}

# Build JSON array from newline-separated values
json_build_array() {
    input="$1"
    is_json_objects="${2:-false}"

    if [ -z "$input" ]; then
        echo "[]"
        return
    fi

    result="["
    first=true

    echo "$input" | while IFS= read -r line; do
        if [ -n "$line" ]; then
            if [ "$first" = false ]; then
                result="$result,"
            fi

            if [ "$is_json_objects" = "true" ]; then
                result="$result$line"
            else
                result="$result\"$(json_escape "$line")\""
            fi
            first=false
        fi
    done

    result="$result]"
    echo "$result"
}

# Get listening ports for a process/service
get_listening_ports() {
    process_name="$1"
    ports_json="["
    first=true

    # Try to get ports using ss (modern tool)
    if command_exists ss; then
        # Get listening TCP and UDP ports for the process
        port_lines=$(ss -tlnp 2>/dev/null | grep "$process_name" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        if [ -z "$port_lines" ]; then
            port_lines=$(ss -ulnp 2>/dev/null | grep "$process_name" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        fi
    # Fallback to netstat
    elif command_exists netstat; then
        port_lines=$(netstat -tlnp 2>/dev/null | grep "$process_name" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        if [ -z "$port_lines" ]; then
            port_lines=$(netstat -ulnp 2>/dev/null | grep "$process_name" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        fi
    # Last resort: use lsof if available
    elif command_exists lsof; then
        port_lines=$(lsof -i -P -n 2>/dev/null | grep "$process_name" | grep LISTEN | awk '{print $9}' | sed 's/.*://g' | sort -u)
    fi

    # Build JSON array of port numbers
    if [ -n "$port_lines" ]; then
        for port in $port_lines; do
            # Validate port is a number
            case "$port" in
                ''|*[!0-9]*) continue ;;
            esac

            if [ "$first" = false ]; then
                ports_json="$ports_json,"
            fi
            ports_json="$ports_json$port"
            first=false
        done
    fi

    echo "$ports_json]"
}

# Check if container ID has been seen
is_container_seen() {
    cid="$1"

    if echo "$SEEN_CONTAINERS" | grep -q "^$cid$"; then
        return 0  # Already seen
    else
        SEEN_CONTAINERS="$SEEN_CONTAINERS
$cid"
        return 1  # New container
    fi
}

#==============================================================================
# Host Discovery Functions
#==============================================================================

discover_host_info() {
    log_info "Discovering host information..."

    # Hostname
    HOSTNAME=$(try_command "hostname" || try_command "cat /etc/hostname" || echo "unknown")

    # FQDN
    FQDN=$(try_command "hostname -f" || echo "$HOSTNAME")

    # OS
    if [ -f /etc/os-release ]; then
        OS=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'"' -f2)
        [ -z "$OS" ] && OS=$(grep "^NAME=" /etc/os-release | cut -d'"' -f2)
    else
        OS=$(try_command "uname -o" || echo "Unknown Linux")
    fi

    # Kernel
    KERNEL=$(try_command "uname -r" || echo "unknown")

    # Architecture
    ARCH=$(try_command "uname -m" || echo "unknown")

    # CPU cores
    CPU_CORES=$(try_command "nproc" || try_command "grep -c ^processor /proc/cpuinfo" || echo "0")

    # CPU model
    CPU_MODEL=$(try_command "grep 'model name' /proc/cpuinfo | head -n1 | cut -d':' -f2 | sed 's/^[ \t]*//'")
    if [ -z "$CPU_MODEL" ]; then
        CPU_MODEL=$(try_command "lscpu | grep 'Model name' | cut -d':' -f2 | sed 's/^[ \t]*//'")
    fi
    [ -z "$CPU_MODEL" ] && CPU_MODEL="Unknown"

    # Memory total in MB
    if [ -f /proc/meminfo ]; then
        MEMORY_KB=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
        MEMORY_TOTAL_MB=$((MEMORY_KB / 1024))
    else
        MEMORY_TOTAL_MB=$(try_command "free -m | grep Mem | awk '{print \$2}'" || echo "0")
    fi

    # Disks
    DISKS_JSON=$(discover_disks)

    # Build host_info JSON
    HOST_INFO_JSON=$(json_build_object \
        "hostname" "$HOSTNAME" \
        "fqdn" "$FQDN" \
        "os" "$OS" \
        "kernel" "$KERNEL" \
        "arch" "$ARCH" \
        "cpu_cores" "$CPU_CORES" \
        "cpu_model" "$CPU_MODEL" \
        "memory_total_mb" "$MEMORY_TOTAL_MB" \
        "disks" "$DISKS_JSON")

    log_info "Host info discovered: $HOSTNAME ($OS, $ARCH)"
}

discover_disks() {
    if ! command_exists lsblk; then
        # Fallback to using fdisk or other methods
        if command_exists fdisk; then
            disk_list=$(try_privileged_command "fdisk -l 2>/dev/null | grep '^Disk /dev/' | grep -v 'loop'" "")
        fi
        if [ -z "$disk_list" ]; then
            echo "[]"
            return
        fi
    else
        disk_list=$(lsblk -dno NAME,SIZE 2>/dev/null | grep -v "^loop" | grep -v "^sr")
    fi

    if [ -z "$disk_list" ]; then
        echo "[]"
        return
    fi

    disks_json="["
    first=true

    # Use a while loop with process substitution to avoid subshell
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            # Handle both lsblk and fdisk output
            if echo "$line" | grep -q "^Disk /dev/"; then
                # fdisk format: "Disk /dev/sda: 100 GiB, ..."
                name=$(echo "$line" | sed 's|^Disk /dev/\([^:]*\):.*|\1|')
                size=$(echo "$line" | sed 's|^Disk /dev/[^:]*: \([^ ]*\) \([^ ]*\).*|\1 \2|')
                size_value=$(echo "$size" | awk '{print $1}')
                size_unit=$(echo "$size" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')

                # Convert to GB
                if [ "$size_unit" = "TIB" ] || [ "$size_unit" = "TB" ] || [ "$size_unit" = "T" ]; then
                    size_gb=$(echo "scale=2; $size_value * 1024" | bc 2>/dev/null || echo "$size_value")
                elif [ "$size_unit" = "MIB" ] || [ "$size_unit" = "MB" ] || [ "$size_unit" = "M" ]; then
                    size_gb=$(echo "scale=2; $size_value / 1024" | bc 2>/dev/null || echo "0")
                elif [ "$size_unit" = "GIB" ] || [ "$size_unit" = "GB" ] || [ "$size_unit" = "G" ]; then
                    size_gb="$size_value"
                else
                    # Assume bytes, convert to GB
                    size_gb=$(echo "scale=2; $size_value / 1073741824" | bc 2>/dev/null || echo "0")
                fi
            else
                # lsblk format: "sda 100G"
                name=$(echo "$line" | awk '{print $1}')
                size=$(echo "$line" | awk '{print $2}')
                # Extract numeric part
                size_num=$(echo "$size" | sed 's/[^0-9.]//g')

                # Convert to GB
                if echo "$size" | grep -qi "T"; then
                    size_gb=$(echo "scale=2; $size_num * 1024" | bc 2>/dev/null || echo "$size_num")
                elif echo "$size" | grep -qi "M"; then
                    size_gb=$(echo "scale=2; $size_num / 1024" | bc 2>/dev/null || echo "0")
                else
                    size_gb="$size_num"
                fi
            fi

            if [ "$first" = false ]; then
                disks_json="$disks_json,"
            fi
            disks_json="$disks_json$(json_build_object "name" "$name" "size_gb" "${size_gb:-0}")"
            first=false
        fi
    done <<EOF
$disk_list
EOF

    disks_json="$disks_json]"
    echo "$disks_json"
}

discover_hypervisor() {
    log_info "Discovering hypervisor..."

    HYPERVISOR_TYPE="unknown"
    HYPERVISOR_VERSION=""

    # Try systemd-detect-virt
    if command_exists systemd-detect-virt; then
        virt=$(try_command "systemd-detect-virt")
        case "$virt" in
            vmware) HYPERVISOR_TYPE="vmware" ;;
            microsoft) HYPERVISOR_TYPE="hyperv" ;;
            kvm) HYPERVISOR_TYPE="kvm" ;;
            xen) HYPERVISOR_TYPE="xen" ;;
            oracle) HYPERVISOR_TYPE="virtualbox" ;;
            none) HYPERVISOR_TYPE="physical" ;;
        esac
    fi

    # Try dmidecode
    if [ "$HYPERVISOR_TYPE" = "unknown" ] && command_exists dmidecode; then
        vendor=$(try_privileged_command "dmidecode -s system-manufacturer" "" | tr '[:upper:]' '[:lower:]')
        case "$vendor" in
            *vmware*) HYPERVISOR_TYPE="vmware" ;;
            *microsoft*) HYPERVISOR_TYPE="hyperv" ;;
            *qemu*|*kvm*) HYPERVISOR_TYPE="kvm" ;;
            *xen*) HYPERVISOR_TYPE="xen" ;;
            *virtualbox*) HYPERVISOR_TYPE="virtualbox" ;;
            *nutanix*) HYPERVISOR_TYPE="nutanix" ;;
        esac
    fi

    # Try /sys/class/dmi/id/sys_vendor
    if [ "$HYPERVISOR_TYPE" = "unknown" ] && [ -f /sys/class/dmi/id/sys_vendor ]; then
        vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$vendor" in
            *vmware*) HYPERVISOR_TYPE="vmware" ;;
            *microsoft*) HYPERVISOR_TYPE="hyperv" ;;
            *qemu*|*kvm*) HYPERVISOR_TYPE="kvm" ;;
            *xen*) HYPERVISOR_TYPE="xen" ;;
            *virtualbox*) HYPERVISOR_TYPE="virtualbox" ;;
            *nutanix*) HYPERVISOR_TYPE="nutanix" ;;
        esac
    fi

    # Check /proc/cpuinfo for hypervisor flag
    if [ "$HYPERVISOR_TYPE" = "unknown" ] && [ -f /proc/cpuinfo ]; then
        if grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
            HYPERVISOR_TYPE="unknown"
        else
            HYPERVISOR_TYPE="physical"
        fi
    fi

    # Try to get version for VMware
    if [ "$HYPERVISOR_TYPE" = "vmware" ] && command_exists vmware-toolbox-cmd; then
        HYPERVISOR_VERSION=$(try_command "vmware-toolbox-cmd -v")
    fi

    HYPERVISOR_JSON=$(json_build_object \
        "type" "$HYPERVISOR_TYPE" \
        "version" "$HYPERVISOR_VERSION")

    log_info "Hypervisor detected: $HYPERVISOR_TYPE"
}

discover_network() {
    log_info "Discovering network information..."

    # IP addresses
    IP_ADDRESSES_JSON=$(discover_ip_addresses)

    # Default gateway
    DEFAULT_GATEWAY=$(try_command "ip route | grep default | awk '{print \$3}' | head -n1")
    if [ -z "$DEFAULT_GATEWAY" ]; then
        DEFAULT_GATEWAY=$(try_command "route -n | grep '^0.0.0.0' | awk '{print \$2}' | head -n1")
    fi
    [ -z "$DEFAULT_GATEWAY" ] && DEFAULT_GATEWAY=""

    # DNS servers
    DNS_SERVERS_JSON=$(discover_dns_servers)

    NETWORK_JSON=$(json_build_object \
        "ip_addresses" "$IP_ADDRESSES_JSON" \
        "default_gateway" "\"$DEFAULT_GATEWAY\"" \
        "dns_servers" "$DNS_SERVERS_JSON")

    log_info "Network discovery completed"
}

discover_ip_addresses() {
    ip_json="["
    first=true

    if command_exists ip; then
        # Parse text output - use heredoc to avoid subshell
        current_iface=""
        ip_output=$(ip addr show 2>/dev/null)

        while IFS= read -r line; do
            # Check for interface line
            if echo "$line" | grep -q "^[0-9]*:"; then
                current_iface=$(echo "$line" | awk '{print $2}' | tr -d ':')
            fi

            # Check for inet lines
            if echo "$line" | grep -q "inet "; then
                addr=$(echo "$line" | grep -o "inet [0-9.]*" | awk '{print $2}')
                if [ -n "$addr" ] && [ "$addr" != "127.0.0.1" ]; then
                    if [ "$first" = false ]; then
                        ip_json="$ip_json,"
                    fi
                    ip_json="$ip_json$(json_build_object "address" "$addr" "version" "ipv4" "interface" "$current_iface")"
                    first=false
                fi
            elif echo "$line" | grep -q "inet6 "; then
                addr=$(echo "$line" | grep -o "inet6 [0-9a-fA-F:]*" | awk '{print $2}')
                if [ -n "$addr" ] && [ "$addr" != "::1" ]; then
                    if [ "$first" = false ]; then
                        ip_json="$ip_json,"
                    fi
                    ip_json="$ip_json$(json_build_object "address" "$addr" "version" "ipv6" "interface" "$current_iface")"
                    first=false
                fi
            fi
        done <<EOF
$ip_output
EOF
    fi

    ip_json="$ip_json]"
    echo "$ip_json"
}

discover_dns_servers() {
    dns_json="["
    first=true

    # Try resolvectl
    if command_exists resolvectl; then
        dns_list=$(resolvectl status 2>/dev/null | grep "DNS Servers:" | awk '{for(i=3;i<=NF;i++) print $i}')
    fi

    # Fallback to /etc/resolv.conf
    if [ -z "$dns_list" ] && [ -f /etc/resolv.conf ]; then
        dns_list=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}')
    fi

    if [ -n "$dns_list" ]; then
        while IFS= read -r dns; do
            if [ -n "$dns" ]; then
                if [ "$first" = false ]; then
                    dns_json="$dns_json,"
                fi
                dns_json="$dns_json\"$dns\""
                first=false
            fi
        done <<EOF
$dns_list
EOF
    fi

    dns_json="$dns_json]"
    echo "$dns_json"
}

#==============================================================================
# Container Runtime Detection and Discovery
#==============================================================================

detect_container_runtimes() {
    log_info "Detecting container runtimes..."

    RUNTIMES_DETECTED=""

    # Check for containerd
    if command_exists containerd || systemctl is-active containerd >/dev/null 2>&1 || [ -S /run/containerd/containerd.sock ]; then
        RUNTIMES_DETECTED="$RUNTIMES_DETECTED containerd"
        log_info "containerd detected"
        discover_containerd
    fi

    # Check for Docker
    if command_exists dockerd || command_exists docker || systemctl is-active docker >/dev/null 2>&1 || [ -S /var/run/docker.sock ]; then
        RUNTIMES_DETECTED="$RUNTIMES_DETECTED docker"
        log_info "Docker detected"
        discover_docker
    fi

    # Check for CRI-O
    if command_exists crio || systemctl is-active crio >/dev/null 2>&1 || [ -S /var/run/crio/crio.sock ]; then
        RUNTIMES_DETECTED="$RUNTIMES_DETECTED crio"
        log_info "CRI-O detected"
        discover_crio
    fi

    # Check for Podman
    if command_exists podman || systemctl is-active podman >/dev/null 2>&1 || [ -S /run/podman/podman.sock ] || [ -S /run/user/$(id -u)/podman/podman.sock ]; then
        RUNTIMES_DETECTED="$RUNTIMES_DETECTED podman"
        log_info "Podman detected"
        discover_podman
    fi

    RUNTIMES_DETECTED=$(echo "$RUNTIMES_DETECTED" | sed 's/^[ \t]*//')
}

discover_containerd() {
    log_info "Discovering containerd..."

    # Version
    version=$(try_command "containerd --version 2>/dev/null | awk '{print \$3}' | sed 's/^v//'")
    [ -z "$version" ] && version=$(try_command "ctr version 2>/dev/null | grep 'Version:' | head -n1 | awk '{print \$2}'")
    [ -z "$version" ] && version=""

    # Socket
    socket="/run/containerd/containerd.sock"
    [ ! -S "$socket" ] && socket=""

    # Storage root
    storage_root="/var/lib/containerd"

    # Namespaces
    namespaces=$(try_privileged_command "ctr namespaces list -q" "")
    if [ -z "$namespaces" ]; then
        # Fallback: check directories
        if [ -d "/var/lib/containerd/io.containerd.grpc.v1.namespaces" ]; then
            namespaces=$(ls /var/lib/containerd/io.containerd.grpc.v1.namespaces 2>/dev/null)
        fi
    fi
    namespaces_json=$(json_build_array "$namespaces" false)

    # Container counts
    container_count=0
    running_count=0

    if [ -n "$namespaces" ]; then
        for ns in $namespaces; do
            ns_containers=$(try_command "ctr -n $ns containers list -q 2>/dev/null | wc -l" || echo "0")
            container_count=$((container_count + ns_containers))

            ns_running=$(try_command "ctr -n $ns tasks list -q 2>/dev/null | wc -l" || echo "0")
            running_count=$((running_count + ns_running))
        done
    fi

    # Fallback to crictl
    if [ "$container_count" -eq 0 ] && command_exists crictl; then
        container_count=$(try_command "crictl ps -a -q 2>/dev/null | wc -l" || echo "0")
        running_count=$(try_command "crictl ps -q 2>/dev/null | wc -l" || echo "0")
    fi

    # Image count
    image_count=0
    if [ -n "$namespaces" ]; then
        for ns in $namespaces; do
            ns_images=$(try_command "ctr -n $ns images list -q 2>/dev/null | wc -l" || echo "0")
            image_count=$((image_count + ns_images))
        done
    fi

    if [ "$image_count" -eq 0 ] && command_exists crictl; then
        image_count=$(try_command "crictl images -q 2>/dev/null | wc -l" || echo "0")
    fi

    # Storage driver
    storage_driver="overlayfs"
    if [ -f /etc/containerd/config.toml ]; then
        snap=$(grep snapshotter /etc/containerd/config.toml 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        [ -n "$snap" ] && storage_driver="$snap"
    fi

    # Cgroup driver
    cgroup_driver="systemd"
    if [ -f /etc/containerd/config.toml ]; then
        systemd_cgroup=$(grep SystemdCgroup /etc/containerd/config.toml 2>/dev/null | head -n1 | awk '{print $3}')
        if [ "$systemd_cgroup" = "false" ]; then
            cgroup_driver="cgroupfs"
        fi
    fi

    # Resource usage
    pid=$(get_pid "containerd")
    cpu_mem=$(get_process_cpu_mem "$pid")
    cpu_cores=$(echo "$cpu_mem" | awk '{print $1}')
    memory_mb=$(echo "$cpu_mem" | awk '{print $2}')

    resource_usage_json=$(json_build_object \
        "cpu_cores" "${cpu_cores:-0}" \
        "memory_mb" "${memory_mb:-0}")

    # Registries
    registries="registry.k8s.io
docker.io"
    registries_json=$(json_build_array "$registries" false)

    # Containers (empty for now to keep script manageable)
    containers_json="[]"
    images_json="[]"

    # Build final JSON
    CONTAINERD_JSON=$(json_build_object \
        "name" "containerd" \
        "runtime_type" "containerd" \
        "version" "$version" \
        "socket" "$socket" \
        "storage_driver" "$storage_driver" \
        "storage_root" "$storage_root" \
        "rootless" "false" \
        "cgroup_driver" "$cgroup_driver" \
        "namespaces" "$namespaces_json" \
        "image_count" "$image_count" \
        "container_count" "$container_count" \
        "running_container_count" "$running_count" \
        "paused_container_count" "0" \
        "stopped_container_count" "$((container_count - running_count))" \
        "client_version" "$version" \
        "server_version" "$version" \
        "crictl_version" "$(try_command 'crictl --version 2>/dev/null | awk \"{print \\\$3}\"')" \
        "resource_usage" "$resource_usage_json" \
        "registries" "$registries_json" \
        "containers" "$containers_json" \
        "images" "$images_json")

    log_info "containerd discovery completed: $container_count containers, $running_count running"
}

discover_docker() {
    log_info "Discovering Docker..."

    # Version
    version=$(try_command "docker version --format '{{.Server.Version}}' 2>/dev/null")
    [ -z "$version" ] && version=$(try_command "dockerd --version 2>/dev/null | awk '{print \$3}' | tr -d ','")
    [ -z "$version" ] && version=""

    # Socket
    socket="/var/run/docker.sock"
    [ ! -S "$socket" ] && socket=""

    # Storage root
    storage_root="/var/lib/docker"

    # Try docker info
    container_count=0
    running_count=0
    image_count=0
    storage_driver="overlay2"
    cgroup_driver="cgroupfs"

    docker_info=$(try_privileged_command "docker info --format json" "")

    if [ -n "$docker_info" ]; then
        container_count=$(echo "$docker_info" | grep -o '"Containers":[0-9]*' | cut -d: -f2 | head -n1)
        running_count=$(echo "$docker_info" | grep -o '"ContainersRunning":[0-9]*' | cut -d: -f2 | head -n1)
        stopped_count=$(echo "$docker_info" | grep -o '"ContainersStopped":[0-9]*' | cut -d: -f2 | head -n1)
        paused_count=$(echo "$docker_info" | grep -o '"ContainersPaused":[0-9]*' | cut -d: -f2 | head -n1)
        image_count=$(echo "$docker_info" | grep -o '"Images":[0-9]*' | cut -d: -f2 | head -n1)
        storage_driver=$(echo "$docker_info" | grep -o '"Driver":"[^"]*"' | cut -d\" -f4 | head -n1)
        cgroup_driver=$(echo "$docker_info" | grep -o '"CgroupDriver":"[^"]*"' | cut -d\" -f4 | head -n1)
    fi

    # Fallback to docker ps
    if [ "$container_count" = "0" ] || [ -z "$container_count" ]; then
        container_count=$(try_command "docker ps -aq 2>/dev/null | wc -l" || echo "0")
        running_count=$(try_command "docker ps -q 2>/dev/null | wc -l" || echo "0")
    fi

    if [ "$image_count" = "0" ] || [ -z "$image_count" ]; then
        image_count=$(try_command "docker images -q 2>/dev/null | wc -l" || echo "0")
    fi

    # Defaults
    [ -z "$container_count" ] && container_count=0
    [ -z "$running_count" ] && running_count=0
    [ -z "$stopped_count" ] && stopped_count=0
    [ -z "$paused_count" ] && paused_count=0
    [ -z "$image_count" ] && image_count=0
    [ -z "$storage_driver" ] && storage_driver="overlay2"
    [ -z "$cgroup_driver" ] && cgroup_driver="cgroupfs"

    # Resource usage
    pid=$(get_pid "dockerd")
    cpu_mem=$(get_process_cpu_mem "$pid")
    cpu_cores=$(echo "$cpu_mem" | awk '{print $1}')
    memory_mb=$(echo "$cpu_mem" | awk '{print $2}')

    resource_usage_json=$(json_build_object \
        "cpu_cores" "${cpu_cores:-0}" \
        "memory_mb" "${memory_mb:-0}")

    # Registries
    registries="docker.io"
    registries_json=$(json_build_array "$registries" false)

    # Containers and images (empty for now)
    containers_json="[]"
    images_json="[]"

    # Build final JSON
    DOCKER_JSON=$(json_build_object \
        "name" "docker" \
        "runtime_type" "docker" \
        "version" "$version" \
        "socket" "$socket" \
        "storage_driver" "$storage_driver" \
        "storage_root" "$storage_root" \
        "rootless" "false" \
        "cgroup_driver" "$cgroup_driver" \
        "namespaces" "[]" \
        "image_count" "$image_count" \
        "container_count" "$container_count" \
        "running_container_count" "$running_count" \
        "paused_container_count" "$paused_count" \
        "stopped_container_count" "$stopped_count" \
        "client_version" "$version" \
        "server_version" "$version" \
        "crictl_version" "" \
        "resource_usage" "$resource_usage_json" \
        "registries" "$registries_json" \
        "containers" "$containers_json" \
        "images" "$images_json")

    log_info "Docker discovery completed: $container_count containers, $running_count running"
}

discover_crio() {
    log_info "Discovering CRI-O..."

    # Version
    version=$(try_command "crio --version 2>/dev/null | head -n1 | awk '{print \$3}'")
    [ -z "$version" ] && version=$(try_command "crictl version 2>/dev/null | grep 'RuntimeVersion' | awk '{print \$2}'")
    [ -z "$version" ] && version=""

    # Socket
    socket="/var/run/crio/crio.sock"
    [ ! -S "$socket" ] && socket=""

    # Storage root
    storage_root="/var/lib/containers/storage"

    # Container counts
    container_count=$(try_command "crictl ps -a -q 2>/dev/null | wc -l" || echo "0")
    running_count=$(try_command "crictl ps -q 2>/dev/null | wc -l" || echo "0")

    # Image count
    image_count=$(try_command "crictl images -q 2>/dev/null | wc -l" || echo "0")

    # Storage driver
    storage_driver="overlay"
    if [ -f /etc/crio/crio.conf ]; then
        driver=$(grep storage_driver /etc/crio/crio.conf 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        [ -n "$driver" ] && storage_driver="$driver"
    fi

    # Cgroup driver
    cgroup_driver="systemd"
    if [ -f /etc/crio/crio.conf ]; then
        cgm=$(grep cgroup_manager /etc/crio/crio.conf 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        [ -n "$cgm" ] && cgroup_driver="$cgm"
    fi

    # Resource usage
    pid=$(get_pid "crio")
    cpu_mem=$(get_process_cpu_mem "$pid")
    cpu_cores=$(echo "$cpu_mem" | awk '{print $1}')
    memory_mb=$(echo "$cpu_mem" | awk '{print $2}')

    resource_usage_json=$(json_build_object \
        "cpu_cores" "${cpu_cores:-0}" \
        "memory_mb" "${memory_mb:-0}")

    # Registries
    registries="registry.access.redhat.com
registry.redhat.io
quay.io
docker.io"
    registries_json=$(json_build_array "$registries" false)

    # Namespaces (CRI-O uses k8s.io)
    namespaces="k8s.io"
    namespaces_json=$(json_build_array "$namespaces" false)

    # Containers and images
    containers_json="[]"
    images_json="[]"

    # Build final JSON
    CRIO_JSON=$(json_build_object \
        "name" "crio" \
        "runtime_type" "crio" \
        "version" "$version" \
        "socket" "$socket" \
        "storage_driver" "$storage_driver" \
        "storage_root" "$storage_root" \
        "rootless" "false" \
        "cgroup_driver" "$cgroup_driver" \
        "namespaces" "$namespaces_json" \
        "image_count" "$image_count" \
        "container_count" "$container_count" \
        "running_container_count" "$running_count" \
        "paused_container_count" "0" \
        "stopped_container_count" "$((container_count - running_count))" \
        "client_version" "$version" \
        "server_version" "$version" \
        "crictl_version" "$(try_command 'crictl --version 2>/dev/null | awk \"{print \\\$3}\"')" \
        "resource_usage" "$resource_usage_json" \
        "registries" "$registries_json" \
        "containers" "$containers_json" \
        "images" "$images_json")

    log_info "CRI-O discovery completed: $container_count containers, $running_count running"
}

discover_podman() {
    log_info "Discovering Podman..."

    # Version
    version=$(try_command "podman version --format '{{.Server.Version}}' 2>/dev/null")
    [ -z "$version" ] && version=$(try_command "podman --version 2>/dev/null | awk '{print \$3}'")
    [ -z "$version" ] && version=""

    # Rootless detection
    rootless="false"
    current_uid=$(id -u)
    if [ "$current_uid" != "0" ]; then
        # Check if podman is running in rootless mode
        if command_exists podman; then
            rootless_check=$(try_command "podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null")
            [ "$rootless_check" = "true" ] && rootless="true"
        fi
    fi

    # Socket
    if [ "$rootless" = "true" ]; then
        socket="/run/user/$current_uid/podman/podman.sock"
    else
        socket="/run/podman/podman.sock"
    fi
    [ ! -S "$socket" ] && socket=""

    # Storage root
    if [ "$rootless" = "true" ]; then
        storage_root="$HOME/.local/share/containers/storage"
    else
        storage_root="/var/lib/containers/storage"
    fi

    # Container counts
    container_count=$(try_command "podman ps -a -q 2>/dev/null | wc -l" || echo "0")
    running_count=$(try_command "podman ps -q 2>/dev/null | wc -l" || echo "0")

    # Image count
    image_count=$(try_command "podman images -q 2>/dev/null | wc -l" || echo "0")

    # Storage driver
    storage_driver=$(try_command "podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null")
    [ -z "$storage_driver" ] && storage_driver="overlay"

    # Cgroup driver
    cgroup_driver="systemd"

    # Resource usage
    pid=$(get_pid "podman")
    cpu_mem=$(get_process_cpu_mem "$pid")
    cpu_cores=$(echo "$cpu_mem" | awk '{print $1}')
    memory_mb=$(echo "$cpu_mem" | awk '{print $2}')

    resource_usage_json=$(json_build_object \
        "cpu_cores" "${cpu_cores:-0}" \
        "memory_mb" "${memory_mb:-0}")

    # Registries
    registries="registry.access.redhat.com
registry.redhat.io
docker.io
quay.io"
    registries_json=$(json_build_array "$registries" false)

    # Containers and images
    containers_json="[]"
    images_json="[]"

    # Build final JSON
    PODMAN_JSON=$(json_build_object \
        "name" "podman" \
        "runtime_type" "podman" \
        "version" "$version" \
        "socket" "$socket" \
        "storage_driver" "$storage_driver" \
        "storage_root" "$storage_root" \
        "rootless" "$rootless" \
        "cgroup_driver" "$cgroup_driver" \
        "namespaces" "[]" \
        "image_count" "$image_count" \
        "container_count" "$container_count" \
        "running_container_count" "$running_count" \
        "paused_container_count" "0" \
        "stopped_container_count" "$((container_count - running_count))" \
        "client_version" "$version" \
        "server_version" "$version" \
        "crictl_version" "" \
        "resource_usage" "$resource_usage_json" \
        "registries" "$registries_json" \
        "containers" "$containers_json" \
        "images" "$images_json")

    log_info "Podman discovery completed: $container_count containers, $running_count running (rootless: $rootless)"
}

#==============================================================================
# Orchestrator Detection and Discovery
#==============================================================================

detect_orchestrators() {
    log_info "Detecting orchestrators..."

    ORCHESTRATORS_DETECTED=""

    # Check for Docker Swarm
    if echo "$RUNTIMES_DETECTED" | grep -q "docker"; then
        swarm_state=$(try_command "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null")
        if [ "$swarm_state" = "active" ]; then
            ORCHESTRATORS_DETECTED="$ORCHESTRATORS_DETECTED docker-swarm"
            log_info "Docker Swarm detected"
            discover_docker_swarm
        fi
    fi

    # Check for Kubernetes
    if command_exists kubectl || command_exists kubelet || [ -d /etc/kubernetes ]; then
        if try_command "kubectl cluster-info 2>/dev/null" >/dev/null 2>&1 || systemctl is-active kubelet >/dev/null 2>&1; then
            ORCHESTRATORS_DETECTED="$ORCHESTRATORS_DETECTED kubernetes"
            log_info "Kubernetes detected"
            discover_kubernetes
        fi
    fi

    # Check for OpenShift
    if command_exists oc || (command_exists kubectl && try_command "kubectl get clusterversion 2>/dev/null" >/dev/null 2>&1); then
        ORCHESTRATORS_DETECTED="$ORCHESTRATORS_DETECTED openshift"
        log_info "OpenShift detected"
        discover_openshift
    fi

    # Check for Tanzu
    if command_exists tanzu || (command_exists kubectl && try_command "kubectl get tkr 2>/dev/null" >/dev/null 2>&1); then
        ORCHESTRATORS_DETECTED="$ORCHESTRATORS_DETECTED tanzu"
        log_info "Tanzu detected"
        discover_tanzu
    fi

    ORCHESTRATORS_DETECTED=$(echo "$ORCHESTRATORS_DETECTED" | sed 's/^[ \t]*//')
}

discover_docker_swarm() {
    log_info "Discovering Docker Swarm..."

    # Swarm state
    swarm_state=$(try_command "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null" || echo "inactive")

    # Cluster ID - with multiple fallbacks
    cluster_id=$(try_command "docker info --format '{{.Swarm.Cluster.ID}}' 2>/dev/null")
    if [ -z "$cluster_id" ]; then
        # Fallback: try using socket API
        cluster_id=$(try_privileged_command "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | grep -o '\"ClusterID\":\"[^\"]*\"' | cut -d'\"' -f4" "")
    fi
    if [ -z "$cluster_id" ]; then
        # Fallback: try docker swarm info
        cluster_id=$(try_command "docker system info 2>/dev/null | grep 'Cluster ID' | awk '{print \$3}'" || echo "")
    fi
    # Filter out error messages that might have been captured
    case "$cluster_id" in
        *"error"*|*"Error"*|*"ERROR"*|*"failed"*|*"refused"*|*"debug"*)
            cluster_id=""
            ;;
    esac
    [ -z "$cluster_id" ] && cluster_id=""

    # Cluster name - try to get from node labels or hostname
    cluster_name=$(try_command "docker info --format '{{.Name}}' 2>/dev/null")
    if [ -z "$cluster_name" ]; then
        # Fallback: use hostname as cluster identifier
        cluster_name=$(hostname 2>/dev/null || echo "")
    fi
    [ -z "$cluster_name" ] && cluster_name=""

    # Node role
    is_manager=$(try_command "docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null")
    if [ "$is_manager" = "true" ]; then
        node_role="manager"
    else
        node_role="worker"
    fi

    # Current node
    node_id=$(try_command "docker info --format '{{.Swarm.NodeID}}' 2>/dev/null" || echo "")

    current_node_json=$(json_build_object \
        "node_id" "$node_id" \
        "role" "$node_role" \
        "availability" "active")

    # Node counts
    total_count=0
    master_count=0
    worker_count=0

    if [ "$node_role" = "manager" ]; then
        total_count=$(try_command "docker node ls -q 2>/dev/null | wc -l" || echo "0")
        master_count=$(try_command "docker node ls --filter role=manager -q 2>/dev/null | wc -l" || echo "0")
        worker_count=$((total_count - master_count))
    fi

    nodes_json=$(json_build_object \
        "total_count" "$total_count" \
        "master_count" "$master_count" \
        "worker_count" "$worker_count" \
        "master_nodes" "[]" \
        "worker_nodes" "[]")

    # Service count
    service_count=0
    if [ "$node_role" = "manager" ]; then
        service_count=$(try_command "docker service ls -q 2>/dev/null | wc -l" || echo "0")
    fi

    # Workloads
    workloads_json=$(json_build_object \
        "total_container_count" "0" \
        "system_container_count" "0" \
        "user_container_count" "0" \
        "pod_count" "0" \
        "service_count" "$service_count" \
        "deployment_count" "0" \
        "daemonset_count" "0" \
        "statefulset_count" "0" \
        "namespace_count" "0" \
        "namespaces" "[]")

    # Cluster components
    cluster_components_json=$(json_build_object \
        "api_server" "$(json_build_object 'version' '' 'status' '')" \
        "coredns" "$(json_build_object 'version' '' 'status' '')" \
        "ingress_controller" "$(json_build_object 'type' '' 'version' '')" \
        "cni_plugin" "$(json_build_object 'type' 'overlay' 'version' '')" \
        "csi_drivers" "[]")

    # Platform specific
    raft_index=$(try_command "docker info --format '{{.Swarm.Cluster.RaftIndex}}' 2>/dev/null" || echo "0")

    swarm_specific=$(json_build_object \
        "raft_index" "$raft_index" \
        "task_history_limit" "5")

    platform_specific_json=$(json_build_object \
        "swarm" "$swarm_specific" \
        "kubernetes" "null" \
        "openshift" "null" \
        "tanzu" "null")

    # Get Docker version for Swarm
    swarm_version=$(try_command "docker version --format '{{.Server.Version}}' 2>/dev/null")
    [ -z "$swarm_version" ] && swarm_version=""

    # Resource usage - get from dockerd process
    swarm_cpu=0
    swarm_mem=0
    dockerd_pid=$(get_pid "dockerd")
    if [ -n "$dockerd_pid" ] && [ "$dockerd_pid" != "0" ]; then
        cpu_mem=$(get_process_cpu_mem "$dockerd_pid")
        swarm_cpu=$(echo "$cpu_mem" | awk '{print $1}')
        swarm_mem=$(echo "$cpu_mem" | awk '{print $2}')
    fi

    # Format with 2 decimal places
    swarm_cpu=$(printf "%.2f" "$swarm_cpu" 2>/dev/null || echo "0")
    swarm_mem=$(printf "%.2f" "$swarm_mem" 2>/dev/null || echo "0")

    resource_usage_json=$(json_build_object \
        "cpu_cores" "$swarm_cpu" \
        "memory_mb" "$swarm_mem")

    # Build final JSON
    SWARM_JSON=$(json_build_object \
        "name" "docker_swarm" \
        "orchestrator_type" "docker-swarm" \
        "version" "$swarm_version" \
        "cluster_id" "$cluster_id" \
        "cluster_name" "$cluster_name" \
        "state" "$swarm_state" \
        "current_node" "$current_node_json" \
        "nodes" "$nodes_json" \
        "workloads" "$workloads_json" \
        "cluster_components" "$cluster_components_json" \
        "platform_specific" "$platform_specific_json" \
        "resource_usage" "$resource_usage_json")

    log_info "Docker Swarm discovery completed"
}

discover_kubernetes() {
    log_info "Discovering Kubernetes..."

    # Version
    version=$(try_command "kubectl version --short 2>/dev/null | grep Server | awk '{print \$3}'")
    [ -z "$version" ] && version=$(try_command "kubelet --version 2>/dev/null | awk '{print \$2}'")
    [ -z "$version" ] && version=""

    # Cluster ID - with multiple fallbacks
    cluster_id=$(try_command "kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null")
    if [ -z "$cluster_id" ]; then
        # Fallback: try to get from kubeadm config
        cluster_id=$(try_privileged_command "cat /etc/kubernetes/admin.conf 2>/dev/null | grep cluster: | head -n1 | awk '{print \$2}'" "")
    fi
    if [ -z "$cluster_id" ]; then
        # Fallback: try to get from kubelet config
        cluster_id=$(try_command "cat /var/lib/kubelet/kubeadm-flags.env 2>/dev/null | grep -o 'cluster-name=[^ ]*' | cut -d= -f2" || echo "")
    fi
    if [ -z "$cluster_id" ]; then
        # Fallback: check for k3s
        if [ -d /var/lib/rancher/k3s ]; then
            cluster_id=$(try_command "cat /var/lib/rancher/k3s/server/cred/cluster-id 2>/dev/null" || echo "")
        fi
    fi
    # Filter out kubectl error messages that might have been captured
    case "$cluster_id" in
        *"To further debug"*|*"cluster-info dump"*|*"connection"*"refused"*)
            cluster_id=""
            ;;
    esac
    [ -z "$cluster_id" ] && cluster_id=""

    # Cluster name - with multiple fallbacks
    cluster_name=$(try_command "kubectl config current-context 2>/dev/null")
    if [ -z "$cluster_name" ]; then
        # Fallback: try to get from kubeconfig
        cluster_name=$(try_command "kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null" || echo "")
    fi
    if [ -z "$cluster_name" ]; then
        # Fallback: try to get from kubelet config
        cluster_name=$(try_command "cat /var/lib/kubelet/kubeadm-flags.env 2>/dev/null | grep -o 'cluster-name=[^ ]*' | cut -d= -f2" || echo "")
    fi
    if [ -z "$cluster_name" ]; then
        # Fallback: check hostname or domain
        cluster_name=$(try_command "hostname -d 2>/dev/null | cut -d. -f1" || echo "")
    fi
    [ -z "$cluster_name" ] && cluster_name=""

    # State
    state="active"

    # Current node
    node_name=$(hostname)
    node_role="worker"
    node_status="Unknown"

    if command_exists kubectl; then
        node_labels=$(try_command "kubectl get node $node_name -o jsonpath='{.metadata.labels}' 2>/dev/null")
        if echo "$node_labels" | grep -q "node-role.kubernetes.io/control-plane"; then
            node_role="control-plane"
        elif echo "$node_labels" | grep -q "node-role.kubernetes.io/master"; then
            node_role="control-plane"
        fi

        node_status=$(try_command "kubectl get node $node_name -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null" || echo "Unknown")
        [ "$node_status" = "True" ] && node_status="Ready"
    fi

    current_node_json=$(json_build_object \
        "node_id" "$node_name" \
        "role" "$node_role" \
        "availability" "$node_status")

    # Node counts
    total_count=$(try_command "kubectl get nodes --no-headers 2>/dev/null | wc -l" || echo "0")
    master_count=$(try_command "kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l" || echo "0")
    [ "$master_count" = "0" ] && master_count=$(try_command "kubectl get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l" || echo "0")
    worker_count=$((total_count - master_count))

    nodes_json=$(json_build_object \
        "total_count" "$total_count" \
        "master_count" "$master_count" \
        "worker_count" "$worker_count" \
        "master_nodes" "[]" \
        "worker_nodes" "[]")

    # Workload counts
    pod_count=$(try_command "kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    service_count=$(try_command "kubectl get services --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    deployment_count=$(try_command "kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    daemonset_count=$(try_command "kubectl get daemonsets --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    statefulset_count=$(try_command "kubectl get statefulsets --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    namespace_count=$(try_command "kubectl get namespaces --no-headers 2>/dev/null | wc -l" || echo "0")

    namespaces=$(try_command "kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" | tr ' ' '\n')
    namespaces_json=$(json_build_array "$namespaces" false)

    workloads_json=$(json_build_object \
        "total_container_count" "0" \
        "system_container_count" "0" \
        "user_container_count" "0" \
        "pod_count" "$pod_count" \
        "service_count" "$service_count" \
        "deployment_count" "$deployment_count" \
        "daemonset_count" "$daemonset_count" \
        "statefulset_count" "$statefulset_count" \
        "namespace_count" "$namespace_count" \
        "namespaces" "$namespaces_json")

    # Detect distribution
    distribution="kubeadm"
    if [ -d /var/lib/rancher/k3s ]; then
        distribution="k3s"
    elif [ -d /var/lib/rancher/rke2 ]; then
        distribution="rke2"
    elif command_exists microk8s; then
        distribution="microk8s"
    elif [ -f /kind-version ]; then
        distribution="kind"
    fi

    # CNI detection
    cni_plugin="unknown"
    if command_exists kubectl; then
        if try_command "kubectl get pods -n kube-system 2>/dev/null | grep -q calico"; then
            cni_plugin="calico"
        elif try_command "kubectl get pods -n kube-system 2>/dev/null | grep -q flannel"; then
            cni_plugin="flannel"
        elif try_command "kubectl get pods -n kube-system 2>/dev/null | grep -q cilium"; then
            cni_plugin="cilium"
        elif try_command "kubectl get pods -n kube-system 2>/dev/null | grep -q weave"; then
            cni_plugin="weave"
        elif [ -d /etc/cni/net.d ]; then
            cni_conf=$(ls /etc/cni/net.d/*.conf 2>/dev/null | head -n1)
            if [ -n "$cni_conf" ]; then
                cni_plugin=$(basename "$cni_conf" .conf)
            fi
        fi
    fi

    # Cluster components
    api_server_json=$(json_build_object "version" "$version" "status" "Healthy")
    coredns_json=$(json_build_object "version" "" "status" "Running")
    ingress_json=$(json_build_object "type" "none" "version" "")
    cni_json=$(json_build_object "type" "$cni_plugin" "version" "")

    cluster_components_json=$(json_build_object \
        "api_server" "$api_server_json" \
        "coredns" "$coredns_json" \
        "ingress_controller" "$ingress_json" \
        "cni_plugin" "$cni_json" \
        "csi_drivers" "[]")

    # Platform specific
    api_endpoint=$(try_command "kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null" || echo "")

    # Detect cluster CIDR - try multiple sources
    cluster_cidr=""
    # Method 1: From kube-controller-manager pod
    if [ -z "$cluster_cidr" ]; then
        cluster_cidr=$(try_command "kubectl get pods -n kube-system -l component=kube-controller-manager -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null | grep -o 'cluster-cidr=[^ ]*' | cut -d= -f2" || echo "")
    fi
    # Method 2: From kube-proxy configmap
    if [ -z "$cluster_cidr" ]; then
        cluster_cidr=$(try_command "kubectl get configmap kube-proxy -n kube-system -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -o 'clusterCIDR: .*' | awk '{print \$2}'" || echo "")
    fi
    # Method 3: From kubeadm config
    if [ -z "$cluster_cidr" ]; then
        cluster_cidr=$(try_privileged_command "grep -r 'podSubnet' /etc/kubernetes/manifests/ 2>/dev/null | grep -o 'podSubnet: .*' | awk '{print \$2}' | head -n1" "")
    fi
    # Method 4: From kube-controller-manager manifest
    if [ -z "$cluster_cidr" ]; then
        cluster_cidr=$(try_privileged_command "grep -o 'cluster-cidr=[^ ]*' /etc/kubernetes/manifests/kube-controller-manager.yaml 2>/dev/null | cut -d= -f2" "")
    fi
    # Method 5: For k3s
    if [ -z "$cluster_cidr" ] && [ -d /var/lib/rancher/k3s ]; then
        cluster_cidr=$(try_privileged_command "grep -o 'cluster-cidr=[^ ]*' /etc/systemd/system/k3s.service 2>/dev/null | cut -d= -f2" "")
    fi

    # Detect service CIDR - try multiple sources
    service_cidr=""
    # Method 1: From kube-apiserver pod
    if [ -z "$service_cidr" ]; then
        service_cidr=$(try_command "kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null | grep -o 'service-cluster-ip-range=[^ ]*' | cut -d= -f2" || echo "")
    fi
    # Method 2: From kube-apiserver manifest
    if [ -z "$service_cidr" ]; then
        service_cidr=$(try_privileged_command "grep -o 'service-cluster-ip-range=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null | cut -d= -f2" "")
    fi
    # Method 3: From kubeadm config
    if [ -z "$service_cidr" ]; then
        service_cidr=$(try_privileged_command "grep -r 'serviceSubnet' /etc/kubernetes/ 2>/dev/null | grep -o 'serviceSubnet: .*' | awk '{print \$2}' | head -n1" "")
    fi
    # Method 4: For k3s
    if [ -z "$service_cidr" ] && [ -d /var/lib/rancher/k3s ]; then
        service_cidr=$(try_privileged_command "grep -o 'service-cidr=[^ ]*' /etc/systemd/system/k3s.service 2>/dev/null | cut -d= -f2" "")
    fi

    # Detect kubeconfig path dynamically
    kubeconfig_path=""
    # Method 1: From environment variable
    if [ -n "$KUBECONFIG" ]; then
        kubeconfig_path="$KUBECONFIG"
    # Method 2: Standard locations
    elif [ -f "/etc/kubernetes/admin.conf" ]; then
        kubeconfig_path="/etc/kubernetes/admin.conf"
    elif [ -f "$HOME/.kube/config" ]; then
        kubeconfig_path="$HOME/.kube/config"
    elif [ -f "/var/lib/rancher/k3s/server/cred/admin.kubeconfig" ]; then
        kubeconfig_path="/var/lib/rancher/k3s/server/cred/admin.kubeconfig"
    elif [ -f "/var/lib/rancher/rke2/server/cred/admin.kubeconfig" ]; then
        kubeconfig_path="/var/lib/rancher/rke2/server/cred/admin.kubeconfig"
    else
        kubeconfig_path=""
    fi

    k8s_specific=$(json_build_object \
        "distribution" "$distribution" \
        "api_server_endpoint" "$api_endpoint" \
        "cluster_cidr" "$cluster_cidr" \
        "service_cidr" "$service_cidr" \
        "kubeconfig_path" "$kubeconfig_path")

    platform_specific_json=$(json_build_object \
        "swarm" "null" \
        "kubernetes" "$k8s_specific" \
        "openshift" "null" \
        "tanzu" "null")

    # Resource usage - calculate from running components
    k8s_cpu_total=0
    k8s_mem_total=0

    # Try to get resource usage from kubelet and kube-proxy
    if command_exists pgrep; then
        for proc_name in kubelet kube-proxy kube-apiserver kube-controller kube-scheduler etcd; do
            pid=$(get_pid "$proc_name")
            if [ -n "$pid" ] && [ "$pid" != "0" ]; then
                cpu_mem=$(get_process_cpu_mem "$pid")
                proc_cpu=$(echo "$cpu_mem" | awk '{print $1}')
                proc_mem=$(echo "$cpu_mem" | awk '{print $2}')

                # Add to totals (handle decimal addition)
                if [ -n "$proc_cpu" ] && [ "$proc_cpu" != "0.0" ]; then
                    k8s_cpu_total=$(echo "$k8s_cpu_total + $proc_cpu" | bc 2>/dev/null || echo "$k8s_cpu_total")
                fi
                if [ -n "$proc_mem" ] && [ "$proc_mem" != "0.0" ]; then
                    k8s_mem_total=$(echo "$k8s_mem_total + $proc_mem" | bc 2>/dev/null || echo "$k8s_mem_total")
                fi
            fi
        done
    fi

    # Format with 2 decimal places
    k8s_cpu_total=$(printf "%.2f" "$k8s_cpu_total" 2>/dev/null || echo "0")
    k8s_mem_total=$(printf "%.2f" "$k8s_mem_total" 2>/dev/null || echo "0")

    resource_usage_json=$(json_build_object \
        "cpu_cores" "$k8s_cpu_total" \
        "memory_mb" "$k8s_mem_total")

    # Build final JSON
    K8S_JSON=$(json_build_object \
        "name" "kubernetes" \
        "orchestrator_type" "kubernetes" \
        "version" "$version" \
        "cluster_id" "$cluster_id" \
        "cluster_name" "$cluster_name" \
        "state" "$state" \
        "current_node" "$current_node_json" \
        "nodes" "$nodes_json" \
        "workloads" "$workloads_json" \
        "cluster_components" "$cluster_components_json" \
        "platform_specific" "$platform_specific_json" \
        "resource_usage" "$resource_usage_json")

    log_info "Kubernetes discovery completed: $pod_count pods, $total_count nodes"
}

discover_openshift() {
    log_info "Discovering OpenShift..."

    # Version
    ocp_version=$(try_command "oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null")
    [ -z "$ocp_version" ] && ocp_version=$(try_command "kubectl get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null")
    [ -z "$ocp_version" ] && ocp_version=""

    # Cluster ID - with multiple fallbacks
    cluster_id=$(try_command "oc get clusterversion -o jsonpath='{.items[0].spec.clusterID}' 2>/dev/null")
    if [ -z "$cluster_id" ]; then
        # Fallback: try to get from namespace
        cluster_id=$(try_command "kubectl get ns openshift-apiserver -o jsonpath='{.metadata.uid}' 2>/dev/null" || echo "")
    fi
    # Filter out error messages that might have been captured
    case "$cluster_id" in
        *"error"*|*"Error"*|*"ERROR"*|*"failed"*|*"refused"*|*"debug"*|*"To further debug"*|*"cluster-info dump"*|*"connection"*"refused"*)
            cluster_id=""
            ;;
    esac
    [ -z "$cluster_id" ] && cluster_id=""

    # Cluster name - with multiple fallbacks
    cluster_name=$(try_command "oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null")
    if [ -z "$cluster_name" ]; then
        # Fallback: try current context
        cluster_name=$(try_command "oc config current-context 2>/dev/null" || echo "")
    fi
    if [ -z "$cluster_name" ]; then
        # Fallback: use hostname
        cluster_name=$(hostname 2>/dev/null || echo "")
    fi
    [ -z "$cluster_name" ] && cluster_name=""

    # Resource usage - get from OpenShift control plane processes
    ocp_cpu_total=0
    ocp_mem_total=0

    if command_exists pgrep; then
        for proc_name in openshift-apiserver openshift-controller hyperkube oc; do
            pid=$(get_pid "$proc_name")
            if [ -n "$pid" ] && [ "$pid" != "0" ]; then
                cpu_mem=$(get_process_cpu_mem "$pid")
                proc_cpu=$(echo "$cpu_mem" | awk '{print $1}')
                proc_mem=$(echo "$cpu_mem" | awk '{print $2}')

                if [ -n "$proc_cpu" ] && [ "$proc_cpu" != "0.0" ]; then
                    ocp_cpu_total=$(echo "$ocp_cpu_total + $proc_cpu" | bc 2>/dev/null || echo "$ocp_cpu_total")
                fi
                if [ -n "$proc_mem" ] && [ "$proc_mem" != "0.0" ]; then
                    ocp_mem_total=$(echo "$ocp_mem_total + $proc_mem" | bc 2>/dev/null || echo "$ocp_mem_total")
                fi
            fi
        done
    fi

    # Format with 2 decimal places
    ocp_cpu_total=$(printf "%.2f" "$ocp_cpu_total" 2>/dev/null || echo "0")
    ocp_mem_total=$(printf "%.2f" "$ocp_mem_total" 2>/dev/null || echo "0")

    OPENSHIFT_JSON=$(json_build_object \
        "name" "openshift" \
        "orchestrator_type" "openshift" \
        "version" "$ocp_version" \
        "cluster_id" "$cluster_id" \
        "cluster_name" "$cluster_name" \
        "state" "active" \
        "current_node" "$(json_build_object 'node_id' '' 'role' 'worker' 'availability' 'Ready')" \
        "nodes" "$(json_build_object 'total_count' '0' 'master_count' '0' 'worker_count' '0' 'master_nodes' '[]' 'worker_nodes' '[]')" \
        "workloads" "$(json_build_object 'total_container_count' '0' 'system_container_count' '0' 'user_container_count' '0' 'pod_count' '0' 'service_count' '0' 'deployment_count' '0' 'daemonset_count' '0' 'statefulset_count' '0' 'namespace_count' '0' 'namespaces' '[]')" \
        "cluster_components" "$(json_build_object 'api_server' '$(json_build_object \"version\" \"\" \"status\" \"\")' 'coredns' '$(json_build_object \"version\" \"\" \"status\" \"\")' 'ingress_controller' '$(json_build_object \"type\" \"\" \"version\" \"\")' 'cni_plugin' '$(json_build_object \"type\" \"\" \"version\" \"\")' 'csi_drivers' '[]')" \
        "platform_specific" "$(json_build_object 'swarm' 'null' 'kubernetes' 'null' 'openshift' '$(json_build_object \"ocp_version\" \"$ocp_version\" \"channel\" \"\" \"cluster_id\" \"\" \"infra_id\" \"\" \"install_type\" \"\" \"project_count\" \"0\" \"route_count\" \"0\" \"build_config_count\" \"0\" \"operator_count\" \"0\" \"operator_hub_enabled\" \"false\" \"scc_count\" \"0\" \"cluster_operators_degraded\" \"0\" \"cluster_operators_available\" \"0\")' 'tanzu' 'null')" \
        "resource_usage" "$(json_build_object 'cpu_cores' '$ocp_cpu_total' 'memory_mb' '$ocp_mem_total')")

    log_info "OpenShift discovery completed"
}

discover_tanzu() {
    log_info "Discovering Tanzu..."

    # Version
    tkg_version=$(try_command "tanzu version 2>/dev/null | grep version | awk '{print \$2}'")
    [ -z "$tkg_version" ] && tkg_version=""

    # Cluster ID - with multiple fallbacks
    cluster_id=$(try_command "kubectl get cluster -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null")
    if [ -z "$cluster_id" ]; then
        # Fallback: try to get from namespace
        cluster_id=$(try_command "kubectl get ns tkg-system -o jsonpath='{.metadata.uid}' 2>/dev/null" || echo "")
    fi
    # Filter out error messages that might have been captured
    case "$cluster_id" in
        *"error"*|*"Error"*|*"ERROR"*|*"failed"*|*"refused"*|*"debug"*|*"To further debug"*|*"cluster-info dump"*|*"connection"*"refused"*)
            cluster_id=""
            ;;
    esac
    [ -z "$cluster_id" ] && cluster_id=""

    # Cluster name - with multiple fallbacks
    cluster_name=$(try_command "kubectl get cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null")
    if [ -z "$cluster_name" ]; then
        # Fallback: try current context
        cluster_name=$(try_command "kubectl config current-context 2>/dev/null" || echo "")
    fi
    if [ -z "$cluster_name" ]; then
        # Fallback: check for tanzu config
        cluster_name=$(try_command "tanzu cluster list -o json 2>/dev/null | grep -o '\"name\":\"[^\"]*\"' | head -n1 | cut -d'\"' -f4" || echo "")
    fi
    [ -z "$cluster_name" ] && cluster_name=""

    # Resource usage - get from Tanzu control plane processes
    tanzu_cpu_total=0
    tanzu_mem_total=0

    if command_exists pgrep; then
        for proc_name in tanzu kapp-controller; do
            pid=$(get_pid "$proc_name")
            if [ -n "$pid" ] && [ "$pid" != "0" ]; then
                cpu_mem=$(get_process_cpu_mem "$pid")
                proc_cpu=$(echo "$cpu_mem" | awk '{print $1}')
                proc_mem=$(echo "$cpu_mem" | awk '{print $2}')

                if [ -n "$proc_cpu" ] && [ "$proc_cpu" != "0.0" ]; then
                    tanzu_cpu_total=$(echo "$tanzu_cpu_total + $proc_cpu" | bc 2>/dev/null || echo "$tanzu_cpu_total")
                fi
                if [ -n "$proc_mem" ] && [ "$proc_mem" != "0.0" ]; then
                    tanzu_mem_total=$(echo "$tanzu_mem_total + $proc_mem" | bc 2>/dev/null || echo "$tanzu_mem_total")
                fi
            fi
        done
    fi

    # Format with 2 decimal places
    tanzu_cpu_total=$(printf "%.2f" "$tanzu_cpu_total" 2>/dev/null || echo "0")
    tanzu_mem_total=$(printf "%.2f" "$tanzu_mem_total" 2>/dev/null || echo "0")

    TANZU_JSON=$(json_build_object \
        "name" "tanzu" \
        "orchestrator_type" "tanzu" \
        "version" "$tkg_version" \
        "cluster_id" "$cluster_id" \
        "cluster_name" "$cluster_name" \
        "state" "active" \
        "current_node" "$(json_build_object 'node_id' '' 'role' 'worker' 'availability' 'Ready')" \
        "nodes" "$(json_build_object 'total_count' '0' 'master_count' '0' 'worker_count' '0' 'master_nodes' '[]' 'worker_nodes' '[]')" \
        "workloads" "$(json_build_object 'total_container_count' '0' 'system_container_count' '0' 'user_container_count' '0' 'pod_count' '0' 'service_count' '0' 'deployment_count' '0' 'daemonset_count' '0' 'statefulset_count' '0' 'namespace_count' '0' 'namespaces' '[]')" \
        "cluster_components" "$(json_build_object 'api_server' '$(json_build_object \"version\" \"\" \"status\" \"\")' 'coredns' '$(json_build_object \"version\" \"\" \"status\" \"\")' 'ingress_controller' '$(json_build_object \"type\" \"\" \"version\" \"\")' 'cni_plugin' '$(json_build_object \"type\" \"\" \"version\" \"\")' 'csi_drivers' '[]')" \
        "platform_specific" "$(json_build_object 'swarm' 'null' 'kubernetes' 'null' 'openshift' 'null' 'tanzu' '$(json_build_object \"tkg_version\" \"$tkg_version\" \"tkr_version\" \"\" \"cluster_class\" \"\" \"management_cluster\" \"\" \"supervisor_cluster\" \"\" \"vsphere_namespace\" \"\" \"workload_cluster_count\" \"0\" \"infrastructure_provider\" \"\" \"ceip_enabled\" \"false\" \"pinniped_enabled\" \"false\")')" \
        "resource_usage" "$(json_build_object 'cpu_cores' '$tanzu_cpu_total' 'memory_mb' '$tanzu_mem_total')")

    log_info "Tanzu discovery completed"
}

#==============================================================================
# Services Discovery
#==============================================================================

discover_services() {
    log_info "Discovering services..."

    services_json="["
    first=true

    for service_name in containerd docker crio podman kubelet; do
        active="inactive"
        enabled="disabled"
        service_exists=false

        if command_exists systemctl; then
            # Check if service exists first
            if systemctl list-unit-files "$service_name.service" 2>/dev/null | grep -q "$service_name.service"; then
                service_exists=true
            fi

            active_check=$(systemctl is-active "$service_name" 2>/dev/null)
            [ -n "$active_check" ] && active="$active_check"

            enabled_check=$(systemctl is-enabled "$service_name" 2>/dev/null)
            [ -n "$enabled_check" ] && enabled="$enabled_check"
        else
            # SysV init fallback
            if service "$service_name" status >/dev/null 2>&1; then
                service_exists=true
                active="active"
            fi
            enabled="unknown"
        fi

        # Skip services that are both inactive and not-found/disabled
        # Only include services that are either:
        # 1. Active (running)
        # 2. Enabled (will start on boot)
        # 3. Have a process running (not a systemd service but exists as a process)
        if [ "$active" = "inactive" ] && [ "$enabled" = "not-found" ]; then
            # Check if process is actually running (might not be a service)
            if ! pgrep -x "$service_name" >/dev/null 2>&1; then
                continue
            fi
        fi

        # Also skip services that don't exist and are inactive
        if [ "$service_exists" = false ] && [ "$active" = "inactive" ] && [ "$enabled" = "disabled" ]; then
            continue
        fi

        # Get listening ports for the service
        listening_ports=$(get_listening_ports "$service_name")

        service_json=$(json_build_object \
            "name" "$service_name" \
            "active" "$active" \
            "enabled" "$enabled" \
            "listening_ports" "$listening_ports")

        if [ "$first" = false ]; then
            services_json="$services_json,"
        fi
        services_json="$services_json$service_json"
        first=false
    done

    services_json="$services_json]"

    SERVICES_JSON="$services_json"

    log_info "Services discovery completed"
}

#==============================================================================
# JSON Assembly and Output
#==============================================================================

build_final_json() {
    log_info "Building final JSON output..."

    # Combine runtime JSONs
    runtimes_array="["
    first=true

    for runtime in $RUNTIMES_DETECTED; do
        if [ "$first" = false ]; then
            runtimes_array="$runtimes_array,"
        fi

        case "$runtime" in
            containerd) runtimes_array="$runtimes_array$CONTAINERD_JSON" ;;
            docker) runtimes_array="$runtimes_array$DOCKER_JSON" ;;
            crio) runtimes_array="$runtimes_array$CRIO_JSON" ;;
            podman) runtimes_array="$runtimes_array$PODMAN_JSON" ;;
        esac

        first=false
    done

    runtimes_array="$runtimes_array]"

    # Combine orchestrator JSONs
    orchestrators_array="["
    first=true

    for orch in $ORCHESTRATORS_DETECTED; do
        if [ "$first" = false ]; then
            orchestrators_array="$orchestrators_array,"
        fi

        case "$orch" in
            docker-swarm) orchestrators_array="$orchestrators_array$SWARM_JSON" ;;
            kubernetes) orchestrators_array="$orchestrators_array$K8S_JSON" ;;
            openshift) orchestrators_array="$orchestrators_array$OPENSHIFT_JSON" ;;
            tanzu) orchestrators_array="$orchestrators_array$TANZU_JSON" ;;
        esac

        first=false
    done

    orchestrators_array="$orchestrators_array]"

    # Discovery timestamp
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build properties object
    properties=$(json_build_object \
        "schema_version" "1.0.0" \
        "timestamp" "$TIMESTAMP" \
        "host_info" "$HOST_INFO_JSON" \
        "hypervisor" "$HYPERVISOR_JSON" \
        "network" "$NETWORK_JSON" \
        "container_runtimes" "$runtimes_array" \
        "orchestrators" "$orchestrators_array" \
        "services" "$SERVICES_JSON")

    # Build armResources
    arm_resource=$(json_build_object \
        "type" "" \
        "name" "" \
        "apiVersion" "" \
        "properties" "$properties")

    # Final output
    final_json="{\"armResources\":[$arm_resource]}"

    echo "$final_json" > "$OUTPUT_FILE"

    log_info "JSON output written to $OUTPUT_FILE"
}

#==============================================================================
# Main Function
#==============================================================================

main() {
    log_info "===== Container Discovery Script Started ====="
    log_info "Script version: 1.0.0"
    log_info "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    log_info "Running as user: $(whoami)"
    log_info "Privilege level: $(check_privilege)"

    # Discover all components
    discover_host_info
    discover_hypervisor
    discover_network
    detect_container_runtimes
    detect_orchestrators
    discover_services

    # Build and output JSON
    build_final_json

    log_info "===== Container Discovery Script Completed ====="
    log_info "Output written to: $OUTPUT_FILE"
    log_info "Errors logged to: $ERROR_FILE"
    log_info "Debug logs written to: $DEBUG_FILE"
    log_info "Exit code: $EXIT_CODE"

    # Output JSON to stdout as well
    cat "$OUTPUT_FILE"

    return $EXIT_CODE
}

# Entry point
main "$@"
