#!/bin/sh
# GuestDetails_Container.sh — Container & Orchestrator Discovery Script
# Schema Version: 1.0.0
# POSIX-compatible shell script for Linux hosts
# Discovers container runtimes and orchestrators, outputs JSON conforming to schema.json

# --------------------------------------------------------------------------
# Global variables
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR="$(pwd)"
OUTPUT_FILE="${SCRIPT_DIR}/output.json"
DEBUG_FILE="${SCRIPT_DIR}/debug.txt"
ERROR_FILE="${SCRIPT_DIR}/error.txt"
SCHEMA_VERSION="1.0.0"
TIMESTAMP=""
HAS_JQ=false
HAS_TIMEOUT=false
HAS_SUDO=false
IS_ROOT=false
CMD_TIMEOUT=10
EXIT_CODE=0

# --------------------------------------------------------------------------
# 1. Utility Functions
# --------------------------------------------------------------------------

init_files() {
    : > "$DEBUG_FILE"
    : > "$ERROR_FILE"
    : > "$OUTPUT_FILE"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
}

log_info() {
    echo "[INFO]  $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) $*" >> "$DEBUG_FILE"
    echo "[INFO]  $*" >&2
}

log_warn() {
    echo "[WARN]  $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) $*" >> "$DEBUG_FILE"
    echo "[WARN]  $*" >&2
}

log_error() {
    echo "[ERROR] $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) $*" >> "$ERROR_FILE"
    echo "[ERROR] $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) $*" >> "$DEBUG_FILE"
    echo "[ERROR] $*" >&2
}

# Execute a command with timeout; return output or empty string
# Usage: result=$(try_command "description" command arg1 arg2 ...)
try_command() {
    _desc="$1"; shift
    log_info "Attempting: $_desc -> $*"
    if $HAS_TIMEOUT; then
        _out=$(timeout "$CMD_TIMEOUT" "$@" 2>/dev/null)
    else
        _out=$("$@" 2>/dev/null)
    fi
    _rc=$?
    if [ $_rc -ne 0 ]; then
        log_warn "Failed ($_rc): $_desc"
        echo ""
        return 1
    fi
    echo "$_out"
    return 0
}

# Execute a command string via sh -c with timeout
try_command_str() {
    _desc="$1"; shift
    _cmd="$*"
    log_info "Attempting: $_desc -> $_cmd"
    if $HAS_TIMEOUT; then
        _out=$(timeout "$CMD_TIMEOUT" sh -c "$_cmd" 2>/dev/null)
    else
        _out=$(sh -c "$_cmd" 2>/dev/null)
    fi
    _rc=$?
    if [ $_rc -ne 0 ]; then
        log_warn "Failed ($_rc): $_desc"
        echo ""
        return 1
    fi
    echo "$_out"
    return 0
}

# Try with sudo if available
try_sudo_command() {
    _desc="$1"; shift
    if $IS_ROOT; then
        try_command "$_desc" "$@"
        return $?
    elif $HAS_SUDO; then
        try_command "$_desc (sudo)" sudo "$@"
        return $?
    else
        log_warn "No privilege for: $_desc"
        echo ""
        return 1
    fi
}

try_sudo_command_str() {
    _desc="$1"; shift
    _cmd="$*"
    if $IS_ROOT; then
        try_command_str "$_desc" "$_cmd"
        return $?
    elif $HAS_SUDO; then
        try_command_str "$_desc (sudo)" "sudo sh -c '$_cmd'"
        return $?
    else
        log_warn "No privilege for: $_desc"
        echo ""
        return 1
    fi
}

check_privilege() {
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
        IS_ROOT=true
        HAS_SUDO=true
        log_info "Running as root"
    elif sudo -n true 2>/dev/null; then
        HAS_SUDO=true
        log_info "sudo available (passwordless)"
    else
        log_info "No root/sudo — will use unprivileged fallbacks"
    fi

    # Check for jq
    if command -v jq >/dev/null 2>&1; then
        HAS_JQ=true
        log_info "jq is available"
    else
        log_info "jq not found — using string concatenation for JSON"
    fi

    # Check for timeout
    if command -v timeout >/dev/null 2>&1; then
        HAS_TIMEOUT=true
        log_info "timeout command available"
    else
        log_info "timeout command not found — commands may hang"
    fi
}

# Try a command, then retry with sudo if it fails
# Usage: _result=$(docker_try "description" "command string")
docker_try() {
    _dt_desc="$1"; _dt_cmd="$2"
    _dt_out=$(try_command_str "$_dt_desc" "$_dt_cmd") || _dt_out=""
    if [ -z "$_dt_out" ]; then
        _dt_out=$(try_sudo_command_str "$_dt_desc (sudo)" "$_dt_cmd") || _dt_out=""
    fi
    echo "$_dt_out"
}

# Escape a string for safe JSON embedding
safe_json_string() {
    _s="$1"
    # Escape backslash, double-quote, control chars
    printf '%s' "$_s" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | tr '\n' ' ' | sed 's/[[:cntrl:]]//g'
}

# Convert newline-separated values to a JSON array of strings
to_json_array() {
    _input="$1"
    if [ -z "$_input" ]; then
        echo "[]"
        return
    fi
    _arr="["
    _first=true
    echo "$_input" | while IFS= read -r _line; do
        _line=$(safe_json_string "$_line")
        if [ -z "$_line" ]; then continue; fi
        if $_first; then
            _arr="${_arr}\"${_line}\""
            _first=false
        else
            _arr="${_arr},\"${_line}\""
        fi
        # We need to output the final result, so we use a trick
        echo "$_arr"
    done | tail -1 | sed 's/$/]/'
}

# Safer to_json_array using temp variable approach
build_json_array() {
    _input="$1"
    if [ -z "$_input" ]; then
        echo "[]"
        return
    fi
    _result="["
    _first=true
    _oldIFS="$IFS"
    IFS='
'
    for _line in $_input; do
        _line=$(safe_json_string "$_line")
        if [ -z "$_line" ]; then continue; fi
        if $_first; then
            _result="${_result}\"${_line}\""
            _first=false
        else
            _result="${_result},\"${_line}\""
        fi
    done
    IFS="$_oldIFS"
    echo "${_result}]"
}

# Get numeric value or default
num_or_default() {
    _val="$1"
    _def="${2:-0}"
    case "$_val" in
        ''|*[!0-9.]*) echo "$_def" ;;
        *) echo "$_val" ;;
    esac
}

# --------------------------------------------------------------------------
# 2. Discovery Modules
# --------------------------------------------------------------------------

# ========================
# 2.1 Host Info
# ========================
discover_host_info() {
    log_info "=== Discovering host info ==="

    # hostname
    _hostname=$(try_command "hostname" hostname) || _hostname=""
    if [ -z "$_hostname" ]; then
        _hostname=$(try_command "hostname from /etc/hostname" cat /etc/hostname) || _hostname=""
    fi
    _hostname=$(safe_json_string "$_hostname")

    # fqdn
    _fqdn=$(try_command "fqdn" hostname -f) || _fqdn=""
    if [ -z "$_fqdn" ]; then
        _fqdn="$_hostname"
    fi
    _fqdn=$(safe_json_string "$_fqdn")

    # os
    _os=""
    if [ -f /etc/os-release ]; then
        _os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
    fi
    if [ -z "$_os" ]; then
        _os=$(try_command "os via uname" uname -o) || _os=""
    fi
    _os=$(safe_json_string "$_os")

    # kernel
    _kernel=$(try_command "kernel" uname -r) || _kernel=""
    _kernel=$(safe_json_string "$_kernel")

    # arch
    _arch=$(try_command "arch" uname -m) || _arch=""
    _arch=$(safe_json_string "$_arch")

    # cpu_cores
    _cpu_cores=$(try_command "cpu_cores via nproc" nproc) || _cpu_cores=""
    if [ -z "$_cpu_cores" ]; then
        _cpu_cores=$(try_command_str "cpu_cores from /proc/cpuinfo" "grep -c '^processor' /proc/cpuinfo") || _cpu_cores="0"
    fi
    _cpu_cores=$(num_or_default "$_cpu_cores" 0)

    # cpu_model
    _cpu_model=$(try_command_str "cpu_model" "grep 'model name' /proc/cpuinfo | head -1 | sed 's/.*: //'") || _cpu_model=""
    if [ -z "$_cpu_model" ]; then
        _cpu_model=$(try_command_str "cpu_model via lscpu" "lscpu | grep 'Model name' | sed 's/.*: *//'") || _cpu_model=""
    fi
    _cpu_model=$(safe_json_string "$_cpu_model")

    # memory_total_mb
    _mem_kb=$(try_command_str "memory" "grep MemTotal /proc/meminfo | awk '{print \$2}'") || _mem_kb=""
    if [ -n "$_mem_kb" ]; then
        _memory_total_mb=$(( _mem_kb / 1024 ))
    else
        _memory_total_mb=$(try_command_str "memory via free" "free -m | awk '/^Mem:/{print \$2}'") || _memory_total_mb="0"
    fi
    _memory_total_mb=$(num_or_default "$_memory_total_mb" 0)

    # disks
    _disks_json="[]"
    _disks_raw=$(try_command_str "disks via lsblk" "lsblk -dno NAME,SIZE 2>/dev/null | grep -v '^loop'") || _disks_raw=""
    if [ -z "$_disks_raw" ]; then
        _disks_raw=$(try_sudo_command_str "disks via fdisk" "fdisk -l 2>/dev/null | grep '^Disk /dev/' | grep -v loop | sed 's/Disk \/dev\///' | sed 's/:.*//' | while read d; do sz=\$(fdisk -l /dev/\$d 2>/dev/null | head -1 | awk '{print \$3}'); echo \"\$d \${sz}G\"; done") || _disks_raw=""
    fi
    if [ -n "$_disks_raw" ]; then
        _disks_json="[$(echo "$_disks_raw" | awk '{
            name=$1;
            size_raw=$2;
            gsub(/[^0-9.]/, "", size_raw);
            size=size_raw+0;
            if ($2 ~ /T/) size=size*1024;
            else if ($2 ~ /M/) size=size/1024;
            else if ($2 ~ /K/) size=size/1048576;
            if (NR>1) printf ",";
            printf "{\"name\":\"%s\",\"size_gb\":%d}", name, size;
        }')]"
    fi

    HOST_INFO_JSON=$(cat <<HOSTEOF
{
      "hostname": "${_hostname}",
      "fqdn": "${_fqdn}",
      "os": "${_os}",
      "kernel": "${_kernel}",
      "arch": "${_arch}",
      "cpu_cores": ${_cpu_cores},
      "cpu_model": "${_cpu_model}",
      "memory_total_mb": ${_memory_total_mb},
      "disks": ${_disks_json}
    }
HOSTEOF
)
    log_info "Host info discovery complete"
}

# ========================
# 2.2 Hypervisor
# ========================
discover_hypervisor() {
    log_info "=== Discovering hypervisor ==="
    _virt_type=""
    _virt_version=""

    # Method 1: systemd-detect-virt
    _raw=$(try_command "systemd-detect-virt" systemd-detect-virt) || _raw=""
    if [ -n "$_raw" ] && [ "$_raw" != "none" ]; then
        _virt_type="$_raw"
    fi

    # Method 2: dmidecode
    if [ -z "$_virt_type" ]; then
        _raw=$(try_sudo_command "dmidecode manufacturer" dmidecode -s system-manufacturer) || _raw=""
        if [ -n "$_raw" ]; then
            _virt_type="$_raw"
        fi
    fi

    # Method 3: sys_vendor
    if [ -z "$_virt_type" ]; then
        _raw=$(try_command "sys_vendor" cat /sys/class/dmi/id/sys_vendor) || _raw=""
        if [ -n "$_raw" ]; then
            _virt_type="$_raw"
        fi
    fi

    # Method 4: virt-what
    if [ -z "$_virt_type" ]; then
        _raw=$(try_sudo_command "virt-what" virt-what) || _raw=""
        if [ -n "$_raw" ]; then
            _virt_type=$(echo "$_raw" | head -1)
        fi
    fi

    # Method 5: dmesg
    if [ -z "$_virt_type" ]; then
        _raw=$(try_sudo_command_str "dmesg hypervisor" "dmesg | grep -i hypervisor | head -1") || _raw=""
        if [ -n "$_raw" ]; then
            _virt_type="$_raw"
        fi
    fi

    # Method 6: /proc/cpuinfo hypervisor flag
    if [ -z "$_virt_type" ]; then
        _raw=$(try_command_str "cpuinfo hypervisor" "grep -q hypervisor /proc/cpuinfo && echo hypervisor") || _raw=""
        if [ -n "$_raw" ]; then
            _virt_type="hypervisor"
        fi
    fi

    # Map to enum
    _mapped_type="unknown"
    case "$(echo "$_virt_type" | tr '[:upper:]' '[:lower:]')" in
        *vmware*|*vmw*)       _mapped_type="vmware" ;;
        *hyperv*|*microsoft*) _mapped_type="hyperv" ;;
        *kvm*|*qemu*)         _mapped_type="kvm" ;;
        *xen*)                _mapped_type="xen" ;;
        *virtualbox*|*oracle*|*vbox*) _mapped_type="virtualbox" ;;
        *nutanix*|*ahv*)      _mapped_type="nutanix" ;;
        *none*|*physical*)    _mapped_type="physical" ;;
        *hypervisor*)         _mapped_type="unknown" ;;
        "")                   _mapped_type="unknown" ;;
        *)                    _mapped_type="unknown" ;;
    esac

    # Try to get version — multi-fallback per hypervisor type
    _virt_version=""

    if [ "$_mapped_type" = "vmware" ]; then
        # Fallback 1: vmware-toolbox-cmd (VMware Tools reports ESXi host version — most reliable)
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "vmware tools stat" "vmware-toolbox-cmd stat hostversion 2>/dev/null") || _virt_version=""
        fi
        # Fallback 2: vmtoolsd --cmd 'info-get guestinfo.hypervisor.version'
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "vmtoolsd hypervisor version" "vmtoolsd --cmd 'info-get guestinfo.hypervisor.version' 2>/dev/null") || _virt_version=""
        fi
        # Fallback 3: vmware-rpctool 'info-get guestinfo.hypervisor.version'
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "vmware rpctool version" "vmware-rpctool 'info-get guestinfo.hypervisor.version' 2>/dev/null") || _virt_version=""
        fi
        # Fallback 4: vmtoolsd --cmd 'info-get guestinfo.vmware.ESX.version'
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "vmtoolsd esx version" "vmtoolsd --cmd 'info-get guestinfo.vmware.ESX.version' 2>/dev/null") || _virt_version=""
        fi
        # Fallback 5: VMware Tools version (open-vm-tools) — indicates Guest Tools version
        if [ -z "$_virt_version" ]; then
            _vmtools_ver=$(try_command_str "vmware tools version" "vmware-toolbox-cmd -v 2>/dev/null") || _vmtools_ver=""
            if [ -n "$_vmtools_ver" ]; then
                _virt_version="$_vmtools_ver"
            fi
        fi
        # Fallback 6: dmidecode system-product-name (e.g. "VMware7,1" → extract HW version "7.1")
        if [ -z "$_virt_version" ]; then
            _raw_product=$(try_sudo_command_str "vmware product name" "dmidecode -s system-product-name 2>/dev/null") || _raw_product=""
            case "$_raw_product" in
                VMware[0-9]*)
                    # "VMware7,1" → "7.1"
                    _hw_ver=$(echo "$_raw_product" | sed 's/^VMware//;s/,/./g')
                    _virt_version="$_hw_ver"
                    ;;
            esac
        fi
        # Fallback 7: /sys/class/dmi/id/product_name (same logic as above)
        if [ -z "$_virt_version" ]; then
            _raw_product=$(try_command_str "vmware product from sysfs" "cat /sys/class/dmi/id/product_name 2>/dev/null") || _raw_product=""
            case "$_raw_product" in
                VMware[0-9]*)
                    _hw_ver=$(echo "$_raw_product" | sed 's/^VMware//;s/,/./g')
                    _virt_version="$_hw_ver"
                    ;;
            esac
        fi
        # Fallback 8: dmidecode system-version (may contain actual version info)
        if [ -z "$_virt_version" ]; then
            _sys_ver=$(try_sudo_command_str "vmware system version" "dmidecode -s system-version 2>/dev/null") || _sys_ver=""
            if [ -n "$_sys_ver" ] && [ "$_sys_ver" != "None" ] && [ "$_sys_ver" != "Not Specified" ]; then
                _virt_version="$_sys_ver"
            fi
        fi
        # Fallback 9: /sys/class/dmi/id/product_version
        if [ -z "$_virt_version" ]; then
            _prod_ver=$(try_command_str "vmware product version sysfs" "cat /sys/class/dmi/id/product_version 2>/dev/null") || _prod_ver=""
            if [ -n "$_prod_ver" ] && [ "$_prod_ver" != "None" ] && [ "$_prod_ver" != "Not Specified" ]; then
                _virt_version="$_prod_ver"
            fi
        fi
        # Fallback 10: dmidecode bios-version (e.g. "6.00")
        if [ -z "$_virt_version" ]; then
            _bios_ver=$(try_sudo_command_str "vmware bios version" "dmidecode -s bios-version 2>/dev/null") || _bios_ver=""
            if [ -n "$_bios_ver" ]; then
                _virt_version="$_bios_ver"
            fi
        fi
        # Fallback 11: /sys/class/dmi/id/bios_version
        if [ -z "$_virt_version" ]; then
            _bios_ver=$(try_command_str "vmware bios from sysfs" "cat /sys/class/dmi/id/bios_version 2>/dev/null") || _bios_ver=""
            if [ -n "$_bios_ver" ]; then
                _virt_version="$_bios_ver"
            fi
        fi
        # Fallback 12: dmesg for VMware version string
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "vmware dmesg version" "dmesg 2>/dev/null | grep -i 'vmware' | grep -ioE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1") || _virt_version=""
        fi

    elif [ "$_mapped_type" = "hyperv" ]; then
        # Fallback 1: /sys/class/dmi/id/bios_version
        _virt_version=$(try_command_str "hyperv bios version" "cat /sys/class/dmi/id/bios_version 2>/dev/null") || _virt_version=""
        # Fallback 2: dmidecode bios-version
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "hyperv dmidecode bios" "dmidecode -s bios-version 2>/dev/null") || _virt_version=""
        fi
        # Fallback 3: /sys/class/dmi/id/product_name (e.g. "Virtual Machine 7.0")
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "hyperv product name" "cat /sys/class/dmi/id/product_name 2>/dev/null") || _virt_version=""
        fi
        # Fallback 4: dmidecode system-product-name
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "hyperv product dmidecode" "dmidecode -s system-product-name 2>/dev/null") || _virt_version=""
        fi
        # Fallback 5: /var/lib/hyperv/.kvp_pool_3 (Hyper-V KVP daemon data)
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "hyperv kvp version" "strings /var/lib/hyperv/.kvp_pool_3 2>/dev/null | grep -A1 HostingSystemOsMajor | tail -1") || _virt_version=""
            if [ -n "$_virt_version" ]; then
                _minor=$(try_command_str "hyperv kvp minor" "strings /var/lib/hyperv/.kvp_pool_3 2>/dev/null | grep -A1 HostingSystemOsMinor | tail -1") || _minor=""
                [ -n "$_minor" ] && _virt_version="${_virt_version}.${_minor}"
                _build=$(try_command_str "hyperv kvp build" "strings /var/lib/hyperv/.kvp_pool_3 2>/dev/null | grep -A1 HostingSystemOsBuildNumber | tail -1") || _build=""
                [ -n "$_build" ] && _virt_version="${_virt_version}.${_build}"
            fi
        fi
        # Fallback 6: dmesg
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "hyperv dmesg" "dmesg 2>/dev/null | grep -i 'hyper-v\|hyperv' | grep -ioE '[0-9]+\.[0-9]+' | head -1") || _virt_version=""
        fi

    elif [ "$_mapped_type" = "kvm" ]; then
        # Fallback 1: /sys/class/dmi/id/product_name (e.g. "KVM", "RHEV Hypervisor", "Standard PC")
        _virt_version=$(try_command_str "kvm product name" "cat /sys/class/dmi/id/product_name 2>/dev/null") || _virt_version=""
        # Fallback 2: /sys/class/dmi/id/product_version
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "KVM" ] || [ "$_virt_version" = "Standard PC (i440FX + PIIX, 1996)" ] || [ "$_virt_version" = "Standard PC (Q35 + ICH9, 2009)" ]; then
            _raw_ver=$(try_command_str "kvm product version" "cat /sys/class/dmi/id/product_version 2>/dev/null") || _raw_ver=""
            if [ -n "$_raw_ver" ] && [ "$_raw_ver" != "None" ] && [ "$_raw_ver" != "Not Specified" ]; then
                _virt_version="$_raw_ver"
            fi
        fi
        # Fallback 3: dmidecode system-version
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "KVM" ]; then
            _raw_ver=$(try_sudo_command_str "kvm dmidecode version" "dmidecode -s system-version 2>/dev/null") || _raw_ver=""
            if [ -n "$_raw_ver" ] && [ "$_raw_ver" != "None" ] && [ "$_raw_ver" != "Not Specified" ]; then
                _virt_version="$_raw_ver"
            fi
        fi
        # Fallback 4: QEMU version from dmidecode bios-version (e.g. "1.5.3")
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "KVM" ]; then
            _bios_ver=$(try_sudo_command_str "kvm bios version" "dmidecode -s bios-version 2>/dev/null") || _bios_ver=""
            if [ -n "$_bios_ver" ]; then
                _virt_version="$_bios_ver"
            fi
        fi
        # Fallback 5: /sys/class/dmi/id/bios_version
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "KVM" ]; then
            _bios_ver=$(try_command_str "kvm bios sysfs" "cat /sys/class/dmi/id/bios_version 2>/dev/null") || _bios_ver=""
            if [ -n "$_bios_ver" ]; then
                _virt_version="$_bios_ver"
            fi
        fi
        # Fallback 6: libvirtd version
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "KVM" ]; then
            _lv=$(try_command_str "libvirtd version" "libvirtd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'") || _lv=""
            [ -n "$_lv" ] && _virt_version="$_lv"
        fi

    elif [ "$_mapped_type" = "xen" ]; then
        # Fallback 1: xl info
        _virt_version=$(try_sudo_command_str "xen version xl" "xl info 2>/dev/null | grep 'xen_version' | awk '{print \$3}'") || _virt_version=""
        # Fallback 2: /sys/hypervisor/version/major and minor
        if [ -z "$_virt_version" ]; then
            _xmajor=$(try_command_str "xen major" "cat /sys/hypervisor/version/major 2>/dev/null") || _xmajor=""
            _xminor=$(try_command_str "xen minor" "cat /sys/hypervisor/version/minor 2>/dev/null") || _xminor=""
            _xextra=$(try_command_str "xen extra" "cat /sys/hypervisor/version/extra 2>/dev/null") || _xextra=""
            if [ -n "$_xmajor" ]; then
                _virt_version="${_xmajor}.${_xminor:-0}${_xextra}"
            fi
        fi
        # Fallback 3: xm info
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "xen version xm" "xm info 2>/dev/null | grep 'xen_version' | awk '{print \$3}'") || _virt_version=""
        fi
        # Fallback 4: xenstore-read
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "xen xenstore" "xenstore-read /mh/version 2>/dev/null") || _virt_version=""
        fi
        # Fallback 5: dmidecode bios-version
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "xen dmidecode" "dmidecode -s bios-version 2>/dev/null") || _virt_version=""
        fi
        # Fallback 6: dmesg
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "xen dmesg" "dmesg 2>/dev/null | grep -i 'xen version' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1") || _virt_version=""
        fi

    elif [ "$_mapped_type" = "virtualbox" ]; then
        # Fallback 1: dmidecode system-product-name (e.g. "VirtualBox")
        _virt_version=$(try_sudo_command_str "vbox product" "dmidecode -s system-product-name 2>/dev/null") || _virt_version=""
        # Fallback 2: /sys/class/dmi/id/product_name
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "VirtualBox" ]; then
            _raw_ver=$(try_command_str "vbox product sysfs" "cat /sys/class/dmi/id/product_name 2>/dev/null") || _raw_ver=""
        fi
        # Fallback 3: dmidecode system-version (often has VBox version)
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "VirtualBox" ]; then
            _raw_ver=$(try_sudo_command_str "vbox system version" "dmidecode -s system-version 2>/dev/null") || _raw_ver=""
            if [ -n "$_raw_ver" ] && [ "$_raw_ver" != "Not Specified" ]; then
                _virt_version="$_raw_ver"
            fi
        fi
        # Fallback 4: /sys/class/dmi/id/product_version
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "VirtualBox" ]; then
            _raw_ver=$(try_command_str "vbox product version sysfs" "cat /sys/class/dmi/id/product_version 2>/dev/null") || _raw_ver=""
            if [ -n "$_raw_ver" ] && [ "$_raw_ver" != "None" ]; then
                _virt_version="$_raw_ver"
            fi
        fi
        # Fallback 5: dmidecode bios-version (e.g. "VirtualBox")
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "VirtualBox" ]; then
            _virt_version=$(try_sudo_command_str "vbox bios version" "dmidecode -s bios-version 2>/dev/null") || _virt_version=""
        fi
        # Fallback 6: /sys/class/dmi/id/bios_version
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "VirtualBox" ]; then
            _virt_version=$(try_command_str "vbox bios sysfs" "cat /sys/class/dmi/id/bios_version 2>/dev/null") || _virt_version=""
        fi
        # Fallback 7: VBoxControl (GA inside guest)
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "VirtualBox" ]; then
            _virt_version=$(try_command_str "vboxcontrol version" "VBoxControl --version 2>/dev/null | head -1") || _virt_version=""
        fi

    elif [ "$_mapped_type" = "nutanix" ]; then
        # Fallback 1: dmidecode system-version
        _virt_version=$(try_sudo_command_str "nutanix system version" "dmidecode -s system-version 2>/dev/null") || _virt_version=""
        if [ -z "$_virt_version" ] || [ "$_virt_version" = "Not Specified" ]; then
            _virt_version=""
        fi
        # Fallback 2: /sys/class/dmi/id/product_version
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "nutanix product version sysfs" "cat /sys/class/dmi/id/product_version 2>/dev/null") || _virt_version=""
            [ "$_virt_version" = "None" ] && _virt_version=""
        fi
        # Fallback 3: dmidecode system-product-name
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "nutanix product" "dmidecode -s system-product-name 2>/dev/null") || _virt_version=""
        fi
        # Fallback 4: /sys/class/dmi/id/product_name
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_command_str "nutanix product sysfs" "cat /sys/class/dmi/id/product_name 2>/dev/null") || _virt_version=""
        fi
        # Fallback 5: dmidecode bios-version
        if [ -z "$_virt_version" ]; then
            _virt_version=$(try_sudo_command_str "nutanix bios" "dmidecode -s bios-version 2>/dev/null") || _virt_version=""
        fi
    fi
    _virt_version=$(safe_json_string "$_virt_version")

    HYPERVISOR_JSON=$(cat <<HVEOF
{
      "type": "${_mapped_type}",
      "version": "${_virt_version}"
    }
HVEOF
)
    log_info "Hypervisor discovery complete: ${_mapped_type}"
}

