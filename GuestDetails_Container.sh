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

    # Use here-string to avoid subshell issue with pipe
    while IFS= read -r line; do
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
    done <<EOF
$input
EOF

    result="$result]"
    echo "$result"
}

# Get listening ports for a process/service
get_listening_ports() {
    service_name="$1"
    ports_json="["
    first=true
    port_lines=""

    log_debug "get_listening_ports: discovering ports for service '$service_name'"

    # Step 1: Collect all PIDs related to this service
    all_pids=""

    # Method A: Get MainPID from systemd (most reliable for services)
    if command_exists systemctl; then
        main_pid=$(systemctl show -p MainPID "$service_name" 2>/dev/null | cut -d= -f2)
        if [ -n "$main_pid" ] && [ "$main_pid" != "0" ]; then
            all_pids="$main_pid"
            # Also get child processes
            if command_exists pgrep; then
                child_pids=$(pgrep -P "$main_pid" 2>/dev/null | tr '\n' ' ')
                all_pids="$all_pids $child_pids"
            fi
            log_debug "  systemctl MainPID=$main_pid, children: $child_pids"
        fi
    fi

    # Method B: Map service name to known daemon process names and pgrep them
    daemon_names="$service_name"
    case "$service_name" in
        docker)     daemon_names="docker dockerd docker-proxy" ;;
        containerd) daemon_names="containerd containerd-shim containerd-shim-runc-v2" ;;
        podman)     daemon_names="podman conmon" ;;
        crio)       daemon_names="crio conmon" ;;
        kubelet)    daemon_names="kubelet kube-proxy" ;;
    esac

    if command_exists pgrep; then
        for dname in $daemon_names; do
            dpids=$(pgrep -x "$dname" 2>/dev/null | tr '\n' ' ')
            all_pids="$all_pids $dpids"
        done
    fi
    if command_exists pidof; then
        for dname in $daemon_names; do
            dpids=$(pidof "$dname" 2>/dev/null | tr ' ' ' ')
            all_pids="$all_pids $dpids"
        done
    fi

    # Method C: Broader pattern match (e.g. "dockerd" contains "docker")
    if command_exists pgrep; then
        fpids=$(pgrep -f "^${service_name}" 2>/dev/null | tr '\n' ' ')
        all_pids="$all_pids $fpids"
    fi

    # Deduplicate PIDs
    all_pids=$(echo "$all_pids" | tr ' ' '\n' | grep -v '^$' | grep -v '^0$' | sort -un | tr '\n' ' ')
    log_debug "  all PIDs for '$service_name': $all_pids"

    # Build grep patterns from daemon names and PIDs
    grep_pattern=""
    for dn in $daemon_names; do
        if [ -z "$grep_pattern" ]; then
            grep_pattern="$dn"
        else
            grep_pattern="$grep_pattern\\|$dn"
        fi
    done
    for pid in $all_pids; do
        grep_pattern="$grep_pattern\\|pid=$pid\\|,$pid,"
    done

    # Step 2: Dynamic port discovery — try ss (both TCP and UDP)
    # Always try with sudo first if available for better results
    priv=$(check_privilege)

    if command_exists ss; then
        if [ "$priv" = "root" ]; then
            tcp_ports=$(ss -tlnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
            udp_ports=$(ss -ulnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        elif [ "$priv" = "sudo" ]; then
            tcp_ports=$(sudo ss -tlnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
            udp_ports=$(sudo ss -ulnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        else
            tcp_ports=$(ss -tlnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
            udp_ports=$(ss -ulnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        fi
        port_lines=$(printf '%s\n%s' "$tcp_ports" "$udp_ports" | grep -v '^$' | sort -un)
        log_debug "  ss found ports: $port_lines"
    fi

    # Step 3: Fallback to netstat with sudo
    if [ -z "$port_lines" ] && command_exists netstat; then
        if [ "$priv" = "root" ]; then
            tcp_ports=$(netstat -tlnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
            udp_ports=$(netstat -ulnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        elif [ "$priv" = "sudo" ]; then
            tcp_ports=$(sudo netstat -tlnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
            udp_ports=$(sudo netstat -ulnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        else
            tcp_ports=$(netstat -tlnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
            udp_ports=$(netstat -ulnp 2>/dev/null | grep -i "$grep_pattern" | awk '{print $4}' | sed 's/.*://g' | sort -u)
        fi
        port_lines=$(printf '%s\n%s' "$tcp_ports" "$udp_ports" | grep -v '^$' | sort -un)
        log_debug "  netstat found ports: $port_lines"
    fi

    # Step 4: Fallback to lsof with sudo
    if [ -z "$port_lines" ] && command_exists lsof; then
        if [ "$priv" = "root" ]; then
            port_lines=$(lsof -i -P -n 2>/dev/null | grep -i "$grep_pattern" | grep LISTEN | awk '{print $9}' | sed 's/.*://g' | sort -u)
        elif [ "$priv" = "sudo" ]; then
            port_lines=$(sudo lsof -i -P -n 2>/dev/null | grep -i "$grep_pattern" | grep LISTEN | awk '{print $9}' | sed 's/.*://g' | sort -u)
        else
            port_lines=$(lsof -i -P -n 2>/dev/null | grep -i "$grep_pattern" | grep LISTEN | awk '{print $9}' | sed 's/.*://g' | sort -u)
        fi
        log_debug "  lsof found ports: $port_lines"
    fi

    # Step 5: PID-based /proc/net/tcp fallback
    if [ -z "$port_lines" ] && [ -n "$all_pids" ]; then
        proc_ports=""
        for pid in $all_pids; do
            fd_dir="/proc/$pid/fd"
            socket_inodes=""

            # Access /proc with sudo if needed
            if [ -d "$fd_dir" ]; then
                if [ "$priv" = "root" ]; then
                    socket_inodes=$(ls -l "$fd_dir" 2>/dev/null | grep 'socket:\[' | sed 's/.*socket:\[\([0-9]*\)\]/\1/')
                elif [ "$priv" = "sudo" ]; then
                    socket_inodes=$(sudo ls -l "$fd_dir" 2>/dev/null | grep 'socket:\[' | sed 's/.*socket:\[\([0-9]*\)\]/\1/')
                else
                    socket_inodes=$(ls -l "$fd_dir" 2>/dev/null | grep 'socket:\[' | sed 's/.*socket:\[\([0-9]*\)\]/\1/')
                fi

                if [ -n "$socket_inodes" ]; then
                    for net_file in /proc/net/tcp /proc/net/tcp6; do
                        [ -f "$net_file" ] || continue
                        while IFS= read -r line; do
                            echo "$line" | grep -q "local_address" && continue
                            state=$(echo "$line" | awk '{print $4}')
                            [ "$state" = "0A" ] || continue  # 0A = LISTEN
                            inode=$(echo "$line" | awk '{print $10}')
                            if echo "$socket_inodes" | grep -qw "$inode"; then
                                hex_port=$(echo "$line" | awk '{print $2}' | sed 's/.*://')
                                dec_port=$(printf '%d' "0x$hex_port" 2>/dev/null)
                                [ -n "$dec_port" ] && [ "$dec_port" -gt 0 ] 2>/dev/null && proc_ports="$proc_ports $dec_port"
                            fi
                        done < "$net_file"
                    done
                fi
            fi
        done
        port_lines=$(echo "$proc_ports" | tr ' ' '\n' | grep -v '^$' | sort -un)
        log_debug "  /proc/net fallback found ports: $port_lines"
    fi

    # Step 6: Parse config files for configured listen addresses
    if [ -z "$port_lines" ]; then
        config_ports=""
        case "$service_name" in
            docker)
                # Check Docker daemon.json for TCP hosts
                for cfg in /etc/docker/daemon.json; do
                    if [ -f "$cfg" ]; then
                        cfg_ports=$(grep -o 'tcp://[^"]*' "$cfg" 2>/dev/null | sed 's/.*://g')
                        config_ports="$config_ports $cfg_ports"
                    fi
                done
                # Check systemd override for -H tcp://...
                if command_exists systemctl; then
                    exec_line=$(systemctl cat docker.service 2>/dev/null | grep 'ExecStart=' | tail -1)
                    if [ -n "$exec_line" ]; then
                        cfg_ports=$(echo "$exec_line" | grep -o 'tcp://[^ ]*' | sed 's/.*://g')
                        config_ports="$config_ports $cfg_ports"
                    fi
                fi
                ;;
            kubelet)
                # Check kubelet config for port settings
                for cfg in /var/lib/kubelet/config.yaml /etc/kubernetes/kubelet-config.yaml; do
                    if [ -f "$cfg" ]; then
                        port_val=$(grep '^port:' "$cfg" 2>/dev/null | awk '{print $2}')
                        [ -n "$port_val" ] && config_ports="$config_ports $port_val"
                        healthz_port=$(grep 'healthzPort:' "$cfg" 2>/dev/null | awk '{print $2}')
                        [ -n "$healthz_port" ] && config_ports="$config_ports $healthz_port"
                    fi
                done
                ;;
            containerd)
                # Check containerd config for TCP gRPC listeners
                for cfg in /etc/containerd/config.toml; do
                    if [ -f "$cfg" ]; then
                        cfg_ports=$(grep -A5 '\[grpc\]' "$cfg" 2>/dev/null | grep 'address' | grep -o '[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*' | sed 's/.*://')
                        [ -n "$cfg_ports" ] && config_ports="$config_ports $cfg_ports"
                    fi
                done
                ;;
        esac

        # Verify config-discovered ports are actually listening
        if [ -n "$config_ports" ]; then
            verified=""
            for cp in $config_ports; do
                case "$cp" in ''|*[!0-9]*) continue ;; esac
                if command_exists ss; then
                    if ss -tln 2>/dev/null | grep -q ":${cp} "; then
                        verified="$verified $cp"
                    fi
                elif command_exists netstat; then
                    if netstat -tln 2>/dev/null | grep -q ":${cp} "; then
                        verified="$verified $cp"
                    fi
                fi
            done
            port_lines=$(echo "$verified" | tr ' ' '\n' | grep -v '^$' | sort -un)
            log_debug "  config file ports (verified): $port_lines"
        fi
    fi

    # Step 7: Well-known port fallback — if service is active, check if known ports are open
    if [ -z "$port_lines" ]; then
        wellknown_ports=""
        case "$service_name" in
            docker)     wellknown_ports="2375 2376" ;;
            kubelet)    wellknown_ports="10250 10248 10255" ;;
            containerd) wellknown_ports="2379" ;;  # containerd metrics/debug
            crio)       wellknown_ports="10010" ;;  # CRI-O stream port
        esac

        if [ -n "$wellknown_ports" ]; then
            verified=""
            for wkp in $wellknown_ports; do
                port_open=false
                if command_exists ss; then
                    ss -tln 2>/dev/null | grep -q ":${wkp} " && port_open=true
                elif command_exists netstat; then
                    netstat -tln 2>/dev/null | grep -q ":${wkp} " && port_open=true
                fi
                # Also try /proc/net/tcp if ss/netstat didn't work
                if [ "$port_open" = false ] && [ -f /proc/net/tcp ]; then
                    hex_port=$(printf '%04X' "$wkp" 2>/dev/null)
                    if [ -n "$hex_port" ]; then
                        if grep -qi ":${hex_port} " /proc/net/tcp 2>/dev/null || grep -qi ":${hex_port} " /proc/net/tcp6 2>/dev/null; then
                            port_open=true
                        fi
                    fi
                fi
                if [ "$port_open" = true ]; then
                    verified="$verified $wkp"
                fi
            done
            port_lines=$(echo "$verified" | tr ' ' '\n' | grep -v '^$' | sort -un)
            log_debug "  well-known port fallback (verified): $port_lines"
        fi
    fi

    # Step 8: Last resort — scan all listening ports and match by PID in /proc
    if [ -z "$port_lines" ] && [ -n "$all_pids" ] && [ -f /proc/net/tcp ]; then
        proc_ports=""
        # Build a set of all socket inodes for our PIDs
        all_inodes=""
        for pid in $all_pids; do
            fd_dir="/proc/$pid/fd"
            if [ -d "$fd_dir" ]; then
                if [ "$priv" = "root" ]; then
                    inodes=$(ls -l "$fd_dir" 2>/dev/null | grep 'socket:\[' | sed 's/.*socket:\[\([0-9]*\)\]/\1/' | tr '\n' ' ')
                elif [ "$priv" = "sudo" ]; then
                    inodes=$(sudo ls -l "$fd_dir" 2>/dev/null | grep 'socket:\[' | sed 's/.*socket:\[\([0-9]*\)\]/\1/' | tr '\n' ' ')
                else
                    inodes=$(ls -l "$fd_dir" 2>/dev/null | grep 'socket:\[' | sed 's/.*socket:\[\([0-9]*\)\]/\1/' | tr '\n' ' ')
                fi
                all_inodes="$all_inodes $inodes"
            fi
        done
        if [ -n "$all_inodes" ]; then
            for net_file in /proc/net/tcp /proc/net/tcp6; do
                [ -f "$net_file" ] || continue
                while IFS= read -r line; do
                    echo "$line" | grep -q "local_address" && continue
                    state=$(echo "$line" | awk '{print $4}')
                    [ "$state" = "0A" ] || continue
                    inode=$(echo "$line" | awk '{print $10}')
                    for si in $all_inodes; do
                        if [ "$inode" = "$si" ]; then
                            hex_port=$(echo "$line" | awk '{print $2}' | sed 's/.*://')
                            dec_port=$(printf '%d' "0x$hex_port" 2>/dev/null)
                            [ -n "$dec_port" ] && [ "$dec_port" -gt 0 ] 2>/dev/null && proc_ports="$proc_ports $dec_port"
                            break
                        fi
                    done
                done < "$net_file"
            done
        fi
        port_lines=$(echo "$proc_ports" | tr ' ' '\n' | grep -v '^$' | sort -un)
        log_debug "  /proc inode scan found ports: $port_lines"
    fi

    log_debug "  final ports for '$service_name': $port_lines"

    # Build JSON array of port objects matching schema: [{"port":N,"protocol":"tcp"}]
    if [ -n "$port_lines" ]; then
        for port in $port_lines; do
            # Validate port is a number
            case "$port" in
                ''|*[!0-9]*) continue ;;
            esac

            if [ "$first" = false ]; then
                ports_json="$ports_json,"
            fi
            ports_json="${ports_json}{\"port\":${port},\"protocol\":\"tcp\"}"
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
    seen_ipv6=""

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
                    # Check if this IPv6 address was already seen to avoid duplicates
                    addr_found=false
                    for seen_addr in $seen_ipv6; do
                        if [ "$seen_addr" = "$addr" ]; then
                            addr_found=true
                            log_debug "Skipping duplicate IPv6 address $addr on $current_iface"
                            break
                        fi
                    done

                    if [ "$addr_found" = "false" ]; then
                        if [ "$first" = false ]; then
                            ip_json="$ip_json,"
                        fi
                        ip_json="$ip_json$(json_build_object "address" "$addr" "version" "ipv6" "interface" "$current_iface")"
                        first=false
                        seen_ipv6="$seen_ipv6 $addr"
                    fi
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

    # Namespaces - try multiple methods with sudo
    namespaces=""
    priv=$(check_privilege)

    # Method 1: Try with privilege
    if [ "$priv" = "root" ]; then
        namespaces=$(try_command "ctr namespaces list -q")
    elif [ "$priv" = "sudo" ]; then
        namespaces=$(try_command "sudo ctr namespaces list -q")
    fi

    # Method 2: Fallback - check directories with privilege
    if [ -z "$namespaces" ]; then
        if [ "$priv" = "root" ]; then
            if [ -d "/var/lib/containerd/io.containerd.grpc.v1.namespaces" ]; then
                namespaces=$(ls /var/lib/containerd/io.containerd.grpc.v1.namespaces 2>/dev/null)
            fi
        elif [ "$priv" = "sudo" ]; then
            namespaces=$(try_command "sudo ls /var/lib/containerd/io.containerd.grpc.v1.namespaces 2>/dev/null")
        fi
    fi

    # Method 3: Try crictl if available
    if [ -z "$namespaces" ] && command_exists crictl; then
        # crictl uses k8s.io namespace by default
        if try_command "crictl ps -a -q 2>/dev/null | head -n1" >/dev/null 2>&1; then
            namespaces="k8s.io"
        fi
    fi

    namespaces_json=$(json_build_array "$namespaces" false)

    # Container counts - use sudo for ctr commands
    container_count=0
    running_count=0

    if [ -n "$namespaces" ]; then
        for ns in $namespaces; do
            if [ "$priv" = "root" ]; then
                ns_containers=$(try_command "ctr -n $ns containers list -q 2>/dev/null | wc -l" || echo "0")
                ns_running=$(try_command "ctr -n $ns tasks list -q 2>/dev/null | wc -l" || echo "0")
            elif [ "$priv" = "sudo" ]; then
                ns_containers=$(try_command "sudo ctr -n $ns containers list -q 2>/dev/null | wc -l" || echo "0")
                ns_running=$(try_command "sudo ctr -n $ns tasks list -q 2>/dev/null | wc -l" || echo "0")
            else
                ns_containers=$(try_command "ctr -n $ns containers list -q 2>/dev/null | wc -l" || echo "0")
                ns_running=$(try_command "ctr -n $ns tasks list -q 2>/dev/null | wc -l" || echo "0")
            fi
            container_count=$((container_count + ns_containers))
            running_count=$((running_count + ns_running))
        done
    fi

    # Fallback to crictl with sudo
    if [ "$container_count" -eq 0 ] && command_exists crictl; then
        # Set runtime endpoint for crictl
        export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
        if [ "$priv" = "root" ]; then
            container_count=$(try_command "crictl ps -a -q 2>/dev/null | wc -l" || echo "0")
            running_count=$(try_command "crictl ps -q 2>/dev/null | wc -l" || echo "0")
        elif [ "$priv" = "sudo" ]; then
            container_count=$(try_command "sudo crictl ps -a -q 2>/dev/null | wc -l" || echo "0")
            running_count=$(try_command "sudo crictl ps -q 2>/dev/null | wc -l" || echo "0")
        else
            container_count=$(try_command "crictl ps -a -q 2>/dev/null | wc -l" || echo "0")
            running_count=$(try_command "crictl ps -q 2>/dev/null | wc -l" || echo "0")
        fi
    fi

    # Image count - use sudo for ctr commands
    image_count=0
    if [ -n "$namespaces" ]; then
        for ns in $namespaces; do
            if [ "$priv" = "root" ]; then
                ns_images=$(try_command "ctr -n $ns images list -q 2>/dev/null | wc -l" || echo "0")
            elif [ "$priv" = "sudo" ]; then
                ns_images=$(try_command "sudo ctr -n $ns images list -q 2>/dev/null | wc -l" || echo "0")
            else
                ns_images=$(try_command "ctr -n $ns images list -q 2>/dev/null | wc -l" || echo "0")
            fi
            image_count=$((image_count + ns_images))
        done
    fi

    # Fallback to crictl with sudo
    if [ "$image_count" -eq 0 ] && command_exists crictl; then
        if [ "$priv" = "root" ]; then
            image_count=$(try_command "crictl images -q 2>/dev/null | wc -l" || echo "0")
        elif [ "$priv" = "sudo" ]; then
            image_count=$(try_command "sudo crictl images -q 2>/dev/null | wc -l" || echo "0")
        else
            image_count=$(try_command "crictl images -q 2>/dev/null | wc -l" || echo "0")
        fi
    fi

    # Storage driver
    storage_driver="overlayfs"
    if [ -f /etc/containerd/config.toml ]; then
        if [ "$priv" = "root" ]; then
            snap=$(grep snapshotter /etc/containerd/config.toml 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        elif [ "$priv" = "sudo" ]; then
            snap=$(try_command "sudo cat /etc/containerd/config.toml 2>/dev/null | grep snapshotter | head -n1 | awk '{print \$3}' | tr -d '\"'")
        else
            snap=$(grep snapshotter /etc/containerd/config.toml 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        fi
        [ -n "$snap" ] && storage_driver="$snap"
    fi

    # Cgroup driver
    cgroup_driver="systemd"
    if [ -f /etc/containerd/config.toml ]; then
        if [ "$priv" = "root" ]; then
            systemd_cgroup=$(grep SystemdCgroup /etc/containerd/config.toml 2>/dev/null | head -n1 | awk '{print $3}')
        elif [ "$priv" = "sudo" ]; then
            systemd_cgroup=$(try_command "sudo cat /etc/containerd/config.toml 2>/dev/null | grep SystemdCgroup | head -n1 | awk '{print \$3}'")
        else
            systemd_cgroup=$(grep SystemdCgroup /etc/containerd/config.toml 2>/dev/null | head -n1 | awk '{print $3}')
        fi
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

    # Registries - always provide default registries for Kubernetes/containerd
    registries="registry.k8s.io
docker.io"

    # Try to extract additional registries from config
    if [ -f /etc/containerd/config.toml ]; then
        config_registries=$(grep -A5 'plugins."io.containerd.grpc.v1.cri".registry.mirrors' /etc/containerd/config.toml 2>/dev/null | grep '\[' | sed 's/.*"\(.*\)".*/\1/' | grep -v '^\[')
        if [ -n "$config_registries" ]; then
            registries="$registries
$config_registries"
        fi
    fi
    registries_json=$(json_build_array "$registries" false)

    # Rootless detection for containerd
    rootless="false"
    current_uid=$(id -u)
    # Containerd is rootless if socket is in user directory or if running as non-root with user-specific socket
    if [ "$current_uid" != "0" ] && [ -S "$HOME/.local/share/containerd/containerd.sock" ]; then
        rootless="true"
        socket="$HOME/.local/share/containerd/containerd.sock"
        storage_root="$HOME/.local/share/containerd"
    elif [ "$current_uid" != "0" ] && [ -S "/run/user/$current_uid/containerd/containerd.sock" ]; then
        rootless="true"
        socket="/run/user/$current_uid/containerd/containerd.sock"
        storage_root="$HOME/.local/share/containerd"
    fi

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
        "rootless" "$rootless" \
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

    # Try docker info with sudo
    container_count=0
    running_count=0
    image_count=0
    storage_driver="overlay2"
    cgroup_driver="cgroupfs"

    priv=$(check_privilege)
    docker_info=""

    if [ "$priv" = "root" ]; then
        docker_info=$(try_command "docker info --format json")
    elif [ "$priv" = "sudo" ]; then
        docker_info=$(try_command "sudo docker info --format json")
    else
        docker_info=$(try_command "docker info --format json")
    fi

    if [ -n "$docker_info" ]; then
        container_count=$(echo "$docker_info" | grep -o '"Containers":[0-9]*' | cut -d: -f2 | head -n1)
        running_count=$(echo "$docker_info" | grep -o '"ContainersRunning":[0-9]*' | cut -d: -f2 | head -n1)
        stopped_count=$(echo "$docker_info" | grep -o '"ContainersStopped":[0-9]*' | cut -d: -f2 | head -n1)
        paused_count=$(echo "$docker_info" | grep -o '"ContainersPaused":[0-9]*' | cut -d: -f2 | head -n1)
        image_count=$(echo "$docker_info" | grep -o '"Images":[0-9]*' | cut -d: -f2 | head -n1)
        storage_driver=$(echo "$docker_info" | grep -o '"Driver":"[^"]*"' | cut -d\" -f4 | head -n1)
        cgroup_driver=$(echo "$docker_info" | grep -o '"CgroupDriver":"[^"]*"' | cut -d\" -f4 | head -n1)
    fi

    # Fallback to docker ps with sudo
    if [ "$container_count" = "0" ] || [ -z "$container_count" ]; then
        if [ "$priv" = "root" ]; then
            container_count=$(try_command "docker ps -aq 2>/dev/null | wc -l" || echo "0")
            running_count=$(try_command "docker ps -q 2>/dev/null | wc -l" || echo "0")
        elif [ "$priv" = "sudo" ]; then
            container_count=$(try_command "sudo docker ps -aq 2>/dev/null | wc -l" || echo "0")
            running_count=$(try_command "sudo docker ps -q 2>/dev/null | wc -l" || echo "0")
        else
            container_count=$(try_command "docker ps -aq 2>/dev/null | wc -l" || echo "0")
            running_count=$(try_command "docker ps -q 2>/dev/null | wc -l" || echo "0")
        fi
    fi

    if [ "$image_count" = "0" ] || [ -z "$image_count" ]; then
        if [ "$priv" = "root" ]; then
            image_count=$(try_command "docker images -q 2>/dev/null | wc -l" || echo "0")
        elif [ "$priv" = "sudo" ]; then
            image_count=$(try_command "sudo docker images -q 2>/dev/null | wc -l" || echo "0")
        else
            image_count=$(try_command "docker images -q 2>/dev/null | wc -l" || echo "0")
        fi
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

    # Registries - always provide default Docker registry
    registries="docker.io"

    # Try to extract additional registries from daemon.json
    if [ -f /etc/docker/daemon.json ]; then
        config_registries=$(grep -o '"registry-mirrors"[^]]*' /etc/docker/daemon.json 2>/dev/null | grep -o 'https\?://[^"]*' | sed 's|https\?://||')
        if [ -n "$config_registries" ]; then
            registries="$registries
$config_registries"
        fi
    fi
    registries_json=$(json_build_array "$registries" false)

    # Collect container details
    containers_json="[]"
    if [ "$container_count" -gt 0 ]; then
        container_list=""

        # Get container details with format: ID|Name|Image|State|CreatedAt|Labels
        if [ "$priv" = "root" ]; then
            container_data=$(try_command "docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.CreatedAt}}|{{.Labels}}' 2>/dev/null" || echo "")
        elif [ "$priv" = "sudo" ]; then
            container_data=$(try_command "sudo docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.CreatedAt}}|{{.Labels}}' 2>/dev/null" || echo "")
        else
            container_data=$(try_command "docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.CreatedAt}}|{{.Labels}}' 2>/dev/null" || echo "")
        fi

        if [ -n "$container_data" ]; then
            while IFS='|' read -r container_id name image state created_at labels; do
                [ -z "$container_id" ] && continue

                # Convert state to lowercase
                state_lower=$(echo "$state" | tr '[:upper:]' '[:lower:]')

                # Parse labels into JSON object (POSIX-compliant)
                labels_json="{}"
                if [ -n "$labels" ]; then
                    # Labels come in format: key1=value1,key2=value2
                    # Build a simple JSON object
                    label_pairs=""
                    # Replace commas with newlines for POSIX-compliant parsing
                    label_list=$(echo "$labels" | tr ',' '\n')
                    while IFS= read -r label; do
                        if [ -n "$label" ]; then
                            label_key=$(echo "$label" | cut -d= -f1)
                            label_value=$(echo "$label" | cut -d= -f2-)
                            if [ -z "$label_pairs" ]; then
                                label_pairs="\"$label_key\":\"$(json_escape "$label_value")\""
                            else
                                label_pairs="$label_pairs,\"$label_key\":\"$(json_escape "$label_value")\""
                            fi
                        fi
                    done <<EOF
$label_list
EOF
                    [ -n "$label_pairs" ] && labels_json="{$label_pairs}"
                fi

                # Determine if orchestrator managed (check for swarm labels)
                orchestrator_managed="false"
                orchestrator_type=""
                service_name=""
                task_id=""

                case "$labels" in
                    *com.docker.swarm.service.name=*)
                        orchestrator_managed="true"
                        orchestrator_type="docker-swarm"
                        service_name=$(echo "$labels" | grep -o 'com.docker.swarm.service.name=[^,]*' | cut -d= -f2)
                        task_id=$(echo "$labels" | grep -o 'com.docker.swarm.task.id=[^,]*' | cut -d= -f2)
                        ;;
                    *io.kubernetes.pod.name=*)
                        orchestrator_managed="true"
                        orchestrator_type="kubernetes"
                        ;;
                esac

                orchestrator_ref_json=$(json_build_object \
                    "type" "$orchestrator_type" \
                    "service_name" "$service_name" \
                    "task_id" "$task_id" \
                    "pod_name" "" \
                    "namespace" "")

                # Get image ID
                if [ "$priv" = "root" ]; then
                    image_id=$(try_command "docker inspect --format '{{.Image}}' $container_id 2>/dev/null" || echo "")
                elif [ "$priv" = "sudo" ]; then
                    image_id=$(try_command "sudo docker inspect --format '{{.Image}}' $container_id 2>/dev/null" || echo "")
                else
                    image_id=$(try_command "docker inspect --format '{{.Image}}' $container_id 2>/dev/null" || echo "")
                fi
                [ -z "$image_id" ] && image_id=""

                # Build resource usage (empty for now as detailed stats require more API calls)
                cpu_usage_json=$(json_build_object \
                    "usage_cores" "0" \
                    "request_millicores" "0" \
                    "limit_millicores" "0")

                memory_usage_json=$(json_build_object \
                    "usage_mb" "0" \
                    "request_mb" "0" \
                    "limit_mb" "0")

                resource_usage_json=$(json_build_object \
                    "cpu" "$cpu_usage_json" \
                    "memory" "$memory_usage_json")

                # Build container object
                container_obj=$(json_build_object \
                    "container_id" "$container_id" \
                    "name" "$name" \
                    "image" "$image" \
                    "image_id" "$image_id" \
                    "state" "$state_lower" \
                    "created_at" "$created_at" \
                    "labels" "$labels_json" \
                    "ports" "[]" \
                    "resource_usage" "$resource_usage_json" \
                    "network_mode" "" \
                    "restart_policy" "" \
                    "orchestrator_managed" "$orchestrator_managed" \
                    "orchestrator_ref" "$orchestrator_ref_json")

                if [ -z "$container_list" ]; then
                    container_list="$container_obj"
                else
                    container_list="$container_list,$container_obj"
                fi
            done << EOF
$container_data
EOF
            [ -n "$container_list" ] && containers_json="[$container_list]"
        fi
    fi

    # Collect image details
    images_json="[]"
    if [ "$image_count" -gt 0 ]; then
        image_list=""

        # Get image details with format: ID|Repository|Tag|CreatedAt|Size
        if [ "$priv" = "root" ]; then
            image_data=$(try_command "docker images --format '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.CreatedAt}}|{{.Size}}' 2>/dev/null" || echo "")
        elif [ "$priv" = "sudo" ]; then
            image_data=$(try_command "sudo docker images --format '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.CreatedAt}}|{{.Size}}' 2>/dev/null" || echo "")
        else
            image_data=$(try_command "docker images --format '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.CreatedAt}}|{{.Size}}' 2>/dev/null" || echo "")
        fi

        if [ -n "$image_data" ]; then
            while IFS='|' read -r image_id repository tag created_at size; do
                [ -z "$image_id" ] && continue

                # Convert size to MB (handle KB, MB, GB)
                size_mb="0"
                case "$size" in
                    *KB)
                        size_num=$(echo "$size" | sed 's/KB//')
                        size_mb=$(awk "BEGIN {printf \"%.2f\", $size_num / 1024}")
                        ;;
                    *MB)
                        size_mb=$(echo "$size" | sed 's/MB//')
                        ;;
                    *GB)
                        size_num=$(echo "$size" | sed 's/GB//')
                        size_mb=$(awk "BEGIN {printf \"%.2f\", $size_num * 1024}")
                        ;;
                    *)
                        size_mb="0"
                        ;;
                esac

                # Build image object
                image_obj=$(json_build_object \
                    "image_id" "$image_id" \
                    "repository" "$repository" \
                    "tag" "$tag" \
                    "size_mb" "$size_mb" \
                    "created_at" "$created_at")

                if [ -z "$image_list" ]; then
                    image_list="$image_obj"
                else
                    image_list="$image_list,$image_obj"
                fi
            done << EOF
