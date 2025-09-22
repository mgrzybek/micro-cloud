#! /usr/bin/env bash

set -e

BUFFER=$(mktemp -d)
INSTANCE=bootstrap
RING0_ROOT="$(find $PWD -type d -name ring0)"
PKI_ROOT=/var/lib/pki/files

################################################################################
# External libraries
source $RING0_ROOT/scripts/common.sh

################################################################################
# Testing variables
print_check "Checking variables"

if [[ -z "$BRIDGE_BOOTSTRAP_NAME" ]]; then
	echo "BRIDGE_BOOTSTRAP_NAME must be defined".
	exit 1
else
	if ! incus network show $BRIDGE_BOOTSTRAP_NAME; then
		echo "$BRIDGE_BOOTSTRAP_NAME not found. Please choose an existing bridge."
		incus network list
		exit 1
	fi
fi

if [[ -z "$BRIDGE_BOOTSTRAP_VLAN" ]]; then
	echo "BRIDGE_BOOTSTRAP_VLAN must be defined".
	exit 1
fi

if [[ -z "$PHYS_IFACE" ]]; then
	echo "PHYS_IFACE must be defined".
	exit 1
else
	if ! incus network show $BRIDGE_BOOTSTRAP_NAME; then
		echo "$BRIDGE_BOOTSTRAP_NAME not found. Please choose an existing interface."
		incus network list
		exit 1
	fi
fi

if [[ -z "$IFACE_BOOTSTRAP_IPADDR_CIDR" ]]; then
	echo "IFACE_BOOTSTRAP_IPADDR_CIDR must be defined"
	exit 1
fi

if [[ -z "$TALOS_FACTORY_UUID" ]]; then
	echo "TALOS_FACTOR_UUID must be defined"
	exit 1
fi

if [[ -z "$TALOS_VERSION" ]]; then
	echo "TALOS_VERSION must be defined"
	exit 1
fi

if [[ -z "$TALOS_FACTORY_URL" ]]; then
	echo "$TALOS_FACTORY_URL must be defined"
	exit 1
fi

if [[ -z "$PKI_COUNTRY" ]]; then
	echo "PKI_COUNTRY must be defined"
	exit 1
fi

if [[ -z "$PKI_LOCATION" ]]; then
	echo "PKI_LOCATION must be defined"
	exit 1
fi

if [[ -z "$PKI_ORG" ]]; then
	echo "PKI_ORG must be defined"
	exit 1
fi

if [[ -z "$PKI_ORG_UNIT" ]]; then
	echo "PKI_ORG_UNIT must be defined"
	exit 1
fi

if [[ -z "$PKI_STATE" ]]; then
	echo "PKI_STATE must be defined"
	exit 1
fi

################################################################################
# Functions
function main() {
	prepare
	push_csr
	create_certificates
	pull_certificates
	push_certificates

	configure_instance
}

function prepare() {
	export TLD=$(tailscale dns status | awk '/MagicDNS:/ {gsub(")","") ; print $NF}')
	if [[ -z "$TLD" ]]; then
		echo "Error getting Tailscale's TLD"
		exit 1
	fi

	cat <<EOF | tee dist/$INSTANCE.sh
SERVER_ADDR=$SERVER_ADDR
SERVER_CIDR=$IFACE_BOOTSTRAP_IPADDR_CIDR
NTP_ADDR=$SERVER_ADDR
LOG_ADDR=$SERVER_ADDR

TALOS_FACTORY_UUID=$TALOS_FACTORY_UUID
TALOS_VERSION=$TALOS_VERSION
TALOS_FACTORY_URL=$TALOS_FACTORY_URL
EOF

	export SERVER_ADDR=$(echo "$IFACE_BOOTSTRAP_IPADDR_CIDR" | awk -F/ '{print $1}')
}

function create_instance() {
	# documentation: https://technicallyrambling.calmatlas.com/create-vlan-aware-incus-bridge-for-dhcp-passthrough/
	print_milestone "Creating networking"

	configure_bridge $BRIDGE_BOOTSTRAP_NAME $PHYS_IFACE $BRIDGE_BOOTSTRAP_VLAN

	print_milestone "Deploying on $INSTANCE instance"

	if ! incus list $NAME -f yaml | grep -q name:; then
		incus create -v images:debian/12 "$NAME"
		incus config device add "$INSTANCE" eth1 nic network="$BRIDGE_BOOTSTRAP_NAME"
		incus start "$INSTANCE"
		incus exec $INSTANCE -- "ip addr add dev eth1 $IFACE_BOOTSTRAP_IPADDR_CIDR"
	fi
}

function configure_instance() {
	incus file push dist/$INSTANCE.sh bootstrap/etc/cloud.sh
	incus exec $INSTANCE -- bash <core-services/bootstrap/debian-$INSTANCE-cloud-init.sh
}

function push_csr() {
	local CSR="$INSTANCE.$TLD-csr.json"

	cat <<EOF >"$BUFFER/$CSR"
{
  "CN": "$INSTANCE.$TLD",
  "hosts": [
    "$INSTANCE",
    "matchbox",
    "$SERVER_ADDR"
  ],
  "names": [
    {
      "C": "$PKI_COUNTRY",
      "L": "$PKI_LOCATION",
      "O": "$PKI_ORG",
      "OU": "$PKI_ORG_UNIT",
      "ST": "$PKI_STATE"
    }
  ]
}
EOF

	incus file push "$BUFFER/$CSR" "pki/$PKI_ROOT/certificates/$CSR"
}

function create_certificates() {
	print_milestone "Creating certificates"

	echo "$PKI_ROOT/../create-certificates.sh" | incus exec pki -- bash
}

function pull_certificates() {
	print_milestone "Pulling files"

	incus file pull pki/$PKI_ROOT/certificates/$INSTANCE.$TLD.pem $BUFFER/
	incus file pull pki/$PKI_ROOT/certificates/$INSTANCE.$TLD-key.pem $BUFFER/
}

function push_certificates() {
	print_milestone "Pushing files"

	echo "mkdir -p /etc/matchbox/ssl" | incus exec bootstrap -- bash
	incus file push $BUFFER/$INSTANCE.$TLD.pem bootstrap/etc/matchbox/ssl/server.crt
	incus file push $BUFFER/$INSTANCE.$TLD-key.pem bootstrap/etc/matchbox/ssl/server.key

	rm -rf $BUFFER

	print_check "Checking files"
	echo "find /etc/matchbox/ssl" | incus exec bootstrap -- bash
}

main "$@"
