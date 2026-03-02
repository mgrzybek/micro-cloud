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

install_cmdb_api_gateway

if ! kubectl get secret -n platform-management cmdb-netbox-remote-auth >/dev/null 2>&1; then
	create_remote_netbox_auth_secret
fi

if ! helm list -n platform-management -o json | jq -e '.[] | select(.name=="cmdb" and .status=="deployed")' >/dev/null 2>&1; then
	install_netbox
else
	print_check "Netbox has already been deployed. Nothing to do."
fi
