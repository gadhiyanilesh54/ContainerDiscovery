# Prompt: Container & Orchestrator Discovery Shell Script

## Objective

Write a **production-grade POSIX-compatible shell script** (`GuestDetails_Container.sh`) that discovers container runtimes and container orchestrators on a Linux host and outputs the results as a **single JSON object** conforming to the attached normalized schema and update README.md

---

## Target Platforms

### Container Runtimes (detect all that are present)
- **containerd** (standalone or as Docker/K8s backend)
- **Docker (dockerd)** (standalone or with Swarm)
- **CRI-O** (typically with Kubernetes/OpenShift)
- **Podman** (rootful and rootless)

### Container Orchestrators (detect all that are present)
- **Docker Swarm**
- **Kubernetes** (kubeadm, k3s, rke2, microk8s, kind, minikube, EKS, AKS, GKE)
- **Red Hat OpenShift Container Platform (OCP)**
- **VMware Tanzu Kubernetes Grid (TKG)**

---

## Execution Context & Constraints

### Environment
- The user running the script may have **root/sudo privileges** OR may be a **non-privileged guest user**
- The script must **never fail or exit** due to missing privileges — always degrade gracefully
- The script must work on: Ubuntu, RHEL, CentOS, SUSE, Flatcar, Photon OS
- The script should be self-sufficient and should not depend on any other script.

### Privilege Handling
- **Always attempt the privileged method first** (e.g., `sudo crictl`, `docker info`, socket access)
- If privileged access fails, **fall back to non-privileged methods** (e.g., reading `/proc`, parsing `ps aux`, checking systemctl, reading config files)
- If a fallback also fails, populate the field with its **default empty value** (`""`, `0`, `[]`, `false`) — **never use `null` for common fields**
- Log what was attempted to debug.txt and what failed to error.txt
- Return an integer, termed as Error Code. 0 should be returned for successful completion and a non-zero error code in case of error.

### Fallback Strategy (per data point)

For each piece of information, attempt discovery in this priority order:

```
1. Native CLI tool (e.g., docker info, crictl info, podman info, kubectl get nodes)
2. Socket API query (e.g., curl --unix-socket /var/run/docker.sock)
3. Configuration file parsing (e.g., /etc/containerd/config.toml, /etc/crio/crio.conf)
4. Process inspection (e.g., ps aux | grep containerd, /proc/*/cmdline)
5. Systemd service inspection (e.g., systemctl is-active containerd)
6. File system inspection (e.g., ls /var/lib/containerd, ls /etc/kubernetes)
7. Default empty value with error/warning logged
```

---

## Output Requirements

### Format
- Output **must be a single valid JSON object** in output.json
- All diagnostic/progress messages must go to `stderr`
- The JSON must conform **exactly** to the attached `schema.json`
- Use `jq` for JSON construction if available; if not, construct JSON using string concatenation with proper escaping
- output.json, error.txt and debug.txt should be generated at the same location of GuestDetails_Container.sh

### Schema Compliance
- Follow the attached `schema.json` for structure
- Follow the attached `schema_reference.md` for all possible values
- Every field in the schema **must be present** in the output (use defaults for missing data)
- `platform_specific` — only populate the matching orchestrator key; set others to `null`

---

## Discovery Logic — Detailed Requirements

### 1. Host Info (`host_info`)

| Field | Primary Method | Fallback |
|-------|---------------|----------|
| `hostname` | `hostname` | `cat /etc/hostname` |
| `fqdn` | `hostname -f` | `hostname` |
| `os` | `cat /etc/os-release` → PRETTY_NAME | `uname -o` |
| `kernel` | `uname -r` | — |
| `arch` | `uname -m` | — |
| `cpu_cores` | `nproc` | `grep -c ^processor /proc/cpuinfo` |
| `cpu_model` | `grep "model name" /proc/cpuinfo` | `lscpu` |
| `memory_total_mb` | `grep MemTotal /proc/meminfo` (convert to MB) | `free -m` |
| `disks` | `lsblk -dno NAME,SIZE` | `fdisk -l` |

