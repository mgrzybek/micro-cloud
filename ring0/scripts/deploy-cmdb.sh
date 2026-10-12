#! /usr/bin/env bash

set -euo pipefail

################################################################################
# External libraries
RING0_ROOT="$(find "$PWD" -type d -name ring0 | head -n1)"

# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/management/install-platform-management.sh"

################################################################################
# Starting the tasks
# Netbox is installed by Flux (HelmRelease apps/04-cmdb).
# The cmdb-netbox-remote-auth secret is rendered by hand from
# core-services/management/manifests/04-cmdb/netbox-remote-auth.py.j2 with the
# Authentik OAuth credentials: no script creates it.
# This script only creates the Tailscale API gateway needed to expose cmdb.<ts_suffix>.

install_cmdb_api_gateway