# ========================
# 2.2b Network discovery
# ========================
NETWORK_JSON="{}"

discover_network() {
    log_info "=== Discovering Network ==="

    # ---- IP Addresses ----
    _ip_json="[]"
    _ip_raw=""

    # Method 1: ip -j addr show (JSON output from iproute2)
    _ip_raw=$(try_command_str "ip addr json" "ip -j addr show 2>/dev/null") || _ip_raw=""
    if [ -z "$_ip_raw" ] && ($HAS_SUDO || $IS_ROOT); then
        _ip_raw=$(try_sudo_command_str "ip addr json (sudo)" "ip -j addr show 2>/dev/null") || _ip_raw=""
    fi

    if [ -n "$_ip_raw" ] && $HAS_JQ; then
        _ip_json=$(echo "$_ip_raw" | jq -c '[
            .[]? |
            select(.ifname != "lo") |
            .ifname as $iface |
            .addr_info[]? |
            select(.family == "inet" or .family == "inet6") |
            {
                address: .local,
                version: (if .family == "inet" then "ipv4" else "ipv6" end),
                interface: $iface
            }
        ]' 2>/dev/null) || _ip_json="[]"
    fi

    # Method 2: ip addr show (parse text output)
    if [ "$_ip_json" = "[]" ]; then
        _ip_text=$(try_command_str "ip addr text" "ip addr show 2>/dev/null") || _ip_text=""
        if [ -z "$_ip_text" ] && ($HAS_SUDO || $IS_ROOT); then
            _ip_text=$(try_sudo_command_str "ip addr text (sudo)" "ip addr show 2>/dev/null") || _ip_text=""
        fi
        if [ -n "$_ip_text" ]; then
            _ip_entries=""
            _cur_iface=""
            _oldIFS="$IFS"
            IFS="
"
            for _line in $(echo "$_ip_text"); do
                case "$_line" in
                    [0-9]*:*)
                        _cur_iface=$(echo "$_line" | sed 's/^[0-9]*: *//;s/:.*//' | sed 's/@.*//')
                        ;;
                esac
                case "$_line" in
                    *"inet "*)
                        if [ "$_cur_iface" != "lo" ] && [ -n "$_cur_iface" ]; then
                            _addr=$(echo "$_line" | awk '{print $2}' | cut -d/ -f1)
                            if [ -n "$_addr" ]; then
                                [ -n "$_ip_entries" ] && _ip_entries="${_ip_entries},"
                                _ip_entries="${_ip_entries}{\"address\":\"${_addr}\",\"version\":\"ipv4\",\"interface\":\"${_cur_iface}\"}"
                            fi
                        fi
                        ;;
                    *"inet6 "*)
                        if [ "$_cur_iface" != "lo" ] && [ -n "$_cur_iface" ]; then
                            _addr=$(echo "$_line" | awk '{print $2}' | cut -d/ -f1)
                            if [ -n "$_addr" ]; then
                                [ -n "$_ip_entries" ] && _ip_entries="${_ip_entries},"
                                _ip_entries="${_ip_entries}{\"address\":\"${_addr}\",\"version\":\"ipv6\",\"interface\":\"${_cur_iface}\"}"
                            fi
                        fi
                        ;;
                esac
            done
            IFS="$_oldIFS"
            [ -n "$_ip_entries" ] && _ip_json="[${_ip_entries}]"
        fi
    fi

    # Method 3: ifconfig fallback
    if [ "$_ip_json" = "[]" ]; then
        _ifc_text=$(try_command_str "ifconfig" "ifconfig -a 2>/dev/null") || _ifc_text=""
        if [ -z "$_ifc_text" ] && ($HAS_SUDO || $IS_ROOT); then
            _ifc_text=$(try_sudo_command_str "ifconfig (sudo)" "ifconfig -a 2>/dev/null") || _ifc_text=""
        fi
        if [ -n "$_ifc_text" ]; then
            _ip_entries=""
            _cur_iface=""
            _oldIFS="$IFS"
            IFS="
"
            for _line in $(echo "$_ifc_text"); do
                # Interface line starts without whitespace
                case "$_line" in
                    [a-zA-Z]*|[0-9]*)
                        _cur_iface=$(echo "$_line" | awk '{print $1}' | sed 's/:$//')
                        ;;
                esac
                case "$_line" in
                    *"inet "*)
                        if [ "$_cur_iface" != "lo" ] && [ -n "$_cur_iface" ]; then
                            # Handle both "inet addr:x.x.x.x" and "inet x.x.x.x"
                            _addr=$(echo "$_line" | grep -oE 'inet (addr:)?[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $NF}' | sed 's/addr://')
                            if [ -n "$_addr" ]; then
                                [ -n "$_ip_entries" ] && _ip_entries="${_ip_entries},"
                                _ip_entries="${_ip_entries}{\"address\":\"${_addr}\",\"version\":\"ipv4\",\"interface\":\"${_cur_iface}\"}"
                            fi
                        fi
                        ;;
                    *"inet6 "*)
                        if [ "$_cur_iface" != "lo" ] && [ -n "$_cur_iface" ]; then
                            _addr=$(echo "$_line" | grep -oE 'inet6 (addr: ?)?[0-9a-fA-F:]+' | head -1 | awk '{print $NF}' | sed 's/addr://')
                            if [ -n "$_addr" ]; then
                                [ -n "$_ip_entries" ] && _ip_entries="${_ip_entries},"
                                _ip_entries="${_ip_entries}{\"address\":\"${_addr}\",\"version\":\"ipv6\",\"interface\":\"${_cur_iface}\"}"
                            fi
                        fi
                        ;;
                esac
            done
            IFS="$_oldIFS"
            [ -n "$_ip_entries" ] && _ip_json="[${_ip_entries}]"
        fi
    fi

    [ -z "$_ip_json" ] && _ip_json="[]"
    log_info "IP addresses discovered: $(echo "$_ip_json" | grep -o 'address' | wc -l)"

    # ---- Default Gateway ----
    _gateway=""

    # Method 1: ip route
    _gateway=$(try_command_str "default gateway via ip route" "ip route 2>/dev/null | grep '^default' | head -1 | awk '{print \$3}'") || _gateway=""
    if [ -z "$_gateway" ] && ($HAS_SUDO || $IS_ROOT); then
        _gateway=$(try_sudo_command_str "default gateway via ip route (sudo)" "ip route 2>/dev/null | grep '^default' | head -1 | awk '{print \$3}'") || _gateway=""
    fi

    # Method 2: route -n
    if [ -z "$_gateway" ]; then
        _gateway=$(try_command_str "default gateway via route" "route -n 2>/dev/null | grep '^0\.0\.0\.0' | head -1 | awk '{print \$2}'") || _gateway=""
        if [ -z "$_gateway" ] && ($HAS_SUDO || $IS_ROOT); then
            _gateway=$(try_sudo_command_str "default gateway via route (sudo)" "route -n 2>/dev/null | grep '^0\.0\.0\.0' | head -1 | awk '{print \$2}'") || _gateway=""
        fi
    fi

    # Method 3: /proc/net/route fallback
    if [ -z "$_gateway" ] && [ -f /proc/net/route ]; then
        _hex_gw=$(try_command_str "gateway via /proc/net/route" "awk '\$2 == \"00000000\" {print \$3; exit}' /proc/net/route 2>/dev/null") || _hex_gw=""
        if [ -n "$_hex_gw" ] && [ "$_hex_gw" != "00000000" ]; then
            # Convert hex to IP (little-endian on x86)
            _gateway=$(printf '%d.%d.%d.%d' \
                "0x$(echo "$_hex_gw" | cut -c7-8)" \
                "0x$(echo "$_hex_gw" | cut -c5-6)" \
                "0x$(echo "$_hex_gw" | cut -c3-4)" \
                "0x$(echo "$_hex_gw" | cut -c1-2)" 2>/dev/null) || _gateway=""
        fi
    fi

    _gateway=$(safe_json_string "$_gateway")
    log_info "Default gateway: ${_gateway}"

    # ---- DNS Servers ----
    _dns_json="[]"
    _dns_entries=""

    # Method 1: resolvectl status
    _dns_raw=$(try_command_str "dns via resolvectl" "resolvectl status 2>/dev/null | grep -i 'DNS Servers' | head -5 | sed 's/.*DNS Servers: *//' | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+|^[0-9a-fA-F]*:'") || _dns_raw=""
    if [ -z "$_dns_raw" ] && ($HAS_SUDO || $IS_ROOT); then
        _dns_raw=$(try_sudo_command_str "dns via resolvectl (sudo)" "resolvectl status 2>/dev/null | grep -i 'DNS Servers' | head -5 | sed 's/.*DNS Servers: *//' | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+|^[0-9a-fA-F]*:'") || _dns_raw=""
    fi

    # Method 2: systemd-resolve --status (older systems)
    if [ -z "$_dns_raw" ]; then
        _dns_raw=$(try_command_str "dns via systemd-resolve" "systemd-resolve --status 2>/dev/null | grep -i 'DNS Servers' | head -5 | sed 's/.*DNS Servers: *//' | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+|^[0-9a-fA-F]*:'") || _dns_raw=""
    fi

    # Method 3: /etc/resolv.conf
    if [ -z "$_dns_raw" ] && [ -f /etc/resolv.conf ]; then
        _dns_raw=$(try_command_str "dns via resolv.conf" "grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print \$2}'") || _dns_raw=""
    fi

    # Method 4: nmcli fallback
    if [ -z "$_dns_raw" ]; then
        _dns_raw=$(try_command_str "dns via nmcli" "nmcli dev show 2>/dev/null | grep 'IP4.DNS' | awk '{print \$2}'") || _dns_raw=""
    fi

    if [ -n "$_dns_raw" ]; then
        _oldIFS="$IFS"
        IFS="
"
        for _dns in $(echo "$_dns_raw" | grep -v '^$'); do
            _dns=$(echo "$_dns" | tr -d ' \t\r')
            [ -z "$_dns" ] && continue
            _dns_safe=$(safe_json_string "$_dns")
            [ -n "$_dns_entries" ] && _dns_entries="${_dns_entries},"
            _dns_entries="${_dns_entries}\"${_dns_safe}\""
        done
        IFS="$_oldIFS"
    fi

    [ -n "$_dns_entries" ] && _dns_json="[${_dns_entries}]"
    [ -z "$_dns_json" ] && _dns_json="[]"
    log_info "DNS servers: $(echo "$_dns_json" | grep -o '"' | wc -l | awk '{print $1/2}')"

    # ---- Assemble network JSON ----
    NETWORK_JSON="{
      \"ip_addresses\": ${_ip_json},
      \"default_gateway\": \"${_gateway}\",
      \"dns_servers\": ${_dns_json}
    }"
    log_info "Network discovery complete"
}

# ========================
# 2.3 Container Runtimes
# ========================

# Helper: get resource usage for a process
get_process_resource_usage() {
    _pname="$1"
    _pid=$(pgrep -x "$_pname" 2>/dev/null | head -1)
    if [ -z "$_pid" ]; then
        _pid=$(pgrep -f "$_pname" 2>/dev/null | head -1)
    fi
    _cpu="0.0"
    _mem="0.0"
    if [ -n "$_pid" ]; then
        _ps_out=$(ps -p "$_pid" -o %cpu=,rss= 2>/dev/null)
        if [ -n "$_ps_out" ]; then
            _cpu=$(echo "$_ps_out" | awk '{printf "%.2f", $1/100}')
            _rss=$(echo "$_ps_out" | awk '{print $2}')
            _mem=$(echo "$_rss" | awk '{printf "%.2f", $1/1024}')
        fi
    fi
    echo "${_cpu} ${_mem}"
}

# Helper: build container JSON for a single container
# Sets global _CONT_JSON
build_container_json() {
    _cid="$1"
    _cname="$2"
    _cimage="$3"
    _cimage_id="$4"
    _cstate="$5"
    _ccreated="$6"
    _cports_json="$7"
    _ccpu_usage="$8"
    _ccpu_req="$9"
    shift 9
    _ccpu_lim="$1"
    _cmem_usage="$2"
    _cmem_req="$3"
    _cmem_lim="$4"
    _cnet_mode="$5"
    _crestart_pol="$6"
    _orch_managed="$7"
    _orch_type="$8"
    _orch_svc="$9"
    shift 9
    _orch_task="${1:-}"
    _orch_pod="${2:-}"
    _orch_ns="${3:-}"

    [ -z "$_cports_json" ] && _cports_json="[]"
    [ -z "$_ccpu_usage" ] && _ccpu_usage="0.0"
    [ -z "$_ccpu_req" ] && _ccpu_req="0"
    [ -z "$_ccpu_lim" ] && _ccpu_lim="0"
    [ -z "$_cmem_usage" ] && _cmem_usage="0.0"
    [ -z "$_cmem_req" ] && _cmem_req="0"
    [ -z "$_cmem_lim" ] && _cmem_lim="0"
    [ -z "$_cnet_mode" ] && _cnet_mode=""
    [ -z "$_crestart_pol" ] && _crestart_pol=""
    [ -z "$_orch_managed" ] && _orch_managed="false"
    [ -z "$_orch_type" ] && _orch_type=""
    [ -z "$_orch_svc" ] && _orch_svc=""
    [ -z "$_orch_task" ] && _orch_task=""
    [ -z "$_orch_pod" ] && _orch_pod=""
    [ -z "$_orch_ns" ] && _orch_ns=""

    _CONT_JSON="{
                \"container_id\": \"$(safe_json_string "$_cid")\",
                \"name\": \"$(safe_json_string "$_cname")\",
                \"image\": \"$(safe_json_string "$_cimage")\",
                \"image_id\": \"$(safe_json_string "$_cimage_id")\",
                \"state\": \"$(safe_json_string "$_cstate")\",
                \"created_at\": \"$(safe_json_string "$_ccreated")\",
                \"ports\": $_cports_json,
                \"resource_usage\": {
                  \"cpu\": {
                    \"usage_cores\": $_ccpu_usage,
                    \"request_millicores\": $_ccpu_req,
                    \"limit_millicores\": $_ccpu_lim
                  },
                  \"memory\": {
                    \"usage_mb\": $_cmem_usage,
                    \"request_mb\": $_cmem_req,
                    \"limit_mb\": $_cmem_lim
                  }
                },
                \"network_mode\": \"$(safe_json_string "$_cnet_mode")\",
                \"restart_policy\": \"$(safe_json_string "$_crestart_pol")\",
                \"orchestrator_managed\": $_orch_managed,
                \"orchestrator_ref\": {
                  \"type\": \"$(safe_json_string "$_orch_type")\",
                  \"service_name\": \"$(safe_json_string "$_orch_svc")\",
                  \"task_id\": \"$(safe_json_string "$_orch_task")\",
                  \"pod_name\": \"$(safe_json_string "$_orch_pod")\",
                  \"namespace\": \"$(safe_json_string "$_orch_ns")\"
                }
              }"
}

# ========================
# 2.3a Docker discovery
# ========================
DOCKER_DETECTED=false
DOCKER_RUNTIME_JSON=""

