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

### TPM2 tooling

`tpm2-tools` is embedded into an OCI image to be used as a Tinkerbell action for TPM2 initialization.

```bash
task create-tpm2-tools-oci
task push-tpm2-tools-oci
```

## TPM2 initialization workflow

The `tpm2-init` Tinkerbell template initializes the TPM2 chip of a bare-metal machine during provisioning:

1. Creates a primary key in the **endorsement hierarchy** (RSA 2048)
2. Exports the public key as a PEM file
3. Pushes the public key to a remote HTTP endpoint, identified by the machine MAC address

### Required environment variables

| Variable | Description |
|---|---|
| `NAMESPACE` | Kubernetes namespace for the Tinkerbell Template object |
| `TPM2_PUBKEY_ENDPOINT` | HTTP endpoint receiving the public key (e.g. `https://vault.example.com/tpm/pubkeys`) |

### Create the template

```bash
export NAMESPACE=<namespace>
export TPM2_PUBKEY_ENDPOINT=https://<endpoint>/tpm/pubkeys
task create-tpm2-init-template
```

The rendered manifest is written to `dist/tpm2-init-template.yaml` and applied to the cluster.
To use it, create a Tinkerbell `Workflow` object referencing `templateRef: tpm2-init` and the target `Hardware`.
