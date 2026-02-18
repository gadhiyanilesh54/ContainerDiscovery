# Validation Checklist

Use this checklist to validate the Container Discovery Script in your environment.

## Prerequisites

- [ ] Linux system (Ubuntu, RHEL, CentOS, SUSE, Flatcar, or Photon OS)
- [ ] `jq` installed (`sudo apt-get install jq` or `sudo yum install jq`)
- [ ] One or more container runtimes installed (containerd, Docker, CRI-O, or Podman)
- [ ] Optional: Container orchestrator running (Kubernetes, Docker Swarm, OpenShift, or Tanzu)

## Step 1: Basic Execution Test

### With Privileges (sudo/root)

```bash
# Run the discovery script
sudo ./GuestDetails_Container.sh

# Verify output files exist
ls -l output.json debug.txt error.txt

# Validate JSON is well-formed
jq . output.json

# Run basic privileged test
sudo ./test_privileged.sh
```

**Expected Results:**
- [x] Script completes without crashing (exit code 0 or 1)
- [x] `output.json` exists and is valid JSON
- [x] `debug.txt` exists with debug logs
- [x] `error.txt` exists (may be empty)
- [x] At least one container runtime detected
- [x] Basic test passes

### Without Privileges (guest user)

```bash
# Run as normal user
./GuestDetails_Container.sh

# Validate output
jq . output.json

# Run unprivileged test
./test_unprivileged.sh
```

**Expected Results:**
- [x] Script completes without crashing
- [x] `output.json` exists and is valid JSON
- [x] Fallback mechanisms used (check debug.txt)
- [x] Some data collected despite limited privileges
- [x] Unprivileged test passes

## Step 2: Comprehensive Validation

```bash
# Run comprehensive validation (after running GuestDetails_Container.sh)
./test_validation_comprehensive.sh
```

**This test validates:**
- [ ] No hardcoded values in dynamic output
- [ ] Runtime versions are dynamically detected
- [ ] Orchestrator versions are dynamically detected
- [ ] Cluster IDs don't contain error messages
- [ ] Container counts are consistent (running + paused + stopped ≤ total)
- [ ] Node counts are consistent (master + worker = total)
- [ ] Workload counts are consistent (system + user = total)
- [ ] Socket paths are valid absolute paths
- [ ] Storage roots are valid absolute paths
- [ ] Privilege level was properly detected
- [ ] Host information is properly populated

**Expected Results:**
- [ ] All tests pass
- [ ] No hardcoded values found in output
- [ ] Cross-field consistency validated
- [ ] Error messages filtered from output fields

## Step 3: Fallback Mechanism Validation

```bash
# Validate fallback mechanisms
./test_fallback_mechanisms.sh
```

**This test validates:**
- [ ] Privilege level detected correctly
- [ ] Primary detection methods attempted
- [ ] Fallback methods used when needed
- [ ] Version detection tried multiple methods
- [ ] Socket detection attempted
- [ ] Config file parsing used as fallback
- [ ] Process inspection attempted
- [ ] Systemd queries performed
- [ ] Error handling and recovery working

**Expected Results:**
- [ ] Fallback test passes
- [ ] Fallback mechanisms logged in debug.txt
- [ ] Multiple detection methods attempted
- [ ] Graceful degradation verified

## Step 4: Kubernetes-Specific Validation (if applicable)

```bash
# Only run if Kubernetes is installed and running
./test_kubernetes_fields.sh
```

**This test validates:**
- [ ] Kubernetes orchestrator detected
- [ ] Master nodes array populated
- [ ] Worker nodes array populated
- [ ] Node counts consistent
- [ ] Container counts calculated correctly
- [ ] System vs user container separation
- [ ] API server version detected
- [ ] CoreDNS status detected
- [ ] CNI plugin type detected
- [ ] Ingress controller detected (if present)
- [ ] CSI drivers detected (if present)

**Expected Results:**
- [ ] Kubernetes fields test passes
- [ ] Node arrays not empty when nodes exist
- [ ] Container counts match pod counts
- [ ] Cluster components have proper detection

## Step 5: Runtime-Specific Validation

### containerd
- [ ] Runtime detected in `container_runtimes` array
- [ ] Version is not empty or error message
- [ ] Namespaces array populated (k8s.io, moby, or default)
- [ ] Socket path: `/run/containerd/containerd.sock`
- [ ] Storage root: `/var/lib/containerd`
- [ ] Container count ≥ 0
- [ ] Image count ≥ 0

### Docker
- [ ] Runtime detected in `container_runtimes` array
- [ ] Version is not empty or error message
- [ ] Socket path: `/var/run/docker.sock`
- [ ] Storage root: `/var/lib/docker`
- [ ] Storage driver detected (overlay2, etc.)
- [ ] Cgroup driver detected
- [ ] Container count ≥ 0
- [ ] Image count ≥ 0

### CRI-O
- [ ] Runtime detected in `container_runtimes` array
- [ ] Version is not empty or error message
- [ ] Socket path: `/var/run/crio/crio.sock`
- [ ] Storage root: `/var/lib/containers/storage`
- [ ] Storage driver detected
- [ ] Container count ≥ 0
- [ ] Image count ≥ 0

### Podman
- [ ] Runtime detected in `container_runtimes` array
- [ ] Version is not empty or error message
- [ ] Rootless mode correctly detected
- [ ] Socket path appropriate for mode (root vs rootless)
- [ ] Storage root appropriate for mode
- [ ] Container count ≥ 0
- [ ] Image count ≥ 0