discover_docker() {
    log_info "=== Discovering Docker ==="

    # Detection
    _docker_found=false
    if command -v dockerd >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
        _docker_found=true
    elif systemctl is-active docker >/dev/null 2>&1; then
        _docker_found=true
    elif [ -S /var/run/docker.sock ]; then
        _docker_found=true
    fi

    if ! $_docker_found; then
        log_info "Docker not detected"
        return
    fi

    DOCKER_DETECTED=true
    log_info "Docker detected"

    # Version
    _version=$(docker_try "docker version" "docker version --format '{{.Server.Version}}'")
    if [ -z "$_version" ]; then
        _version=$(try_command_str "dockerd version" "dockerd --version 2>/dev/null | awk '{print \$3}' | tr -d ','") || _version=""
    fi
    if [ -z "$_version" ]; then
        _version=$(docker_try "docker version via socket" "curl -s --unix-socket /var/run/docker.sock http://localhost/version 2>/dev/null | grep -o '\"Version\":\"[^\"]*\"' | head -1 | sed 's/\"Version\":\"//;s/\"//'")
    fi
    if [ -z "$_version" ]; then
        _version=$(try_command_str "docker version dpkg" "dpkg -l 2>/dev/null | grep -i docker-ce | awk '{print \$3}' | head -1 | sed 's/[^0-9.].*//; s/^[0-9]*://'") || _version=""
    fi
    if [ -z "$_version" ]; then
        _version=$(try_command_str "docker version rpm" "rpm -qa 2>/dev/null | grep -i docker-ce | head -1 | sed 's/docker-ce-//i; s/-.*//'") || _version=""
    fi
    _version=$(safe_json_string "$_version")

    # Client version
    _client_version=$(docker_try "docker client version" "docker version --format '{{.Client.Version}}'")
    [ -z "$_client_version" ] && _client_version="$_version"
    _client_version=$(safe_json_string "$_client_version")

    # Server version 
    _server_version="$_version"

    # Socket
    _socket="/var/run/docker.sock"
    if [ ! -S "$_socket" ]; then
        _socket=$(try_command_str "docker socket from ps" "ps aux | grep dockerd | grep -v grep | grep -o '\\-\\-host[= ]unix://[^ ]*' | sed 's/.*unix:\\/\\//\\//'") || _socket="/var/run/docker.sock"
    fi

    # Storage driver
    _storage_driver=$(docker_try "docker storage driver" "docker info --format '{{.Driver}}'")
    if [ -z "$_storage_driver" ]; then
        _storage_driver=$(docker_try "docker storage driver via socket" "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | grep -o '\"Driver\":\"[^\"]*\"' | sed 's/\"Driver\":\"//;s/\"//'")
    fi
    _storage_driver=$(safe_json_string "$_storage_driver")

    # Storage root
    _storage_root=$(docker_try "docker root dir" "docker info --format '{{.DockerRootDir}}'")
    [ -z "$_storage_root" ] && _storage_root="/var/lib/docker"
    _storage_root=$(safe_json_string "$_storage_root")

    # Rootless
    _rootless=false
    _rootless_check=$(docker_try "docker rootless" "docker info --format '{{.SecurityOptions}}'")
    case "$_rootless_check" in *rootless*) _rootless=true ;; esac

    # Cgroup driver
    _cgroup_driver=$(docker_try "docker cgroup driver" "docker info --format '{{.CgroupDriver}}'")
    if [ -z "$_cgroup_driver" ]; then
        _cgroup_driver=$(docker_try "docker cgroup via socket" "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | grep -o '\"CgroupDriver\":\"[^\"]*\"' | sed 's/\"CgroupDriver\":\"//;s/\"//'")
    fi
    [ -z "$_cgroup_driver" ] && _cgroup_driver="systemd"
    _cgroup_driver=$(safe_json_string "$_cgroup_driver")

    # Container count
    _container_count=$(docker_try "docker container count" "docker info --format '{{.Containers}}'")
    if [ -z "$_container_count" ]; then
        _container_count=$(docker_try "docker containers via socket" "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | grep -o '\"Containers\":[0-9]*' | sed 's/\"Containers\"://'")
    fi
    _container_count=$(num_or_default "$_container_count" 0)
    # Cross-check: count via docker ps -aq
    if [ "$_container_count" = "0" ]; then
        _cc_ids=$(docker_try "docker ps -aq" "docker ps -aq")
        if [ -n "$_cc_ids" ]; then
            _cc_check=$(echo "$_cc_ids" | grep -c .)
            _cc_check=$(num_or_default "$_cc_check" 0)
            [ "$_cc_check" -gt 0 ] 2>/dev/null && _container_count="$_cc_check"
        fi
    fi
    log_info "Docker container_count=$_container_count"

    # Running container count
    _running_count=$(docker_try "docker running count" "docker info --format '{{.ContainersRunning}}'")
    if [ -z "$_running_count" ]; then
        _running_count=$(docker_try "docker running via socket" "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | grep -o '\"ContainersRunning\":[0-9]*' | sed 's/\"ContainersRunning\"://'")
    fi
    _running_count=$(num_or_default "$_running_count" 0)

    # Image count
    _image_count=$(docker_try "docker image count" "docker info --format '{{.Images}}'")
    if [ -z "$_image_count" ]; then
        _image_count=$(docker_try "docker images via socket" "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | grep -o '\"Images\":[0-9]*' | sed 's/\"Images\"://'")
    fi
    _image_count=$(num_or_default "$_image_count" 0)
    # Cross-check: count via docker image ls -q
    if [ "$_image_count" = "0" ]; then
        _ic_ids=$(docker_try "docker image ls -q" "docker image ls -q")
        if [ -n "$_ic_ids" ]; then
            _ic_check=$(echo "$_ic_ids" | grep -c .)
            _ic_check=$(num_or_default "$_ic_check" 0)
            [ "$_ic_check" -gt 0 ] 2>/dev/null && _image_count="$_ic_check"
        fi
    fi
    log_info "Docker image_count=$_image_count"

    # Resource usage
    _res=$(get_process_resource_usage "dockerd")
    _docker_cpu=$(echo "$_res" | awk '{print $1}')
    _docker_mem=$(echo "$_res" | awk '{print $2}')

    # Discover containers
    _containers_json="[]"
    _cont_list=""
    # Method 1: docker ps with --format
    _cont_list=$(docker_try "docker ps" "docker ps -a --no-trunc --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.CreatedAt}}'")
    # Method 2: docker container ls (alias, in case docker ps has issues)
    if [ -z "$_cont_list" ]; then
        _cont_list=$(docker_try "docker container ls" "docker container ls -a --no-trunc --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.CreatedAt}}'")
    fi
    # Method 3: docker ps without --format (parse table output)
    if [ -z "$_cont_list" ]; then
        _raw_table=$(docker_try "docker ps table" "docker ps -a --no-trunc")
        if [ -n "$_raw_table" ]; then
            # Skip header line, extract CONTAINER_ID and NAMES (first and second-to-last columns vary)
            # Use docker ps -a -q to get IDs and docker inspect to fill details
            _raw_ids=$(echo "$_raw_table" | tail -n +2 | awk '{print $1}')
            if [ -n "$_raw_ids" ]; then
                log_info "Got container IDs from table output: $(echo "$_raw_ids" | wc -l)"
                # Build pipe-delimited list from docker inspect per ID
                _cont_list=""
                for _rid in $_raw_ids; do
                    _ri=$(docker_try "docker inspect $_rid" "docker inspect --format '{{.Id}}|{{.Name}}|{{.Config.Image}}|{{.State.Status}}|{{.Created}}' $_rid 2>/dev/null")
                    if [ -n "$_ri" ]; then
                        # docker inspect Name has leading /, strip it
                        _ri=$(echo "$_ri" | sed 's/|\//|/')
                        _cont_list="${_cont_list:+${_cont_list}
}${_ri}"
                    fi
                done
            fi
        fi
    fi
    log_info "docker ps result (before API fallback): $(echo "$_cont_list" | grep -c . 2>/dev/null) entries"

    if [ -n "$_cont_list" ]; then
        _containers_json="[$(echo "$_cont_list" | {
            _cf=true
            while IFS='|' read -r _cid _cname _cimage _cstate _ccreated; do
                [ -z "$_cid" ] && continue

                _inspect=$(docker_try "docker inspect $_cid" "docker inspect $_cid 2>/dev/null")
                _image_id="" _net_mode="" _restart_pol="" _orch_managed="false"
                _orch_type="" _orch_svc="" _orch_task="" _orch_pod="" _orch_ns=""

                if [ -n "$_inspect" ] && $HAS_JQ; then
                    _image_id=$(echo "$_inspect" | jq -r '.[0].Image // ""' 2>/dev/null)
                    _net_mode=$(echo "$_inspect" | jq -r '.[0].HostConfig.NetworkMode // ""' 2>/dev/null)
                    _restart_pol=$(echo "$_inspect" | jq -r '.[0].HostConfig.RestartPolicy.Name // ""' 2>/dev/null)
                    _ccreated=$(echo "$_inspect" | jq -r '.[0].Created // ""' 2>/dev/null)

                    # --- Ports ---
                    _cports_json=$(echo "$_inspect" | jq -c '[.[0].NetworkSettings.Ports // {} | to_entries[] | select(.value != null) | .value[] as $v | {
                        host_ip: ($v.HostIp // "0.0.0.0"),
                        host_port: (($v.HostPort // "0") | tonumber),
                        container_port: ((.key | split("/")[0]) | tonumber),
                        protocol: (.key | split("/")[1] // "tcp")
                    }]' 2>/dev/null) || _cports_json="[]"
                    # Fallback: if no published ports, list exposed ports without host binding
                    if [ "$_cports_json" = "[]" ]; then
                        _cports_json=$(echo "$_inspect" | jq -c '[.[0].NetworkSettings.Ports // {} | to_entries[] | {
                            host_ip: "",
                            host_port: 0,
                            container_port: ((.key | split("/")[0]) | tonumber),
                            protocol: (.key | split("/")[1] // "tcp")
                        }]' 2>/dev/null) || _cports_json="[]"
                    fi

                    # --- Resource limits ---
                    # CPU: NanoCpus (--cpus) → millicores; or CpuQuota/CpuPeriod → millicores
                    _ccpu_lim=0
                    _nano=$(echo "$_inspect" | jq -r '.[0].HostConfig.NanoCpus // 0' 2>/dev/null) || _nano=0
                    if [ "$_nano" -gt 0 ] 2>/dev/null; then
                        _ccpu_lim=$((_nano / 1000000))
                    else
                        _cquota=$(echo "$_inspect" | jq -r '.[0].HostConfig.CpuQuota // 0' 2>/dev/null) || _cquota=0
                        _cperiod=$(echo "$_inspect" | jq -r '.[0].HostConfig.CpuPeriod // 0' 2>/dev/null) || _cperiod=0
                        if [ "$_cquota" -gt 0 ] 2>/dev/null && [ "$_cperiod" -gt 0 ] 2>/dev/null; then
                            _ccpu_lim=$((_cquota * 1000 / _cperiod))
                        fi
                    fi
                    # Memory limit (bytes → MB)
                    _cmem_lim=0
                    _mem_bytes=$(echo "$_inspect" | jq -r '.[0].HostConfig.Memory // 0' 2>/dev/null) || _mem_bytes=0
                    if [ "$_mem_bytes" -gt 0 ] 2>/dev/null; then
                        _cmem_lim=$((_mem_bytes / 1048576))
                    fi
                    # Memory reservation → request_mb
                    _cmem_req=0
                    _mem_res=$(echo "$_inspect" | jq -r '.[0].HostConfig.MemoryReservation // 0' 2>/dev/null) || _mem_res=0
                    if [ "$_mem_res" -gt 0 ] 2>/dev/null; then
                        _cmem_req=$((_mem_res / 1048576))
                    fi

                    _swarm_svc=$(echo "$_inspect" | jq -r '.[0].Config.Labels["com.docker.swarm.service.name"] // ""' 2>/dev/null)
                    _k8s_pod=$(echo "$_inspect" | jq -r '.[0].Config.Labels["io.kubernetes.pod.name"] // ""' 2>/dev/null)
                    _k8s_ns=$(echo "$_inspect" | jq -r '.[0].Config.Labels["io.kubernetes.pod.namespace"] // ""' 2>/dev/null)
                    _ocp=$(echo "$_inspect" | jq -r '.[0].Config.Labels | keys[] | select(startswith("io.openshift"))' 2>/dev/null | head -1)
                    if [ -n "$_swarm_svc" ]; then
                        _orch_managed="true"; _orch_type="docker-swarm"; _orch_svc="$_swarm_svc"
                        _orch_task=$(echo "$_inspect" | jq -r '.[0].Config.Labels["com.docker.swarm.task.id"] // ""' 2>/dev/null)
                    elif [ -n "$_ocp" ]; then
                        _orch_managed="true"; _orch_type="openshift"; _orch_pod="$_k8s_pod"; _orch_ns="$_k8s_ns"
                    elif [ -n "$_k8s_pod" ]; then
                        _orch_managed="true"; _orch_type="kubernetes"; _orch_pod="$_k8s_pod"; _orch_ns="$_k8s_ns"
                    fi
                fi

                case "$_cstate" in
                    (running|Running) _cstate="running" ;;
                    (paused|Paused) _cstate="paused" ;;
                    (exited|Exited) _cstate="exited" ;;
                    (created|Created) _cstate="created" ;;
                    (dead|Dead) _cstate="dead" ;;
                    (*) _cstate="unknown" ;;
                esac

                [ -z "$_cports_json" ] && _cports_json="[]"
                [ -z "$_ccpu_lim" ] && _ccpu_lim=0
                [ -z "$_cmem_lim" ] && _cmem_lim=0
                [ -z "$_cmem_req" ] && _cmem_req=0

                if ! $_cf; then printf ','; fi
                _cf=false
                printf '{
                "container_id":"%s","name":"%s","image":"%s","image_id":"%s","state":"%s","created_at":"%s",
                "ports":%s,"resource_usage":{"cpu":{"usage_cores":0.0,"request_millicores":0,"limit_millicores":%s},"memory":{"usage_mb":0.0,"request_mb":%s,"limit_mb":%s}},
                "network_mode":"%s","restart_policy":"%s","orchestrator_managed":%s,
                "orchestrator_ref":{"type":"%s","service_name":"%s","task_id":"%s","pod_name":"%s","namespace":"%s"}
                }' \
                "$(safe_json_string "$_cid")" "$(safe_json_string "$_cname")" "$(safe_json_string "$_cimage")" \
                "$(safe_json_string "$_image_id")" "$_cstate" "$(safe_json_string "$_ccreated")" \
                "$_cports_json" "$_ccpu_lim" "$_cmem_req" "$_cmem_lim" \
                "$(safe_json_string "$_net_mode")" "$(safe_json_string "$_restart_pol")" "$_orch_managed" \
                "$(safe_json_string "$_orch_type")" "$(safe_json_string "$_orch_svc")" "$(safe_json_string "$_orch_task")" \
                "$(safe_json_string "$_orch_pod")" "$(safe_json_string "$_orch_ns")"
            done
        })]"
    fi

    # Fallback: Docker API via socket + jq for containers
    if [ "$_containers_json" = "[]" ] && $HAS_JQ; then
        _api_c=$(docker_try "Docker API containers" "curl -s --unix-socket /var/run/docker.sock 'http://localhost/containers/json?all=true'")
        if [ -n "$_api_c" ] && [ "$_api_c" != "null" ] && [ "$_api_c" != "[]" ]; then
            _containers_json=$(echo "$_api_c" | jq -c '[.[]? | {
                container_id: .Id,
                name: ((.Names[0] // "") | ltrimstr("/")),
                image: (.Image // ""),
                image_id: (.ImageID // ""),
                state: ((.State // "unknown") | ascii_downcase),
                created_at: ((.Created // 0) | todate),
                ports: [],
                resource_usage: {cpu: {usage_cores: 0.0, request_millicores: 0, limit_millicores: 0}, memory: {usage_mb: 0.0, request_mb: 0, limit_mb: 0}},
                network_mode: (((.NetworkSettings.Networks // {}) | keys | first) // ""),
                restart_policy: "",
                orchestrator_managed: ((((.Labels["com.docker.swarm.service.name"] // "") | length) > 0) or (((.Labels["io.kubernetes.pod.name"] // "") | length) > 0)),
                orchestrator_ref: {
                    type: (if ((.Labels["com.docker.swarm.service.name"] // "") | length) > 0 then "docker-swarm" elif ((.Labels["io.kubernetes.pod.name"] // "") | length) > 0 then (if (.Labels | keys[] | select(startswith("io.openshift"))) then "openshift" else "kubernetes" end) else "" end),
                    service_name: (.Labels["com.docker.swarm.service.name"] // ""),
                    task_id: (.Labels["com.docker.swarm.task.id"] // ""),
                    pod_name: (.Labels["io.kubernetes.pod.name"] // ""),
                    namespace: (.Labels["io.kubernetes.pod.namespace"] // "")
                }
            }]' 2>/dev/null) || _containers_json="[]"
            [ -z "$_containers_json" ] && _containers_json="[]"
            log_info "Docker API container fallback returned $(echo "$_containers_json" | jq length 2>/dev/null || echo 0) containers"
        fi
    fi

    # Discover images
    _images_json="[]"
    # Method 1: docker images with --format
    _img_list=$(docker_try "docker images" "docker images --no-trunc --format '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.Size}}|{{.CreatedAt}}'")
    # Method 2: docker image ls (alternate)
    if [ -z "$_img_list" ]; then
        _img_list=$(docker_try "docker image ls" "docker image ls --no-trunc --format '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.Size}}|{{.CreatedAt}}'")
    fi
    log_info "docker images result: $(echo "$_img_list" | grep -c . 2>/dev/null) entries"
    if [ -n "$_img_list" ]; then
        _images_json="[$(echo "$_img_list" | {
            _if=true
            while IFS='|' read -r _iid _irepo _itag _isize _icreated; do
                [ -z "$_iid" ] && continue
                # Convert size to MB
                _size_mb=0
                case "$_isize" in
                    (*GB*) _size_mb=$(echo "$_isize" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1 * 1024}') ;;
                    (*MB*) _size_mb=$(echo "$_isize" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1}') ;;
                    (*KB*|*kB*) _size_mb=$(echo "$_isize" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1 / 1024}') ;;
                    (*) _size_mb=$(echo "$_isize" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1}') ;;
                esac
                [ -z "$_size_mb" ] && _size_mb="0.0"
                if ! $_if; then printf ','; fi
                _if=false
                printf '{"image_id":"%s","repository":"%s","tag":"%s","size_mb":%s,"created_at":"%s"}' \
                    "$(safe_json_string "$_iid")" "$(safe_json_string "$_irepo")" "$(safe_json_string "$_itag")" \
                    "$_size_mb" "$(safe_json_string "$_icreated")"
            done
        })]"
    fi

    # Fallback: Docker API via socket + jq for images
    if [ "$_images_json" = "[]" ] && $HAS_JQ; then
        _api_i=$(docker_try "Docker API images" "curl -s --unix-socket /var/run/docker.sock 'http://localhost/images/json'")
        if [ -n "$_api_i" ] && [ "$_api_i" != "null" ] && [ "$_api_i" != "[]" ]; then
            _images_json=$(echo "$_api_i" | jq -c '[.[]? | {
                image_id: .Id,
                repository: (((.RepoTags[0] // ":") | split(":") | .[0]) // "<none>"),
                tag: (((.RepoTags[0] // ":") | split(":") | .[1]) // "<none>"),
                size_mb: (((.Size // 0) / 1048576) | . * 10 | floor / 10),
                created_at: ((.Created // 0) | todate)
            }]' 2>/dev/null) || _images_json="[]"
            [ -z "$_images_json" ] && _images_json="[]"
            log_info "Docker API image fallback returned $(echo "$_images_json" | jq length 2>/dev/null || echo 0) images"
        fi
    fi

    # Reconcile counts with actual discovered items
    if $HAS_JQ; then
        _actual_cc=$(echo "$_containers_json" | jq 'length' 2>/dev/null) || _actual_cc=""
        _actual_cc=$(num_or_default "$_actual_cc" 0)
        if [ "$_actual_cc" -gt "$_container_count" ] 2>/dev/null; then
            _container_count="$_actual_cc"
        fi
        _actual_ic=$(echo "$_images_json" | jq 'length' 2>/dev/null) || _actual_ic=""
        _actual_ic=$(num_or_default "$_actual_ic" 0)
        if [ "$_actual_ic" -gt "$_image_count" ] 2>/dev/null; then
            _image_count="$_actual_ic"
        fi
    fi
    log_info "Docker final: container_count=$_container_count image_count=$_image_count containers=$(echo "$_containers_json" | wc -c)B images=$(echo "$_images_json" | wc -c)B"

    DOCKER_RUNTIME_JSON="{
          \"name\": \"docker\",
          \"runtime_type\": \"docker\",
          \"version\": \"${_version}\",
          \"socket\": \"$(safe_json_string "$_socket")\",
          \"storage_driver\": \"${_storage_driver}\",
          \"storage_root\": \"${_storage_root}\",
          \"rootless\": ${_rootless},
          \"cgroup_driver\": \"${_cgroup_driver}\",
          \"image_count\": ${_image_count},
          \"container_count\": ${_container_count},
          \"client_version\": \"${_client_version}\",
          \"server_version\": \"${_server_version}\",
          \"resource_usage\": {
            \"cpu_cores\": ${_docker_cpu},
            \"memory_mb\": ${_docker_mem}
          },
          \"containers\": ${_containers_json},
          \"images\": ${_images_json}
        }"
    log_info "Docker discovery complete"
}

# ========================
# 2.3b containerd discovery
# ========================
CONTAINERD_DETECTED=false
CONTAINERD_RUNTIME_JSON=""
EXTRA_CONTAINERD_RUNTIMES_JSON=""

# Helper: discover containers and images for a given containerd socket.
# Sets these variables in caller scope (via eval): _ctrd_cc, _ctrd_ic, _ctrd_cjson, _ctrd_ijson
_enumerate_containerd_socket() {
    _ecs_socket="$1"
    _ecs_ctr_bin="$2"  # path to ctr binary (e.g. ctr, /snap/microk8s/.../bin/ctr)
    _ctrd_cc=0
    _ctrd_ic=0
    _ctrd_cjson="[]"
    _ctrd_ijson="[]"

    log_info "Enumerating containerd socket: $_ecs_socket (ctr=$_ecs_ctr_bin)"

    # Enumerate namespaces
    _ecs_ns=$(try_sudo_command_str "ctr namespaces ($_ecs_socket)" \
        "$_ecs_ctr_bin --address '$_ecs_socket' namespaces list -q 2>/dev/null") || _ecs_ns=""
    if [ -z "$_ecs_ns" ]; then
        _ecs_ns="k8s.io default"
    fi
    log_info "containerd [$_ecs_socket] namespaces: $_ecs_ns"

    # Container count
    for _ns in $_ecs_ns; do
        _nc=$(try_sudo_command_str "ctr $_ns containers ($_ecs_socket)" \
            "$_ecs_ctr_bin --address '$_ecs_socket' -n '$_ns' containers list -q 2>/dev/null | wc -l | tr -d ' '") || _nc="0"
        _nc=$(num_or_default "$_nc" 0)
        _ctrd_cc=$((_ctrd_cc + _nc))
        log_info "containerd [$_ecs_socket] namespace '$_ns': $_nc containers"
    done

    # Image count
    for _ns in $_ecs_ns; do
        _ni=$(try_sudo_command_str "ctr $_ns images ($_ecs_socket)" \
            "$_ecs_ctr_bin --address '$_ecs_socket' -n '$_ns' images list -q 2>/dev/null | wc -l | tr -d ' '") || _ni="0"
        _ni=$(num_or_default "$_ni" 0)
        _ctrd_ic=$((_ctrd_ic + _ni))
        log_info "containerd [$_ecs_socket] namespace '$_ns': $_ni images"
    done
    log_info "containerd [$_ecs_socket] totals: containers=$_ctrd_cc images=$_ctrd_ic"

    # Containers detail via ctr per namespace
    if [ "$_ctrd_cc" -gt 0 ] 2>/dev/null; then
        _ctr_all_json=""
        for _ns in $_ecs_ns; do
            _ns_list=$(try_sudo_command_str "ctr $_ns containers list ($_ecs_socket)" \
                "$_ecs_ctr_bin --address '$_ecs_socket' -n '$_ns' containers list 2>/dev/null | tail -n +2") || _ns_list=""
            if [ -n "$_ns_list" ]; then
                _tasks_out=$(try_sudo_command_str "ctr $_ns tasks ($_ecs_socket)" \
                    "$_ecs_ctr_bin --address '$_ecs_socket' -n '$_ns' tasks list 2>/dev/null") || _tasks_out=""
                _ns_entries=$(echo "$_ns_list" | while IFS= read -r _ctr_line; do
                    _ctr_id=$(echo "$_ctr_line" | awk '{print $1}')
                    _ctr_img=$(echo "$_ctr_line" | awk '{print $2}')
                    [ -z "$_ctr_id" ] && continue
                    _ctr_state="unknown"
                    _task_match=$(echo "$_tasks_out" | grep "$_ctr_id" 2>/dev/null)
                    case "$_task_match" in
                        (*RUNNING*) _ctr_state="running" ;;
                        (*STOPPED*) _ctr_state="exited" ;;
                        (*PAUSED*) _ctr_state="paused" ;;
                    esac
                    # Detect k8s orchestrator managed
                    _is_k8s=false
                    [ "$_ns" = "k8s.io" ] && _is_k8s=true
                    _orch_type=""
                    [ "$_is_k8s" = "true" ] && _orch_type="kubernetes"
                    printf '{"container_id":"%s","name":"%s","image":"%s","image_id":"","state":"%s","created_at":"","ports":[],"resource_usage":{"cpu":{"usage_cores":0.0,"request_millicores":0,"limit_millicores":0},"memory":{"usage_mb":0.0,"request_mb":0,"limit_mb":0}},"network_mode":"","restart_policy":"","orchestrator_managed":%s,"orchestrator_ref":{"type":"%s","service_name":"","task_id":"","pod_name":"","namespace":""}}\n' \
                        "$(safe_json_string "$_ctr_id")" "$(safe_json_string "$_ctr_id")" "$(safe_json_string "$_ctr_img")" "$_ctr_state" "$_is_k8s" "$_orch_type"
                done)
                _oldIFS="$IFS"
                IFS='
'
                for _e in $_ns_entries; do
                    [ -z "$_e" ] && continue
                    _ctr_all_json="${_ctr_all_json:+${_ctr_all_json},}${_e}"
                done
                IFS="$_oldIFS"
            fi
        done
        [ -n "$_ctr_all_json" ] && _ctrd_cjson="[${_ctr_all_json}]"
    fi

    # Images detail via ctr per namespace
    if [ "$_ctrd_ic" -gt 0 ] 2>/dev/null; then
        _ctr_all_imgs=""
        for _ns in $_ecs_ns; do
            _ns_imgs=$(try_sudo_command_str "ctr $_ns images list ($_ecs_socket)" \
                "$_ecs_ctr_bin --address '$_ecs_socket' -n '$_ns' images list 2>/dev/null | tail -n +2") || _ns_imgs=""
            if [ -n "$_ns_imgs" ]; then
                _ns_img_entries=$(echo "$_ns_imgs" | while IFS= read -r _img_line; do
                    _img_ref=$(echo "$_img_line" | awk '{print $1}')
                    _img_size=$(echo "$_img_line" | awk '{print $NF}')
                    [ -z "$_img_ref" ] && continue
                    _img_repo=$(echo "$_img_ref" | sed 's/:.*$//')
                    _img_tag=$(echo "$_img_ref" | grep ':' | sed 's/^[^:]*://' | sed 's/@.*//')
                    [ -z "$_img_tag" ] && _img_tag="latest"
                    _img_smb="0.0"
                    case "$_img_size" in
                        (*[0-9]) _img_smb=$(echo "$_img_size" | awk '{printf "%.1f", $1 / 1048576}') ;;
                        (*MiB*|*MB*) _img_smb=$(echo "$_img_size" | sed 's/[^0-9.]//g') ;;
                        (*GiB*|*GB*) _img_smb=$(echo "$_img_size" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1 * 1024}') ;;
                        (*KiB*|*KB*) _img_smb=$(echo "$_img_size" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1 / 1024}') ;;
                    esac
                    printf '{"image_id":"%s","repository":"%s","tag":"%s","size_mb":%s,"created_at":""}\n' \
                        "$(safe_json_string "$_img_ref")" "$(safe_json_string "$_img_repo")" "$(safe_json_string "$_img_tag")" "$_img_smb"
                done)
                _oldIFS="$IFS"
                IFS='
'
                for _e in $_ns_img_entries; do
                    [ -z "$_e" ] && continue
                    _ctr_all_imgs="${_ctr_all_imgs:+${_ctr_all_imgs},}${_e}"
                done
                IFS="$_oldIFS"
            fi
        done
        [ -n "$_ctr_all_imgs" ] && _ctrd_ijson="[${_ctr_all_imgs}]"
    fi
}

# Discover additional containerd instances (MicroK8s, k3s, etc.)
discover_extra_containerd() {
    log_info "=== Discovering additional containerd instances ==="

    # Find all containerd processes and extract their socket addresses
    _ctrd_procs=$(ps -eo args 2>/dev/null | grep '[c]ontainerd' | grep -v 'shim' | grep -v grep) || _ctrd_procs=""
    log_info "containerd processes found: $(echo "$_ctrd_procs" | wc -l)"

    # Known system sockets to skip (already handled by discover_containerd)
    _sys_socks="/run/containerd/containerd.sock /var/run/containerd/containerd.sock"

    echo "$_ctrd_procs" | while IFS= read -r _proc_line; do
        [ -z "$_proc_line" ] && continue

        # Extract --address flag from the process
        _extra_sock=$(echo "$_proc_line" | grep -o '\-\-address [^ ]*' | awk '{print $2}')
        [ -z "$_extra_sock" ] && continue

        # Skip system containerd sockets
        _is_sys=false
        for _ss in $_sys_socks; do
            [ "$_extra_sock" = "$_ss" ] && _is_sys=true
        done
        $_is_sys && continue

        # Check socket accessibility
        if [ ! -S "$_extra_sock" ] && ! ($HAS_SUDO && sudo test -S "$_extra_sock" 2>/dev/null); then
            log_info "Extra containerd socket not accessible: $_extra_sock"
            continue
        fi

        log_info "Found additional containerd socket: $_extra_sock"

        # Determine the ctr binary to use (try the one from the same installation)
        _extra_ctr="ctr"
        _proc_bin=$(echo "$_proc_line" | awk '{print $1}')
        _proc_dir=$(dirname "$_proc_bin" 2>/dev/null)
        if [ -x "${_proc_dir}/ctr" ]; then
            _extra_ctr="${_proc_dir}/ctr"
        fi

        # Determine the runtime name from the socket path
        _extra_name="containerd"
        case "$_extra_sock" in
            (*microk8s*) _extra_name="containerd (microk8s)" ;;
            (*k3s*) _extra_name="containerd (k3s)" ;;
            (*rke2*) _extra_name="containerd (rke2)" ;;
        esac

        # Get version from the process binary
        _extra_version=$(try_command_str "extra containerd version" "$_proc_bin --version 2>/dev/null | awk '{print \$3}'") || _extra_version=""
        _extra_version=$(safe_json_string "$_extra_version")

        # Get storage root from process args (--root flag) or config
        _extra_root=$(echo "$_proc_line" | grep -o '\-\-root [^ ]*' | awk '{print $2}')
        [ -z "$_extra_root" ] && _extra_root="/var/lib/containerd"

        # Get config file and extract storage driver
        _extra_config=$(echo "$_proc_line" | grep -o '\-\-config [^ ]*' | awk '{print $2}')
        _extra_sd="overlayfs"
        if [ -n "$_extra_config" ] && [ -f "$_extra_config" ]; then
            _esd=$(grep -i 'snapshotter' "$_extra_config" 2>/dev/null | grep -v '#' | head -1 | sed 's/.*= *"//;s/"//')
            [ -n "$_esd" ] && _extra_sd="$_esd"
        fi

        # Enumerate containers and images
        _enumerate_containerd_socket "$_extra_sock" "$_extra_ctr"

        # Resource usage (estimate from the specific process)
        _extra_pid=$(echo "$_proc_line" | awk '{print $1}')
        # Use ps to get CPU/MEM for the binary path
        _extra_res=$(get_process_resource_usage "$(basename "$_proc_bin")")
        _extra_cpu=$(echo "$_extra_res" | awk '{print $1}')
        _extra_mem=$(echo "$_extra_res" | awk '{print $2}')

        _extra_json="{
          \"name\": \"$(safe_json_string "$_extra_name")\",
          \"runtime_type\": \"containerd\",
          \"version\": \"${_extra_version}\",
          \"socket\": \"$(safe_json_string "$_extra_sock")\",
          \"storage_driver\": \"$(safe_json_string "$_extra_sd")\",
          \"storage_root\": \"$(safe_json_string "$_extra_root")\",
          \"rootless\": false,
          \"cgroup_driver\": \"systemd\",
          \"image_count\": ${_ctrd_ic},
          \"container_count\": ${_ctrd_cc},
          \"client_version\": \"${_extra_version}\",
          \"server_version\": \"${_extra_version}\",
          \"resource_usage\": {
            \"cpu_cores\": ${_extra_cpu},
            \"memory_mb\": ${_extra_mem}
          },
          \"containers\": ${_ctrd_cjson},
          \"images\": ${_ctrd_ijson}
        }"

        # Append to EXTRA_CONTAINERD_RUNTIMES_JSON (newline-separated)
        if [ -z "$EXTRA_CONTAINERD_RUNTIMES_JSON" ]; then
            EXTRA_CONTAINERD_RUNTIMES_JSON="$_extra_json"
        else
            EXTRA_CONTAINERD_RUNTIMES_JSON="${EXTRA_CONTAINERD_RUNTIMES_JSON}
EXTRA_CTRD_SEP
${_extra_json}"
        fi
    done

    # The while loop runs in a subshell due to the pipe — capture output via temp file
    # Re-implement without pipe to avoid subshell
    :
}

# Re-implement discover_extra_containerd to avoid subshell issues with pipe
discover_extra_containerd() {
    log_info "=== Discovering additional containerd instances ==="

    _ctrd_procs=$(ps -eo args 2>/dev/null | grep '[c]ontainerd' | grep -v 'shim' | grep -v grep) || _ctrd_procs=""
    if [ -z "$_ctrd_procs" ]; then
        log_info "No containerd processes found"
        return
    fi

    _sys_socks="/run/containerd/containerd.sock /var/run/containerd/containerd.sock"

    # Use temp file to collect extra sockets and avoid subshell issues
    _extra_socks_file=$(mktemp 2>/dev/null || echo "/tmp/_extra_ctrd_$$")
    echo "$_ctrd_procs" | grep -o '\-\-address [^ ]*' | awk '{print $2}' | sort -u > "$_extra_socks_file" 2>/dev/null

    while IFS= read -r _extra_sock; do
        [ -z "$_extra_sock" ] && continue

        # Skip system containerd sockets
        _is_sys=false
        for _ss in $_sys_socks; do
            [ "$_extra_sock" = "$_ss" ] && _is_sys=true
        done
        $_is_sys && continue

        # Check socket accessibility
        if [ ! -S "$_extra_sock" ] && ! ($HAS_SUDO && sudo test -S "$_extra_sock" 2>/dev/null); then
            log_info "Extra containerd socket not accessible: $_extra_sock"
            continue
        fi

        log_info "Found additional containerd socket: $_extra_sock"

        # Find the matching process line to determine binary and config
        _proc_line=$(echo "$_ctrd_procs" | grep "$_extra_sock" | head -1)

        # Determine the ctr binary (from the same directory as containerd)
        _extra_ctr="ctr"
        _proc_bin=$(echo "$_proc_line" | awk '{print $1}')
        _proc_dir=$(dirname "$_proc_bin" 2>/dev/null)
        if [ -n "$_proc_dir" ] && [ -x "${_proc_dir}/ctr" ]; then
            _extra_ctr="${_proc_dir}/ctr"
        fi

        # Determine the runtime name
        _extra_name="containerd"
        case "$_extra_sock" in
            (*microk8s*) _extra_name="containerd (microk8s)" ;;
            (*k3s*) _extra_name="containerd (k3s)" ;;
            (*rke2*) _extra_name="containerd (rke2)" ;;
        esac

        # Version
        _extra_version=$(try_command_str "extra containerd version" "$_proc_bin --version 2>/dev/null | awk '{print \$3}'") || _extra_version=""
        _extra_version=$(safe_json_string "$_extra_version")

        # Storage root
        _extra_root=$(echo "$_proc_line" | grep -o '\-\-root [^ ]*' | awk '{print $2}')
        [ -z "$_extra_root" ] && _extra_root="/var/lib/containerd"

        # Storage driver from config
        _extra_config=$(echo "$_proc_line" | grep -o '\-\-config [^ ]*' | awk '{print $2}')
        _extra_sd="overlayfs"
        if [ -n "$_extra_config" ] && [ -f "$_extra_config" ]; then
            _esd=$(grep -i 'snapshotter' "$_extra_config" 2>/dev/null | grep -v '#' | head -1 | sed 's/.*= *"//;s/"//')
            [ -n "$_esd" ] && _extra_sd="$_esd"
        fi

        # Enumerate containers and images via the helper
        _enumerate_containerd_socket "$_extra_sock" "$_extra_ctr"

        # Resource usage
        _extra_res=$(get_process_resource_usage "$(basename "$_proc_bin")")
        _extra_cpu=$(echo "$_extra_res" | awk '{print $1}')
        _extra_mem=$(echo "$_extra_res" | awk '{print $2}')

        _extra_json="{
          \"name\": \"$(safe_json_string "$_extra_name")\",
          \"runtime_type\": \"containerd\",
          \"version\": \"${_extra_version}\",
          \"socket\": \"$(safe_json_string "$_extra_sock")\",
          \"storage_driver\": \"$(safe_json_string "$_extra_sd")\",
          \"storage_root\": \"$(safe_json_string "$_extra_root")\",
          \"rootless\": false,
          \"cgroup_driver\": \"systemd\",
          \"image_count\": ${_ctrd_ic},
          \"container_count\": ${_ctrd_cc},
          \"client_version\": \"${_extra_version}\",
          \"server_version\": \"${_extra_version}\",
          \"resource_usage\": {
            \"cpu_cores\": ${_extra_cpu},
            \"memory_mb\": ${_extra_mem}
          },
          \"containers\": ${_ctrd_cjson},
          \"images\": ${_ctrd_ijson}
        }"

        if [ -z "$EXTRA_CONTAINERD_RUNTIMES_JSON" ]; then
            EXTRA_CONTAINERD_RUNTIMES_JSON="$_extra_json"
        else
            EXTRA_CONTAINERD_RUNTIMES_JSON="${EXTRA_CONTAINERD_RUNTIMES_JSON},${_extra_json}"
        fi

        log_info "Extra containerd instance added: $_extra_name (containers=$_ctrd_cc, images=$_ctrd_ic)"

    done < "$_extra_socks_file"

    rm -f "$_extra_socks_file" 2>/dev/null
    log_info "Extra containerd discovery complete"
}

discover_containerd() {
    log_info "=== Discovering containerd ==="

    _ctrd_found=false
    if command -v containerd >/dev/null 2>&1; then
        _ctrd_found=true
    elif systemctl is-active containerd >/dev/null 2>&1; then
        _ctrd_found=true
    elif [ -S /run/containerd/containerd.sock ]; then
        _ctrd_found=true
    fi

    if ! $_ctrd_found; then
        log_info "containerd not detected"
        return
    fi

    CONTAINERD_DETECTED=true
    log_info "containerd detected"

    # Version
    _version=$(try_command_str "containerd version" "containerd --version 2>/dev/null | awk '{print \$3}'") || _version=""
    if [ -z "$_version" ]; then
        _version=$(try_command_str "containerd version via pkg" "dpkg -l containerd.io 2>/dev/null | awk '/containerd.io/{print \$3}' || rpm -q containerd.io 2>/dev/null | sed 's/containerd.io-//' | sed 's/-.*//'") || _version=""
    fi
    _version=$(safe_json_string "$_version")

    # Socket
    _socket="/run/containerd/containerd.sock"
    [ ! -S "$_socket" ] && _socket="/var/run/containerd/containerd.sock"

    # Storage driver
    _storage_driver=""
    if [ -f /etc/containerd/config.toml ]; then
        _storage_driver=$(try_command_str "containerd storage driver" "grep -i 'snapshotter' /etc/containerd/config.toml | grep -v '#' | head -1 | sed 's/.*= *\"//;s/\"//'") || _storage_driver=""
    fi
    if [ -z "$_storage_driver" ]; then
        _storage_driver=$(try_sudo_command_str "containerd config dump snapshotter" "containerd config dump 2>/dev/null | grep -i snapshotter | head -1 | sed 's/.*= *\"//;s/\"//'") || _storage_driver=""
    fi
    [ -z "$_storage_driver" ] && _storage_driver="overlayfs"
    _storage_driver=$(safe_json_string "$_storage_driver")

    # Storage root
    _storage_root="/var/lib/containerd"
    if [ -f /etc/containerd/config.toml ]; then
        _sr=$(grep -i 'root' /etc/containerd/config.toml 2>/dev/null | grep -v '#' | head -1 | sed 's/.*= *"//;s/"//')
        [ -n "$_sr" ] && _storage_root="$_sr"
    fi

    # Rootless
    _rootless=false

    # Cgroup driver
    _cgroup_driver="systemd"
    if [ -f /etc/containerd/config.toml ]; then
        _cg=$(grep -i 'SystemdCgroup' /etc/containerd/config.toml 2>/dev/null | grep -v '#' | head -1)
        case "$_cg" in *false*) _cgroup_driver="cgroupfs" ;; esac
    fi
    _cgroup_driver=$(safe_json_string "$_cgroup_driver")

    # Enumerate containerd namespaces (moby = Docker-managed, k8s.io = Kubernetes, default = standalone)
    _ctrd_namespaces=$(try_sudo_command_str "ctr namespaces" "ctr namespaces list -q 2>/dev/null") || _ctrd_namespaces=""
    if [ -z "$_ctrd_namespaces" ]; then
        _ctrd_namespaces="moby k8s.io default"
    fi
    log_info "containerd namespaces found: $_ctrd_namespaces"

    # Skip 'moby' namespace when Docker daemon is present — those containers are
    # already reported by discover_docker() with richer metadata.  Reporting them
    # again under containerd creates duplicates with hash-only names and image "-".
    _docker_is_present=false
    if [ -S /var/run/docker.sock ] || [ -S /run/docker.sock ] || pgrep -x dockerd >/dev/null 2>&1; then
        _docker_is_present=true
    fi
    if $_docker_is_present; then
        _filtered_ns=""
        for _ns in $_ctrd_namespaces; do
            case "$_ns" in
                moby) log_info "Skipping containerd 'moby' namespace (Docker daemon detected — containers reported under Docker runtime)" ;;
                *)    _filtered_ns="${_filtered_ns:+${_filtered_ns} }${_ns}" ;;
            esac
        done
        _ctrd_namespaces="$_filtered_ns"
        log_info "containerd namespaces after moby filter: $_ctrd_namespaces"
    fi

    # Container count — iterate all namespaces
    _container_count=0
    for _ns in $_ctrd_namespaces; do
        _nc=$(try_sudo_command_str "ctr $_ns containers" "ctr -n $_ns containers list -q 2>/dev/null | wc -l | tr -d ' '") || _nc="0"
        _nc=$(num_or_default "$_nc" 0)
        _container_count=$((_container_count + _nc))
        log_info "containerd namespace '$_ns': $_nc containers"
    done
    # Fallback: crictl for Kubernetes CRI
    if [ "$_container_count" = "0" ]; then
        _container_count=$(try_sudo_command_str "crictl containers count" "crictl ps -a 2>/dev/null | tail -n +2 | wc -l") || _container_count="0"
        _container_count=$(num_or_default "$_container_count" 0)
    fi

    # Running container count
    _running_count=0
    _rc_crictl=$(try_sudo_command_str "crictl running count" "crictl ps 2>/dev/null | tail -n +2 | wc -l") || _rc_crictl=""
    if [ -n "$_rc_crictl" ] && [ "$_rc_crictl" != "0" ]; then
        _running_count=$(num_or_default "$_rc_crictl" 0)
    else
        for _ns in $_ctrd_namespaces; do
            _nr=$(try_sudo_command_str "ctr $_ns tasks running" "ctr -n $_ns tasks list 2>/dev/null | grep -c RUNNING") || _nr="0"
            _nr=$(num_or_default "$_nr" 0)
            _running_count=$((_running_count + _nr))
        done
    fi
    _running_count=$(num_or_default "$_running_count" 0)

    # Image count — iterate all namespaces
    _image_count=0
    for _ns in $_ctrd_namespaces; do
        _ni=$(try_sudo_command_str "ctr $_ns images" "ctr -n $_ns images list -q 2>/dev/null | wc -l | tr -d ' '") || _ni="0"
        _ni=$(num_or_default "$_ni" 0)
        _image_count=$((_image_count + _ni))
        log_info "containerd namespace '$_ns': $_ni images"
    done
    # Fallback: crictl for Kubernetes CRI
    if [ "$_image_count" = "0" ]; then
        _image_count=$(try_sudo_command_str "crictl images count" "crictl images 2>/dev/null | tail -n +2 | wc -l") || _image_count="0"
        _image_count=$(num_or_default "$_image_count" 0)
    fi
    log_info "containerd totals: container_count=$_container_count image_count=$_image_count"

    # Resource usage
    _res=$(get_process_resource_usage "containerd")
    _ctrd_cpu=$(echo "$_res" | awk '{print $1}')
    _ctrd_mem=$(echo "$_res" | awk '{print $2}')

    # Client/server version
    _client_version="$_version"
    _server_version="$_version"

    # Containers detail
    _containers_json="[]"

    # Method 1: crictl (Kubernetes CRI)
    _cont_list=$(try_sudo_command_str "crictl ps all" "crictl ps -a -o json 2>/dev/null") || _cont_list=""
    if [ -n "$_cont_list" ] && $HAS_JQ; then
        # Step 1: Build base container list from crictl ps
        _containers_json=$(echo "$_cont_list" | jq -c '[.containers[]? | {
            container_id: .id,
            name: (.metadata.name // ""),
            image: (.imageRef // .image.image // ""),
            image_id: (.imageRef // ""),
            state: (if .state == "CONTAINER_RUNNING" then "running" elif .state == "CONTAINER_EXITED" then "exited" elif .state == "CONTAINER_CREATED" then "created" else "unknown" end),
            created_at: (.createdAt // ""),
            ports: [],
            resource_usage: {cpu: {usage_cores: 0.0, request_millicores: 0, limit_millicores: 0}, memory: {usage_mb: 0.0, request_mb: 0, limit_mb: 0}},
            network_mode: "",
            restart_policy: "",
            orchestrator_managed: (if .labels["io.kubernetes.pod.name"] then true else false end),
            orchestrator_ref: {
                type: (if .labels["io.kubernetes.pod.name"] then (if (.labels | keys[] | select(startswith("io.openshift"))) then "openshift" else "kubernetes" end) else "" end),
                service_name: "",
                task_id: "",
                pod_name: (.labels["io.kubernetes.pod.name"] // ""),
                namespace: (.labels["io.kubernetes.pod.namespace"] // "")
            }
        }]' 2>/dev/null) || _containers_json="[]"

        # Step 2: Enrich running containers with resource limits from crictl inspect
        _cid_list=$(echo "$_cont_list" | jq -r '.containers[]? | select(.state == "CONTAINER_RUNNING") | .id' 2>/dev/null) || _cid_list=""
        if [ -n "$_cid_list" ]; then
            for _cid in $_cid_list; do
                _ci=$(try_sudo_command_str "crictl inspect $_cid" "crictl inspect $_cid 2>/dev/null") || _ci=""
                [ -z "$_ci" ] && continue
                # Extract resource limits from OCI runtime spec
                _ci_cpu_quota=$(echo "$_ci" | jq -r '.info.runtimeSpec.linux.resources.cpu.quota // 0' 2>/dev/null) || _ci_cpu_quota=0
                _ci_cpu_period=$(echo "$_ci" | jq -r '.info.runtimeSpec.linux.resources.cpu.period // 0' 2>/dev/null) || _ci_cpu_period=0
                _ci_mem_limit=$(echo "$_ci" | jq -r '.info.runtimeSpec.linux.resources.memory.limit // 0' 2>/dev/null) || _ci_mem_limit=0

                _ci_cpu_lim=0
                if [ "$_ci_cpu_quota" -gt 0 ] 2>/dev/null && [ "$_ci_cpu_period" -gt 0 ] 2>/dev/null; then
                    _ci_cpu_lim=$((_ci_cpu_quota * 1000 / _ci_cpu_period))
                fi
                _ci_mem_lim=0
                if [ "$_ci_mem_limit" -gt 0 ] 2>/dev/null; then
                    _ci_mem_lim=$((_ci_mem_limit / 1048576))
                fi

                # Get pod-level ports from the sandbox
                _ci_pod_id=$(echo "$_ci" | jq -r '.info.sandboxID // ""' 2>/dev/null) || _ci_pod_id=""
                _ci_ports="[]"
                if [ -n "$_ci_pod_id" ]; then
                    _pi=$(try_sudo_command_str "crictl inspectp $_ci_pod_id" "crictl inspectp $_ci_pod_id 2>/dev/null") || _pi=""
                    if [ -n "$_pi" ]; then
                        _ci_ports=$(echo "$_pi" | jq -c '[(.info.config.port_mappings // [])[] | {
                            host_ip: (.host_ip // "0.0.0.0"),
                            host_port: (.host_port // 0),
                            container_port: (.container_port // 0),
                            protocol: (if .protocol == 0 then "tcp" elif .protocol == 1 then "udp" else "tcp" end)
                        }]' 2>/dev/null) || _ci_ports="[]"
                    fi
                fi
                [ -z "$_ci_ports" ] && _ci_ports="[]"

                # Merge into containers_json if we have any data to add
                if [ "$_ci_cpu_lim" -gt 0 ] 2>/dev/null || [ "$_ci_mem_lim" -gt 0 ] 2>/dev/null || [ "$_ci_ports" != "[]" ]; then
                    _containers_json=$(echo "$_containers_json" | jq -c --arg cid "$_cid" \
                        --argjson cpu_lim "$_ci_cpu_lim" --argjson mem_lim "$_ci_mem_lim" \
                        --argjson ports "$_ci_ports" \
                        '[.[] | if (.container_id | startswith($cid)) then
                            .ports = $ports |
                            .resource_usage.cpu.limit_millicores = $cpu_lim |
                            .resource_usage.memory.limit_mb = $mem_lim
                        else . end]' 2>/dev/null) || true
                fi
            done
            log_info "Enriched crictl containers with resource limits and ports"
        fi

        # Step 3: Enrich with pod-level requests from kubectl (if available)
        _my_hostname=$(hostname 2>/dev/null)
        # Resolve KUBECONFIG for kubectl — discover_containerd runs before discover_kubernetes
        _kctl_env=""
        if [ -n "$KUBECONFIG" ] && [ -r "$KUBECONFIG" ]; then
            _kctl_env="KUBECONFIG=$KUBECONFIG "
        else
            for _kc in "$HOME/.kube/config" /etc/kubernetes/admin.conf /etc/rancher/k3s/k3s.yaml; do
                if [ -r "$_kc" ]; then
                    _kctl_env="KUBECONFIG=$_kc "
                    break
                fi
            done
        fi
        _kubectl_cmd="kubectl"
        if ! command -v kubectl >/dev/null 2>&1; then
            if command -v microk8s >/dev/null 2>&1; then _kubectl_cmd="microk8s kubectl"
            elif command -v microk8s.kubectl >/dev/null 2>&1; then _kubectl_cmd="microk8s.kubectl"; fi
        fi
        _pods_json=$(try_sudo_command_str "kubectl pods on node" "${_kctl_env}${_kubectl_cmd} get pods --all-namespaces --field-selector spec.nodeName=$_my_hostname -o json 2>/dev/null") || _pods_json=""
        if [ -n "$_pods_json" ] && $HAS_JQ; then
            # Build a lookup: pod_name+container_name -> {cpu_req, mem_req, cpu_lim, mem_lim, ports}
            _pod_resources=$(echo "$_pods_json" | jq -c '[.items[]? | .metadata as $meta | .spec.containers[]? | {
                key: ($meta.name + "/" + .name),
                cpu_req: (if .resources.requests.cpu then (if (.resources.requests.cpu | test("m$")) then (.resources.requests.cpu | rtrimstr("m") | tonumber) else ((.resources.requests.cpu | tonumber) * 1000) end) else 0 end),
                mem_req: (if .resources.requests.memory then (if (.resources.requests.memory | test("Mi$")) then (.resources.requests.memory | rtrimstr("Mi") | tonumber) elif (.resources.requests.memory | test("Gi$")) then ((.resources.requests.memory | rtrimstr("Gi") | tonumber) * 1024) elif (.resources.requests.memory | test("Ki$")) then ((.resources.requests.memory | rtrimstr("Ki") | tonumber) / 1024 | floor) else 0 end) else 0 end),
                cpu_lim: (if .resources.limits.cpu then (if (.resources.limits.cpu | test("m$")) then (.resources.limits.cpu | rtrimstr("m") | tonumber) else ((.resources.limits.cpu | tonumber) * 1000) end) else 0 end),
                mem_lim: (if .resources.limits.memory then (if (.resources.limits.memory | test("Mi$")) then (.resources.limits.memory | rtrimstr("Mi") | tonumber) elif (.resources.limits.memory | test("Gi$")) then ((.resources.limits.memory | rtrimstr("Gi") | tonumber) * 1024) elif (.resources.limits.memory | test("Ki$")) then ((.resources.limits.memory | rtrimstr("Ki") | tonumber) / 1024 | floor) else 0 end) else 0 end),
                ports: [(.ports // [])[] | {host_ip: (.hostIP // ""), host_port: (.hostPort // 0), container_port: (.containerPort // 0), protocol: ((.protocol // "TCP") | ascii_downcase)}]
            }]' 2>/dev/null) || _pod_resources=""

            if [ -n "$_pod_resources" ] && [ "$_pod_resources" != "[]" ]; then
                _containers_json=$(echo "$_containers_json" | jq -c --argjson pr "$_pod_resources" '
                    [.[] | . as $c |
                        ($pr[] | select(.key == ($c.orchestrator_ref.pod_name + "/" + $c.name))) as $match |
                        if $match then
                            (if ($match.cpu_req > 0) then .resource_usage.cpu.request_millicores = $match.cpu_req else . end) |
                            (if ($match.cpu_lim > 0) then .resource_usage.cpu.limit_millicores = $match.cpu_lim else . end) |
                            (if ($match.mem_req > 0) then .resource_usage.memory.request_mb = $match.mem_req else . end) |
                            (if ($match.mem_lim > 0) then .resource_usage.memory.limit_mb = $match.mem_lim else . end) |
                            (if ($match.ports | length > 0) then .ports = $match.ports else . end)
                        else . end
                    ]' 2>/dev/null) || true
                log_info "Enriched containers with kubectl pod resource requests/limits"
            fi
        fi
    fi
    [ -z "$_containers_json" ] && _containers_json="[]"

    # Method 2: ctr per namespace (catches Docker-managed moby containers, standalone, etc.)
    if [ "$_containers_json" = "[]" ] && [ "$_container_count" -gt 0 ] 2>/dev/null; then
        _ctr_all_json=""
        for _ns in $_ctrd_namespaces; do
            _ns_list=$(try_sudo_command_str "ctr $_ns containers list" "ctr -n $_ns containers list 2>/dev/null | tail -n +2") || _ns_list=""
            if [ -n "$_ns_list" ]; then
                # Get tasks list once for state lookup
                _tasks_out=$(try_sudo_command_str "ctr $_ns tasks" "ctr -n $_ns tasks list 2>/dev/null") || _tasks_out=""
                # Capture entries from pipe subshell via stdout
                _ns_entries=$(echo "$_ns_list" | while IFS= read -r _ctr_line; do
                    _ctr_id=$(echo "$_ctr_line" | awk '{print $1}')
                    _ctr_img=$(echo "$_ctr_line" | awk '{print $2}')
                    [ -z "$_ctr_id" ] && continue
                    # Lookup task state
                    _ctr_state="unknown"
                    _task_match=$(echo "$_tasks_out" | grep "$_ctr_id" 2>/dev/null)
                    case "$_task_match" in
                        (*RUNNING*) _ctr_state="running" ;;
                        (*STOPPED*) _ctr_state="exited" ;;
                        (*PAUSED*) _ctr_state="paused" ;;
                    esac
                    printf '{"container_id":"%s","name":"%s","image":"%s","image_id":"","state":"%s","created_at":"","ports":[],"resource_usage":{"cpu":{"usage_cores":0.0,"request_millicores":0,"limit_millicores":0},"memory":{"usage_mb":0.0,"request_mb":0,"limit_mb":0}},"network_mode":"","restart_policy":"","orchestrator_managed":false,"orchestrator_ref":{"type":"","service_name":"","task_id":"","pod_name":"","namespace":""}}\n' \
                        "$(safe_json_string "$_ctr_id")" "$(safe_json_string "$_ctr_id")" "$(safe_json_string "$_ctr_img")" "$_ctr_state"
                done)
                # Join entries from this namespace into the accumulator
                _oldIFS="$IFS"
                IFS='
'
                for _e in $_ns_entries; do
                    [ -z "$_e" ] && continue
                    _ctr_all_json="${_ctr_all_json:+${_ctr_all_json},}${_e}"
                done
                IFS="$_oldIFS"
            fi
        done
        [ -n "$_ctr_all_json" ] && _containers_json="[${_ctr_all_json}]"
    fi
    log_info "containerd containers detail: $(echo "$_containers_json" | wc -c)B"

    # Images detail
    _images_json="[]"

    # Method 1: crictl (Kubernetes CRI)
    _img_list=$(try_sudo_command_str "crictl images json" "crictl images -o json 2>/dev/null") || _img_list=""
    if [ -n "$_img_list" ] && $HAS_JQ; then
        _images_json=$(echo "$_img_list" | jq -c '[.images[]? | {
            image_id: .id,
            repository: ((.repoTags[0] // "") | split(":")[0]),
            tag: ((.repoTags[0] // ":") | split(":")[1] // ""),
            size_mb: ((.size // 0) / 1048576 | . * 10 | floor / 10),
            created_at: ""
        }]' 2>/dev/null) || _images_json="[]"
    fi
    [ -z "$_images_json" ] && _images_json="[]"

    # Method 2: ctr per namespace for images
    if [ "$_images_json" = "[]" ] && [ "$_image_count" -gt 0 ] 2>/dev/null; then
        _ctr_all_imgs=""
        for _ns in $_ctrd_namespaces; do
            _ns_imgs=$(try_sudo_command_str "ctr $_ns images list" "ctr -n $_ns images list 2>/dev/null | tail -n +2") || _ns_imgs=""
            if [ -n "$_ns_imgs" ]; then
                # Capture entries from pipe subshell via stdout
                _ns_img_entries=$(echo "$_ns_imgs" | while IFS= read -r _img_line; do
                    _img_ref=$(echo "$_img_line" | awk '{print $1}')
                    _img_size=$(echo "$_img_line" | awk '{print $NF}')
                    [ -z "$_img_ref" ] && continue
                    # Parse repo:tag from reference
                    _img_repo=$(echo "$_img_ref" | sed 's/:.*$//')
                    _img_tag=$(echo "$_img_ref" | grep ':' | sed 's/^[^:]*://' | sed 's/@.*//')
                    [ -z "$_img_tag" ] && _img_tag="latest"
                    # Convert size to MB (ctr shows bytes or human-readable)
                    _img_smb="0.0"
                    case "$_img_size" in
                        (*[0-9]) _img_smb=$(echo "$_img_size" | awk '{printf "%.1f", $1 / 1048576}') ;;
                        (*MiB*|*MB*) _img_smb=$(echo "$_img_size" | sed 's/[^0-9.]//g') ;;
                        (*GiB*|*GB*) _img_smb=$(echo "$_img_size" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1 * 1024}') ;;
                        (*KiB*|*KB*) _img_smb=$(echo "$_img_size" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1 / 1024}') ;;
                    esac
                    printf '{"image_id":"%s","repository":"%s","tag":"%s","size_mb":%s,"created_at":""}\n' \
                        "$(safe_json_string "$_img_ref")" "$(safe_json_string "$_img_repo")" "$(safe_json_string "$_img_tag")" "$_img_smb"
                done)
                # Join entries from this namespace into the accumulator
                _oldIFS="$IFS"
                IFS='
'
                for _e in $_ns_img_entries; do
                    [ -z "$_e" ] && continue
                    _ctr_all_imgs="${_ctr_all_imgs:+${_ctr_all_imgs},}${_e}"
                done
                IFS="$_oldIFS"
            fi
        done
        [ -n "$_ctr_all_imgs" ] && _images_json="[${_ctr_all_imgs}]"
    fi
    log_info "containerd images detail: $(echo "$_images_json" | wc -c)B"

    CONTAINERD_RUNTIME_JSON="{
          \"name\": \"containerd\",
          \"runtime_type\": \"containerd\",
          \"version\": \"${_version}\",
          \"socket\": \"$(safe_json_string "$_socket")\",
          \"storage_driver\": \"${_storage_driver}\",
          \"storage_root\": \"$(safe_json_string "$_storage_root")\",
          \"rootless\": ${_rootless},
          \"cgroup_driver\": \"${_cgroup_driver}\",
          \"image_count\": ${_image_count},
          \"container_count\": ${_container_count},
          \"client_version\": \"${_client_version}\",
          \"server_version\": \"${_server_version}\",
          \"resource_usage\": {
            \"cpu_cores\": ${_ctrd_cpu},
            \"memory_mb\": ${_ctrd_mem}
          },
          \"containers\": ${_containers_json},
          \"images\": ${_images_json}
        }"
    log_info "containerd discovery complete"
}

# ========================
# 2.3c CRI-O discovery
# ========================
CRIO_DETECTED=false
CRIO_RUNTIME_JSON=""

discover_crio() {
    log_info "=== Discovering CRI-O ==="

    _crio_found=false
    if command -v crio >/dev/null 2>&1; then
        _crio_found=true
    elif systemctl is-active crio >/dev/null 2>&1; then
        _crio_found=true
    elif [ -S /var/run/crio/crio.sock ]; then
        _crio_found=true
    fi

    if ! $_crio_found; then
        log_info "CRI-O not detected"
        return
    fi

    CRIO_DETECTED=true
    log_info "CRI-O detected"

    # Version
    _version=$(try_command_str "crio version" "crio --version 2>/dev/null | head -1 | awk '{print \$NF}'") || _version=""
    if [ -z "$_version" ]; then
        _version=$(try_sudo_command_str "crictl version for crio" "crictl version 2>/dev/null | grep 'RuntimeVersion' | awk '{print \$2}'") || _version=""
    fi
    _version=$(safe_json_string "$_version")

    # Socket
    _socket="/var/run/crio/crio.sock"

    # Storage driver
    _storage_driver=$(try_sudo_command_str "crio storage_driver" "crio config 2>/dev/null | grep 'storage_driver' | head -1 | sed 's/.*= *\"//;s/\"//'") || _storage_driver=""
    if [ -z "$_storage_driver" ] && [ -f /etc/crio/crio.conf ]; then
        _storage_driver=$(try_command_str "crio conf storage" "grep 'storage_driver' /etc/crio/crio.conf | head -1 | sed 's/.*= *\"//;s/\"//'") || _storage_driver=""
    fi
    [ -z "$_storage_driver" ] && _storage_driver="overlay"
    _storage_driver=$(safe_json_string "$_storage_driver")

    # Storage root
    _storage_root="/var/lib/containers/storage"

    # Cgroup driver
    _cgroup_driver=$(try_sudo_command_str "crio cgroup_manager" "crio config 2>/dev/null | grep 'cgroup_manager' | head -1 | sed 's/.*= *\"//;s/\"//'") || _cgroup_driver=""
    if [ -z "$_cgroup_driver" ] && [ -f /etc/crio/crio.conf ]; then
        _cgroup_driver=$(try_command_str "crio conf cgroup" "grep 'cgroup_manager' /etc/crio/crio.conf | head -1 | sed 's/.*= *\"//;s/\"//'") || _cgroup_driver=""
    fi
    [ -z "$_cgroup_driver" ] && _cgroup_driver="systemd"
    _cgroup_driver=$(safe_json_string "$_cgroup_driver")

    # Container count
    _container_count=$(try_sudo_command_str "crictl ps count" "crictl ps -a 2>/dev/null | tail -n +2 | wc -l") || _container_count="0"
    _container_count=$(num_or_default "$_container_count" 0)

    # Image count
    _image_count=$(try_sudo_command_str "crictl images count" "crictl images 2>/dev/null | tail -n +2 | wc -l") || _image_count="0"
    _image_count=$(num_or_default "$_image_count" 0)

    # Resource usage
    _res=$(get_process_resource_usage "crio")
    _crio_cpu=$(echo "$_res" | awk '{print $1}')
    _crio_mem=$(echo "$_res" | awk '{print $2}')

    _rootless=false

    # Containers
    _containers_json="[]"
    _cont_list=$(try_sudo_command_str "crictl ps crio" "crictl ps -a -o json 2>/dev/null") || _cont_list=""
    if [ -n "$_cont_list" ] && $HAS_JQ; then
        _containers_json=$(echo "$_cont_list" | jq -c '[.containers[]? | {
            container_id: .id,
            name: (.metadata.name // ""),
            image: (.imageRef // .image.image // ""),
            image_id: (.imageRef // ""),
            state: (if .state == "CONTAINER_RUNNING" then "running" elif .state == "CONTAINER_EXITED" then "exited" elif .state == "CONTAINER_CREATED" then "created" else "unknown" end),
            created_at: (.createdAt // ""),
            ports: [],
            resource_usage: {cpu: {usage_cores: 0.0, request_millicores: 0, limit_millicores: 0}, memory: {usage_mb: 0.0, request_mb: 0, limit_mb: 0}},
            network_mode: "",
            restart_policy: "",
            orchestrator_managed: (if .labels["io.kubernetes.pod.name"] then true else false end),
            orchestrator_ref: {
                type: (if .labels["io.kubernetes.pod.name"] then (if (.labels | keys[] | select(startswith("io.openshift"))) then "openshift" else "kubernetes" end) else "" end),
                service_name: "",
                task_id: "",
                pod_name: (.labels["io.kubernetes.pod.name"] // ""),
                namespace: (.labels["io.kubernetes.pod.namespace"] // "")
            }
        }]' 2>/dev/null) || _containers_json="[]"
    fi
    [ -z "$_containers_json" ] && _containers_json="[]"

    # Images
    _images_json="[]"
    _img_list=$(try_sudo_command_str "crictl images for crio" "crictl images -o json 2>/dev/null") || _img_list=""
    if [ -n "$_img_list" ] && $HAS_JQ; then
        _images_json=$(echo "$_img_list" | jq -c '[.images[]? | {
            image_id: .id,
            repository: ((.repoTags[0] // "") | split(":")[0]),
            tag: ((.repoTags[0] // ":") | split(":")[1] // ""),
            size_mb: ((.size // 0) / 1048576 | . * 10 | floor / 10),
            created_at: ""
        }]' 2>/dev/null) || _images_json="[]"
    fi
    [ -z "$_images_json" ] && _images_json="[]"

    CRIO_RUNTIME_JSON="{
          \"name\": \"crio\",
          \"runtime_type\": \"crio\",
          \"version\": \"${_version}\",
          \"socket\": \"$(safe_json_string "$_socket")\",
          \"storage_driver\": \"${_storage_driver}\",
          \"storage_root\": \"$(safe_json_string "$_storage_root")\",
          \"rootless\": ${_rootless},
          \"cgroup_driver\": \"${_cgroup_driver}\",
          \"image_count\": ${_image_count},
          \"container_count\": ${_container_count},
          \"client_version\": \"${_version}\",
          \"server_version\": \"${_version}\",
          \"resource_usage\": {
            \"cpu_cores\": ${_crio_cpu},
            \"memory_mb\": ${_crio_mem}
          },
          \"containers\": ${_containers_json},
          \"images\": ${_images_json}
        }"
    log_info "CRI-O discovery complete"
}

# ========================
# 2.3d Podman discovery
# ========================
PODMAN_DETECTED=false
PODMAN_RUNTIME_JSON=""

discover_podman() {
    log_info "=== Discovering Podman ==="

    _podman_found=false
    if command -v podman >/dev/null 2>&1; then
        _podman_found=true
    elif systemctl is-active podman >/dev/null 2>&1; then
        _podman_found=true
    elif [ -S /run/podman/podman.sock ]; then
        _podman_found=true
    fi

    if ! $_podman_found; then
        log_info "Podman not detected"
        return
    fi

    PODMAN_DETECTED=true
    log_info "Podman detected"

    # Version
    _version=$(try_command_str "podman version" "podman version --format '{{.Client.Version}}' 2>/dev/null || podman --version 2>/dev/null | awk '{print \$NF}'") || _version=""
    _version=$(safe_json_string "$_version")

    # Socket
    _socket=""
    if [ -S /run/podman/podman.sock ]; then
        _socket="/run/podman/podman.sock"
    elif [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock" ]; then
        _socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    fi

    # Storage driver
    _storage_driver=$(try_command_str "podman storage driver" "podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null") || _storage_driver=""
    [ -z "$_storage_driver" ] && _storage_driver="overlay"
    _storage_driver=$(safe_json_string "$_storage_driver")

    # Storage root
    _storage_root=$(try_command_str "podman graph root" "podman info --format '{{.Store.GraphRoot}}' 2>/dev/null") || _storage_root="/var/lib/containers/storage"
    _storage_root=$(safe_json_string "$_storage_root")

    # Rootless
    _rootless=false
    _rootless_check=$(try_command_str "podman rootless" "podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null") || _rootless_check=""
    case "$_rootless_check" in *true*|*True*) _rootless=true ;; esac

    # Cgroup driver
    _cgroup_driver=$(try_command_str "podman cgroup" "podman info --format '{{.Host.CgroupManager}}' 2>/dev/null") || _cgroup_driver="systemd"
    _cgroup_driver=$(safe_json_string "$_cgroup_driver")

    # Container count
    _container_count=$(try_command_str "podman container count" "podman ps -a --format '{{.ID}}' 2>/dev/null | wc -l") || _container_count="0"
    _container_count=$(num_or_default "$_container_count" 0)

    # Image count
    _image_count=$(try_command_str "podman image count" "podman images --format '{{.ID}}' 2>/dev/null | wc -l") || _image_count="0"
    _image_count=$(num_or_default "$_image_count" 0)

    # Resource usage
    _res=$(get_process_resource_usage "podman")
    _podman_cpu=$(echo "$_res" | awk '{print $1}')
    _podman_mem=$(echo "$_res" | awk '{print $2}')

    # Containers
    _containers_json="[]"
    _cont_list=$(try_command_str "podman ps json" "podman ps -a --format json 2>/dev/null") || _cont_list=""
    if [ -n "$_cont_list" ] && $HAS_JQ; then
        _containers_json=$(echo "$_cont_list" | jq -c '[.[]? | {
            container_id: (.Id // .id // ""),
            name: ((.Names[0]? // .Name // .name // "") | gsub("^/"; "")),
            image: (.Image // .image // ""),
            image_id: (.ImageID // .imageID // ""),
            state: ((.State // .state // "unknown") | ascii_downcase),
            created_at: (.Created // .CreatedAt // ""),
            ports: [],
            resource_usage: {cpu: {usage_cores: 0.0, request_millicores: 0, limit_millicores: 0}, memory: {usage_mb: 0.0, request_mb: 0, limit_mb: 0}},
            network_mode: "",
            restart_policy: "",
            orchestrator_managed: false,
            orchestrator_ref: {type: "", service_name: "", task_id: "", pod_name: "", namespace: ""}
        }]' 2>/dev/null) || _containers_json="[]"
    fi
    [ -z "$_containers_json" ] && _containers_json="[]"

    # Images
    _images_json="[]"
    _img_list=$(try_command_str "podman images json" "podman images --format json 2>/dev/null") || _img_list=""
    if [ -n "$_img_list" ] && $HAS_JQ; then
        _images_json=$(echo "$_img_list" | jq -c '[.[]? | {
            image_id: (.Id // .id // ""),
            repository: ((.Names[0]? // "") | split(":")[0]),
            tag: ((.Names[0]? // ":") | split(":")[1] // ""),
            size_mb: ((.Size // 0) / 1048576 | . * 10 | floor / 10),
            created_at: (.Created // "")
        }]' 2>/dev/null) || _images_json="[]"
    fi
    [ -z "$_images_json" ] && _images_json="[]"

    PODMAN_RUNTIME_JSON="{
          \"name\": \"podman\",
          \"runtime_type\": \"podman\",
          \"version\": \"${_version}\",
          \"socket\": \"$(safe_json_string "$_socket")\",
          \"storage_driver\": \"${_storage_driver}\",
          \"storage_root\": \"${_storage_root}\",
          \"rootless\": ${_rootless},
          \"cgroup_driver\": \"${_cgroup_driver}\",
          \"image_count\": ${_image_count},
          \"container_count\": ${_container_count},
          \"client_version\": \"${_version}\",
          \"server_version\": \"${_version}\",
          \"resource_usage\": {
            \"cpu_cores\": ${_podman_cpu},
            \"memory_mb\": ${_podman_mem}
          },
          \"containers\": ${_containers_json},
          \"images\": ${_images_json}
        }"
    log_info "Podman discovery complete"
}

# ========================
# 2.4 Orchestrators
# ========================

# ========================
# 2.4a Docker Swarm
# ========================
SWARM_DETECTED=false
SWARM_JSON=""

discover_docker_swarm() {
    log_info "=== Discovering Docker Swarm ==="

    _swarm_state=""

    # Method 1: docker info --format (Go template)
    _swarm_state=$(try_command_str "swarm state via format" "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null") || _swarm_state=""
    log_info "Swarm detection method 1 (docker info --format): '${_swarm_state}'"

    # Method 2: docker info plain text grep (works on all Docker versions)
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        _swarm_grep=$(try_command_str "swarm state via grep" "docker info 2>/dev/null | grep -i '^ *Swarm:' | awk '{print \$2}'") || _swarm_grep=""
        log_info "Swarm detection method 2 (docker info grep): '${_swarm_grep}'"
        if [ -n "$_swarm_grep" ]; then
            _swarm_state="$_swarm_grep"
        fi
    fi

    # Method 3: sudo docker info --format (in case docker group membership is missing)
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        _swarm_state_sudo=$(try_sudo_command_str "swarm state via sudo format" "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null") || _swarm_state_sudo=""
        log_info "Swarm detection method 3 (sudo docker info --format): '${_swarm_state_sudo}'"
        if [ -n "$_swarm_state_sudo" ]; then
            _swarm_state="$_swarm_state_sudo"
        fi
    fi

    # Method 4: sudo docker info plain text grep
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        _swarm_grep2=$(try_sudo_command_str "swarm state via sudo grep" "docker info 2>/dev/null | grep -i '^ *Swarm:' | awk '{print \$2}'") || _swarm_grep2=""
        log_info "Swarm detection method 4 (sudo docker info grep): '${_swarm_grep2}'"
        if [ -n "$_swarm_grep2" ]; then
            _swarm_state="$_swarm_grep2"
        fi
    fi

    # Method 5: Docker socket API (works without docker CLI)
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        _swarm_state_sock=$(try_command_str "swarm state via socket" "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | grep -o '\"LocalNodeState\":\"[^\"]*\"' | sed 's/\"LocalNodeState\":\"//;s/\"//'") || _swarm_state_sock=""
        log_info "Swarm detection method 5 (docker socket API): '${_swarm_state_sock}'"
        if [ -n "$_swarm_state_sock" ]; then
            _swarm_state="$_swarm_state_sock"
        fi
    fi

    # Method 6: Check for Swarm filesystem artifacts + listening port 2377
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        if [ -d /var/lib/docker/swarm ] || [ -d /var/lib/docker/swarm/raft ]; then
            if ss -tln 2>/dev/null | grep -q ':2377 ' || netstat -tln 2>/dev/null | grep -q ':2377 '; then
                _swarm_state="active"
                log_info "Swarm detection method 6 (filesystem + port 2377): active"
            fi
        fi
    fi

    # Method 7: Check docker node ls (only works on manager nodes but confirms swarm)
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        if try_command_str "swarm node ls check" "docker node ls >/dev/null 2>&1"; then
            _swarm_state="active"
            log_info "Swarm detection method 7 (docker node ls): active"
        elif try_sudo_command_str "swarm node ls sudo check" "docker node ls >/dev/null 2>&1"; then
            _swarm_state="active"
            log_info "Swarm detection method 7b (sudo docker node ls): active"
        fi
    fi

    # --- Unprivileged detection methods (no docker socket / no sudo needed) ---

    # Method 8: docker_gwbridge network interface (created automatically by Swarm)
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        if ip link show docker_gwbridge >/dev/null 2>&1 || ifconfig docker_gwbridge >/dev/null 2>&1; then
            _swarm_state="active"
            log_info "Swarm detection method 8 (docker_gwbridge interface): active"
        fi
    fi

    # Method 9: Swarm-specific ports listening (2377 cluster mgmt, 7946 gossip)
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        _swarm_port_count=0
        for _sp in 2377 7946; do
            if ss -tln 2>/dev/null | grep -q ":${_sp} " || netstat -tln 2>/dev/null | grep -q ":${_sp} "; then
                _swarm_port_count=$(( _swarm_port_count + 1 ))
            fi
        done
        if [ "$_swarm_port_count" -ge 2 ]; then
            _swarm_state="active"
            log_info "Swarm detection method 9 (ports 2377+7946 listening): active"
        elif [ "$_swarm_port_count" -ge 1 ]; then
            # Single port — only trust if docker_gwbridge also exists
            if ip link show docker_gwbridge >/dev/null 2>&1; then
                _swarm_state="active"
                log_info "Swarm detection method 9b (1 swarm port + gwbridge): active"
            fi
        fi
    fi

    # Method 10: Check for swarm-related processes (unprivileged ps)
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        if ps -eo args 2>/dev/null | grep -q '[d]ockerd' 2>/dev/null; then
            if ps -eo args 2>/dev/null | grep -qE 'swarm|docker-containerd.*swarm' 2>/dev/null; then
                _swarm_state="active"
                log_info "Swarm detection method 10 (swarm process found): active"
            fi
        fi
    fi

    # Method 11: VXLAN port 4789 + docker_gwbridge (Swarm overlay networking)
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        if ss -uln 2>/dev/null | grep -q ':4789 ' || netstat -uln 2>/dev/null | grep -q ':4789 '; then
            if ip link show docker_gwbridge >/dev/null 2>&1 || [ -d /var/lib/docker/swarm ]; then
                _swarm_state="active"
                log_info "Swarm detection method 11 (VXLAN 4789 + gwbridge/swarm dir): active"
            fi
        fi
    fi

    # Method 12: Network namespace for Swarm ingress
    if [ -z "$_swarm_state" ] || [ "$_swarm_state" = "inactive" ]; then
        if [ -f /var/run/docker/netns/ingress_sbox ] || ls /var/run/docker/netns/ 2>/dev/null | grep -q 'ingress'; then
            _swarm_state="active"
            log_info "Swarm detection method 12 (ingress_sbox netns): active"
        fi
    fi

    log_info "Final swarm state: '${_swarm_state}'"
    if [ "$_swarm_state" != "active" ]; then
        log_info "Docker Swarm not active (state: ${_swarm_state:-none})"
        return
    fi

    SWARM_DETECTED=true
    log_info "Docker Swarm active"

    # Version — try docker CLI, then dpkg/rpm, then dockerd binary
    _version=$(docker_try "docker version for swarm" "docker version --format '{{.Server.Version}}'")
    if [ -z "$_version" ]; then
        _version=$(docker_try "docker version no-format" "docker version 2>/dev/null | grep -i 'Server:' -A2 | grep 'Version:' | awk '{print \$2}'")
    fi
    if [ -z "$_version" ]; then
        # Unprivileged: get version from package manager
        _version=$(try_command_str "docker version dpkg" "dpkg -l 2>/dev/null | grep -i docker-ce | awk '{print \$3}' | head -1 | sed 's/[^0-9.].*//; s/^[0-9]*://'") || _version=""
    fi
    if [ -z "$_version" ]; then
        _version=$(try_command_str "docker version rpm" "rpm -qa 2>/dev/null | grep -i docker-ce | head -1 | sed 's/docker-ce-//i; s/-.*//'") || _version=""
    fi
    if [ -z "$_version" ]; then
        _version=$(try_command_str "docker version binary" "dockerd --version 2>/dev/null | awk '{print \$3}' | tr -d ','") || _version=""
    fi
    _version=$(safe_json_string "$_version")

    # Cluster ID
    _cluster_id=$(docker_try "swarm cluster ID" "docker info --format '{{.Swarm.Cluster.ID}}'")
    if [ -z "$_cluster_id" ]; then
        _cluster_id=$(docker_try "swarm cluster ID grep" "docker info 2>/dev/null | grep 'ClusterID:' | awk '{print \$2}'")
    fi
    if [ -z "$_cluster_id" ]; then
        _cluster_id=$(try_command_str "swarm ID via socket" "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | grep -o '\"Cluster\":{\"ID\":\"[^\"]*\"' | sed 's/.*\"ID\":\"//;s/\"//'") || _cluster_id=""
    fi
    # Fallback for worker nodes: read cluster ID from swarm TLS certificate (O= field)
    if [ -z "$_cluster_id" ]; then
        _cert_path="/var/lib/docker/swarm/certificates/swarm-node.crt"
        if [ -f "$_cert_path" ] || ($HAS_SUDO && sudo test -f "$_cert_path" 2>/dev/null); then
            _cluster_id=$(try_sudo_command_str "swarm cluster ID from cert" \
                "openssl x509 -in $_cert_path -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/.*O=\([^,]*\).*/\1/p'") || _cluster_id=""
            if [ -n "$_cluster_id" ]; then
                log_info "Got cluster_id from swarm TLS certificate: ${_cluster_id}"
            fi
        else
            log_info "Swarm TLS certificate not found at $_cert_path"
        fi
    fi
    _cluster_id=$(safe_json_string "$_cluster_id")

    # Current node
    _node_id=$(docker_try "swarm node id" "docker info --format '{{.Swarm.NodeID}}'")
    if [ -z "$_node_id" ]; then
        _node_id=$(docker_try "swarm node id grep" "docker info 2>/dev/null | grep 'NodeID:' | awk '{print \$2}'")
    fi
    _node_id=$(safe_json_string "$_node_id")

    _control_avail=$(docker_try "swarm control available" "docker info --format '{{.Swarm.ControlAvailable}}'")
    if [ -z "$_control_avail" ]; then
        _control_avail=$(docker_try "swarm control via grep" "docker info 2>/dev/null | grep -i 'Is Manager:' | awk '{print \$3}'")
    fi
    # Unprivileged manager detection: port 2377 = manager node
    if [ -z "$_control_avail" ]; then
        if ss -tln 2>/dev/null | grep -q ':2377 ' || netstat -tln 2>/dev/null | grep -q ':2377 '; then
            _control_avail="true"
            log_info "Detected manager role via port 2377"
        fi
    fi
    _node_role="worker"
    case "$_control_avail" in (*true*|*True*|*yes*|*Yes*) _node_role="manager" ;; esac

    _node_avail="active"

    # Nodes
    _total_nodes=0
    _manager_count=0
    _worker_count=0
    _manager_nodes_json="[]"
    _worker_nodes_json="[]"

    if [ "$_node_role" = "manager" ]; then
        _nodes_raw=$(docker_try "docker node ls" "docker node ls --format '{{.ID}}|{{.Hostname}}|{{.Status}}|{{.ManagerStatus}}'")
        log_info "docker node ls raw output: '${_nodes_raw}'"
        if [ -n "$_nodes_raw" ]; then
            _manager_list=""
            _worker_list=""
            _total_nodes=0
            _manager_count=0
            _worker_count=0

            echo "$_nodes_raw" | grep -v '^$' | while IFS='|' read -r _nid _nname _nstatus _nmgr; do
                log_info "Node: id='${_nid}' name='${_nname}' status='${_nstatus}' mgr='${_nmgr}'"
            done

            # Count totals outside subshell
            _total_nodes=$(echo "$_nodes_raw" | grep -cv '^$')
            _manager_count=$(echo "$_nodes_raw" | grep -v '^$' | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); if ($4 != "") print}' | wc -l | tr -d ' ')
            _worker_count=$(( _total_nodes - _manager_count ))

            # Build manager nodes JSON
            _manager_nodes_json="[$(echo "$_nodes_raw" | grep -v '^$' | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); if ($4 != "") print}' | {
                _mf=true
                while IFS='|' read -r _nid _nname _nstatus _nmgr; do
                    case "$_nstatus" in
                        (Ready) _ns="ready" ;;
                        (Down)  _ns="down" ;;
                        (*)     _ns="unknown" ;;
                    esac
                    if ! $_mf; then printf ','; fi; _mf=false
                    printf '{"name":"%s","node_id":"%s","status":"%s"}' \
                        "$(safe_json_string "$_nname")" "$(safe_json_string "$_nid")" "$_ns"
                done
            })]"

            # Build worker nodes JSON
            _worker_nodes_json="[$(echo "$_nodes_raw" | grep -v '^$' | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); if ($4 == "") print}' | {
                _wf=true
                while IFS='|' read -r _nid _nname _nstatus _nmgr; do
                    [ -z "$_nid" ] && continue
                    case "$_nstatus" in
                        (Ready) _ns="ready" ;;
                        (Down)  _ns="down" ;;
                        (*)     _ns="unknown" ;;
                    esac
                    if ! $_wf; then printf ','; fi; _wf=false
                    printf '{"name":"%s","node_id":"%s","status":"%s"}' \
                        "$(safe_json_string "$_nname")" "$(safe_json_string "$_nid")" "$_ns"
                done
            })]"

            log_info "Node counts: total=${_total_nodes} managers=${_manager_count} workers=${_worker_count}"
        else
            # Unprivileged fallback: docker node ls failed but we know this is a manager
            # Report at least the current node
            log_info "docker node ls unavailable (no socket access) — using unprivileged fallback"
            _cur_hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
            _cur_hostname=$(safe_json_string "$_cur_hostname")
            _cur_nid=$(safe_json_string "$_node_id")
            _total_nodes=1
            _manager_count=1
            _worker_count=0
            _manager_nodes_json="[{\"name\":\"${_cur_hostname}\",\"node_id\":\"${_cur_nid}\",\"status\":\"ready\"}]"
            _worker_nodes_json="[]"
            log_info "Unprivileged fallback: reported current node as manager (hostname=${_cur_hostname})"
        fi
    else
        # Worker node — report self and try to discover manager nodes
        log_info "Current node is a worker — gathering available cluster info"
        _cur_hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
        _cur_hostname=$(safe_json_string "$_cur_hostname")
        _cur_nid=$(safe_json_string "$_node_id")
        _worker_count=1
        _worker_nodes_json="[{\"name\":\"${_cur_hostname}\",\"node_id\":\"${_cur_nid}\",\"status\":\"ready\"}]"

        # Try to discover manager nodes via RemoteManagers (available on workers)
        _remote_mgrs=""
        _remote_mgrs=$(docker_try "swarm remote managers json" "docker info --format '{{json .Swarm.RemoteManagers}}'")
        if [ -z "$_remote_mgrs" ] || [ "$_remote_mgrs" = "null" ] || [ "$_remote_mgrs" = "<no value>" ]; then
            _remote_mgrs=$(docker_try "swarm remote managers via socket" \
                "curl -s --unix-socket /var/run/docker.sock http://localhost/info 2>/dev/null | sed -n 's/.*\"RemoteManagers\":\\(\\[[^]]*\\]\\).*/\\1/p'")
        fi
        log_info "RemoteManagers raw: ${_remote_mgrs}"

        _manager_count=0
        _manager_nodes_json="[]"

        if [ -n "$_remote_mgrs" ] && [ "$_remote_mgrs" != "null" ] && [ "$_remote_mgrs" != "<no value>" ]; then
            if $HAS_JQ; then
                _manager_count=$(echo "$_remote_mgrs" | jq 'if type == "array" then length else 0 end' 2>/dev/null)
                _manager_count=$(num_or_default "$_manager_count" 0)
                if [ "$_manager_count" -gt 0 ] 2>/dev/null; then
                    _manager_nodes_json=$(echo "$_remote_mgrs" | jq -c '[.[] | {name: .Addr, node_id: .NodeID, status: "ready"}]' 2>/dev/null)
                    [ -z "$_manager_nodes_json" ] && _manager_nodes_json="[]"
                fi
            else
                # Without jq: count NodeID occurrences and build JSON with awk
                _manager_count=$(echo "$_remote_mgrs" | grep -o '"NodeID"' | wc -l | tr -d ' ')
                _manager_count=$(num_or_default "$_manager_count" 0)
                if [ "$_manager_count" -gt 0 ] 2>/dev/null; then
                    _manager_nodes_json=$(echo "$_remote_mgrs" | sed 's/\[//;s/\]//' | tr '}' '\n' | awk -F'"' '
                        BEGIN { printf "[" }
                        /NodeID/ {
                            for (i=1; i<=NF; i++) {
                                if ($i == "NodeID") nid=$(i+2)
                                if ($i == "Addr") addr=$(i+2)
                            }
                            if (c++ > 0) printf ","
                            printf "{\"name\":\"%s\",\"node_id\":\"%s\",\"status\":\"ready\"}", addr, nid
                        }
                        END { printf "]" }
                    ')
                    [ -z "$_manager_nodes_json" ] && _manager_nodes_json="[]"
                fi
            fi
        fi

        # Fallback: parse manager addresses from docker info plain text
        if [ "$_manager_count" -eq 0 ] 2>/dev/null; then
            _mgr_addrs=$(docker_try "swarm manager addrs text" \
                "docker info 2>/dev/null | sed -n '/Manager Addresses:/,/^[^ ]/p' | grep -E '^  +[0-9]' | sed 's/^ *//'")
            if [ -n "$_mgr_addrs" ]; then
                _manager_count=$(echo "$_mgr_addrs" | grep -c .)
                _manager_count=$(num_or_default "$_manager_count" 0)
                _manager_nodes_json=$(echo "$_mgr_addrs" | awk '
                    BEGIN { printf "[" }
                    NF > 0 {
                        gsub(/^[ \t]+|[ \t]+$/, "")
                        if (c++ > 0) printf ","
                        printf "{\"name\":\"%s\",\"node_id\":\"\",\"status\":\"ready\"}", $0
                    }
                    END { printf "]" }
                ')
                [ -z "$_manager_nodes_json" ] && _manager_nodes_json="[]"
                log_info "Got ${_manager_count} manager(s) from docker info text"
            fi
        fi

        _total_nodes=$(( _manager_count + _worker_count ))
        log_info "Worker node: detected ${_manager_count} manager(s), total_count=${_total_nodes}"
    fi

    # Raft index
    _raft_index=$(docker_try "swarm raft index" "docker info --format '{{.Swarm.Cluster.Spec.Raft.SnapshotInterval}}'")
    _raft_index=$(num_or_default "$_raft_index" 0)

    # Task history
    _task_history=$(docker_try "swarm task history" "docker info --format '{{.Swarm.Cluster.Spec.TaskHistoryRetentionLimit}}'")
    _task_history=$(num_or_default "$_task_history" 5)

    # Resource usage
    _res=$(get_process_resource_usage "dockerd")
    _swarm_cpu=$(echo "$_res" | awk '{print $1}')
    _swarm_mem=$(echo "$_res" | awk '{print $2}')

    SWARM_JSON="{
          \"name\": \"docker_swarm\",
          \"orchestrator_type\": \"docker-swarm\",
          \"version\": \"${_version}\",
          \"cluster_id\": \"${_cluster_id}\",
          \"cluster_name\": \"\",
          \"state\": \"active\",
          \"current_node\": {
            \"node_id\": \"${_node_id}\",
            \"role\": \"${_node_role}\",
            \"availability\": \"${_node_avail}\"
          },
          \"nodes\": {
            \"total_count\": ${_total_nodes},
            \"master_count\": ${_manager_count},
            \"worker_count\": ${_worker_count},
            \"master_nodes\": ${_manager_nodes_json},
            \"worker_nodes\": ${_worker_nodes_json}
          },
          \"platform_specific\": {
            \"swarm\": {
              \"raft_index\": ${_raft_index},
              \"task_history_limit\": ${_task_history}
            },
            \"kubernetes\": null,
            \"openshift\": null,
            \"tanzu\": null
          },
          \"resource_usage\": {
            \"cpu_cores\": ${_swarm_cpu},
            \"memory_mb\": ${_swarm_mem}
          }
        }"
    log_info "Docker Swarm discovery complete"
}

# ========================
# 2.4 Shared KUBECONFIG Setup
# ========================
_KUBECONFIG_ENSURED=false

ensure_kubeconfig() {
    # Idempotent: only run once per script execution
    if $_KUBECONFIG_ENSURED; then
        return
    fi
    _KUBECONFIG_ENSURED=true
    log_info "Ensuring KUBECONFIG is set"

    if [ -n "$KUBECONFIG" ] && [ -r "$KUBECONFIG" ]; then
        log_info "KUBECONFIG already set and readable: $KUBECONFIG"
        return
    fi

    # Discover KUBECONFIG — try standard locations
    # Use -r (readable) not -f (exists) — /etc/kubernetes/admin.conf is root-owned
    # and unreadable without sudo, causing all kubectl/oc commands to fail.
    # kubelet.conf is included for worker nodes where admin.conf doesn't exist.
    if [ -z "$KUBECONFIG" ]; then
        for _kc in /etc/kubernetes/admin.conf "$HOME/.kube/config" /etc/rancher/k3s/k3s.yaml /etc/rancher/rke2/rke2.yaml /etc/kubernetes/kubelet.conf; do
            if [ -r "$_kc" ]; then
                export KUBECONFIG="$_kc"
                log_info "Set KUBECONFIG=$_kc (readable)"
                break
            elif [ -f "$_kc" ]; then
                log_info "KUBECONFIG candidate $_kc exists but is not readable (need sudo?)"
            fi
        done
    fi
    # If no readable config found, try sudo to copy admin.conf or kubelet.conf to a temp location
    if [ -z "$KUBECONFIG" ]; then
        for _kc_src in /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf; do
            if [ -f "$_kc_src" ]; then
                _tmp_kc="/tmp/.guestdetails_kubeconfig_$$"
                if try_sudo_command_str "copy $(basename $_kc_src)" "cp $_kc_src $_tmp_kc && chmod 644 $_tmp_kc" >/dev/null 2>&1; then
                    export KUBECONFIG="$_tmp_kc"
                    log_info "Copied $_kc_src to $_tmp_kc via sudo for kubectl access"
                    break
                fi
            fi
        done
    fi
}

cleanup_kubeconfig() {
    case "${KUBECONFIG:-}" in /tmp/.guestdetails_kubeconfig_*)
        rm -f "$KUBECONFIG" 2>/dev/null
        unset KUBECONFIG
        log_info "Cleaned up temporary kubeconfig"
    ;; esac
}

# ========================
# 2.4b Kubernetes
# ========================
K8S_DETECTED=false
K8S_JSON=""

discover_kubernetes() {
    log_info "=== Discovering Kubernetes ==="

    _k8s_found=false
    if command -v kubectl >/dev/null 2>&1 && try_command "kubectl cluster-info" kubectl cluster-info >/dev/null 2>&1; then
        _k8s_found=true
    elif systemctl is-active kubelet >/dev/null 2>&1; then
        _k8s_found=true
    elif [ -d /etc/kubernetes ]; then
        _k8s_found=true
    elif pgrep -x kubelet >/dev/null 2>&1; then
        _k8s_found=true
    # MicroK8s detection
    elif command -v microk8s >/dev/null 2>&1; then
        _k8s_found=true
        log_info "Kubernetes detected via microk8s CLI"
    elif snap list microk8s >/dev/null 2>&1; then
        _k8s_found=true
        log_info "Kubernetes detected via microk8s snap"
    elif pgrep -f 'snap.microk8s.daemon-kubelite' >/dev/null 2>&1; then
        _k8s_found=true
        log_info "Kubernetes detected via microk8s kubelite process"
    elif [ -S /var/snap/microk8s/common/run/containerd.sock ]; then
        _k8s_found=true
        log_info "Kubernetes detected via microk8s containerd socket"
    fi

    if ! $_k8s_found; then
        log_info "Kubernetes not detected"
        return
    fi

    K8S_DETECTED=true
    log_info "Kubernetes detected"

    # Use shared KUBECONFIG setup
    ensure_kubeconfig

    # Determine kubectl command — standard kubectl or microk8s kubectl
    _kubectl="kubectl"
    if ! command -v kubectl >/dev/null 2>&1; then
        if command -v microk8s >/dev/null 2>&1; then
            _kubectl="microk8s kubectl"
            log_info "Using microk8s kubectl as kubectl alternative"
        elif command -v microk8s.kubectl >/dev/null 2>&1; then
            _kubectl="microk8s.kubectl"
            log_info "Using microk8s.kubectl as kubectl alternative"
        fi
    fi

    # Version
    _version=$(try_command_str "kubectl version" "$_kubectl version --short 2>/dev/null | grep 'Server' | awk '{print \$NF}'") || _version=""
    if [ -z "$_version" ] && $HAS_JQ; then
        _version=$(try_command_str "kubectl version json jq" "$_kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // .clientVersion.gitVersion // empty'") || _version=""
    fi
    if [ -z "$_version" ]; then
        _version=$(try_command_str "kubectl version json grep" "$_kubectl version -o json 2>/dev/null | grep -o '\"gitVersion\":\"[^\"]*\"' | tail -1 | sed 's/\"gitVersion\":\"//;s/\"//g'") || _version=""
    fi
    if [ -z "$_version" ]; then
        _version=$(try_command "kubelet version" kubelet --version 2>/dev/null | awk '{print $2}') || _version=""
    fi
    if [ -z "$_version" ] && command -v microk8s >/dev/null 2>&1; then
        _version=$(try_command_str "microk8s version" "microk8s version 2>/dev/null | grep -o 'v[0-9.]*'") || _version=""
    fi
    _version=$(safe_json_string "$_version")

    # Cluster ID
    _cluster_id=$(try_command_str "k8s cluster id" "$_kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null") || _cluster_id=""
    _cluster_id=$(safe_json_string "$_cluster_id")

    # Cluster name
    _cluster_name=$(try_command_str "k8s cluster name" "$_kubectl config current-context 2>/dev/null") || _cluster_name=""
    # Fallback: parse kubeconfig file directly (use resolved $KUBECONFIG, not hardcoded path)
    _kc_file="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
    if [ -z "$_cluster_name" ] && [ -r "$_kc_file" ]; then
        _cluster_name=$(grep 'current-context:' "$_kc_file" 2>/dev/null | awk '{print $2}') || _cluster_name=""
    fi
    if [ -z "$_cluster_name" ] && [ -r "$_kc_file" ]; then
        _cluster_name=$(grep -E '^\s+cluster:\s+\S' "$_kc_file" 2>/dev/null | head -1 | awk '{print $2}') || _cluster_name=""
    fi
    _cluster_name=$(safe_json_string "$_cluster_name")

    # Current node
    _my_hostname=$(hostname 2>/dev/null)
    _node_id=$(safe_json_string "$_my_hostname")
    _node_role="worker"
    _node_avail="Unknown"

    _node_labels=$(try_command_str "k8s node labels" "$_kubectl get node '$_my_hostname' -o jsonpath='{.metadata.labels}' 2>/dev/null") || _node_labels=""
    if echo "$_node_labels" | grep -q "node-role.kubernetes.io/control-plane"; then
        _node_role="control-plane"
    elif echo "$_node_labels" | grep -q "node-role.kubernetes.io/master"; then
        _node_role="control-plane"
    fi

    # Fallback control-plane detection without kubectl (check for kube-apiserver)
    if [ "$_node_role" = "worker" ]; then
        if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] || \
           pgrep -x kube-apiserver >/dev/null 2>&1 || \
           (ss -tln 2>/dev/null | grep -q ':6443 '); then
            _node_role="control-plane"
            log_info "Detected control-plane role via fallback (apiserver manifest/process/port)"
        fi
    fi

    _node_status=$(try_command_str "k8s node status" "$_kubectl get node '$_my_hostname' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null") || _node_status=""
    case "$_node_status" in
        True|true) _node_avail="Ready" ;;
        False|false) _node_avail="NotReady" ;;
        *) _node_avail="Unknown" ;;
    esac

    # Check for schedulable
    _unschedulable=$(try_command_str "k8s node schedulable" "$_kubectl get node '$_my_hostname' -o jsonpath='{.spec.unschedulable}' 2>/dev/null") || _unschedulable=""
    [ "$_unschedulable" = "true" ] && _node_avail="SchedulingDisabled"

    # Nodes
    _total_nodes=0
    _master_count=0
    _worker_count=0
    _master_nodes_json="[]"
    _worker_nodes_json="[]"

    _nodes_json_raw=$(try_command_str "k8s nodes" "$_kubectl get nodes -o json 2>/dev/null") || _nodes_json_raw=""
    if [ -n "$_nodes_json_raw" ] && $HAS_JQ; then
        _total_nodes=$(echo "$_nodes_json_raw" | jq '.items | length' 2>/dev/null) || _total_nodes=0

        _master_nodes_json=$(echo "$_nodes_json_raw" | jq -c '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null or .metadata.labels["node-role.kubernetes.io/master"] != null) | {
            name: .metadata.name,
            node_id: .metadata.name,
            status: (if (.status.conditions[] | select(.type == "Ready")).status == "True" then "Ready" else "NotReady" end)
        }]' 2>/dev/null) || _master_nodes_json="[]"

        _worker_nodes_json=$(echo "$_nodes_json_raw" | jq -c '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null and .metadata.labels["node-role.kubernetes.io/master"] == null) | {
            name: .metadata.name,
            node_id: .metadata.name,
            status: (if (.status.conditions[] | select(.type == "Ready")).status == "True" then "Ready" else "NotReady" end)
        }]' 2>/dev/null) || _worker_nodes_json="[]"

        _master_count=$(echo "$_master_nodes_json" | jq 'length' 2>/dev/null) || _master_count=0
        _worker_count=$(echo "$_worker_nodes_json" | jq 'length' 2>/dev/null) || _worker_count=0
    elif [ -n "$_nodes_json_raw" ]; then
        # Without jq, parse node list
        _nodes_text=$(try_command_str "kubectl get nodes" "$_kubectl get nodes 2>/dev/null") || _nodes_text=""
        if [ -n "$_nodes_text" ]; then
            _total_nodes=$(echo "$_nodes_text" | tail -n +2 | wc -l)
            _master_count=$(echo "$_nodes_text" | grep -c 'control-plane\|master')
            _worker_count=$(( _total_nodes - _master_count ))
        fi
    fi

    # State
    _state="unknown"
    if [ -n "$_nodes_json_raw" ] && $HAS_JQ; then
        _not_ready=$(echo "$_nodes_json_raw" | jq '[.items[].status.conditions[] | select(.type == "Ready" and .status != "True")] | length' 2>/dev/null) || _not_ready=0
        if [ "$_not_ready" = "0" ] && [ "$_total_nodes" -gt 0 ]; then
            _state="active"
        elif [ "$_not_ready" -gt 0 ]; then
            _state="degraded"
        fi
    elif [ -n "$_nodes_json_raw" ]; then
        _state="active"
    fi

    # Distribution detection
    _distribution=""
    if [ -d /var/lib/rancher/k3s ]; then
        _distribution="k3s"
    elif [ -d /var/lib/rancher/rke2 ]; then
        _distribution="rke2"
    elif snap list microk8s >/dev/null 2>&1; then
        _distribution="microk8s"
    elif command -v kubeadm >/dev/null 2>&1; then
        _distribution="kubeadm"
    elif command -v kind >/dev/null 2>&1 && try_command_str "kind clusters" "kind get clusters 2>/dev/null" | grep -q .; then
        _distribution="kind"
    elif command -v minikube >/dev/null 2>&1 && try_command_str "minikube status" "minikube status 2>/dev/null" | grep -q "Running"; then
        _distribution="minikube"
    else
        # Check node labels for cloud provider
        if echo "$_node_labels" | grep -qi "eks.amazonaws.com"; then
            _distribution="eks"
        elif echo "$_node_labels" | grep -qi "kubernetes.azure.com"; then
            _distribution="aks"
        elif echo "$_node_labels" | grep -qi "cloud.google.com"; then
            _distribution="gke"
        # kubeadm on worker nodes: kubeadm may not be in PATH but bootstrap-kubelet.conf exists
        elif [ -f /etc/kubernetes/bootstrap-kubelet.conf ] || [ -f /etc/kubernetes/kubelet.conf ]; then
            _distribution="kubeadm"
        fi
    fi
    _distribution=$(safe_json_string "$_distribution")

    # API server endpoint
    _api_endpoint=$(try_command_str "k8s api endpoint" "$_kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null") || _api_endpoint=""
    _api_endpoint=$(safe_json_string "$_api_endpoint")

    # Cluster CIDR / Service CIDR
    _cluster_cidr=$(try_command_str "k8s cluster cidr" "$_kubectl cluster-info dump 2>/dev/null | grep -m1 'cluster-cidr' | grep -o '[0-9]\\+\\.[0-9]\\+\\.[0-9]\\+\\.[0-9]\\+/[0-9]\\+'") || _cluster_cidr=""
    if [ -z "$_cluster_cidr" ]; then
        _cluster_cidr=$(try_command_str "k8s cidr from cm" "$_kubectl get cm kubeadm-config -n kube-system -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null | grep -o 'podSubnet: [^ ]*' | awk '{print \$2}'") || _cluster_cidr=""
    fi
    _cluster_cidr=$(safe_json_string "$_cluster_cidr")

    _service_cidr=$(try_command_str "k8s service cidr" "$_kubectl cluster-info dump 2>/dev/null | grep -m1 'service-cluster-ip-range' | grep -o '[0-9]\\+\\.[0-9]\\+\\.[0-9]\\+\\.[0-9]\\+/[0-9]\\+'") || _service_cidr=""
    if [ -z "$_service_cidr" ]; then
        _service_cidr=$(try_command_str "k8s svc cidr from cm" "$_kubectl get cm kubeadm-config -n kube-system -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null | grep -o 'serviceSubnet: [^ ]*' | awk '{print \$2}'") || _service_cidr=""
    fi
    _service_cidr=$(safe_json_string "$_service_cidr")

    # ========================================================
    # Worker-node / unprivileged fallbacks
    # When kubectl has no working kubeconfig (common on worker nodes
    # as unprivileged user), fill in gaps from process args, kubelet
    # healthz, kubelet.conf via sudo, and CA cert fingerprint.
    # ========================================================

    # --- Sudo kubectl with kubelet.conf ---
    # kubelet.conf has limited RBAC but CAN read nodes
    _kubelet_kc="/etc/kubernetes/kubelet.conf"
    if [ -f "$_kubelet_kc" ] && { [ -z "$_nodes_json_raw" ] || [ "$_state" = "unknown" ]; }; then
        log_info "Attempting sudo kubectl with kubelet.conf for worker node fallback"

        # Nodes via kubelet.conf (kubelet RBAC allows reading nodes)
        if [ -z "$_nodes_json_raw" ]; then
            _nodes_json_raw=$(try_sudo_command_str "k8s nodes via kubelet.conf" \
                "kubectl --kubeconfig=$_kubelet_kc get nodes -o json 2>/dev/null") || _nodes_json_raw=""
            if [ -n "$_nodes_json_raw" ] && $HAS_JQ; then
                _total_nodes=$(echo "$_nodes_json_raw" | jq '.items | length' 2>/dev/null) || _total_nodes=0

                _master_nodes_json=$(echo "$_nodes_json_raw" | jq -c '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null or .metadata.labels["node-role.kubernetes.io/master"] != null) | {
                    name: .metadata.name,
                    node_id: .metadata.name,
                    status: (if (.status.conditions[] | select(.type == "Ready")).status == "True" then "Ready" else "NotReady" end)
                }]' 2>/dev/null) || _master_nodes_json="[]"

                _worker_nodes_json=$(echo "$_nodes_json_raw" | jq -c '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null and .metadata.labels["node-role.kubernetes.io/master"] == null) | {
                    name: .metadata.name,
                    node_id: .metadata.name,
                    status: (if (.status.conditions[] | select(.type == "Ready")).status == "True" then "Ready" else "NotReady" end)
                }]' 2>/dev/null) || _worker_nodes_json="[]"

                _master_count=$(echo "$_master_nodes_json" | jq 'length' 2>/dev/null) || _master_count=0
                _worker_count=$(echo "$_worker_nodes_json" | jq 'length' 2>/dev/null) || _worker_count=0

                log_info "Got nodes via kubelet.conf: total=$_total_nodes masters=$_master_count workers=$_worker_count"
            elif [ -n "$_nodes_json_raw" ]; then
                _nodes_text=$(try_sudo_command_str "k8s nodes text kubelet.conf" \
                    "kubectl --kubeconfig=$_kubelet_kc get nodes 2>/dev/null") || _nodes_text=""
                if [ -n "$_nodes_text" ]; then
                    _total_nodes=$(echo "$_nodes_text" | tail -n +2 | wc -l)
                    _master_count=$(echo "$_nodes_text" | grep -c 'control-plane\|master')
                    _worker_count=$(( _total_nodes - _master_count ))
                fi
            fi
        fi

        # Node availability via kubelet.conf
        if [ "$_node_avail" = "Unknown" ]; then
            _node_status=$(try_sudo_command_str "k8s node status kubelet.conf" \
                "kubectl --kubeconfig=$_kubelet_kc get node '$_my_hostname' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null") || _node_status=""
            case "$_node_status" in
                True|true) _node_avail="Ready" ;;
                False|false) _node_avail="NotReady" ;;
            esac
        fi

        # State from nodes via kubelet.conf
        if [ "$_state" = "unknown" ] && [ -n "$_nodes_json_raw" ] && $HAS_JQ; then
            _not_ready=$(echo "$_nodes_json_raw" | jq '[.items[].status.conditions[] | select(.type == "Ready" and .status != "True")] | length' 2>/dev/null) || _not_ready=0
            if [ "$_not_ready" = "0" ] && [ "$_total_nodes" -gt 0 ] 2>/dev/null; then
                _state="active"
            elif [ "$_not_ready" -gt 0 ] 2>/dev/null; then
                _state="degraded"
            fi
        fi

        # Cluster name from kubelet.conf content
        if [ -z "$_cluster_name" ]; then
            _cluster_name=$(try_sudo_command_str "k8s cluster name kubelet.conf" \
                "awk '/^clusters:/,/^[^ ]/{if(/^  - cluster:/){found=1} if(found && /^    name:/){print \$2; exit}}' $_kubelet_kc 2>/dev/null") || _cluster_name=""
            if [ -z "$_cluster_name" ]; then
                _cluster_name=$(try_sudo_command_str "k8s cluster name kubelet.conf grep" \
                    "grep -A20 '^clusters:' $_kubelet_kc 2>/dev/null | grep '  name:' | head -1 | awk '{print \$2}'") || _cluster_name=""
            fi
        fi

        # API server endpoint from kubelet.conf content
        if [ -z "$_api_endpoint" ]; then
            _api_endpoint=$(try_sudo_command_str "k8s api from kubelet.conf" \
                "grep 'server:' $_kubelet_kc 2>/dev/null | awk '{print \$2}' | head -1") || _api_endpoint=""
        fi
    fi

    # --- Non-sudo fallbacks from kubelet process args ---
    _kc_from_proc=""
    if [ -z "$_api_endpoint" ] || [ -z "$_cluster_name" ]; then
        _kc_from_proc=$(ps aux 2>/dev/null | grep '[k]ubelet' | sed -n 's/.*--kubeconfig=\([^ ]*\).*/\1/p' | head -1)
        if [ -n "$_kc_from_proc" ] && [ -r "$_kc_from_proc" ]; then
            if [ -z "$_api_endpoint" ]; then
                _api_endpoint=$(grep 'server:' "$_kc_from_proc" 2>/dev/null | awk '{print $2}' | head -1) || _api_endpoint=""
                [ -n "$_api_endpoint" ] && log_info "Got API endpoint from kubelet kubeconfig: $_api_endpoint"
            fi
            if [ -z "$_cluster_name" ]; then
                _cluster_name=$(awk '/^clusters:/,/^[^ ]/{if(/^  - cluster:/){found=1} if(found && /^    name:/){print $2; exit}}' "$_kc_from_proc" 2>/dev/null) || _cluster_name=""
                [ -n "$_cluster_name" ] && log_info "Got cluster name from kubelet kubeconfig: $_cluster_name"
            fi
        fi
    fi

    # --- API server endpoint from established network connections ---
    if [ -z "$_api_endpoint" ]; then
        # kubelet maintains persistent connections to the API server on port 6443
        _api_host=$(ss -tn state established 2>/dev/null | awk '/:6443$/{print $4}' | head -1 | sed 's/:[0-9]*$//; s/^\[//; s/\]$//') || _api_host=""
        if [ -z "$_api_host" ]; then
            _api_host=$(ss -tn 2>/dev/null | grep 'ESTAB' | awk '{print $5}' | grep ':6443$' | head -1 | sed 's/:6443$//') || _api_host=""
        fi
        if [ -n "$_api_host" ]; then
            _api_endpoint="https://${_api_host}:6443"
            log_info "Got API endpoint from network connections: $_api_endpoint"
        fi
    fi

    # --- Kubelet healthz for state and availability ---
    if [ "$_state" = "unknown" ] && pgrep -x kubelet >/dev/null 2>&1; then
        _healthz=$(curl -s --max-time 3 http://127.0.0.1:10248/healthz 2>/dev/null) || _healthz=""
        if [ "$_healthz" = "ok" ]; then
            _state="active"
            log_info "Set state=active from kubelet healthz"
        else
            # kubelet process running implies cluster is active even if healthz unreachable
            _state="active"
            log_info "Set state=active from kubelet process presence"
        fi
    fi

    if [ "$_node_avail" = "Unknown" ] && pgrep -x kubelet >/dev/null 2>&1; then
        _healthz=$(curl -s --max-time 3 http://127.0.0.1:10248/healthz 2>/dev/null) || _healthz=""
        if [ "$_healthz" = "ok" ]; then
            _node_avail="Ready"
            log_info "Set availability=Ready from kubelet healthz"
        fi
    fi

    # --- Cluster ID fallback: hashed CA cert fingerprint ---
    # The raw fingerprint could be considered sensitive, so we hash it with SHA256
    # to produce a stable, unique, non-reversible cluster identifier.
    if [ -z "$_cluster_id" ] && [ -r /etc/kubernetes/pki/ca.crt ]; then
        _raw_fp=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 2>/dev/null \
            | sed 's/.*=//;s/://g') || _raw_fp=""
        if [ -n "$_raw_fp" ]; then
            _cluster_id=$(printf '%s' "$_raw_fp" | sha256sum 2>/dev/null | awk '{print $1}') || _cluster_id=""
            # Fallback if sha256sum not available
            if [ -z "$_cluster_id" ]; then
                _cluster_id=$(printf '%s' "$_raw_fp" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}') || _cluster_id=""
            fi
            [ -n "$_cluster_id" ] && log_info "Got cluster_id from hashed CA cert fingerprint"
        fi
    fi

    # --- Nodes: report current node as minimum ---
    if [ "$_total_nodes" -eq 0 ] 2>/dev/null || [ -z "$_total_nodes" ]; then
        _total_nodes=1
        if [ "$_node_role" = "control-plane" ]; then
            _master_count=1; _worker_count=0
            _master_nodes_json="[{\"name\":\"$_my_hostname\",\"node_id\":\"$_my_hostname\",\"status\":\"$_node_avail\"}]"
            _worker_nodes_json="[]"
        else
            _master_count=0; _worker_count=1
            _master_nodes_json="[]"
            _worker_nodes_json="[{\"name\":\"$_my_hostname\",\"node_id\":\"$_my_hostname\",\"status\":\"$_node_avail\"}]"
        fi
        log_info "Reported self as minimum node entry (role=$_node_role, status=$_node_avail)"
    fi

    # Re-sanitize fields that may have been set by fallbacks
    _cluster_id=$(safe_json_string "$_cluster_id")
    _cluster_name=$(safe_json_string "$_cluster_name")
    _api_endpoint=$(safe_json_string "$_api_endpoint")

    # Kubeconfig path
    _kubeconfig="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
    [ ! -f "$_kubeconfig" ] && _kubeconfig="$HOME/.kube/config"
    [ ! -f "$_kubeconfig" ] && _kubeconfig="/etc/kubernetes/kubelet.conf"
    [ ! -f "$_kubeconfig" ] && _kubeconfig=""
    _kubeconfig=$(safe_json_string "$_kubeconfig")

    # Resource usage (kubelet)
    _res=$(get_process_resource_usage "kubelet")
    _k8s_cpu=$(echo "$_res" | awk '{print $1}')
    _k8s_mem=$(echo "$_res" | awk '{print $2}')

    K8S_JSON="{
          \"name\": \"kubernetes\",
          \"orchestrator_type\": \"kubernetes\",
          \"version\": \"${_version}\",
          \"cluster_id\": \"${_cluster_id}\",
          \"cluster_name\": \"${_cluster_name}\",
          \"state\": \"${_state}\",
          \"current_node\": {
            \"node_id\": \"${_node_id}\",
            \"role\": \"${_node_role}\",
            \"availability\": \"${_node_avail}\"
          },
          \"nodes\": {
            \"total_count\": ${_total_nodes},
            \"master_count\": ${_master_count},
            \"worker_count\": ${_worker_count},
            \"master_nodes\": ${_master_nodes_json},
            \"worker_nodes\": ${_worker_nodes_json}
          },
          \"platform_specific\": {
            \"swarm\": null,
            \"kubernetes\": {
              \"distribution\": \"${_distribution}\",
              \"api_server_endpoint\": \"${_api_endpoint}\",
              \"cluster_cidr\": \"${_cluster_cidr}\",
              \"service_cidr\": \"${_service_cidr}\",
              \"kubeconfig_path\": \"${_kubeconfig}\"
            },
            \"openshift\": null,
            \"tanzu\": null
          },
          \"resource_usage\": {
            \"cpu_cores\": ${_k8s_cpu},
            \"memory_mb\": ${_k8s_mem}
          }
        }"
    log_info "Kubernetes discovery complete"
}

# ========================
# 2.4c OpenShift
# ========================
OCP_DETECTED=false
OCP_JSON=""

discover_openshift() {
    log_info "=== Discovering OpenShift ==="

    _ocp_found=false
    if command -v oc >/dev/null 2>&1 && try_command "oc version" oc version >/dev/null 2>&1; then
        _ocp_found=true
        log_info "OpenShift detected via oc CLI"
    elif try_command_str "kubectl clusterversion" "kubectl get clusterversion 2>/dev/null" | grep -q "version"; then
        _ocp_found=true
        log_info "OpenShift detected via kubectl clusterversion"
    fi
    # Fallback: detect OpenShift via namespaces (openshift-apiserver, openshift-controller-manager)
    if ! $_ocp_found; then
        _ocp_ns=$(try_command_str "openshift namespaces" "kubectl get ns 2>/dev/null | grep -c '^openshift-'") || _ocp_ns="0"
        if [ "$_ocp_ns" -gt 0 ] 2>/dev/null; then
            _ocp_found=true
            log_info "OpenShift detected via openshift-* namespaces ($_ocp_ns found)"
        fi
    fi
    # Fallback: detect OpenShift via openshift-apiserver process
    if ! $_ocp_found; then
        if pgrep -f 'openshift-apiserver' >/dev/null 2>&1; then
            _ocp_found=true
            log_info "OpenShift detected via openshift-apiserver process"
        fi
    fi
    # Fallback: detect OpenShift via CRI-O + openshift labels on containers
    if ! $_ocp_found && $CRIO_DETECTED; then
        _ocp_label=$(try_sudo_command_str "openshift label check" "crictl ps -o json 2>/dev/null | grep -c 'io.openshift'") || _ocp_label="0"
        if [ "$_ocp_label" -gt 0 ] 2>/dev/null; then
            _ocp_found=true
            log_info "OpenShift detected via io.openshift container labels on CRI-O"
        fi
    fi

    if ! $_ocp_found; then
        log_info "OpenShift not detected"
        return
    fi

    OCP_DETECTED=true
    log_info "OpenShift detected"

    # Ensure KUBECONFIG is set so oc/kubectl commands work without root
    ensure_kubeconfig

    # OCP version
    _ocp_version=$(try_command_str "ocp version" "oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null") || _ocp_version=""
    if [ -z "$_ocp_version" ]; then
        _ocp_version=$(try_command_str "ocp version via kubectl" "kubectl get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null") || _ocp_version=""
    fi
    # Unprivileged fallback: extract OCP version from openshift-apiserver image tag or process
    if [ -z "$_ocp_version" ]; then
        _ocp_version=$(try_command_str "ocp version from crictl" "crictl ps 2>/dev/null | grep 'openshift-apiserver' | awk '{print \$2}' | grep -o 'v[0-9][0-9.]*' | head -1") || _ocp_version=""
    fi
    if [ -z "$_ocp_version" ]; then
        _ocp_version=$(try_sudo_command_str "ocp version from crictl sudo" "crictl ps 2>/dev/null | grep 'openshift-apiserver' | awk '{print \$2}' | grep -o 'v[0-9][0-9.]*' | head -1") || _ocp_version=""
    fi
    if [ -z "$_ocp_version" ]; then
        _ocp_version=$(try_command_str "ocp version from release file" "cat /etc/openshift-release 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1") || _ocp_version=""
    fi
    _version="$_ocp_version"
    _version=$(safe_json_string "$_version")

    # Channel
    _channel=$(try_command_str "ocp channel" "oc get clusterversion -o jsonpath='{.items[0].spec.channel}' 2>/dev/null") || _channel=""
    _channel=$(safe_json_string "$_channel")

    # Cluster ID
    _cluster_id=$(try_command_str "ocp cluster id" "oc get clusterversion -o jsonpath='{.items[0].spec.clusterID}' 2>/dev/null") || _cluster_id=""
    if [ -z "$_cluster_id" ]; then
        _cluster_id=$(try_command_str "ocp cluster id via ns" "kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null") || _cluster_id=""
    fi
    _cluster_id_ocp="$_cluster_id"
    _cluster_id=$(safe_json_string "$_cluster_id")

    # Cluster name
    _cluster_name=$(try_command_str "ocp cluster name" "oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null") || _cluster_name=""
    _cluster_name=$(safe_json_string "$_cluster_name")

    # Install type
    _install_type=$(try_command_str "ocp install type" "oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null") || _install_type=""
    # Map to IPI/UPI/assisted/SNO
    _install_type_mapped=""
    case "$_install_type" in
        AWS|Azure|GCP|vSphere|OpenStack|BareMetal) _install_type_mapped="IPI" ;;
        None) _install_type_mapped="UPI" ;;
        *) _install_type_mapped="$_install_type" ;;
    esac
    _install_type_mapped=$(safe_json_string "$_install_type_mapped")

    # Infra ID
    _infra_id=$(try_command_str "ocp infra id" "oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null") || _infra_id=""
    _infra_id=$(safe_json_string "$_infra_id")

    # Current node
    _my_hostname=$(hostname 2>/dev/null)
    _node_id=$(safe_json_string "$_my_hostname")
    _node_role="worker"
    _node_avail="Unknown"

    _node_labels=$(try_command_str "ocp node labels" "oc get node '$_my_hostname' -o jsonpath='{.metadata.labels}' 2>/dev/null") || _node_labels=""
    if [ -z "$_node_labels" ]; then
        _node_labels=$(try_command_str "ocp node labels via kubectl" "kubectl get node '$_my_hostname' -o jsonpath='{.metadata.labels}' 2>/dev/null") || _node_labels=""
    fi
    if echo "$_node_labels" | grep -q "node-role.kubernetes.io/master"; then
        _node_role="master"
    elif echo "$_node_labels" | grep -q "node-role.kubernetes.io/control-plane"; then
        _node_role="master"
    elif echo "$_node_labels" | grep -q "node-role.kubernetes.io/infra"; then
        _node_role="infra"
    fi

    _node_status=$(try_command_str "ocp node status" "oc get node '$_my_hostname' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null") || _node_status=""
    if [ -z "$_node_status" ]; then
        _node_status=$(try_command_str "ocp node status via kubectl" "kubectl get node '$_my_hostname' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null") || _node_status=""
    fi
    # Unprivileged fallback: if kubelet is running, assume node is Ready
    if [ -z "$_node_status" ]; then
        if pgrep -x kubelet >/dev/null 2>&1; then
            _node_status="True"
            log_info "Assuming node Ready — kubelet process detected (unprivileged fallback)"
        fi
    fi
    case "$_node_status" in True|true) _node_avail="Ready" ;; False|false) _node_avail="NotReady" ;; *) _node_avail="Unknown" ;; esac

    # Unprivileged node role fallback: check for kube-apiserver/openshift-apiserver (control-plane indicator)
    if [ "$_node_role" = "worker" ]; then
        if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] || \
           pgrep -x kube-apiserver >/dev/null 2>&1 || \
           pgrep -f openshift-apiserver >/dev/null 2>&1 || \
           (ss -tln 2>/dev/null | grep -q ':6443 '); then
            _node_role="master"
            log_info "Detected master role via fallback (apiserver manifest/process/port)"
        fi
    fi

    # Nodes
    _total_nodes=0 _master_count=0 _worker_count=0
    _master_nodes_json="[]" _worker_nodes_json="[]"

    _nodes_json_raw=$(try_command_str "ocp nodes" "oc get nodes -o json 2>/dev/null") || _nodes_json_raw=""
    if [ -z "$_nodes_json_raw" ]; then
        _nodes_json_raw=$(try_command_str "ocp nodes via kubectl" "kubectl get nodes -o json 2>/dev/null") || _nodes_json_raw=""
    fi
    if [ -n "$_nodes_json_raw" ] && $HAS_JQ; then
        _total_nodes=$(echo "$_nodes_json_raw" | jq '.items | length' 2>/dev/null) || _total_nodes=0
        _master_nodes_json=$(echo "$_nodes_json_raw" | jq -c '[.items[] | select(.metadata.labels["node-role.kubernetes.io/master"] != null or .metadata.labels["node-role.kubernetes.io/control-plane"] != null) | {
            name: .metadata.name, node_id: .metadata.name,
            status: (if (.status.conditions[] | select(.type == "Ready")).status == "True" then "Ready" else "NotReady" end)
        }]' 2>/dev/null) || _master_nodes_json="[]"
        _worker_nodes_json=$(echo "$_nodes_json_raw" | jq -c '[.items[] | select(.metadata.labels["node-role.kubernetes.io/master"] == null and .metadata.labels["node-role.kubernetes.io/control-plane"] == null) | {
            name: .metadata.name, node_id: .metadata.name,
            status: (if (.status.conditions[] | select(.type == "Ready")).status == "True" then "Ready" else "NotReady" end)
        }]' 2>/dev/null) || _worker_nodes_json="[]"
        _master_count=$(echo "$_master_nodes_json" | jq 'length' 2>/dev/null) || _master_count=0
        _worker_count=$(echo "$_worker_nodes_json" | jq 'length' 2>/dev/null) || _worker_count=0
    fi

    # State
    _state="unknown"
    _degraded_count=$(try_command_str "ocp degraded" "oc get co -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[] | select(.type == \"Degraded\" and .status == \"True\"))] | length' 2>/dev/null") || _degraded_count=""
    _progressing=$(try_command_str "ocp progressing" "oc get clusterversion -o jsonpath='{.items[0].status.conditions[?(@.type==\"Progressing\")].status}' 2>/dev/null") || _progressing=""
    if [ "$_progressing" = "True" ]; then
        _state="progressing"
    elif [ -n "$_degraded_count" ] && [ "$_degraded_count" != "0" ]; then
        _state="degraded"
    elif [ "$_total_nodes" -gt 0 ]; then
        _state="active"
    fi
    # Unprivileged fallback: if kubectl/oc failed but we detected OCP via process/labels, assume active
    if [ "$_state" = "unknown" ]; then
        if pgrep -x kubelet >/dev/null 2>&1; then
            _state="active"
            log_info "Assuming state=active — kubelet process detected (unprivileged fallback)"
        fi
    fi

    # Project count
    _project_count=$(try_command_str "ocp projects" "oc get projects --no-headers 2>/dev/null | wc -l") || _project_count=""
    if [ -z "$_project_count" ]; then
        _project_count=$(try_command_str "namespaces" "kubectl get namespaces --no-headers 2>/dev/null | wc -l") || _project_count="0"
    fi
    _project_count=$(num_or_default "$_project_count" 0)

    # Route count
    _route_count=$(try_command_str "ocp routes" "oc get routes --all-namespaces --no-headers 2>/dev/null | wc -l") || _route_count="0"
    _route_count=$(num_or_default "$_route_count" 0)

    # Build config count
    _bc_count=$(try_command_str "ocp build configs" "oc get bc --all-namespaces --no-headers 2>/dev/null | wc -l") || _bc_count="0"
    _bc_count=$(num_or_default "$_bc_count" 0)

    # Operator count
    _operator_count=$(try_command_str "ocp operators" "oc get co --no-headers 2>/dev/null | wc -l") || _operator_count="0"
    _operator_count=$(num_or_default "$_operator_count" 0)

    # OperatorHub enabled
    _ophub_enabled=false
    _ophub=$(try_command_str "ocp operatorhub" "oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null") || _ophub=""
    case "$_ophub" in true|True) _ophub_enabled=false ;; *) _ophub_enabled=true ;; esac

    # SCC count
    _scc_count=$(try_command_str "ocp scc" "oc get scc --no-headers 2>/dev/null | wc -l") || _scc_count="0"
    _scc_count=$(num_or_default "$_scc_count" 0)

    # Cluster operators degraded/available
    _co_degraded=$(num_or_default "$_degraded_count" 0)
    _co_available=$(try_command_str "ocp co available" "oc get co -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[] | select(.type == \"Available\" and .status == \"True\"))] | length' 2>/dev/null") || _co_available="0"
    _co_available=$(num_or_default "$_co_available" 0)

    # Resource usage
    _res=$(get_process_resource_usage "kubelet")
    _ocp_cpu=$(echo "$_res" | awk '{print $1}')
    _ocp_mem=$(echo "$_res" | awk '{print $2}')

    OCP_JSON="{
          \"name\": \"openshift\",
          \"orchestrator_type\": \"openshift\",
          \"version\": \"${_version}\",
          \"cluster_id\": \"${_cluster_id}\",
          \"cluster_name\": \"${_cluster_name}\",
          \"state\": \"${_state}\",
          \"current_node\": {
            \"node_id\": \"${_node_id}\",
            \"role\": \"${_node_role}\",
            \"availability\": \"${_node_avail}\"
          },
          \"nodes\": {
            \"total_count\": ${_total_nodes},
            \"master_count\": ${_master_count},
            \"worker_count\": ${_worker_count},
            \"master_nodes\": ${_master_nodes_json},
            \"worker_nodes\": ${_worker_nodes_json}
          },
          \"platform_specific\": {
            \"swarm\": null,
            \"kubernetes\": null,
            \"openshift\": {
              \"ocp_version\": \"$(safe_json_string "$_ocp_version")\",
              \"channel\": \"${_channel}\",
              \"cluster_id\": \"$(safe_json_string "$_cluster_id_ocp")\",
              \"infra_id\": \"${_infra_id}\",
              \"install_type\": \"${_install_type_mapped}\",
              \"project_count\": ${_project_count},
              \"route_count\": ${_route_count},
              \"build_config_count\": ${_bc_count},
              \"operator_count\": ${_operator_count},
              \"operator_hub_enabled\": ${_ophub_enabled},
              \"scc_count\": ${_scc_count},
              \"cluster_operators_degraded\": ${_co_degraded},
              \"cluster_operators_available\": ${_co_available}
            },
            \"tanzu\": null
          },
          \"resource_usage\": {
            \"cpu_cores\": ${_ocp_cpu},
            \"memory_mb\": ${_ocp_mem}
          }
        }"
    log_info "OpenShift discovery complete"
}

# ========================
# 2.4d Tanzu TKG
# ========================
TANZU_DETECTED=false
TANZU_JSON=""

discover_tanzu() {
    log_info "=== Discovering VMware Tanzu TKG ==="

    _tanzu_found=false
    if command -v tanzu >/dev/null 2>&1 && try_command "tanzu version" tanzu version >/dev/null 2>&1; then
        _tanzu_found=true
    fi
    # Check for TKG-specific labels on nodes
    if ! $_tanzu_found && $K8S_DETECTED; then
        _tkr_label=$(try_command_str "tanzu tkr label" "kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -o 'run.tanzu.vmware.com'") || _tkr_label=""
        if [ -n "$_tkr_label" ]; then
            _tanzu_found=true
        fi
    fi
    # Check for vmware-system namespaces
    if ! $_tanzu_found; then
        _vmw_ns=$(try_command_str "vmware namespaces" "kubectl get ns 2>/dev/null | grep 'vmware-system'") || _vmw_ns=""
        if [ -n "$_vmw_ns" ]; then
            _tanzu_found=true
        fi
    fi

    if ! $_tanzu_found; then
        log_info "VMware Tanzu TKG not detected"
        return
    fi

    TANZU_DETECTED=true
    log_info "VMware Tanzu TKG detected"

    # Ensure KUBECONFIG is set so kubectl commands work without root
    ensure_kubeconfig

    # TKG version
    _tkg_version=$(try_command_str "tanzu version" "tanzu version 2>/dev/null | grep 'version' | head -1 | awk '{print \$NF}'") || _tkg_version=""
    _version="$_tkg_version"
    _version=$(safe_json_string "$_version")
    _tkg_version=$(safe_json_string "$_tkg_version")

    # Version from kubectl
    _k8s_ver=$(try_command_str "kubectl version tanzu" "kubectl version -o json 2>/dev/null | grep -o '\"gitVersion\":\"[^\"]*\"' | tail -1 | sed 's/\"gitVersion\":\"//;s/\"//'") || _k8s_ver=""
    [ -z "$_version" ] && _version=$(safe_json_string "$_k8s_ver")

    # TKR version
    _tkr_version=$(try_command_str "tkr version" "kubectl get tkr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null") || _tkr_version=""
    if [ -z "$_tkr_version" ]; then
        _tkr_version=$(try_command_str "tkr from node label" "kubectl get nodes -o jsonpath='{.items[0].metadata.labels.run\\.tanzu\\.vmware\\.com/tkr}' 2>/dev/null") || _tkr_version=""
    fi
    _tkr_version=$(safe_json_string "$_tkr_version")

    # Cluster class
    _cluster_class=$(try_command_str "tanzu cluster class" "kubectl get cluster -A -o jsonpath='{.items[0].spec.topology.class}' 2>/dev/null") || _cluster_class=""
    _cluster_class=$(safe_json_string "$_cluster_class")

    # Management cluster
    _mgmt_cluster=$(try_command_str "tanzu mgmt cluster" "tanzu management-cluster get 2>/dev/null | grep 'NAME' -A1 | tail -1 | awk '{print \$1}'") || _mgmt_cluster=""
    _mgmt_cluster=$(safe_json_string "$_mgmt_cluster")

    # Supervisor cluster
    _supervisor=""
    _sv_ns=$(try_command_str "supervisor ns" "kubectl get ns 2>/dev/null | grep 'vmware-system-tkg' | awk '{print \$1}'") || _sv_ns=""
    [ -n "$_sv_ns" ] && _supervisor="$_sv_ns"
    _supervisor=$(safe_json_string "$_supervisor")

    # vsphere namespace
    _vsphere_ns=$(try_command_str "vsphere namespace" "kubectl get ns -l 'vSphereClusterID' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null") || _vsphere_ns=""
    _vsphere_ns=$(safe_json_string "$_vsphere_ns")

    # Cluster ID / name
    _cluster_id=$(try_command_str "tanzu cluster id" "kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null") || _cluster_id=""
    _cluster_id=$(safe_json_string "$_cluster_id")
    _cluster_name=$(try_command_str "tanzu cluster name" "kubectl config current-context 2>/dev/null") || _cluster_name=""
    _cluster_name=$(safe_json_string "$_cluster_name")

    # Workload cluster count
    _wl_count=$(try_command_str "tanzu workload clusters" "tanzu cluster list 2>/dev/null | tail -n +2 | wc -l") || _wl_count="0"
    _wl_count=$(num_or_default "$_wl_count" 0)

    # Infrastructure provider
    _infra_provider=$(try_command_str "tanzu infra provider" "kubectl get infrastructure -o jsonpath='{.items[0].spec.cloudControllerManager}' 2>/dev/null") || _infra_provider=""
    if [ -z "$_infra_provider" ]; then
        _infra_provider=$(try_command_str "tanzu infra from node" "kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | sed 's/:.*//;s/\/.*//'") || _infra_provider=""
    fi
    case "$(echo "$_infra_provider" | tr '[:upper:]' '[:lower:]')" in
        *vsphere*) _infra_provider="vsphere" ;;
        *aws*)     _infra_provider="aws" ;;
        *azure*)   _infra_provider="azure" ;;
        *)         _infra_provider="" ;;
    esac
    _infra_provider=$(safe_json_string "$_infra_provider")

    # CEIP & Pinniped
    _ceip=false
    _ceip_check=$(try_command_str "tanzu ceip" "tanzu telemetry status 2>/dev/null") || _ceip_check=""
    case "$_ceip_check" in *Opt-in*|*"opted in"*) _ceip=true ;; esac

    _pinniped=false
    _pinniped_check=$(try_command_str "pinniped" "kubectl get deploy -n pinniped-supervisor 2>/dev/null") || _pinniped_check=""
    [ -n "$_pinniped_check" ] && _pinniped=true

    # Current node
    _my_hostname=$(hostname 2>/dev/null)
    _node_id=$(safe_json_string "$_my_hostname")
    _node_role="worker"
    _node_avail="Unknown"
    _node_labels=$(try_command_str "tanzu node labels" "kubectl get node '$_my_hostname' -o jsonpath='{.metadata.labels}' 2>/dev/null") || _node_labels=""
    if echo "$_node_labels" | grep -q "node-role.kubernetes.io/control-plane"; then
        _node_role="control-plane"
    fi
    _node_status=$(try_command_str "tanzu node status" "kubectl get node '$_my_hostname' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null") || _node_status=""
    # Unprivileged fallback: if kubelet is running, assume node is Ready
    if [ -z "$_node_status" ]; then
        if pgrep -x kubelet >/dev/null 2>&1; then
            _node_status="True"
            log_info "Assuming node Ready — kubelet process detected (unprivileged fallback)"
        fi
    fi
    case "$_node_status" in True|true) _node_avail="Ready" ;; False|false) _node_avail="NotReady" ;; *) _node_avail="Unknown" ;; esac

    # Unprivileged node role fallback: check for kube-apiserver (control-plane indicator)
    if [ "$_node_role" = "worker" ]; then
        if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] || \
           pgrep -x kube-apiserver >/dev/null 2>&1 || \
           (ss -tln 2>/dev/null | grep -q ':6443 '); then
            _node_role="control-plane"
            log_info "Detected control-plane role via fallback (apiserver manifest/process/port)"
        fi
    fi

    # Nodes
    _total_nodes=0 _master_count=0 _worker_count=0
    _master_nodes_json="[]" _worker_nodes_json="[]"
    _nodes_json_raw=$(try_command_str "tanzu nodes" "kubectl get nodes -o json 2>/dev/null") || _nodes_json_raw=""
    if [ -n "$_nodes_json_raw" ] && $HAS_JQ; then
        _total_nodes=$(echo "$_nodes_json_raw" | jq '.items | length' 2>/dev/null) || _total_nodes=0
        _master_nodes_json=$(echo "$_nodes_json_raw" | jq -c '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null) | {
            name: .metadata.name, node_id: .metadata.name,
            status: (if (.status.conditions[] | select(.type == "Ready")).status == "True" then "Ready" else "NotReady" end)
        }]' 2>/dev/null) || _master_nodes_json="[]"
        _worker_nodes_json=$(echo "$_nodes_json_raw" | jq -c '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null) | {
            name: .metadata.name, node_id: .metadata.name,
            status: (if (.status.conditions[] | select(.type == "Ready")).status == "True" then "Ready" else "NotReady" end)
        }]' 2>/dev/null) || _worker_nodes_json="[]"
        _master_count=$(echo "$_master_nodes_json" | jq 'length' 2>/dev/null) || _master_count=0
        _worker_count=$(echo "$_worker_nodes_json" | jq 'length' 2>/dev/null) || _worker_count=0
    fi

    # State
    _state="unknown"
    if [ "$_total_nodes" -gt 0 ]; then
        _state="active"
    fi
    # Unprivileged fallback: if kubectl failed but we detected Tanzu, assume active if kubelet runs
    if [ "$_state" = "unknown" ]; then
        if pgrep -x kubelet >/dev/null 2>&1; then
            _state="active"
            log_info "Assuming state=active — kubelet process detected (unprivileged fallback)"
        fi
    fi

    # Resource usage
    _res=$(get_process_resource_usage "kubelet")
    _tanzu_cpu=$(echo "$_res" | awk '{print $1}')
    _tanzu_mem=$(echo "$_res" | awk '{print $2}')

    TANZU_JSON="{
          \"name\": \"tanzu\",
          \"orchestrator_type\": \"tanzu\",
          \"version\": \"${_version}\",
          \"cluster_id\": \"${_cluster_id}\",
          \"cluster_name\": \"${_cluster_name}\",
          \"state\": \"${_state}\",
          \"current_node\": {
            \"node_id\": \"${_node_id}\",
            \"role\": \"${_node_role}\",
            \"availability\": \"${_node_avail}\"
          },
          \"nodes\": {
            \"total_count\": ${_total_nodes},
            \"master_count\": ${_master_count},
            \"worker_count\": ${_worker_count},
            \"master_nodes\": ${_master_nodes_json},
            \"worker_nodes\": ${_worker_nodes_json}
          },
          \"platform_specific\": {
            \"swarm\": null,
            \"kubernetes\": null,
            \"openshift\": null,
            \"tanzu\": {
              \"tkg_version\": \"${_tkg_version}\",
              \"tkr_version\": \"${_tkr_version}\",
              \"cluster_class\": \"${_cluster_class}\",
              \"management_cluster\": \"${_mgmt_cluster}\",
              \"supervisor_cluster\": \"${_supervisor}\",
              \"vsphere_namespace\": \"${_vsphere_ns}\",
              \"workload_cluster_count\": ${_wl_count},
              \"infrastructure_provider\": \"${_infra_provider}\",
              \"ceip_enabled\": ${_ceip},
              \"pinniped_enabled\": ${_pinniped}
            }
          },
          \"resource_usage\": {
            \"cpu_cores\": ${_tanzu_cpu},
            \"memory_mb\": ${_tanzu_mem}
          }
        }"
    log_info "VMware Tanzu TKG discovery complete"
}

