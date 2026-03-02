#! /usr/bin/env bash

set -euo pipefail

function print_milestone() {
	echo
	echo "##########################################"
	echo "👷 $1"
	echo
}

function print_step() {
	echo
	echo "👷 $1"
	echo
}

function print_check() {
	echo
	echo "✔ $1"
}

function configure_bridge() {
	if [[ $# -ne 3 ]]; then
		echo "Usage: configure_bridge NAME IFACE VLAN" >&2
		return 1
	fi

	local NAME=$1
	local IFACE=$2
	local VLAN=$3

	if ! incus network list | grep -qw "$NAME"; then
		incus network create "$NAME" --type=bridge \
			"bridge.external_interfaces=$IFACE.$VLAN/$IFACE/$VLAN" \
			ipv4.address=none \
			ipv6.address=none
	fi
}

if [[ -z "${RING0_ROOT:-}" ]]; then
	RING0_ROOT="$(find "$PWD" -type d -name ring0 | head -n1)"
	export RING0_ROOT
fi
export MANIFESTS_PATH="$RING0_ROOT/core-services/management/manifests"

TS_SUFFIX="$(tailscale dns status | awk '/suffix =/ {gsub(")","");print $NF}')"
export TS_SUFFIX

PKI_IPADDR="$(incus list | awk '/pki/ {print $6}')"
export PKI_IPADDR
export PKI_ENDPOINT="https://$PKI_IPADDR:8000"

BOOTSTRAP_IPADDR="$(incus list | awk '/bootstrap/ {print $6}')"
export BOOTSTRAP_IPADDR
export BOOTSTRAP_ENDPOINT="http://$BOOTSTRAP_IPADDR:8080"
