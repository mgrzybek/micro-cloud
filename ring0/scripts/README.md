# Scripts

## Bootstrap (one-shot, imperative)

These scripts run sequentially to provision the physical infrastructure.
They are not managed by Flux.

- [deploy-pki.sh](deploy-pki.sh): creates the PKI Incus instance, initialises cfssl and OpenBao, generates the intermediate CA and AppRole credentials consumed by cert-manager and ESO.
- [deploy-bootstrap.sh](deploy-bootstrap.sh): creates the bootstrap Incus instance and configures Matchbox for PXE booting.
- [deploy-forge.sh](deploy-forge.sh): creates the forge Incus instance used to build custom OCI images (CoreDNS with Netbox plugin, HookOS).
- [deploy-management.sh](deploy-management.sh): creates the management Talos instance, bootstraps the Kubernetes cluster, and installs the core components (Cilium, cert-manager, CNPG, Tailscale Operator, local-path-provisioner, PostgreSQL cluster).
- [deploy-flux.sh](deploy-flux.sh): bootstraps FluxCD Operator; creates the pre-requisite Secrets and the `cluster-config` ConfigMap; applies the `FluxInstance`. Run after `deploy-management.sh`. From this point on, Flux manages all platform workloads.

## Post-Flux setup (API gateways)

These scripts create the Tailscale `Service` and TLS `Certificate` that expose each
application on the tailnet. They run after Flux has deployed the underlying Helm
chart and Tailscale has assigned a tailnet IP to the service.

- [deploy-idp.sh](deploy-idp.sh): creates the Tailscale API gateway for Authentik (`idp.<ts_suffix>`). Authentik itself is deployed by Flux.
- [deploy-cmdb.sh](deploy-cmdb.sh): creates the Tailscale API gateway for Netbox (`cmdb.<ts_suffix>`). Netbox itself is deployed by Flux.

## BMaaS operations

Steps that remain outside Flux because they involve artifact builds and binary
operations on the Incus instances.

- [deploy-bmaas.sh](deploy-bmaas.sh): builds and syncs HookOS to the bootstrap server; populates the Zot registry with Tinkerbell action images; runs `clusterctl init`. Zot, Tinkerbell, and Kamaji are deployed by Flux.

## Day-2 / worker nodes

- [management/add-worker.sh](management/add-worker.sh): adds a physical worker node to the management cluster via Matchbox PXE boot (use `task add-worker`). Requires `GITOPS_ROOT` pointing to the gitops repository and a per-machine patch file at `$GITOPS_ROOT/ring0/workers/$WORKER_HOSTNAME/patch.yaml`.
- [deploy-netboot-testing-vm.sh](deploy-netboot-testing-vm.sh): creates a dummy VM to validate the PXE/BMaaS enrolment flow.
- [init-headnode.sh](init-headnode.sh): configures the headnode interactively (first run only).
- [upgrade-management.sh](upgrade-management.sh): upgrades the Talos management cluster.

## Shared library

- [common.sh](common.sh): bash functions used by all other scripts (`print_milestone`, `print_step`, `print_check`, …).
