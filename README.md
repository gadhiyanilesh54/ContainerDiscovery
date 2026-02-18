# Container Discovery Script

A production-grade POSIX-compatible shell script for discovering container runtimes and orchestrators on Linux systems with graceful privilege degradation.

## Overview

`GuestDetails_Container.sh` is a comprehensive discovery tool that detects and reports information about:

- **Container Runtimes**: containerd, Docker, CRI-O, Podman
- **Container Orchestrators**: Kubernetes, Docker Swarm, OpenShift, VMware Tanzu
- **Host Information**: CPU, memory, disks, network, hypervisor
- **Services**: System service status for container-related daemons

The script outputs a structured JSON document conforming to schema version 7.0.0, making it suitable for integration with monitoring, inventory, and compliance systems.

## Features

### Comprehensive Discovery
- Detects all major container runtimes (containerd, Docker, CRI-O, Podman)
- Identifies container orchestrators (Kubernetes, Docker Swarm, OpenShift, Tanzu)
- Collects detailed host information (OS, kernel, CPU, memory, network)
- Detects hypervisor type (VMware, KVM, Hyper-V, etc.)

### Graceful Privilege Degradation
- Works with root, sudo, or no privileges
- Automatic fallback to unprivileged methods when needed
- Never fails due to missing permissions
- Comprehensive logging of attempted methods

### Robust Error Handling
- Never exits on error - always completes
- Detailed debug logging to `debug.txt`
- Error logging to `error.txt`
- Returns structured JSON even when data is unavailable

### POSIX Compatibility
- Pure POSIX shell script (no bash-specific features required)
- Works on Ubuntu, RHEL, CentOS, SUSE, Flatcar, Photon OS
- No external dependencies beyond standard Unix tools
- Optional jq support for enhanced JSON handling

## Requirements

### Minimum Requirements
- POSIX-compatible shell (`sh`, `bash`, `dash`, etc.)
- Standard Unix utilities (`grep`, `awk`, `sed`, `cat`, `ps`)

### Optional Tools (Enhance Functionality)
- `jq` - For JSON validation (recommended for testing)
- `timeout` - For command timeouts (improves reliability)
- `systemd-detect-virt` - For hypervisor detection
- `lsblk` - For disk discovery
- Container CLI tools (`docker`, `crictl`, `ctr`, `podman`) - For runtime discovery
- Orchestrator CLI tools (`kubectl`, `oc`, `tanzu`) - For orchestrator discovery

## Installation

1. Download the script:
```bash
wget https://raw.githubusercontent.com/gadhiyanilesh54/ContainerDiscovery/main/GuestDetails_Container.sh
chmod +x GuestDetails_Container.sh
```

2. Or clone the repository:
```bash
git clone https://github.com/gadhiyanilesh54/ContainerDiscovery.git
cd ContainerDiscovery
chmod +x GuestDetails_Container.sh
```

## Usage

### Basic Usage

```bash
# Run with current user privileges
./GuestDetails_Container.sh

# Run with sudo (recommended for full discovery)
sudo ./GuestDetails_Container.sh

# Run as root
su -
./GuestDetails_Container.sh
```

### Output Files

The script generates three files in its directory:

1. **`output.json`** - The main discovery output in JSON format
2. **`debug.txt`** - Detailed debug logs of all operations
3. **`error.txt`** - Error messages and failed operations

### Testing

The repository includes comprehensive test scripts for validation:

```bash
# Basic tests with privileged access (requires sudo/root)
sudo ./GuestDetails_Container.sh
sudo ./test_privileged.sh

# Basic tests without privileges (run as normal user)
./GuestDetails_Container.sh
./test_unprivileged.sh

# Comprehensive validation tests (after running GuestDetails_Container.sh)
./test_validation_comprehensive.sh   # Validates output consistency
./test_fallback_mechanisms.sh        # Validates fallback logic
./test_kubernetes_fields.sh          # Validates Kubernetes-specific fields (if K8s is running)
```

#### Test Scripts