## Step 6: Orchestrator-Specific Validation

### Kubernetes
- [ ] Orchestrator detected in `orchestrators` array
- [ ] Version is not empty or error message
- [ ] Cluster ID present (if accessible)
- [ ] Cluster name present
- [ ] State is valid enum (active, degraded, etc.)
- [ ] Node role detected (control-plane or worker)
- [ ] Total node count > 0 (if cluster accessible)
- [ ] Master nodes array populated
- [ ] Worker nodes array populated
- [ ] Pod count ≥ 0
- [ ] Distribution detected (kubeadm, k3s, kind, etc.)

### Docker Swarm
- [ ] Orchestrator detected in `orchestrators` array
- [ ] Version matches Docker version
- [ ] Cluster ID present
- [ ] State is "active"
- [ ] Node role detected (manager or worker)
- [ ] Service count ≥ 0 (if manager node)
- [ ] Container count ≥ 0

### OpenShift
- [ ] Orchestrator detected in `orchestrators` array
- [ ] Version is not empty or error message
- [ ] Cluster ID present
- [ ] OCP version in platform_specific.openshift
- [ ] Install type detected (IPI, UPI, etc.)
- [ ] Project count ≥ 0

### Tanzu
- [ ] Orchestrator detected in `orchestrators` array
- [ ] Version is not empty or error message
- [ ] TKG version in platform_specific.tanzu
- [ ] TKR version present
- [ ] Infrastructure provider detected (vsphere, aws, azure)

## Step 7: Output Validation

### JSON Structure
- [ ] Valid JSON (no syntax errors)
- [ ] Schema version is "1.0.0"
- [ ] Timestamp is in ISO 8601 format
- [ ] All required top-level fields present:
  - [ ] schema_version
  - [ ] timestamp
  - [ ] host_info
  - [ ] hypervisor
  - [ ] network
  - [ ] container_runtimes (array)
  - [ ] orchestrators (array)
  - [ ] services (array)

### Host Information
- [ ] hostname is not empty or "unknown"
- [ ] os is not empty or "unknown"
- [ ] kernel is not empty or "unknown"
- [ ] arch is valid enum (x86_64, aarch64, etc.)
- [ ] cpu_cores > 0
- [ ] memory_total_mb > 0
- [ ] disks array present (may be empty)

### Network
- [ ] ip_addresses array has at least one entry
- [ ] Each IP has address, version (ipv4/ipv6), interface
- [ ] default_gateway present
- [ ] dns_servers array present (may be empty)

### Services
- [ ] Services array has entries for detected runtimes
- [ ] Each service has name, active, enabled fields
- [ ] Active is valid enum (active, inactive, failed, etc.)
- [ ] Enabled is valid enum (enabled, disabled, masked, static)

## Step 8: Privilege-Specific Validation

### With sudo/root
- [ ] All available runtimes detected
- [ ] All running orchestrators detected
- [ ] Socket access successful
- [ ] Full container/image counts
- [ ] Node lists populated
- [ ] Cluster information complete

### Without privileges
- [ ] Script completes without crashing
- [ ] Basic host info collected
- [ ] Some runtime detection via fallbacks
- [ ] Orchestrator detection limited but graceful
- [ ] Fallback methods logged
- [ ] No hardcoded "permission denied" in output

## Step 9: Error and Debug Logs

### debug.txt
- [ ] Contains timestamp for each entry
- [ ] Shows privilege level detected
- [ ] Logs command attempts
- [ ] Shows fallback usage
- [ ] No sensitive information (passwords, tokens)

### error.txt
- [ ] May be empty (acceptable)
- [ ] Contains only genuine errors
- [ ] No "expected" errors from unprivileged mode
- [ ] No duplicate error messages
- [ ] No sensitive information

## Step 10: Cross-Environment Testing

### Test Environments
- [ ] Tested on Ubuntu
- [ ] Tested on RHEL/CentOS
- [ ] Tested with Kubernetes
- [ ] Tested with Docker Swarm
- [ ] Tested with sudo
- [ ] Tested without sudo
- [ ] Tested with containerd
- [ ] Tested with Docker
- [ ] Tested with CRI-O (if available)
- [ ] Tested with Podman (if available)

## Final Checklist

- [ ] All test scripts pass
- [ ] No hardcoded values in output
- [ ] Fallback mechanisms working
- [ ] Privilege degradation handled
- [ ] JSON always valid
- [ ] Error handling graceful
- [ ] Documentation complete

## If Any Test Fails

1. Check the test output for specific failure details
2. Review `debug.txt` for command execution logs
3. Review `error.txt` for error messages
4. Verify prerequisites are met
5. Check privilege level is appropriate for test
6. Consult `VALIDATION_REPORT.md` for known limitations
7. Report issue with:
   - Test output
   - debug.txt
   - error.txt
   - output.json
   - Environment details (OS, runtime versions)

## Success Criteria

✅ **All tests pass** - Script is validated for your environment
✅ **Valid JSON output** - Can be integrated with monitoring systems
✅ **Comprehensive detection** - All available runtimes/orchestrators found
✅ **Graceful degradation** - Works at all privilege levels
✅ **No hardcoded values** - Dynamic detection working properly

---

**Note**: Some tests may show warnings but still pass. Warnings indicate areas where detection was limited but the script handled it gracefully. Review warnings in context of your environment.
