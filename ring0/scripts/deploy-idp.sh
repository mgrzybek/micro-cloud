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
# Authentik is installed by Flux (HelmRelease apps/03-idp).
# This script only creates the Tailscale API gateway needed to expose idp.<ts_suffix>.

install_idp_api_gateway
