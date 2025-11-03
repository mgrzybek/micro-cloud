#! /usr/bin/env bash

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
	local NAME=$1
	local IFACE=$2
	local VLAN=$3

	if ! incus network list | grep -q $NAME; then
		incus network create "$NAME" --type=bridge \
			bridge.external_interfaces=$IFACE.$VLAN/$IFACE/$VLAN \
			ipv4.address=none \
			ipv6.address=none
	fi
}

if [[ -z "$RING0_ROOT" ]]; then
	export RING0_ROOT=$(find $PWD -type d | grep ring0 | head -n1 | sed 's,ring0.*,ring0,')
fi
export MANIFESTS_PATH=$RING0_ROOT/core-services/management/manifests

export TS_SUFFIX=$(tailscale dns status | awk '/suffix =/ {gsub(")","");print $NF}')

export PKI_IPADDR=$(incus list | awk '/pki/ {print $6}')
export PKI_ENDPOINT=https://$PKI_IPADDR:8000

export BOOTSTRAP_IPADDR=$(incus list | awk '/bootstrap/ {print $6}')
export BOOTSTRAP_ENDPOINT=http://$BOOTSTRAP_IPADDR:8080