### 2. Hypervisor (`hypervisor`)

| Detection Method | Priority |
|-----------------|----------|
| `systemd-detect-virt` | 1st |
| `dmidecode -s system-manufacturer` | 2nd |
| `cat /sys/class/dmi/id/sys_vendor` | 3rd |
| `virt-what` | 4th |
| `dmesg \| grep -i hypervisor` | 5th |
| Check `/proc/cpuinfo` for hypervisor flag | 6th |
| Default: `"unknown"` | Last |

Map detected values to enum: `vmware`, `hyperv`, `kvm`, `xen`, `virtualbox`, `nutanix`, `physical`, `unknown`

### 3. Network (`network`)

| Field | Primary Method | Fallback |
|-------|---------------|----------|
| `ip_addresses` | `ip -j addr show` (parse JSON) | `ip addr show` (parse text) → `ifconfig` |
| `default_gateway` | `ip route \| grep default` | `route -n` |
| `dns_servers` | `resolvectl status` | `cat /etc/resolv.conf` |

Each IP must include: `address`, `version` (ipv4/ipv6), `interface`

### 4. Container Runtimes (`container_runtimes[]`)

#### 4a. Detect which runtimes are installed

Check for each runtime in this order:
```
- which containerd || systemctl is-active containerd || test -S /run/containerd/containerd.sock
- which dockerd || systemctl is-active docker || test -S /var/run/docker.sock
- which crio || systemctl is-active crio || test -S /var/run/crio/crio.sock
- which podman || systemctl is-active podman || test -S /run/podman/podman.sock
```

#### 4b. Per-runtime data collection

**containerd:**
| Field | Primary | Fallback |
|-------|---------|----------|
| `version` | `containerd --version` | Parse from package manager |
| `namespaces` | `ctr namespaces list` | `crictl info` |
| `container_count` | `ctr -n k8s.io containers list \| wc -l` | `crictl ps -a \| wc -l` |
| `running_container_count` | `crictl ps \| wc -l` | Parse `ctr tasks list` |
| `image_count` | `ctr -n k8s.io images list \| wc -l` | `crictl images \| wc -l` |
| `storage_driver` | Parse `/etc/containerd/config.toml` | `containerd config dump` |
| `cgroup_driver` | Parse config for `SystemdCgroup` | Default `systemd` |
| `resource_usage` | `ps -p $(pgrep containerd) -o %cpu,rss` | `/proc/$(pgrep containerd)/stat` |

**Docker (dockerd):**
| Field | Primary | Fallback |
|-------|---------|----------|
| `version` | `docker version --format '{{.Server.Version}}'` | `dockerd --version` |
| `container_count` | `docker info --format '{{.Containers}}'` | `curl --unix-socket /var/run/docker.sock http://localhost/info` |
| `running_container_count` | `docker info --format '{{.ContainersRunning}}'` | Socket API |
| `image_count` | `docker info --format '{{.Images}}'` | Socket API |
| `storage_driver` | `docker info --format '{{.Driver}}'` | Socket API |
| `cgroup_driver` | `docker info --format '{{.CgroupDriver}}'` | Socket API |
| `resource_usage` | `ps -p $(pgrep dockerd) -o %cpu,rss` | `/proc/$(pgrep dockerd)/stat` |

**CRI-O:**
| Field | Primary | Fallback |
|-------|---------|----------|
| `version` | `crio --version` | `crictl version` |
| `container_count` | `crictl ps -a \| wc -l` | Process inspection |
| `storage_driver` | `crio config \| grep storage_driver` | Parse `/etc/crio/crio.conf` |
| `cgroup_driver` | `crio config \| grep cgroup_manager` | Parse `/etc/crio/crio.conf` |
| `registries` | Parse `/etc/containers/registries.conf` | `crio config` |
| `resource_usage` | `ps -p $(pgrep crio) -o %cpu,rss` | `/proc/$(pgrep crio)/stat` |