# ========================
# 2.5 Services
# ========================
SERVICES_JSON=""

discover_services() {
    log_info "=== Discovering services ==="
    _services=""

    for _svc_name in containerd docker crio podman kubelet; do
        _active="inactive"
        _enabled="disabled"
        _ports_json="[]"

        # systemctl
        _sys_active=$(try_command_str "systemctl is-active $_svc_name" "systemctl is-active $_svc_name 2>/dev/null") || _sys_active=""
        if [ -n "$_sys_active" ]; then
            _active="$_sys_active"
        else
            # Fallback: service command
            _svc_status=$(try_command_str "service $_svc_name status" "service $_svc_name status 2>/dev/null") || _svc_status=""
            if echo "$_svc_status" | grep -qi "running"; then
                _active="active"
            elif echo "$_svc_status" | grep -qi "stopped\|dead"; then
                _active="inactive"
            fi
            # Fallback: check init.d
            if [ -z "$_sys_active" ] && [ -z "$_svc_status" ]; then
                if [ -f "/etc/init.d/$_svc_name" ]; then
                    _init_status=$(try_command_str "init.d $_svc_name" "/etc/init.d/$_svc_name status 2>/dev/null") || _init_status=""
                    if echo "$_init_status" | grep -qi "running"; then
                        _active="active"
                    fi
                fi
            fi
            # Fallback: check if the process is running (pgrep)
            if [ "$_active" = "inactive" ]; then
                if pgrep -x "$_svc_name" >/dev/null 2>&1 || pgrep -x "${_svc_name}d" >/dev/null 2>&1; then
                    _active="active"
                fi
            fi
        fi

        _sys_enabled=$(try_command_str "systemctl is-enabled $_svc_name" "systemctl is-enabled $_svc_name 2>/dev/null") || _sys_enabled=""
        if [ -n "$_sys_enabled" ]; then
            _enabled="$_sys_enabled"
        else
            # Fallback: check for init.d symlinks if no systemctl
            if [ -f "/etc/init.d/$_svc_name" ]; then
                _enabled="enabled"
            fi
        fi

        # Skip services that are not present on this machine
        # (both inactive and disabled means the service unit doesn't exist or is completely absent)
        if [ "$_active" = "inactive" ] && [ "$_enabled" = "disabled" ]; then
            log_info "Skipping service $_svc_name — not installed (inactive + disabled)"
            continue
        fi

        # Listening ports — discover for ALL active services
        if [ "$_active" = "active" ]; then
            _port_list=""
            # Build the process name pattern to match in ss/netstat output
            # IMPORTANT: patterns must match the exact daemon process, not child shims
            _proc_pattern="$_svc_name"
            case "$_svc_name" in
                docker)    _proc_pattern="dockerd\|docker-proxy" ;;
                containerd) _proc_pattern="\"containerd\"" ;;
                crio)      _proc_pattern="crio" ;;
                podman)    _proc_pattern="podman" ;;
                kubelet)   _proc_pattern="kubelet" ;;
            esac

            # Method 1: ss with sudo (needs -p for process names)
            if [ -z "$_port_list" ]; then
                _port_list=$(try_sudo_command_str "$_svc_name ports via ss" "ss -tlnp 2>/dev/null | grep -E '$_proc_pattern' | awk '{print \$4}' | grep -oE '[0-9]+$' | sort -un") || _port_list=""
            fi
            # Method 2: netstat with sudo
            if [ -z "$_port_list" ]; then
                _port_list=$(try_sudo_command_str "$_svc_name ports via netstat" "netstat -tlnp 2>/dev/null | grep -E '$_proc_pattern' | awk '{print \$4}' | grep -oE '[0-9]+$' | sort -un") || _port_list=""
            fi
            # Method 3: ss without sudo (may not show process names, but still try)
            if [ -z "$_port_list" ]; then
                _port_list=$(try_command_str "$_svc_name ports ss no-sudo" "ss -tlnp 2>/dev/null | grep -E '$_proc_pattern' | awk '{print \$4}' | grep -oE '[0-9]+$' | sort -un") || _port_list=""
            fi
            # Method 4: /proc/pid/fd — match PIDs of the service process to sockets
            if [ -z "$_port_list" ]; then
                _pids=$(pgrep -x "$_svc_name" 2>/dev/null || pgrep -x "${_svc_name}d" 2>/dev/null) || _pids=""
                if [ -n "$_pids" ]; then
                    _fd_ports=""
                    for _pid in $_pids; do
                        _tcp_entries=$(try_command_str "$_svc_name /proc/$_pid fd" "ls -la /proc/$_pid/fd 2>/dev/null | grep socket | sed 's/.*socket:\[//;s/\]//' | while read _inode; do grep \"\$_inode\" /proc/net/tcp 2>/dev/null; done | awk '{print \$2}' | grep -oE ':[0-9A-F]+$' | while read _hex; do printf '%d\n' \"0x\$(echo \$_hex | tr -d ':')\"; done | sort -un") || true
                        if [ -n "$_tcp_entries" ]; then
                            _fd_ports="${_fd_ports}${_tcp_entries}
