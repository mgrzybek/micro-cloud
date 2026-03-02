# Deploying Kubernetes using Kamaji and Tailscale

This deployment creates a Kamaji `TenantControlPlane` exposed via a Tailscale service.
Workers join the cluster manually using a generated join command.

The CNI is **Cilium**. The API server is reachable via its Tailscale hostname (`$CLUSTER_NAME`).

```console
task: Available tasks for this project:
* clean:    Remove generated files from dist/
* create:   Create the Kamaji TenantControlPlane and publish it on Tailscale
* delete:   Delete the Kamaji TenantControlPlane
```

## Required environment variables

| Variable | Description |
| --- | --- |
| `NAMESPACE` | Kubernetes namespace for the TenantControlPlane |
| `CLUSTER_NAME` | Name of the cluster (also used as Tailscale hostname) |
| `TS_SUFFIX` | Tailscale DNS suffix (e.g. `my-cloud.ts.net`) |

## Create the cluster

```bash
export NAMESPACE=my-namespace CLUSTER_NAME=my-cluster TS_SUFFIX=my-cloud.ts.net
task create
```

The kubeconfig is written to `dist/kubeconfig`.
A worker join script is written to `dist/join-command.sh`.

## Delete the cluster

```bash
task delete
task clean
```
