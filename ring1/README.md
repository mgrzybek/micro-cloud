# Ring 1 — Workload Hosting Zone

Ring 1 is the experimental zone where Kubernetes clusters are deployed and managed by Ring 0.
It supports multiple infrastructure backends (bare-metal, VMs) and control plane strategies.

## Deployment strategies

| Directory | Control plane | Workers | OS |
| --- | --- | --- | --- |
| [kamaji-tailscale/](kubernetes/kamaji-tailscale/) | Kamaji (hosted) | External / manual | — |
| [capi-kamaji-hardware-flatcar/](kubernetes/capi-kamaji-hardware-flatcar/) | Kamaji (hosted) | Bare-metal via Tinkerbell | Flatcar Linux |
| [capi-kamaji-vm-flatcar/](kubernetes/capi-kamaji-vm-flatcar/) | Kamaji (hosted) | Incus VMs | Flatcar Linux |
| [capi-kubeadm-vm-flatcar/](kubernetes/capi-kubeadm-vm-flatcar/) | kubeadm | Incus VMs | Flatcar Linux |
| [capi-kubeadm-vm-ubuntu/](kubernetes/capi-kubeadm-vm-ubuntu/) | kubeadm | Incus VMs | Ubuntu |

All clusters use **Cilium** as the CNI and are exposed via **Tailscale** for admin access.

## Prerequisites

Ring 0 must be fully deployed (`task bmaas` completed):
Kamaji, Cluster API + CAPT, Tinkerbell, and the Zot registry must be operational.

Shared OCI images (butane, flatcar-install, machinecfg) are built from [common/](common/).
