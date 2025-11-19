# Deploying Kubernetes using Ubuntu Linux VMs and Cluster API

This deployment uses image-builder in order to create ready-to-use Ubuntu virtual nodes.

This allows us to validate capi's behaviour without provisioning real hardware.

```console
task: Available tasks for this project:
* build-ubuntu:                 Build Ubuntu using image builder
* delete-nodes:                 Delete virtual instances and cluster
* deploy-nodes:                 Create Hardware objects and start virtual instances
* init-clusterapi:              Deploy Tinkerbell Cluster API
* transfert-ubuntu-image:       Prepare the Ubuntu Linux image from image builder
```

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
