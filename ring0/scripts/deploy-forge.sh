#! /usr/bin/env bash

set -euo pipefail

INSTANCE=forge

RING0_ROOT="$(find "$PWD" -type d -name ring0 | head -n1)"

################################################################################
# External libraries
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"

################################################################################
# Functions
function main() {
	create_instance
}

function create_instance() {
	print_milestone "Deploying the forge"

	if ! incus list -f json | jq -e --arg name "$INSTANCE" '.[] | select(.name==$name)' >/dev/null 2>&1; then
		incus create images:debian/12 "$INSTANCE"
		incus config set "$INSTANCE" \
			security.nesting=true \
			security.syscalls.intercept.mknod=true \
			security.syscalls.intercept.setxattr=true
		incus start "$INSTANCE"
	fi

	incus exec "$INSTANCE" -- bash <"$RING0_ROOT/core-services/$INSTANCE/debian-$INSTANCE-cloud-init.sh"

	print_check "The forge instance is ready"
}

main "$@"