**Podman:**
| Field | Primary | Fallback |
|-------|---------|----------|
| `version` | `podman version --format '{{.Server.Version}}'` | `podman --version` |
| `rootless` | `podman info --format '{{.Host.Security.Rootless}}'` | Check if running as non-root |
| `container_count` | `podman ps -a --format '{{.ID}}' \| wc -l` | `podman info` |
| `storage_driver` | `podman info --format '{{.Store.GraphDriverName}}'` | Parse `/etc/containers/storage.conf` |
| `registries` | Parse `/etc/containers/registries.conf` | `podman info` |
| `resource_usage` | `ps -p $(pgrep podman) -o %cpu,rss` | Conmon process inspection |

#### 4c. Container details (for each running container)

Collect for each container: `container_id`, `name`, `image`, `image_id`, `state`, `created_at`, `started_at`, `labels`, `ports`, `resource_usage` (with cpu request/limit in millicores, memory request/limit in MB), `network_mode`, `restart_policy`, `orchestrator_managed`, `orchestrator_ref`

Detect `orchestrator_managed` by checking labels:
- Docker Swarm: `com.docker.swarm.service.name` label present
- Kubernetes: `io.kubernetes.pod.name` label present
- OpenShift: `io.openshift.*` labels present

### 5. Orchestrators (`orchestrators[]`)

#### 5a. Detect which orchestrators are active

```
- Docker Swarm: `docker info --format '{{.Swarm.LocalNodeState}}'` == "active"
- Kubernetes:   `kubectl cluster-info` succeeds OR kubelet is running OR /etc/kubernetes exists
- OpenShift:    `oc version` succeeds OR `kubectl get clusterversion` succeeds
- Tanzu:        `tanzu cluster list` succeeds OR TKG-specific labels on nodes
```

#### 5b. Kubernetes detection

| Field | Primary | Fallback |
|-------|---------|----------|
| `version` | `kubectl version --short` | `kubelet --version` |
| `cluster_id` | `kubectl get ns kube-system -o jsonpath='{.metadata.uid}'` | — |
| `cluster_name` | `kubectl config current-context` | Parse kubeconfig |
| `current_node.role` | `kubectl get node $(hostname) -o jsonpath='{.metadata.labels}'` | Check for `node-role.kubernetes.io/control-plane` |
| `nodes` | `kubectl get nodes -o json` | — |
| `workloads` | `kubectl get pods,services,deployments,daemonsets,statefulsets --all-namespaces` | — |
| `cluster_components.api_server` | `kubectl get componentstatuses` | `kubectl get pods -n kube-system` |
| `cluster_components.cni_plugin` | Detect by checking pods in kube-system (calico, flannel, cilium, etc.) | Check `/etc/cni/net.d/` |
| `cluster_components.ingress_controller` | `kubectl get pods --all-namespaces \| grep ingress` | Check ingress class |
| `cluster_components.csi_drivers` | `kubectl get csidrivers` | — |
| `distribution` | Detect by checking: k3s (`/var/lib/rancher/k3s`), rke2 (`/var/lib/rancher/rke2`), microk8s (`snap list microk8s`), kubeadm (`which kubeadm`) | Node labels/annotations |

#### 5c. Docker Swarm detection

| Field | Primary | Fallback |
|-------|---------|----------|
| `cluster_id` | `docker info --format '{{.Swarm.Cluster.ID}}'` | Socket API |
| `current_node.role` | `docker info --format '{{.Swarm.ControlAvailable}}'` | Socket API |
| `nodes` | `docker node ls` (only works on manager) | — |
| `service_count` | `docker service ls \| wc -l` | — |
| `raft_index` | `docker info --format '{{.Swarm.Cluster.RaftIndex}}'` | — |

#### 5d. OpenShift detection