"
                        fi
                    done
                    _port_list=$(echo "$_fd_ports" | grep -v '^$' | sort -un)
                fi
            fi
            # Method 5: /proc/net/tcp + /proc/<pid>/fd via sudo
            if [ -z "$_port_list" ]; then
                _pids=$(pgrep -x "$_svc_name" 2>/dev/null || pgrep -x "${_svc_name}d" 2>/dev/null) || _pids=""
                if [ -n "$_pids" ]; then
                    _fd_ports=""
                    for _pid in $_pids; do
                        _tcp_entries=$(try_sudo_command_str "$_svc_name /proc/$_pid fd (sudo)" "ls -la /proc/$_pid/fd 2>/dev/null | grep socket | sed 's/.*socket:\[//;s/\]//' | while read _inode; do grep \"\$_inode\" /proc/net/tcp 2>/dev/null; done | awk '{print \$2}' | grep -oE ':[0-9A-F]+$' | while read _hex; do printf '%d\n' \"0x\$(echo \$_hex | tr -d ':')\"; done | sort -un") || true
                        if [ -n "$_tcp_entries" ]; then
                            _fd_ports="${_fd_ports}${_tcp_entries}
"
                        fi
                    done
                    _port_list=$(echo "$_fd_ports" | grep -v '^$' | sort -un)
                fi
            fi
            # Method 6: Well-known port probe via ss/netstat (no -p, no sudo needed)
            # When process-matching methods fail (non-sudo), check if known ports
            # for this service are actually listening on the host.
            if [ -z "$_port_list" ]; then
                _known_ports=""
                case "$_svc_name" in
                    docker)     _known_ports="2375 2376 2377 7946" ;;
                    containerd) _known_ports="" ;;
                    crio)       _known_ports="10010" ;;
                    podman)     _known_ports="" ;;
                    kubelet)    _known_ports="10250 10255 10248" ;;
                esac
                for _kp in $_known_ports; do
                    if ss -tln 2>/dev/null | grep -q ":${_kp} " || netstat -tln 2>/dev/null | grep -q ":${_kp} "; then
                        _port_list="${_port_list}${_kp}