| Script | Purpose | Requirements |
|--------|---------|--------------|
| `test_privileged.sh` | Basic validation with sudo | sudo/root access |
| `test_unprivileged.sh` | Basic validation without sudo | Normal user |
| `test_validation_comprehensive.sh` | Cross-field validation, hardcoded value checks, error filtering | jq, output.json |
| `test_fallback_mechanisms.sh` | Validates fallback detection methods | jq, debug.txt |
| `test_kubernetes_fields.sh` | Kubernetes node/workload validation | jq, Kubernetes cluster |

## Output Format

The script outputs a JSON document with the following structure:

```json
{
  "armResources": [{
    "type": "",
    "name": "",
    "apiVersion": "",
    "properties": {
      "schema_version": "1.0.0",
      "timestamp": "2026-02-18T16:58:00Z",
      "host_info": { ... },
      "hypervisor": { ... },
      "network": { ... },
      "container_runtimes": [ ... ],
      "orchestrators": [ ... ],
      "services": [ ... ]
    }
  }]
}
```

See `schema.json` for the complete schema definition and `schema_reference.md` for all possible enum values.

## Discovery Methods

The script uses a multi-tiered fallback approach for each data point:

1. **Primary Method** - Native CLI tool (e.g., `docker info`, `kubectl get nodes`)
2. **Secondary Method** - Socket API queries (e.g., curl --unix-socket)
3. **Tertiary Method** - Configuration file parsing
4. **Fallback Method** - Process inspection via `/proc`
5. **Last Resort** - Systemd service inspection
6. **Default** - Empty/default value with logged warning

### Example: Docker Version Detection

```
1. Try: docker version --format '{{.Server.Version}}'
2. Try: dockerd --version
3. Try: Package manager query (dpkg/rpm)
4. Try: systemctl status docker (parse output)
5. Default: "" (empty string)
```

## Privilege Levels

The script automatically detects and adapts to three privilege levels:

### Root Access
- Full discovery capabilities
- All CLI commands work
- Direct socket access
- Complete container and orchestrator details

### Sudo Access (passwordless)
- Near-complete discovery
- Most CLI commands work via sudo
- Good container and orchestrator details

### No Privileges
- Basic discovery only
- Relies on fallback methods
- Process inspection via /proc
- Configuration file reading (if readable)
- Service status checks
- May have incomplete data but still produces valid output

## Container Runtime Detection

### containerd
- Detects via: `containerd` binary, socket, systemd service
- Queries namespaces (default, moby, k8s.io)
- Uses `ctr` and `crictl` for container/image counts
- Parses `/etc/containerd/config.toml` for configuration

### Docker
- Detects via: `docker`/`dockerd` binary, socket, systemd service
- Queries via `docker info` and socket API
- Detects Docker Swarm mode
- Identifies Swarm-managed containers via labels

### CRI-O
- Detects via: `crio` binary, socket, systemd service
- Uses `crictl` for container/image inspection
- Parses `/etc/crio/crio.conf` for configuration
- Common with Kubernetes and OpenShift

### Podman
- Detects via: `podman` binary, socket, systemd service
- Detects rootless vs rootful mode
- Identifies appropriate socket and storage paths
- Queries via `podman info` and `podman ps`

## Orchestrator Detection

### Kubernetes
- Detects via: `kubectl`, `kubelet`, `/etc/kubernetes/`
- Identifies distribution (kubeadm, k3s, rke2, microk8s, kind, EKS, AKS, GKE)
- Detects CNI plugin (Calico, Flannel, Cilium, Weave, etc.)
- Collects workload counts (pods, services, deployments, etc.)
- Determines node role (control-plane/worker)

### Docker Swarm
- Detects via: `docker info` Swarm.LocalNodeState
- Determines node role (manager/worker)
- Collects service counts (manager only)
- Reports Raft consensus state

### OpenShift Container Platform
- Detects via: `oc` CLI or ClusterVersion CRD
- Collects OCP-specific fields (channel, operators, SCCs)
- Inherits Kubernetes detection capabilities

