# Talos patches

## `patch.yaml.j2` (global → `dist/patch.yaml`)

Global patch applied to all machines via `talosctl gen config --config-patch`. Contains only objects that are common to every node:

- `TrustedRootsConfig` — internal CA bundle
- `UserVolumeConfig` — local-path-provisioner data disk

## `patch.yaml.j2` (control plane → `dist/cp-patch.yaml`)

Control-plane-only patch applied via `--config-patch-control-plane`. Contains:

- `cluster` settings (apiServer SANs, admissionControl, CNI, proxy)
- `machine` settings (hostname, network interfaces, NTP, kubelet mounts)
- `ExtensionServiceConfig: tailscale` — management node Tailscale key
- `ExtensionServiceConfig: lldpd` — LLDP daemon config

Variables: `bootstrap_ipaddr`, `services_ipaddr`, `bootstrap_cidr`, `services_cidr`, `bmaas_namespace`, `ts_suffix`, `ts_authkey`.

## Per-machine worker patches (gitops)

Worker-specific patches live in the gitops repository at `ring0/workers/<hostname>/patch.yaml`.
They contain all static Talos objects for the machine (network, VLANs, volumes, `ExtensionServiceConfig: tailscale`)
with two `envsubst` placeholders injected at runtime:

- `${INSTALL_IMAGE}` — Talos factory installer URL built from `TALOS_FACTORY_URL`, `WORKER_TALOS_FACTORY_UUID`, and the cluster's current Talos version
- `${MGMT_TS_IP}` — management node Tailscale IP resolved via `tailscale status`