"
                    fi
                done
                _port_list=$(echo "$_port_list" | grep -v '^$')
            fi
            # Method 7: PID-based port scan via /proc/net/tcp (non-sudo fallback)
            # Read all listening sockets from /proc/net/tcp, convert hex local_address
            # ports to decimal, then check if the PID has those socket inodes open
            # using /proc/<pid>/net/tcp6 as additional source
            if [ -z "$_port_list" ]; then
                _pids=$(pgrep -x "$_svc_name" 2>/dev/null || pgrep -x "${_svc_name}d" 2>/dev/null) || _pids=""
                if [ -n "$_pids" ]; then
                    # Get all listening (state 0A) local ports from /proc/net/tcp
                    _all_listen_ports=""
                    if [ -r /proc/net/tcp ]; then
                        _all_listen_ports=$(awk '$4 == "0A" {split($2, a, ":"); cmd="printf \"%d\\n\" 0x" a[2]; cmd | getline p; close(cmd); print p}' /proc/net/tcp 2>/dev/null | sort -un) || _all_listen_ports=""
                    fi
                    if [ -n "$_all_listen_ports" ]; then
                        _known_ports=""
                        case "$_svc_name" in
                            docker)     _known_ports="2375 2376 2377 7946 4789" ;;
                            kubelet)    _known_ports="10250 10255 10248 10249" ;;
                            crio)       _known_ports="10010 9090 9537" ;;
                            containerd) _known_ports="10010" ;;
                            podman)     _known_ports="" ;;
                        esac
                        for _kp in $_known_ports; do
                            if echo "$_all_listen_ports" | grep -qw "$_kp"; then
                                _port_list="${_port_list}${_kp}
