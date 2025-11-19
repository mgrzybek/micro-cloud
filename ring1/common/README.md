# Deploying Kubernetes using Flatcar Linux

## Create the utility images

Theses image are built using the forge instance on the headnode.

### Flatcar tooling

`flatcar-install` is the official installation script.
It is embedded into an OCI image to be used as a Tinkerbell action.

```bash
task create-flatcar-install-oci
task push-flatcar-install-oci
```

`cloud-init` is embedded into an OCI image to be used at Flatcar Linux startup.
It will grab Kubernetes configurations from the metadata service before letting `kubeadm` setup the node.

```bash
task create-cloud-init-oci
task push-cloud-init-oci
```
