# Deploying Kubernetes using Ubuntu Linux VMs and Cluster API

This deployment uses image-builder in order to create ready-to-use Ubuntu virtual nodes.

This allows us to validate capi's behaviour without provisioning real hardware.

## Initialize the service

```bash
task build-ubuntu
task transfert-ubuntu-image
task init-clusterapi
```

## Create the cluster

```bash
task deploy-nodes
```

## Delete the cluster

```bash
task delete-nodes
```