"
                            fi
                        done
                    fi
                    # Also try /proc/net/tcp6 for IPv6 listeners
                    if [ -z "$_port_list" ] && [ -r /proc/net/tcp6 ]; then
                        _all_listen_ports6=$(awk '$4 == "0A" {split($2, a, ":"); cmd="printf \"%d\\n\" 0x" a[2]; cmd | getline p; close(cmd); print p}' /proc/net/tcp6 2>/dev/null | sort -un) || _all_listen_ports6=""
                        if [ -n "$_all_listen_ports6" ]; then
                            _known_ports=""
                            case "$_svc_name" in
                                docker)     _known_ports="2375 2376 2377 7946" ;;
                                kubelet)    _known_ports="10250 10255 10248 10249" ;;
                                crio)       _known_ports="10010 9090 9537" ;;
                                containerd) _known_ports="10010" ;;
                                podman)     _known_ports="" ;;
                            esac
                            for _kp in $_known_ports; do
                                if echo "$_all_listen_ports6" | grep -qw "$_kp"; then
                                    _port_list="${_port_list}${_kp}
"
                                fi
                            done
                        fi
                    fi
                    _port_list=$(echo "$_port_list" | grep -v '^$' | sort -un)
                fi
            fi

            if [ -n "$_port_list" ]; then
                _ports_json="[$(echo "$_port_list" | {
                    _pf=true
                    while read -r _port; do
                        [ -z "$_port" ] && continue
                        # Validate the value is a number
                        case "$_port" in
                            (*[!0-9]*) continue ;;
                        esac
                        if ! $_pf; then printf ','; fi; _pf=false
                        printf '{"port":%s,"protocol":"tcp"}' "$_port"
                    done
                })]"
            fi
        fi

        _svc_entry="{\"name\":\"${_svc_name}\",\"active\":\"$(safe_json_string "$_active")\",\"enabled\":\"$(safe_json_string "$_enabled")\",\"listening_ports\":${_ports_json}}"

        if [ -z "$_services" ]; then
            _services="$_svc_entry"
        else
            _services="${_services},${_svc_entry}"
        fi
    done

    SERVICES_JSON="[${_services}]"
    log_info "Services discovery complete"
}

