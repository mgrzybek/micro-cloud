# Matchbox files

These files are used to configure the `matchbox` netboot service.

Depending on the needs, the right files are pushed into the bootstrap instance at `/var/lib/matchbox`.

## Profiles (`profiles/`)

- `talos.json` — boots Talos Linux (kernel + initramfs); machine config fetched at `http://<bootstrap>:8080/assets/talos/${hostname}.yaml`
- `flatcar-installer.json` — boots Flatcar Linux live for bare-metal installation
- `flatcar-management.json` — post-install Flatcar profile (selected once `os=installed`)

## Groups (`groups/`)

- `talos-management.json` — selector `hostname=management, domain=incus`; targets the management VM (Incus)
- `talos-<hostname>.json` — selector `mac=<mac-address>`; targets a physical worker node

Physical worker groups are **not versioned** in this directory. They are generated at runtime by [add-worker.sh](../../../scripts/management/add-worker.sh) (via `task add-worker`) from the `WORKER_HOSTNAME` and `WORKER_MAC` environment variables, written to `dist/`, and pushed to the bootstrap instance.
