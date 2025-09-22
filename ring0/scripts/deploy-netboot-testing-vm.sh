#! /usr/bin/env bash

BRIDGE_SERVICES_NAME=services0

if [[ -z "$BRIDGE_SERVICES_NAME" ]]; then
	echo "BRIDGE_SERVICES_NAME must be defined".
	exit 1
fi

function deploy_instance() {
	NAME="$1"

	if ! incus list "$NAME" -f yaml | grep -q name:; then
		incus init "$NAME" --empty --vm \
			-c limits.cpu=1 -c limits.memory=2GiB
		#-d root,size=5GiB

		# IPXE ISO
		incus config device add "$NAME" ipxe disk source=/var/lib/iso/ipxe.iso boot.priority=10

		# Secure boot disabled
		incus config set "$NAME" security.secureboot=false

		# Management services VLAN
		incus config device add "$NAME" eth1 nic network="$BRIDGE_SERVICES_NAME"

		incus start "$NAME" --console
		incus delete "$NAME" --force
	fi
}

deploy_instance testing
