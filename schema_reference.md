# Container Discovery Schema — Enum Reference Table

> **Schema Version**: 7.0.0
> **Last Updated**: 2026-02-18

This document lists all possible values for every enumerated property in the normalized container discovery schema.

---

## Table of Contents

- [Discovery Status](#discovery-status)
- [Host Info](#host-info)
- [Hypervisor](#hypervisor)
- [Network](#network)
- [Container Runtimes](#container-runtimes)
- [Container Object](#container-object)
- [Orchestrators](#orchestrators)
- [Orchestrator — Docker Swarm](#orchestrator--docker-swarm)
- [Orchestrator — Kubernetes](#orchestrator--kubernetes)
- [Orchestrator — OpenShift Container Platform](#orchestrator--openshift-container-platform)
- [Orchestrator — VMware Tanzu](#orchestrator--vmware-tanzu)
- [Cluster Components](#cluster-components)
- [Publisher](#publisher)
- [Services](#services)

---

## Discovery Status

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `discovery_status.overall` | `success`, `partial`, `failed` | Overall discovery outcome |

---

## Host Info

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `host_info.os` | `Ubuntu 24.04.3 LTS`, `Red Hat Enterprise Linux 9.3`, `SUSE Linux Enterprise Server 15 SP5`, `CentOS Stream 9`, `Flatcar Container Linux`, `VMware Photon OS 5.0`, `Windows Server 2022` | Host operating system (free-form string) |
| `host_info.arch` | `x86_64`, `aarch64`, `s390x`, `ppc64le` | CPU architecture |

---

## Hypervisor

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `hypervisor.type` | `vmware`, `hyperv`, `kvm`, `xen`, `virtualbox`, `nutanix`, `physical`, `unknown` | Hypervisor platform type |

---

## Network

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `network.ip_addresses[].version` | `ipv4`, `ipv6` | IP address version |

---

## Container Runtimes

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `runtime_type` | `docker`, `containerd`, `crio`, `podman` | Container runtime type discriminator |
| `cgroup_driver` | `systemd`, `cgroupfs` | Cgroup driver used by the runtime |
| `rootless` | `true`, `false` | Whether runtime is running in rootless mode |

### Storage Driver (per runtime)

| Runtime | Possible Values |
|---------|----------------|
| Docker | `overlay2`, `fuse-overlayfs`, `btrfs`, `zfs`, `vfs`, `devicemapper` |
| containerd | `overlayfs`, `btrfs`, `zfs`, `native` |
| CRI-O | `overlay`, `vfs`, `btrfs` |
| Podman | `overlay`, `vfs`, `btrfs`, `zfs` |

### Namespaces (per runtime)

| Runtime | Possible Values | Notes |
|---------|----------------|-------|
| Docker | `[]` (empty) | Docker does not use containerd-style namespaces |
| containerd | `default`, `moby`, `k8s.io` | `moby` when used by Docker; `k8s.io` when used by Kubernetes |
| CRI-O | `k8s.io` | Always used with Kubernetes |
| Podman | `[]` (empty) | Podman does not use containerd-style namespaces |

---

## Container Object

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `state` | `running`, `paused`, `stopped`, `created`, `exited`, `dead`, `unknown` | Container lifecycle state |
| `ports[].protocol` | `tcp`, `udp` | Port protocol |
| `network_mode` | `host`, `bridge`, `none`, `overlay`, `macvlan`, `ipvlan`, `slirp4netns`, `pasta`, `custom` | Container network mode |
| `restart_policy` | `always`, `unless-stopped`, `on-failure`, `no`, `Never`, `OnFailure`, `Always` | Container restart policy |
| `orchestrator_managed` | `true`, `false` | Whether container is managed by an orchestrator |
| `orchestrator_ref.type` | `docker-swarm`, `kubernetes`, `openshift`, `tanzu`, `""` | Orchestrator managing this container (empty if standalone) |

### Network Mode (per runtime)

| Runtime | Possible Values | Notes |
|---------|----------------|-------|
| Docker | `host`, `bridge`, `none`, `overlay`, `macvlan`, `ipvlan`, `custom` | `overlay` for Swarm services |
| containerd | `host`, `bridge`, `none`, `custom` | Depends on CNI plugin |
| CRI-O | `host`, `bridge`, `none`, `custom` | Depends on CNI plugin |
| Podman | `host`, `bridge`, `none`, `slirp4netns`, `pasta`, `macvlan` | `slirp4netns`/`pasta` for rootless |

### Restart Policy Mapping

| Runtime / Orchestrator | Possible Values | Notes |
|------------------------|----------------|-------|
| Docker / Docker Swarm | `always`, `unless-stopped`, `on-failure`, `no` | Lowercase values |
| Kubernetes / OpenShift / Tanzu | `Always`, `OnFailure`, `Never` | PascalCase values (K8s pod spec) |

---

## Orchestrators

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `orchestrator_type` | `docker-swarm`, `kubernetes`, `openshift`, `tanzu` | Orchestrator type discriminator |

---

## Orchestrator — Docker Swarm

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `state` | `active`, `pending`, `inactive`, `locked`, `error`, `drain` | Swarm cluster state |
| `current_node.role` | `manager`, `worker` | Current node's role in the Swarm |
| `current_node.availability` | `active`, `pause`, `drain` | Current node's scheduling availability |
| `nodes[].status` | `ready`, `down`, `disconnected`, `unknown` | Individual node status |

---

## Orchestrator — Kubernetes

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `state` | `active`, `degraded`, `error`, `unknown` | Cluster health state |
| `current_node.role` | `control-plane`, `worker` | Current node's role |
| `current_node.availability` | `Ready`, `NotReady`, `SchedulingDisabled`, `Unknown` | Current node condition |
| `nodes[].status` | `Ready`, `NotReady`, `Unknown` | Individual node status |
| `platform_specific.kubernetes.distribution` | `kubeadm`, `k3s`, `rke2`, `microk8s`, `kind`, `minikube`, `eks`, `aks`, `gke` | Kubernetes distribution |

---

## Orchestrator — OpenShift Container Platform

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `state` | `active`, `degraded`, `progressing`, `error`, `unknown` | Cluster health state |
| `current_node.role` | `master`, `worker`, `infra` | Current node's role (`infra` is OCP-specific) |
| `current_node.availability` | `Ready`, `NotReady`, `SchedulingDisabled`, `Unknown` | Current node condition |
| `nodes[].status` | `Ready`, `NotReady`, `Unknown` | Individual node status |
| `platform_specific.openshift.install_type` | `IPI`, `UPI`, `assisted`, `SNO` | OCP installation method |
| `platform_specific.openshift.channel` | `stable-4.x`, `fast-4.x`, `candidate-4.x`, `eus-4.x` | OCP update channel |

---

## Orchestrator — VMware Tanzu

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `state` | `active`, `creating`, `deleting`, `updating`, `error`, `unknown` | Cluster lifecycle state |
| `current_node.role` | `control-plane`, `worker` | Current node's role |
| `current_node.availability` | `Ready`, `NotReady`, `Unknown` | Current node condition |
| `nodes[].status` | `Ready`, `NotReady`, `Unknown` | Individual node status |
| `platform_specific.tanzu.infrastructure_provider` | `vsphere`, `aws`, `azure` | Tanzu infrastructure provider |
| `platform_specific.tanzu.cluster_class` | `tkg-vsphere-default-v1.x.x`, `tkg-aws-default-v1.x.x` | TKG cluster class template |

---

## Cluster Components

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `api_server.status` | `Healthy`, `Unhealthy`, `Unknown`, `""` | API server health (empty for Swarm) |
| `coredns.status` | `Running`, `Degraded`, `Unknown`, `""` | CoreDNS health (empty for Swarm) |

### CNI Plugin

| Orchestrator | Possible Values |
|-------------|----------------|
| Docker Swarm | `overlay`, `""` |
| Kubernetes | `calico`, `flannel`, `cilium`, `weave`, `canal`, `antrea`, `none` |
| OpenShift | `ovn-kubernetes`, `openshift-sdn`, `calico` |
| Tanzu | `antrea`, `calico`, `cilium` |

### Ingress Controller

| Orchestrator | Possible Values |
|-------------|----------------|
| Docker Swarm | `""` (none) |
| Kubernetes | `nginx`, `traefik`, `haproxy`, `contour`, `istio`, `kong`, `none` |
| OpenShift | `haproxy`, `openshift-router` |
| Tanzu | `contour`, `nginx`, `istio` |

### CSI Drivers

| Environment | Possible Values |
|------------|----------------|
| VMware | `csi.vsphere.vmware.com` |
| AWS | `ebs.csi.aws.com`, `efs.csi.aws.com` |
| Azure | `disk.csi.azure.com`, `file.csi.azure.com` |
| GCP | `pd.csi.storage.gke.io` |
| NFS | `nfs.csi.k8s.io` |
| Local | `local.csi.k8s.io` |

---

## Publisher

### Package Name (per runtime)

| Runtime | Possible Values | Description |
|---------|----------------|-------------|
| Docker | `docker-ce`, `docker.io`, `docker-ee` | Community, Ubuntu/Debian, Enterprise editions |
| containerd | `containerd.io`, `containerd` | Docker-packaged vs distro-packaged |
| CRI-O | `cri-o`, `crio` | Standard vs alternate package name |
| Podman | `podman`, `podman-docker` | Standard vs Docker-compatible wrapper |

---

## Services

| Property | Possible Values | Description |
|----------|----------------|-------------|
| `services[].name` | `containerd`, `docker`, `crio`, `podman`, `kubelet` | Systemd service name |
| `services[].active` | `active`, `inactive`, `failed`, `activating`, `deactivating` | Systemd active state |
| `services[].enabled` | `enabled`, `disabled`, `masked`, `static` | Systemd enabled state |

---

## Default Values for Non-Applicable Fields

When a field is not applicable to a specific runtime or orchestrator, use these defaults:

| Type | Default Value | Example |
|------|--------------|---------|
| String | `""` (empty string) | `cluster_name` for Swarm |
| Integer | `0` | `pod_count` for Swarm |
| Float | `0.0` | `cpu_cores` when not measurable |
| Boolean | `false` | `rootless` for containerd |
| Array | `[]` | `namespaces` for Podman |
| Object | `null` | `platform_specific.openshift` on a K8s cluster |

> **Rule**: Never use `null` for common/shared fields. Only `platform_specific` sub-objects use `null` to indicate "not this platform".