### VMware Tanzu
- Detects via: `tanzu` CLI or TKR CRDs
- Identifies TKG version and distribution
- Collects Tanzu-specific configuration

## Exit Codes

- **0** - Successful discovery with no errors
- **1** - Discovery completed but some operations failed (acceptable)
- **>1** - Critical failure (rare, script is designed to never fail)

## Troubleshooting

### Empty container_runtimes Array

**Cause**: No container runtimes detected or insufficient privileges

**Solutions**:
- Verify runtimes are installed: `which docker containerd crio podman`
- Check service status: `systemctl status docker containerd crio podman`
- Run with sudo: `sudo ./GuestDetails_Container.sh`
- Check debug.txt for detection attempts

### Invalid JSON Output

**Cause**: Script interrupted or file system error

**Solutions**:
- Check available disk space: `df -h`
- Review error.txt for errors
- Ensure script has write permissions in its directory
- Re-run the script

### "Command not found" Errors

**Cause**: Missing optional tools

**Solutions**:
- These are expected and handled gracefully
- Install missing tools only if needed for your environment
- The script will use fallback methods automatically

### Incomplete Data for Orchestrators

**Cause**: Insufficient cluster access permissions

**Solutions**:
- Run on a cluster node (not external machine)
- Ensure kubeconfig is properly configured
- Verify RBAC permissions for cluster-info queries
- Check if you have access to the cluster at all: `kubectl cluster-info`

## Performance

- Typical execution time: 5-30 seconds (depending on environment)
- All commands have 10-second timeout (configurable)
- Minimal CPU and memory footprint
- No persistent background processes

## Security Considerations

- **No credentials in output**: Tokens, passwords, and kubeconfig credentials are never included
- **Read-only operations**: Script never modifies system state
- **No network calls**: All discovery is local (except kubectl API calls)
- **Privilege escalation**: Only uses sudo if already available (never prompts)
- **Safe parsing**: All external command output is safely parsed

## Limitations

- **Container details**: Currently returns empty arrays for individual containers and images (can be extended)
- **Orchestrator details**: Node lists return empty arrays (can be extended)
- **Windows support**: Linux only (POSIX requirement)
- **Real-time data**: Point-in-time snapshot, not continuous monitoring

## Contributing

Contributions are welcome! Areas for enhancement:

1. Individual container details collection
2. Container image information
3. Detailed node lists for orchestrators
4. Additional hypervisor detection methods
5. Support for additional container runtimes
6. Enhanced CNI/CSI driver detection

## Schema Compliance

This script outputs JSON conforming to:
- Schema version: **1.0.0**
- Schema definition: `schema.json`
- Enum reference: `schema_reference.md`
- Requirements: `prompt.md`
- **Validation Report**: `VALIDATION_REPORT.md` - Comprehensive validation results

## Validation

The script has been thoroughly validated for:
- ✅ All container runtimes (containerd, dockerd, crio, podman) detection
- ✅ All orchestrators (Kubernetes, Docker Swarm, OpenShift, Tanzu) detection
- ✅ Fallback mechanisms when primary detection fails
- ✅ Privilege degradation (root, sudo, no privileges)
- ✅ No hardcoded values in dynamic output
- ✅ Cross-field consistency validation
- ✅ Error message filtering

See `VALIDATION_REPORT.md` for detailed validation results.

## License

[Specify your license here]

## Author

[Specify author information]

## Version History

- **1.0.0** (2026-02-18) - Initial production release
  - Complete runtime discovery (containerd, Docker, CRI-O, Podman)
  - Complete orchestrator discovery (K8s, Swarm, OpenShift, Tanzu)
  - Comprehensive fallback mechanisms
  - Full POSIX compatibility
  - Production-ready error handling

## Support

For issues, questions, or contributions:
- GitHub Issues: [Repository Issues Page]
- Documentation: See `prompt.md`, `schema.json`, `schema_reference.md`

---

**Note**: This script is designed for discovery and inventory purposes. It performs read-only operations and never modifies system state.
