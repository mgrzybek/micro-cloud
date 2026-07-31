#! /usr/bin/env bash

set -euo pipefail

RING0_ROOT="$(find "$PWD" -type d -name ring0 | head -n1)"
export RING0_ROOT

################################################################################
# External libraries
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"

################################################################################
# Testing variables
if [[ -z "${TALOS_FACTORY_UUID:-}" ]]; then
	echo "TALOS_FACTORY_UUID must be defined" >&2
	exit 1
fi

if [[ -z "${TALOS_VERSION:-}" ]]; then
	echo "TALOS_VERSION must be defined" >&2
	exit 1
fi

if [[ -z "${TALOS_FACTORY_URL:-}" ]]; then
	echo "TALOS_FACTORY_URL must be defined" >&2
	exit 1
fi

function upgrade() {
	local machine=$1

	print_step "Current version of $machine"
	talosctl --talosconfig="$RING0_ROOT/dist/talosconfig" -e "$machine" -n "$machine" version

	print_step "Upgrading…"
	talosctl --talosconfig="$RING0_ROOT/dist/talosconfig" -e "$machine" -n "$machine" upgrade \
		--drain=false \
		--reboot-mode powercycle \
		--image "$TALOS_FACTORY_URL/metal-installer/$TALOS_FACTORY_UUID:$TALOS_VERSION"

	print_step "Version after upgrade"
	talosctl --talosconfig="$RING0_ROOT/dist/talosconfig" -e "$machine" -n "$machine" version
}

print_milestone "Upgrading the management node to Talos $TALOS_VERSION"

for cp in $(kubectl get nodes | grep control-plane | awk '{print $1}'); do
	upgrade "$cp"
done

for worker in $(kubectl get nodes | grep none | awk '{print $1}'); do
	upgrade "$worker"
done