| Field | Primary | Fallback |
|-------|---------|----------|
| `ocp_version` | `oc get clusterversion -o jsonpath='{.items[0].status.desired.version}'` | `kubectl get clusterversion` |
| `channel` | `oc get clusterversion -o jsonpath='{.items[0].spec.channel}'` | — |
| `install_type` | Check `oc get infrastructure cluster -o jsonpath='{.status.platform}'` | — |
| `project_count` | `oc get projects \| wc -l` | `kubectl get namespaces \| wc -l` |
| `route_count` | `oc get routes --all-namespaces \| wc -l` | — |
| `cluster_operators_degraded` | `oc get co \| grep -c Degraded` | — |
| `scc_count` | `oc get scc \| wc -l` | — |

#### 5e. VMware Tanzu detection

| Field | Primary | Fallback |
|-------|---------|----------|
| `tkg_version` | `tanzu version` | Check node annotations |
| `tkr_version` | `kubectl get tkr` | Node labels `run.tanzu.vmware.com/tkr` |
| `cluster_class` | `kubectl get cluster -o jsonpath='{.spec.topology.class}'` | — |
| `management_cluster` | `tanzu management-cluster get` | — |
| `supervisor_cluster` | Check for `vmware-system-*` namespaces | — |
| `infrastructure_provider` | `kubectl get infrastructure -o jsonpath='{.spec.cloudControllerManager}'` | Node labels |

### 6. Services (`services[]`)

For each runtime (`containerd`, `docker`, `crio`, `podman`, `kubelet`):
```
systemctl is-active <service>   → active field
systemctl is-enabled <service>  → enabled field
```

Fallback: `service <name> status` or check `/etc/init.d/<name>`

---

## Script Structure Requirements

```
#!/bin/sh
# GuestDetails_Container.sh — Container & Orchestrator Discovery Script
# Schema Version: 1.0.0

# 1. Utility functions
#    - log_info(), log_warn(), log_error() → stderr
#    - add_error(), add_warning() → populate discovery_status arrays
#    - try_command() → execute with timeout, return result or empty
#    - check_privilege() → detect if running as root/sudo available
#    - safe_json_string() → escape strings for JSON output
#    - to_json_array() → convert newline-separated values to JSON array

# 2. Discovery modules (each is a self-contained function)
#    - discover_host_info()
#    - discover_hypervisor()
#    - discover_network()
#    - discover_containerd()
#    - discover_docker()
#    - discover_crio()
#    - discover_podman()
#    - discover_containers_for_runtime(runtime_type)
#    - discover_docker_swarm()
#    - discover_kubernetes()
#    - discover_openshift()
#    - discover_tanzu()
#    - discover_services()

# 3. Main function
#    - Calls all discovery modules
#    - Assembles final JSON
#    - Prints to stdout

# 4. Entry point
#    main "$@"
```

---

## Error Handling Rules

1. **Never use `set -e`** — individual command failures must not terminate the script
2. Wrap every external command in `try_command()` with a **timeout of 10 seconds**
3. If a command fails, log the error and continue with the next fallback
4. If all fallbacks fail for a field, use the default value and add an entry to `debug.txt`
5. If a critical section fails entirely (e.g., cannot detect any runtime), add to `error.txt`
6. The script must **always produce valid JSON output**, even if everything fails

---

## Additional Requirements

1. **No external dependencies required** — the script should work with basic POSIX tools (`sh`, `grep`, `awk`, `sed`, `cat`, `wc`, `ps`, `uname`)
2. **Use `jq` if available** for cleaner JSON construction, but have a fallback without it
3. **Timeout all commands** — no command should hang indefinitely (use `timeout` command if available)
4. **Redact sensitive information** — do not include tokens, passwords, certificates, or kubeconfig credentials in output
5. **Handle multiple instances** — if both Docker and containerd are running, report both; do not skip one
6. **De-duplicate containers** — if containerd is running as Docker's backend, don't count the same container twice; use labels to determine the actual manager
7. **Timestamp**: `timestamp` must be in UTC ISO 8601 format: `date -u +"%Y-%m-%dT%H:%M:%SZ"`

---

## Attached Files

1. **`schema.json`** — The exact JSON structure the output must follow
2. **`schema_reference.md`** — All possible enum values for every field

Please generate the complete shell script.