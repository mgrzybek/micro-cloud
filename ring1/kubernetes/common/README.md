# ring1/kubernetes/common

Sveltos configurations shared across all `ring1` Kubernetes clusters.

These manifests are applied on the management cluster (`ring0`) and drive the automatic deployment of components onto managed clusters (`ring1`) via the Sveltos agent.

## Prerequisites

- [Sveltos](https://projectsveltos.github.io/sveltos/) installed on the management cluster
- Target clusters must carry the label `sveltos-management: "true"` to be picked up

> The label is set automatically at cluster creation time via the CAPI template
> (`capi-hardware.yaml.j2`, `capi-vm-*.yaml.j2`, etc.).

## Contents

### ClusterProfiles

| File | Name | Target | Description |
|---|---|---|---|
| `clusterprofile-core-services.yaml` | `core-services` | `sveltos-management: "true"` | Common services deployed on every ring1 cluster |

#### core-services

Deployed on **all** `ring1` clusters labelled `sveltos-management: "true"`:

| Chart | Version | Namespace | Role |
|---|---|---|---|
| `kyverno/kyverno` | v3.3.3 | `kyverno-system` | Kubernetes policy engine |
| `kured/kured` | 5.10.0 | `kube-system` | Automatic node reboot for Flatcar |

> **Kamaji note**: admission webhooks (e.g. Capsule) are not compatible with Kamaji clusters
> without external exposure, because the control plane hosted on `ring0` cannot reach the
> managed cluster's ClusterIPs. Use `failurePolicy: Ignore` or expose the webhook service
> via NodePort/Tailscale instead.

### ConfigMaps

| File | Name | Namespace | Consumed by |
|---|---|---|---|
| `configmap-kured-config.yaml` | `kured-config` | `mgmt` | `core-services` → kured chart (`valuesFrom`) |

## Deployment

```bash
kubectl apply -f ring1/kubernetes/common/
```

## Adding a cluster

To bring a new cluster under Sveltos management, apply the label:

```bash
kubectl label cluster <name> -n <namespace> sveltos-management=true
```

Then verify that a `ClusterSummary` is created:

```bash
kubectl get clustersummary -n <namespace> -w
```
