# Deploying Kubernetes using Flatcar Linux VMs and Cluster API

This deployment uses custom butane/ignition and clou-init to create ready-to-use Flatcar virtual nodes.

This allows us to validate CAPI and CAPT behaviours without provisioning real hardware.

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
