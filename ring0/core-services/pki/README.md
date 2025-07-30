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
