# Scripts

- [common.sh](common.sh): bash fonctions used by the other scripts.
- [deploy-bmaas.sh](./deploy-bmaas.sh): deploys the bare metal as a service software.
- [deploy-eso.sh](./deploy-eso.sh): deploys External Secrets Operator and creates the ClusterSecretStore backed by OpenBao.
- [deploy-bootstrap.sh](./deploy-bootstrap.sh): creates the bootstrap instance and configure its services.
- [deploy-cmdb.sh](./deploy-cmdb.sh): deploys the CMDB software.
- [deploy-forge.sh](./deploy-forge.sh): creates the forge instance and installes some building tools.
- [deploy-idp.sh](./deploy-idp.sh): deploys the identity provider.
- [deploy-management.sh](./deploy-management.sh): creates the management instance and configures the cluster.
- [management/add-worker.sh](./management/add-worker.sh): adds a physical worker node to the management cluster via Matchbox PXE boot (use `task add-worker`). Requires `GITOPS_ROOT` pointing to the gitops repository and a per-machine patch file at `$GITOPS_ROOT/ring0/workers/$WORKER_HOSTNAME/patch.yaml`.
- [deploy-netboot-testing-vm.sh](./deploy-netboot-testing-vm.sh): creates a dummy machine that you be enrolled by the BMaaS.
- [deploy-pki.sh](./deploy-pki.sh): creates the PKI instance and configures the certificates and services.
- [init-headnode.sh](./init-headnode.sh): configures the headnode in an interactive way.
