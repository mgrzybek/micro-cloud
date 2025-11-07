#! /usr/bin/env bash

RING0_ROOT="$(find $PWD -type d -name ring0)"

################################################################################
# External libraries
source $RING0_ROOT/scripts/common.sh

print_milestone "Deploying a testing VM to netboot"

BRIDGE_SERVICES_NAME=services0

if [[ -z "$BRIDGE_SERVICES_NAME" ]]; then
	echo "BRIDGE_SERVICES_NAME must be defined".
	exit 1
fi

function create_tinkerbell_machine() {
	kubectl apply -f $MANIFESTS_PATH/05-tinkerbell/testing-machine.yaml
}

function delete_tinkerbell_machine() {
	kubectl delete -f $MANIFESTS_PATH/05-tinkerbell/testing-machine.yaml
}

function deploy_instance() {
	NAME="$1"

	if ! incus list "$NAME" -f yaml | grep -qw name:; then
		print_milestone "Creating the VM"

		incus init "$NAME" --empty --vm --no-profiles \
			-c limits.cpu=1 -c limits.memory=2GiB \
			-d root,size=5GiB

		# IPXE ISO
		incus config device add "$NAME" ipxe disk source=/var/lib/iso/ipxe.iso boot.priority=10

		# Secure boot disabled
		incus config set "$NAME" security.secureboot=false

		# Management services VLAN
		incus config device add "$NAME" eth0 nic network="$BRIDGE_SERVICES_NAME" hwaddr="10:66:6a:07:8d:0d"

		incus start "$NAME" --console
		incus delete "$NAME" --force
	else
		print_check "The VM already exists"
		incus console "$NAME"
		incus delete "$NAME" --force
		print_check "The VM has been deleted"
	fi
}

create_tinkerbell_machine
deploy_instance testing
delete_tinkerbell_machine
