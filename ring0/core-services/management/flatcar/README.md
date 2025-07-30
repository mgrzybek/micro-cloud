# Flatcar Linux configuration

This directory contains a `butane` file used to configure the management node using Flatcar Linux.

1. The ZFS extension is loaded.
2. The data disk of the virtual instance (`/dev/sdb`) is used as a data store.
3. `k3s` is installed.

This Flatcar Linux version is not used. Talos Linux is preferred.
