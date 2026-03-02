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

install_idp_api_gateway

if ! helm list -n platform-management -o json | jq -e '.[] | select(.name=="idp" and .status=="deployed")' >/dev/null 2>&1; then
	install_authentik
else
	print_check "Authentik has already been deployed. Nothing to do."
fi
