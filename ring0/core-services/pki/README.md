# Configuring PKI

## Root and intermediate CAs

### Creating the json configuration files

Some files need to be edited according to the desired hierarchy:

- [root-csr.json](./files/root/root-csr.json)
- [intermediate-csr.json](./files/intermediate/intermediate-csr.json)

### Creating the keys and bundles

Then the keys and bundles can be generated using the Makefile target.

```bash
make files/intermediate/intermediate-fullchain.pem
```

## Creating the certificates

The required certificates are created by [deploy-bootstrap.sh](../../scripts/deploy-bootstrap.sh).

## OpenBao

OpenBao runs inside the `pki` Incus instance. Run `bao`/`vault` commands (unseal,
`kv put`, `policy write`, etc.) from inside that container, not from the host:

```bash
incus exec pki -- bash
```

Credentials live in `dist/` on the host (never committed to git):

| File | Purpose |
|---|---|
| `dist/openbao-root.token` | Root token — required for write operations (e.g. `bao kv put`) |
| `dist/openbao-unseal.key` | Unseal key, needed if the OpenBao service restarts sealed |
| `dist/openbao-approle-role-id` / `-secret-id` | `cert-manager` AppRole (PKI signing only) |
| `dist/openbao-eso-role-id` / `-secret-id` | `eso` AppRole (read-only on `secret/*`, used by the ClusterSecretStore) |

Example — writing a secret consumed by an ExternalSecret (from inside the `pki`
container):

```bash
export VAULT_ADDR=https://<pki-instance-ip>:8200
export VAULT_TOKEN="$(cat dist/openbao-root.token)"
bao kv put secret/truenas-csi api-key=<your-api-key>
```