# --------------------------------------------------------------------------
# 3. Main — Assemble JSON
# --------------------------------------------------------------------------
assemble_output() {
    log_info "=== Assembling final JSON output ==="

    # Container runtimes array
    _runtimes_json=""
    _rt_first=true
    if $CONTAINERD_DETECTED && [ -n "$CONTAINERD_RUNTIME_JSON" ]; then
        # Skip containerd if Docker is detected and containerd is purely Docker's
        # backend (0 containers, 0 images after moby namespace filtering).
        _skip_containerd=false
        if $DOCKER_DETECTED; then
            _ctrd_cc=0; _ctrd_ic=0
            if $HAS_JQ; then
                _ctrd_cc=$(echo "$CONTAINERD_RUNTIME_JSON" | jq -r '.container_count // 0' 2>/dev/null) || _ctrd_cc=0
                _ctrd_ic=$(echo "$CONTAINERD_RUNTIME_JSON" | jq -r '.image_count // 0' 2>/dev/null) || _ctrd_ic=0
            fi
            _ctrd_cc=$(num_or_default "$_ctrd_cc" 0)
            _ctrd_ic=$(num_or_default "$_ctrd_ic" 0)
            if [ "$_ctrd_cc" = "0" ] && [ "$_ctrd_ic" = "0" ]; then
                _skip_containerd=true
                log_info "Skipping system containerd runtime — Docker detected and containerd has 0 containers, 0 images (Docker backend only)"
            else
                log_info "Both Docker and containerd detected — reporting both (containerd has $_ctrd_cc containers, $_ctrd_ic images)"
            fi
        fi
        if ! $_skip_containerd; then
            if $_rt_first; then _rt_first=false; else _runtimes_json="${_runtimes_json},"; fi
            _runtimes_json="${_runtimes_json}${CONTAINERD_RUNTIME_JSON}"
        fi
    fi
    if $DOCKER_DETECTED && [ -n "$DOCKER_RUNTIME_JSON" ]; then
        if $_rt_first; then _rt_first=false; else _runtimes_json="${_runtimes_json},"; fi
        _runtimes_json="${_runtimes_json}${DOCKER_RUNTIME_JSON}"
    fi
    if $CRIO_DETECTED && [ -n "$CRIO_RUNTIME_JSON" ]; then
        if $_rt_first; then _rt_first=false; else _runtimes_json="${_runtimes_json},"; fi
        _runtimes_json="${_runtimes_json}${CRIO_RUNTIME_JSON}"
    fi
    if $PODMAN_DETECTED && [ -n "$PODMAN_RUNTIME_JSON" ]; then
        if $_rt_first; then _rt_first=false; else _runtimes_json="${_runtimes_json},"; fi
        _runtimes_json="${_runtimes_json}${PODMAN_RUNTIME_JSON}"
    fi
    # Append any extra containerd instances (MicroK8s, k3s, etc.)
    if [ -n "$EXTRA_CONTAINERD_RUNTIMES_JSON" ]; then
        if $_rt_first; then _rt_first=false; else _runtimes_json="${_runtimes_json},"; fi
        _runtimes_json="${_runtimes_json}${EXTRA_CONTAINERD_RUNTIMES_JSON}"
    fi
    _runtimes_json="[${_runtimes_json}]"

    # Orchestrators array
    _orch_json=""
    _orch_first=true
    if $SWARM_DETECTED && [ -n "$SWARM_JSON" ]; then
        if $_orch_first; then _orch_first=false; else _orch_json="${_orch_json},"; fi
        _orch_json="${_orch_json}${SWARM_JSON}"
    fi
    if $K8S_DETECTED && [ -n "$K8S_JSON" ]; then
        if $_orch_first; then _orch_first=false; else _orch_json="${_orch_json},"; fi
        _orch_json="${_orch_json}${K8S_JSON}"
    fi
    if $OCP_DETECTED && [ -n "$OCP_JSON" ]; then
        if $_orch_first; then _orch_first=false; else _orch_json="${_orch_json},"; fi
        _orch_json="${_orch_json}${OCP_JSON}"
    fi
    if $TANZU_DETECTED && [ -n "$TANZU_JSON" ]; then
        if $_orch_first; then _orch_first=false; else _orch_json="${_orch_json},"; fi
        _orch_json="${_orch_json}${TANZU_JSON}"
    fi
    _orch_json="[${_orch_json}]"

    # Check if we discovered anything
    if ! $DOCKER_DETECTED && ! $CONTAINERD_DETECTED && ! $CRIO_DETECTED && ! $PODMAN_DETECTED; then
        log_error "No container runtimes detected"
        EXIT_CODE=1
    fi

    # Assemble final JSON
    cat > "$OUTPUT_FILE" <<FINALEOF
{
  "armResources": [
    {
      "type": "",
      "name": "",
      "apiVersion": "",
      "properties": {
        "schema_version": "${SCHEMA_VERSION}",
        "timestamp": "${TIMESTAMP}",
        "host_info": ${HOST_INFO_JSON},
        "hypervisor": ${HYPERVISOR_JSON},
        "network": ${NETWORK_JSON},
        "container_runtimes": ${_runtimes_json},
        "orchestrators": ${_orch_json},
        "services": ${SERVICES_JSON}
      }
    }
  ]
}
FINALEOF

    # Validate JSON if jq is available
    if $HAS_JQ; then
        if jq . "$OUTPUT_FILE" > /dev/null 2>&1; then
            log_info "Output JSON is valid"
            # Pretty-print in place
            _tmp=$(jq . "$OUTPUT_FILE" 2>/dev/null)
            if [ -n "$_tmp" ]; then
                echo "$_tmp" > "$OUTPUT_FILE"
            fi
        else
            log_error "Output JSON is INVALID — attempting repair"
            EXIT_CODE=2
        fi
    fi

    log_info "Output written to ${OUTPUT_FILE}"
}

# --------------------------------------------------------------------------
# 4. Entry Point
# --------------------------------------------------------------------------
main() {
    init_files
    check_privilege

    log_info "============================="
    log_info "Container Discovery Script"
    log_info "Schema Version: ${SCHEMA_VERSION}"
    log_info "Timestamp: ${TIMESTAMP}"
    log_info "============================="

    # Run all discovery modules
    discover_host_info
    discover_hypervisor
    discover_network

    # Container runtimes
    discover_containerd
    discover_extra_containerd
    discover_docker
    discover_crio
    discover_podman

    # Orchestrators (order matters: detect OpenShift before generic K8s to avoid
    # double-counting when openshift IS kubernetes)
    discover_docker_swarm
    discover_openshift
    if ! $OCP_DETECTED; then
        # Only discover generic K8s if OpenShift is NOT detected (OpenShift IS K8s)
        discover_kubernetes
    fi
    discover_tanzu

    # Cleanup temp kubeconfig after all orchestrator discovery is done
    cleanup_kubeconfig

    # Services
    discover_services

    # Assemble output
    assemble_output

    log_info "Discovery complete. Exit code: ${EXIT_CODE}"
    return $EXIT_CODE
}

main "$@"
exit $?