$image_data
EOF
            [ -n "$image_list" ] && images_json="[$image_list]"
        fi
    fi

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

    # Check privilege for crictl commands
    priv=$(check_privilege)

    # Container counts - use sudo for crictl commands
    if [ "$priv" = "root" ]; then
        container_count=$(try_command "crictl ps -a -q 2>/dev/null | wc -l" || echo "0")
        running_count=$(try_command "crictl ps -q 2>/dev/null | wc -l" || echo "0")
    elif [ "$priv" = "sudo" ]; then
        container_count=$(try_command "sudo crictl ps -a -q 2>/dev/null | wc -l" || echo "0")
        running_count=$(try_command "sudo crictl ps -q 2>/dev/null | wc -l" || echo "0")
    else
        container_count=$(try_command "crictl ps -a -q 2>/dev/null | wc -l" || echo "0")
        running_count=$(try_command "crictl ps -q 2>/dev/null | wc -l" || echo "0")
    fi

    # Image count - use sudo for crictl commands
    if [ "$priv" = "root" ]; then
        image_count=$(try_command "crictl images -q 2>/dev/null | wc -l" || echo "0")
    elif [ "$priv" = "sudo" ]; then
        image_count=$(try_command "sudo crictl images -q 2>/dev/null | wc -l" || echo "0")
    else
        image_count=$(try_command "crictl images -q 2>/dev/null | wc -l" || echo "0")
    fi

    # Storage driver
    storage_driver="overlay"
    if [ -f /etc/crio/crio.conf ]; then
        if [ "$priv" = "root" ]; then
            driver=$(grep storage_driver /etc/crio/crio.conf 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        elif [ "$priv" = "sudo" ]; then
            driver=$(try_command "sudo cat /etc/crio/crio.conf 2>/dev/null | grep storage_driver | head -n1 | awk '{print \$3}' | tr -d '\"'")
        else
            driver=$(grep storage_driver /etc/crio/crio.conf 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        fi
        [ -n "$driver" ] && storage_driver="$driver"
    fi

    # Cgroup driver
    cgroup_driver="systemd"
    if [ -f /etc/crio/crio.conf ]; then
        if [ "$priv" = "root" ]; then
            cgm=$(grep cgroup_manager /etc/crio/crio.conf 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        elif [ "$priv" = "sudo" ]; then
            cgm=$(try_command "sudo cat /etc/crio/crio.conf 2>/dev/null | grep cgroup_manager | head -n1 | awk '{print \$3}' | tr -d '\"'")
        else
            cgm=$(grep cgroup_manager /etc/crio/crio.conf 2>/dev/null | head -n1 | awk '{print $3}' | tr -d '"')
        fi
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

    # Rootless detection for CRI-O
    rootless="false"
    current_uid=$(id -u)
    # CRI-O is rootless if socket is in user directory or running as non-root with user-specific socket
    if [ "$current_uid" != "0" ] && [ -S "/run/user/$current_uid/crio/crio.sock" ]; then
        rootless="true"
        socket="/run/user/$current_uid/crio/crio.sock"
        storage_root="$HOME/.local/share/containers/storage"
    elif [ "$current_uid" != "0" ] && [ ! -S "/var/run/crio/crio.sock" ] && [ -f "$HOME/.config/crio/crio.conf" ]; then
        # If config exists in user directory, it's likely rootless
        rootless="true"
        storage_root="$HOME/.local/share/containers/storage"
    fi

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
        "rootless" "$rootless" \
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

    # Check for Kubernetes - improved detection for worker nodes
    k8s_detected=false

    # Check if kubelet is running (most reliable for worker nodes)
    if systemctl is-active kubelet >/dev/null 2>&1; then
        k8s_detected=true
    fi

    # Check for kubernetes directories
    if [ "$k8s_detected" = false ] && [ -d /etc/kubernetes ]; then
        k8s_detected=true
    fi

    # Check for kubectl command
    if [ "$k8s_detected" = false ] && command_exists kubectl; then
        if try_command "kubectl cluster-info 2>/dev/null" >/dev/null 2>&1; then
            k8s_detected=true
        fi
    fi

    # Check for kubelet binary
    if [ "$k8s_detected" = false ] && command_exists kubelet; then
        k8s_detected=true
    fi

    if [ "$k8s_detected" = true ]; then
        ORCHESTRATORS_DETECTED="$ORCHESTRATORS_DETECTED kubernetes"
        log_info "Kubernetes detected"
        discover_kubernetes
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

    # Get current node availability
    node_availability="active"
    if [ -n "$node_id" ] && [ "$node_role" = "manager" ]; then
        node_availability=$(try_command "docker node inspect $node_id --format '{{.Spec.Availability}}' 2>/dev/null" || echo "active")
    fi

    current_node_json=$(json_build_object \
        "node_id" "$node_id" \
        "role" "$node_role" \
        "availability" "$node_availability")

    # Node counts and arrays
    total_count=0
    master_count=0
    worker_count=0
    master_nodes_json="[]"
    worker_nodes_json="[]"

    if [ "$node_role" = "manager" ]; then
        total_count=$(try_command "docker node ls -q 2>/dev/null | wc -l" || echo "0")
        master_count=$(try_command "docker node ls --filter role=manager -q 2>/dev/null | wc -l" || echo "0")
        worker_count=$((total_count - master_count))

        # Build master nodes array
        master_nodes_data=$(try_command "docker node ls --filter role=manager --format '{{.Hostname}}|{{.ID}}|{{.Status}}' 2>/dev/null" || echo "")
        if [ -n "$master_nodes_data" ]; then
            master_nodes_list=""
            while IFS='|' read -r hostname node_id status; do
                [ -z "$hostname" ] && continue
                # Convert status to lowercase using tr (POSIX-compliant)
                status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
                node_obj=$(json_build_object \
                    "name" "$hostname" \
                    "node_id" "$node_id" \
                    "status" "$status_lower")
                if [ -z "$master_nodes_list" ]; then
                    master_nodes_list="$node_obj"
                else
                    master_nodes_list="$master_nodes_list,$node_obj"
                fi
            done << EOF
$master_nodes_data
EOF
            [ -n "$master_nodes_list" ] && master_nodes_json="[$master_nodes_list]"
        fi

        # Build worker nodes array
        worker_nodes_data=$(try_command "docker node ls --filter role=worker --format '{{.Hostname}}|{{.ID}}|{{.Status}}' 2>/dev/null" || echo "")
        if [ -n "$worker_nodes_data" ]; then
            worker_nodes_list=""
            while IFS='|' read -r hostname node_id status; do
                [ -z "$hostname" ] && continue
                # Convert status to lowercase using tr (POSIX-compliant)
                status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
                node_obj=$(json_build_object \
                    "name" "$hostname" \
                    "node_id" "$node_id" \
                    "status" "$status_lower")
                if [ -z "$worker_nodes_list" ]; then
                    worker_nodes_list="$node_obj"
                else
                    worker_nodes_list="$worker_nodes_list,$node_obj"
                fi
            done << EOF
$worker_nodes_data
EOF
            [ -n "$worker_nodes_list" ] && worker_nodes_json="[$worker_nodes_list]"
        fi
    fi

    nodes_json=$(json_build_object \
        "total_count" "$total_count" \
        "master_count" "$master_count" \
        "worker_count" "$worker_count" \
        "master_nodes" "$master_nodes_json" \
        "worker_nodes" "$worker_nodes_json")

    # Service count
    service_count=0
    if [ "$node_role" = "manager" ]; then
        service_count=$(try_command "docker service ls -q 2>/dev/null | wc -l" || echo "0")
    fi

    # Container counts - get actual container counts on this node
    total_container_count=0
    system_container_count=0
    user_container_count=0

    priv=$(check_privilege)

    # Get total container count (all containers on the node)
    if [ "$priv" = "root" ]; then
        total_container_count=$(try_command "docker ps -q 2>/dev/null | wc -l" || echo "0")
    elif [ "$priv" = "sudo" ]; then
        total_container_count=$(try_command "sudo docker ps -q 2>/dev/null | wc -l" || echo "0")
    else
        total_container_count=$(try_command "docker ps -q 2>/dev/null | wc -l" || echo "0")
    fi

    # For Swarm, system containers are those with system-related service names
    # Common patterns: monitoring, logging, overlay network, ingress, etc.
    if [ "$total_container_count" -gt "0" ]; then
        if [ "$priv" = "root" ]; then
            system_container_count=$(try_command "docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'ingress-sbox|_monitoring|_logging|portainer|swarm-agent' | wc -l" || echo "0")
        elif [ "$priv" = "sudo" ]; then
            system_container_count=$(try_command "sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'ingress-sbox|_monitoring|_logging|portainer|swarm-agent' | wc -l" || echo "0")
        else
            system_container_count=$(try_command "docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'ingress-sbox|_monitoring|_logging|portainer|swarm-agent' | wc -l" || echo "0")
        fi

        # User containers = total - system
        user_container_count=$((total_container_count - system_container_count))
    fi

    # Ensure all values are set
    [ -z "$total_container_count" ] && total_container_count=0
    [ -z "$system_container_count" ] && system_container_count=0
    [ -z "$user_container_count" ] && user_container_count=0

    # Workloads
    workloads_json=$(json_build_object \
        "total_container_count" "$total_container_count" \
        "system_container_count" "$system_container_count" \
        "user_container_count" "$user_container_count" \
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

    priv=$(check_privilege)

    # Version - try multiple methods
    version=""
    if command_exists kubectl; then
        version=$(try_command "kubectl version --short 2>/dev/null | grep Server | awk '{print \$3}'")
    fi
    if [ -z "$version" ] && command_exists kubelet; then
        version=$(try_command "kubelet --version 2>/dev/null | awk '{print \$2}'")
    fi
    if [ -z "$version" ]; then
        # Try from manifest files with sudo
        if [ "$priv" = "root" ]; then
            version=$(grep -h "image:.*kube-apiserver" /etc/kubernetes/manifests/*.yaml 2>/dev/null | grep -o "v[0-9]*\.[0-9]*\.[0-9]*" | head -n1)
        elif [ "$priv" = "sudo" ]; then
            version=$(try_command "sudo grep -h 'image:.*kube-apiserver' /etc/kubernetes/manifests/*.yaml 2>/dev/null | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*' | head -n1")
        fi
    fi
    [ -z "$version" ] && version=""

    # Cluster ID - with multiple fallbacks
    cluster_id=""
    if command_exists kubectl; then
        cluster_id=$(try_command "kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null")
    fi
    if [ -z "$cluster_id" ]; then
        # Fallback: try to get from kubeadm config with sudo
        if [ "$priv" = "root" ]; then
            cluster_id=$(cat /etc/kubernetes/admin.conf 2>/dev/null | grep "cluster:" | head -n1 | awk '{print $2}')
        elif [ "$priv" = "sudo" ]; then
            cluster_id=$(try_command "sudo cat /etc/kubernetes/admin.conf 2>/dev/null | grep 'cluster:' | head -n1 | awk '{print \$2}'")
        fi
    fi
    if [ -z "$cluster_id" ]; then
        # Fallback: try to get from kubelet config
        cluster_id=$(cat /var/lib/kubelet/kubeadm-flags.env 2>/dev/null | grep -o 'cluster-name=[^ ]*' | cut -d= -f2)
    fi
    if [ -z "$cluster_id" ]; then
        # Fallback: check for k3s
        if [ -d /var/lib/rancher/k3s ]; then
            cluster_id=$(cat /var/lib/rancher/k3s/server/cred/cluster-id 2>/dev/null)
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

    # Get master nodes list
    master_nodes=""
    if command_exists kubectl && [ "$total_count" -gt "0" ]; then
        master_nodes=$(try_command "kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" | tr ' ' '\n')
        if [ -z "$master_nodes" ]; then
            master_nodes=$(try_command "kubectl get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" | tr ' ' '\n')
        fi
    fi
    master_nodes_json=$(json_build_array "$master_nodes" false)

    # Get worker nodes list - nodes without master or control-plane role
    worker_nodes=""
    if command_exists kubectl && [ "$total_count" -gt "0" ]; then
        # Try to get nodes that are not labeled as control-plane or master
        worker_nodes=$(try_command "kubectl get nodes -o jsonpath='{range .items[?(!@.metadata.labels.node-role\.kubernetes\.io/control-plane)]}{.metadata.name}{\"\n\"}{end}' 2>/dev/null")
        if [ -z "$worker_nodes" ]; then
            # Fallback: try with master label
            worker_nodes=$(try_command "kubectl get nodes -o jsonpath='{range .items[?(!@.metadata.labels.node-role\.kubernetes\.io/master)]}{.metadata.name}{\"\n\"}{end}' 2>/dev/null")
        fi
        # If still empty but we have worker_count > 0, manually filter
        if [ -z "$worker_nodes" ] && [ "$worker_count" -gt "0" ]; then
            all_nodes=$(try_command "kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" | tr ' ' '\n')
            if [ -n "$all_nodes" ] && [ -n "$master_nodes" ]; then
                # Create a simple filter by checking each node
                worker_nodes=""
                for node in $all_nodes; do
                    is_master=false
                    for master in $master_nodes; do
                        if [ "$node" = "$master" ]; then
                            is_master=true
                            break
                        fi
                    done
                    if [ "$is_master" = "false" ]; then
                        worker_nodes="${worker_nodes}${node}
"
                    fi
                done
            fi
        fi
    fi
    worker_nodes_json=$(json_build_array "$worker_nodes" false)

    nodes_json=$(json_build_object \
        "total_count" "$total_count" \
        "master_count" "$master_count" \
        "worker_count" "$worker_count" \
        "master_nodes" "$master_nodes_json" \
        "worker_nodes" "$worker_nodes_json")

    # Workload counts
    pod_count=$(try_command "kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    service_count=$(try_command "kubectl get services --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    deployment_count=$(try_command "kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    daemonset_count=$(try_command "kubectl get daemonsets --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    statefulset_count=$(try_command "kubectl get statefulsets --all-namespaces --no-headers 2>/dev/null | wc -l" || echo "0")
    namespace_count=$(try_command "kubectl get namespaces --no-headers 2>/dev/null | wc -l" || echo "0")

    namespaces=$(try_command "kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" | tr ' ' '\n')
    namespaces_json=$(json_build_array "$namespaces" false)

    # Container counts - calculate from pods
    total_container_count=0
    system_container_count=0
    user_container_count=0

    if command_exists kubectl && [ "$pod_count" -gt "0" ]; then
        # Count containers in all pods
        total_container_count=$(try_command "kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{\"\n\"}{end}{end}' 2>/dev/null | wc -l" || echo "0")

        # Count system containers (in kube-system, kube-public, kube-node-lease namespaces)
        system_container_count=$(try_command "kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{\"\n\"}{end}{end}' 2>/dev/null | wc -l" || echo "0")
        kube_public_count=$(try_command "kubectl get pods -n kube-public -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{\"\n\"}{end}{end}' 2>/dev/null | wc -l" || echo "0")
        kube_node_lease_count=$(try_command "kubectl get pods -n kube-node-lease -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{\"\n\"}{end}{end}' 2>/dev/null | wc -l" || echo "0")
        system_container_count=$((system_container_count + kube_public_count + kube_node_lease_count))

        # User containers = total - system
        user_container_count=$((total_container_count - system_container_count))
    fi

    workloads_json=$(json_build_object \
        "total_container_count" "$total_container_count" \
        "system_container_count" "$system_container_count" \
        "user_container_count" "$user_container_count" \
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

    # CNI detection with version
    cni_plugin="unknown"
    cni_version=""
    if command_exists kubectl; then
        if try_command "kubectl get pods -n kube-system 2>/dev/null | grep -q calico"; then
            cni_plugin="calico"
            cni_version=$(try_command "kubectl get pods -n kube-system -l k8s-app=calico-node -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        elif try_command "kubectl get pods -n kube-system 2>/dev/null | grep -q flannel"; then
            cni_plugin="flannel"
            cni_version=$(try_command "kubectl get pods -n kube-system -l app=flannel -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        elif try_command "kubectl get pods -n kube-system 2>/dev/null | grep -q cilium"; then
            cni_plugin="cilium"
            cni_version=$(try_command "kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        elif try_command "kubectl get pods -n kube-system 2>/dev/null | grep -q weave"; then
            cni_plugin="weave"
            cni_version=$(try_command "kubectl get pods -n kube-system -l name=weave-net -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | grep -o '[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        elif [ -d /etc/cni/net.d ]; then
            cni_conf=$(ls /etc/cni/net.d/*.conf 2>/dev/null | head -n1)
            if [ -n "$cni_conf" ]; then
                cni_plugin=$(basename "$cni_conf" .conf)
            fi
        fi
    fi

    # Cluster components
    api_server_json=$(json_build_object "version" "$version" "status" "Healthy")

    # CoreDNS detection with version
    coredns_version=""
    coredns_status="Unknown"
    if command_exists kubectl; then
        coredns_version=$(try_command "kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        if [ -z "$coredns_version" ]; then
            # Try as DaemonSet (some distributions)
            coredns_version=$(try_command "kubectl get daemonset coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        fi
        if [ -z "$coredns_version" ]; then
            # Try kube-dns (older clusters)
            coredns_version=$(try_command "kubectl get deployment kube-dns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -o '[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        fi
        # Get status
        coredns_pods=$(try_command "kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running" || echo "0")
        if [ "$coredns_pods" -gt "0" ]; then
            coredns_status="Running"
        else
            coredns_pods=$(try_command "kubectl get pods -n kube-system -l k8s-app=coredns --no-headers 2>/dev/null | grep -c Running" || echo "0")
            if [ "$coredns_pods" -gt "0" ]; then
                coredns_status="Running"
            fi
        fi
    fi
    coredns_json=$(json_build_object "version" "$coredns_version" "status" "$coredns_status")

    # Ingress controller detection
    ingress_type="none"
    ingress_version=""
    if command_exists kubectl; then
        # Check for nginx ingress
        if try_command "kubectl get pods --all-namespaces 2>/dev/null | grep -q nginx-ingress"; then
            ingress_type="nginx"
            ingress_version=$(try_command "kubectl get deployment -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
            if [ -z "$ingress_version" ]; then
                ingress_version=$(try_command "kubectl get deployment -n kube-system nginx-ingress-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -o '[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
            fi
        # Check for traefik
        elif try_command "kubectl get pods --all-namespaces 2>/dev/null | grep -q traefik"; then
            ingress_type="traefik"
            ingress_version=$(try_command "kubectl get deployment -n kube-system traefik -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        # Check for haproxy
        elif try_command "kubectl get pods --all-namespaces 2>/dev/null | grep -q haproxy-ingress"; then
            ingress_type="haproxy"
            ingress_version=$(try_command "kubectl get deployment --all-namespaces -l app=haproxy-ingress -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null | grep -o '[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        # Check for istio
        elif try_command "kubectl get pods --all-namespaces 2>/dev/null | grep -q istio-ingressgateway"; then
            ingress_type="istio"
            ingress_version=$(try_command "kubectl get deployment -n istio-system istio-ingressgateway -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -o '[0-9]*\.[0-9]*\.[0-9]*'" || echo "")
        fi
    fi
    ingress_json=$(json_build_object "type" "$ingress_type" "version" "$ingress_version")

    cni_json=$(json_build_object "type" "$cni_plugin" "version" "$cni_version")

    # CSI drivers detection
    csi_drivers=""
    if command_exists kubectl; then
        csi_drivers=$(try_command "kubectl get csidrivers -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" | tr ' ' '\n')
    fi
    csi_drivers_json=$(json_build_array "$csi_drivers" false)

    cluster_components_json=$(json_build_object \
        "api_server" "$api_server_json" \
        "coredns" "$coredns_json" \
        "ingress_controller" "$ingress_json" \
        "cni_plugin" "$cni_json" \
        "csi_drivers" "$csi_drivers_json")

    # Platform specific
    api_endpoint=$(try_command "kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null" || echo "")

    # Detect cluster CIDR - try multiple sources with sudo
    cluster_cidr=""
    # Method 1: From kube-controller-manager pod
    if [ -z "$cluster_cidr" ] && command_exists kubectl; then
        cluster_cidr=$(try_command "kubectl get pods -n kube-system -l component=kube-controller-manager -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null | grep -o 'cluster-cidr=[^ ]*' | cut -d= -f2")
    fi
    # Method 2: From kube-proxy configmap
    if [ -z "$cluster_cidr" ] && command_exists kubectl; then
        cluster_cidr=$(try_command "kubectl get configmap kube-proxy -n kube-system -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -o 'clusterCIDR: .*' | awk '{print \$2}'")
    fi
    # Method 3: From kubeadm config with sudo
    if [ -z "$cluster_cidr" ]; then
        if [ "$priv" = "root" ]; then
            cluster_cidr=$(grep -r 'podSubnet' /etc/kubernetes/manifests/ 2>/dev/null | grep -o 'podSubnet: .*' | awk '{print $2}' | head -n1)
        elif [ "$priv" = "sudo" ]; then
            cluster_cidr=$(try_command "sudo grep -r 'podSubnet' /etc/kubernetes/manifests/ 2>/dev/null | grep -o 'podSubnet: .*' | awk '{print \$2}' | head -n1")
        fi
    fi
    # Method 4: From kube-controller-manager manifest with sudo
    if [ -z "$cluster_cidr" ]; then
        if [ "$priv" = "root" ]; then
            cluster_cidr=$(grep -o 'cluster-cidr=[^ ]*' /etc/kubernetes/manifests/kube-controller-manager.yaml 2>/dev/null | cut -d= -f2)
        elif [ "$priv" = "sudo" ]; then
            cluster_cidr=$(try_command "sudo grep -o 'cluster-cidr=[^ ]*' /etc/kubernetes/manifests/kube-controller-manager.yaml 2>/dev/null | cut -d= -f2")
        fi
    fi
    # Method 5: For k3s
    if [ -z "$cluster_cidr" ] && [ -d /var/lib/rancher/k3s ]; then
        if [ "$priv" = "root" ]; then
            cluster_cidr=$(grep -o 'cluster-cidr=[^ ]*' /etc/systemd/system/k3s.service 2>/dev/null | cut -d= -f2)
        elif [ "$priv" = "sudo" ]; then
            cluster_cidr=$(try_command "sudo grep -o 'cluster-cidr=[^ ]*' /etc/systemd/system/k3s.service 2>/dev/null | cut -d= -f2")
        fi
    fi

    # Detect service CIDR - try multiple sources with sudo
    service_cidr=""
    # Method 1: From kube-apiserver pod
    if [ -z "$service_cidr" ] && command_exists kubectl; then
        service_cidr=$(try_command "kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null | grep -o 'service-cluster-ip-range=[^ ]*' | cut -d= -f2")
    fi
    # Method 2: From kube-apiserver manifest with sudo
    if [ -z "$service_cidr" ]; then
        if [ "$priv" = "root" ]; then
            service_cidr=$(grep -o 'service-cluster-ip-range=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null | cut -d= -f2)
        elif [ "$priv" = "sudo" ]; then
            service_cidr=$(try_command "sudo grep -o 'service-cluster-ip-range=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null | cut -d= -f2")
        fi
    fi
    # Method 3: From kubeadm config with sudo
    if [ -z "$service_cidr" ]; then
        if [ "$priv" = "root" ]; then
            service_cidr=$(grep -r 'serviceSubnet' /etc/kubernetes/ 2>/dev/null | grep -o 'serviceSubnet: .*' | awk '{print $2}' | head -n1)
        elif [ "$priv" = "sudo" ]; then
            service_cidr=$(try_command "sudo grep -r 'serviceSubnet' /etc/kubernetes/ 2>/dev/null | grep -o 'serviceSubnet: .*' | awk '{print \$2}' | head -n1")
        fi
    fi
    # Method 4: For k3s
    if [ -z "$service_cidr" ] && [ -d /var/lib/rancher/k3s ]; then
        if [ "$priv" = "root" ]; then
            service_cidr=$(grep -o 'service-cidr=[^ ]*' /etc/systemd/system/k3s.service 2>/dev/null | cut -d= -f2)
        elif [ "$priv" = "sudo" ]; then
            service_cidr=$(try_command "sudo grep -o 'service-cidr=[^ ]*' /etc/systemd/system/k3s.service 2>/dev/null | cut -d= -f2")
        fi
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

    # Current node information using kubectl
    node_name=$(hostname)
    node_role="worker"
    node_status="Unknown"

    if command_exists kubectl || command_exists oc; then
        cmd="kubectl"
        command_exists oc && cmd="oc"

        # Get current node details
        node_info=$($cmd get node "$node_name" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}{"|"}{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ -n "$node_info" ]; then
            IFS='|' read -r role_label ready_status <<EOF
$node_info
EOF
            [ -n "$role_label" ] && node_role="master"
            [ "$ready_status" = "True" ] && node_status="Ready" || node_status="NotReady"
        fi

        # Check for control-plane label as well
        control_plane=$($cmd get node "$node_name" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || echo "")
        [ -n "$control_plane" ] && node_role="master"
    fi

    current_node_json=$(json_build_object \
        "node_id" "$node_name" \
        "role" "$node_role" \
        "availability" "$node_status")

    # Node counts using kubectl
    total_count=0
    master_count=0
    worker_count=0
    master_nodes_json="[]"
    worker_nodes_json="[]"

    if command_exists kubectl || command_exists oc; then
        cmd="kubectl"
        command_exists oc && cmd="oc"

        total_count=$($cmd get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        master_count=$($cmd get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l || echo "0")
        [ "$master_count" = "0" ] && master_count=$($cmd get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l || echo "0")
        worker_count=$((total_count - master_count))

        # Get master nodes list
        master_nodes=$($cmd get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        [ -z "$master_nodes" ] && master_nodes=$($cmd get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        master_nodes_json=$(json_build_array "$master_nodes" false)

        # Get worker nodes list
        worker_nodes=$($cmd get nodes -o jsonpath='{range .items[?(!@.metadata.labels.node-role\.kubernetes\.io/master)]}{.metadata.name}{\"\n\"}{end}' 2>/dev/null)
        [ -z "$worker_nodes" ] && worker_nodes=$($cmd get nodes -o jsonpath='{range .items[?(!@.metadata.labels.node-role\.kubernetes\.io/control-plane)]}{.metadata.name}{\"\n\"}{end}' 2>/dev/null)
        worker_nodes_json=$(json_build_array "$worker_nodes" false)
    fi

    nodes_json=$(json_build_object \
        "total_count" "$total_count" \
        "master_count" "$master_count" \
        "worker_count" "$worker_count" \
        "master_nodes" "$master_nodes_json" \
        "worker_nodes" "$worker_nodes_json")

    # Workloads using kubectl
    pod_count=0
    service_count=0
    deployment_count=0
    daemonset_count=0
    statefulset_count=0
    namespace_count=0
    namespaces_json="[]"
    total_container_count=0
    system_container_count=0
    user_container_count=0

    if command_exists kubectl || command_exists oc; then
        cmd="kubectl"
        command_exists oc && cmd="oc"

        pod_count=$($cmd get pods --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        service_count=$($cmd get services --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        deployment_count=$($cmd get deployments --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        daemonset_count=$($cmd get daemonsets --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        statefulset_count=$($cmd get statefulsets --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        namespace_count=$($cmd get namespaces --no-headers 2>/dev/null | wc -l || echo "0")

        namespaces=$($cmd get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        namespaces_json=$(json_build_array "$namespaces" false)

        # Container counts
        if [ "$pod_count" -gt "0" ]; then
            total_container_count=$($cmd get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{\"\n\"}{end}{end}' 2>/dev/null | wc -l || echo "0")

            # OpenShift system namespaces
            for ns in openshift-apiserver openshift-authentication openshift-console openshift-dns openshift-etcd openshift-ingress openshift-monitoring openshift-operators kube-system kube-public kube-node-lease; do
                ns_count=$($cmd get pods -n $ns -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{\"\n\"}{end}{end}' 2>/dev/null | wc -l || echo "0")
                system_container_count=$((system_container_count + ns_count))
            done

            user_container_count=$((total_container_count - system_container_count))
        fi
    fi

    workloads_json=$(json_build_object \
        "total_container_count" "$total_container_count" \
        "system_container_count" "$system_container_count" \
        "user_container_count" "$user_container_count" \
        "pod_count" "$pod_count" \
        "service_count" "$service_count" \
        "deployment_count" "$deployment_count" \
        "daemonset_count" "$daemonset_count" \
        "statefulset_count" "$statefulset_count" \
        "namespace_count" "$namespace_count" \
        "namespaces" "$namespaces_json")

    # Cluster components (similar to Kubernetes)
    api_server_version=""
    api_server_status="Unknown"
    coredns_version=""
    coredns_status="Unknown"
    ingress_type="haproxy"
    ingress_version=""
    cni_type="ovn-kubernetes"
    cni_version=""

    if command_exists kubectl || command_exists oc; then
        cmd="kubectl"
        command_exists oc && cmd="oc"

        # API server version from pods
        api_server_version=$($cmd get pod -n openshift-apiserver -l app=openshift-apiserver -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
        [ -n "$api_server_version" ] && api_server_status="Running"

        # CoreDNS status
        coredns_pods=$($cmd get pods -n openshift-dns --no-headers 2>/dev/null | wc -l || echo "0")
        [ "$coredns_pods" -gt "0" ] && coredns_status="Running"

        # Detect CNI type
        cni_pods=$($cmd get pods -n openshift-sdn 2>/dev/null | grep -c sdn || echo "0")
        [ "$cni_pods" -gt "0" ] && cni_type="openshift-sdn"
        cni_pods=$($cmd get pods -n openshift-ovn-kubernetes 2>/dev/null | grep -c ovn || echo "0")
        [ "$cni_pods" -gt "0" ] && cni_type="ovn-kubernetes"
    fi

    cluster_components_json=$(json_build_object \
        "api_server" "$(json_build_object 'version' \"$api_server_version\" 'status' \"$api_server_status\")" \
        "coredns" "$(json_build_object 'version' \"$coredns_version\" 'status' \"$coredns_status\")" \
        "ingress_controller" "$(json_build_object 'type' \"$ingress_type\" 'version' \"$ingress_version\")" \
        "cni_plugin" "$(json_build_object 'type' \"$cni_type\" 'version' \"$cni_version\")" \
        "csi_drivers" "[]")

    # OpenShift-specific platform data
    ocp_channel=$(try_command "oc get clusterversion -o jsonpath='{.items[0].spec.channel}' 2>/dev/null" || echo "")
    infra_id=$(try_command "oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null" || echo "")
    install_type=""  # Could be detected from config
    project_count=0
    route_count=0
    build_config_count=0
    operator_count=0

    if command_exists oc; then
        project_count=$(oc get projects --no-headers 2>/dev/null | wc -l || echo "0")
        route_count=$(oc get routes --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        build_config_count=$(oc get buildconfig --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        operator_count=$(oc get csv --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    fi

    openshift_specific=$(json_build_object \
        "ocp_version" "$ocp_version" \
        "channel" "$ocp_channel" \
        "cluster_id" "$cluster_id" \
        "infra_id" "$infra_id" \
        "install_type" "$install_type" \
        "project_count" "$project_count" \
        "route_count" "$route_count" \
        "build_config_count" "$build_config_count" \
        "operator_count" "$operator_count" \
        "operator_hub_enabled" "false" \
        "scc_count" "0" \
        "cluster_operators_degraded" "0" \
        "cluster_operators_available" "0")

    platform_specific_json=$(json_build_object \
        "swarm" "null" \
        "kubernetes" "null" \
        "openshift" "$openshift_specific" \
        "tanzu" "null")

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

    resource_usage_json=$(json_build_object \
        "cpu_cores" "$ocp_cpu_total" \
        "memory_mb" "$ocp_mem_total")

    OPENSHIFT_JSON=$(json_build_object \
        "name" "openshift" \
        "orchestrator_type" "openshift" \
        "version" "$ocp_version" \
        "cluster_id" "$cluster_id" \
        "cluster_name" "$cluster_name" \
        "state" "active" \
        "current_node" "$current_node_json" \
        "nodes" "$nodes_json" \
        "workloads" "$workloads_json" \
        "cluster_components" "$cluster_components_json" \
        "platform_specific" "$platform_specific_json" \
        "resource_usage" "$resource_usage_json")

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

    # Current node information using kubectl
    node_name=$(hostname)
    node_role="worker"
    node_status="Unknown"

    if command_exists kubectl; then
        # Get current node details
        node_info=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}{"|"}{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ -n "$node_info" ]; then
            IFS='|' read -r role_label ready_status <<EOF
$node_info
EOF
            [ -n "$role_label" ] && node_role="control-plane"
            [ "$ready_status" = "True" ] && node_status="Ready" || node_status="NotReady"
        fi

        # Check for control-plane label as well
        control_plane=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || echo "")
        [ -n "$control_plane" ] && node_role="control-plane"
    fi

    current_node_json=$(json_build_object \
        "node_id" "$node_name" \
        "role" "$node_role" \
        "availability" "$node_status")

    # Node counts using kubectl
    total_count=0
    master_count=0
    worker_count=0
    master_nodes_json="[]"
    worker_nodes_json="[]"

    if command_exists kubectl; then
        total_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        master_count=$(kubectl get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l || echo "0")
        [ "$master_count" = "0" ] && master_count=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l || echo "0")
        worker_count=$((total_count - master_count))

        # Get master nodes list
        master_nodes=$(kubectl get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        [ -z "$master_nodes" ] && master_nodes=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        master_nodes_json=$(json_build_array "$master_nodes" false)

        # Get worker nodes list
        worker_nodes=$(kubectl get nodes -o jsonpath='{range .items[?(!@.metadata.labels.node-role\.kubernetes\.io/master)]}{.metadata.name}{\"\n\"}{end}' 2>/dev/null)
        [ -z "$worker_nodes" ] && worker_nodes=$(kubectl get nodes -o jsonpath='{range .items[?(!@.metadata.labels.node-role\.kubernetes\.io/control-plane)]}{.metadata.name}{\"\n\"}{end}' 2>/dev/null)
        worker_nodes_json=$(json_build_array "$worker_nodes" false)
    fi

    nodes_json=$(json_build_object \
        "total_count" "$total_count" \
        "master_count" "$master_count" \
        "worker_count" "$worker_count" \
        "master_nodes" "$master_nodes_json" \
        "worker_nodes" "$worker_nodes_json")

    # Workloads using kubectl
    pod_count=0
    service_count=0
    deployment_count=0
    daemonset_count=0
    statefulset_count=0
    namespace_count=0
    namespaces_json="[]"
    total_container_count=0
    system_container_count=0
    user_container_count=0

    if command_exists kubectl; then
        pod_count=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        service_count=$(kubectl get services --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        deployment_count=$(kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        daemonset_count=$(kubectl get daemonsets --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        statefulset_count=$(kubectl get statefulsets --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
        namespace_count=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l || echo "0")

        namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        namespaces_json=$(json_build_array "$namespaces" false)

        # Container counts
        if [ "$pod_count" -gt "0" ]; then
            total_container_count=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{\"\n\"}{end}{end}' 2>/dev/null | wc -l || echo "0")

            # Tanzu system namespaces
            for ns in tkg-system tanzu-system tanzu-system-ingress kube-system kube-public kube-node-lease vmware-system-tmc; do
                ns_count=$(kubectl get pods -n $ns -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{\"\n\"}{end}{end}' 2>/dev/null | wc -l || echo "0")
                system_container_count=$((system_container_count + ns_count))
            done

            user_container_count=$((total_container_count - system_container_count))
        fi
    fi

    workloads_json=$(json_build_object \
        "total_container_count" "$total_container_count" \
        "system_container_count" "$system_container_count" \
        "user_container_count" "$user_container_count" \
        "pod_count" "$pod_count" \
        "service_count" "$service_count" \
        "deployment_count" "$deployment_count" \
        "daemonset_count" "$daemonset_count" \
        "statefulset_count" "$statefulset_count" \
        "namespace_count" "$namespace_count" \
        "namespaces" "$namespaces_json")

    # Cluster components (similar to Kubernetes)
    api_server_version=""
    api_server_status="Unknown"
    coredns_version=""
    coredns_status="Unknown"
    ingress_type="contour"
    ingress_version=""
    cni_type="antrea"
    cni_version=""

    if command_exists kubectl; then
        # API server version from pods
        api_server_version=$(kubectl get pod -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
        [ -n "$api_server_version" ] && api_server_status="Running"

        # CoreDNS detection
        coredns_version=$(kubectl get deployment -n kube-system coredns -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':\K[0-9.]+' || echo "")
        coredns_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l || echo "0")
        [ "$coredns_pods" -gt "0" ] && coredns_status="Running"

        # Detect ingress controller type
        if kubectl get namespace tanzu-system-ingress >/dev/null 2>&1; then
            contour_pods=$(kubectl get pods -n tanzu-system-ingress -l app=contour 2>/dev/null | grep -c contour || echo "0")
            [ "$contour_pods" -gt "0" ] && ingress_type="contour"
        fi

        # Detect CNI type
        antrea_pods=$(kubectl get pods -n kube-system -l app=antrea 2>/dev/null | grep -c antrea || echo "0")
        [ "$antrea_pods" -gt "0" ] && cni_type="antrea"
        calico_pods=$(kubectl get pods -n kube-system -l k8s-app=calico-node 2>/dev/null | grep -c calico || echo "0")
        [ "$calico_pods" -gt "0" ] && cni_type="calico"
    fi

    cluster_components_json=$(json_build_object \
        "api_server" "$(json_build_object 'version' \"$api_server_version\" 'status' \"$api_server_status\")" \
        "coredns" "$(json_build_object 'version' \"$coredns_version\" 'status' \"$coredns_status\")" \
        "ingress_controller" "$(json_build_object 'type' \"$ingress_type\" 'version' \"$ingress_version\")" \
        "cni_plugin" "$(json_build_object 'type' \"$cni_type\" 'version' \"$cni_version\")" \
        "csi_drivers" "[]")

    # Tanzu-specific platform data
    tkr_version=$(try_command "kubectl get tkr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null" || echo "")
    cluster_class=""
    management_cluster=""
    supervisor_cluster=""
    vsphere_namespace=""
    workload_cluster_count=0
    infrastructure_provider="vsphere"
    ceip_enabled="false"
    pinniped_enabled="false"

    if command_exists tanzu; then
        workload_cluster_count=$(tanzu cluster list -o json 2>/dev/null | grep -c '"name"' || echo "0")
        management_cluster=$(tanzu management-cluster get 2>/dev/null | grep 'NAME' | awk '{print $2}' || echo "")
    fi

    tanzu_specific=$(json_build_object \
        "tkg_version" "$tkg_version" \
        "tkr_version" "$tkr_version" \
        "cluster_class" "$cluster_class" \
        "management_cluster" "$management_cluster" \
        "supervisor_cluster" "$supervisor_cluster" \
        "vsphere_namespace" "$vsphere_namespace" \
        "workload_cluster_count" "$workload_cluster_count" \
        "infrastructure_provider" "$infrastructure_provider" \
        "ceip_enabled" "$ceip_enabled" \
        "pinniped_enabled" "$pinniped_enabled")

    platform_specific_json=$(json_build_object \
        "swarm" "null" \
        "kubernetes" "null" \
        "openshift" "null" \
        "tanzu" "$tanzu_specific")

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

    resource_usage_json=$(json_build_object \
        "cpu_cores" "$tanzu_cpu_total" \
        "memory_mb" "$tanzu_mem_total")

    TANZU_JSON=$(json_build_object \
        "name" "tanzu" \
        "orchestrator_type" "tanzu" \
        "version" "$tkg_version" \
        "cluster_id" "$cluster_id" \
        "cluster_name" "$cluster_name" \
        "state" "active" \
        "current_node" "$current_node_json" \
        "nodes" "$nodes_json" \
        "workloads" "$workloads_json" \
        "cluster_components" "$cluster_components_json" \
        "platform_specific" "$platform_specific_json" \
        "resource_usage" "$resource_usage_json")

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
