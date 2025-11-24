# Deploying Kubernetes using Flatcar Linux VMs, Kamaji, Tinkerbell and ClusterAPI

This deployment uses custom butane/ignition and cloud-init to create ready-to-use Flatcar virtual nodes.
The default CNI is Cilium.

This allows us to validate CAPI and CAPT behaviours without provisioning real hardware.

The controlplane endpoint is available at 192.168.3.8 and is also published via Tailscale (capi-vm).

```console
task: Available tasks for this project:
* create-capi-vm:            Create tinkerbell template and workflow
* create-ignition:           Create dedicated ignition file for CAPI and CAPT
* delete-nodes:              Delete virtual instances and cluster
* deploy-nodes:              Create Hardware objects and start virtual instances
* init-clusterapi:           Deploy Tinkerbell Cluster API
* populate-extensions:       Add Kubernetes extension files to the assets service
* populate-registry:         Add some OCI images into the registry
```

## Initialize the service

```bash
task populate-extensions
task populate-registry
task init-clusterapi
```

## Create the cluster

```bash
task deploy-nodes
task create-ignition
task create-capi-vm
```

## Delete the cluster

```bash
task delete-nodes
```
