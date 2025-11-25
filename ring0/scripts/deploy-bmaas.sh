#! /usr/bin/env bash

set -e

BUFFER=$(mktemp -d)
RING0_ROOT="$(find $PWD -type d -name ring0)"

################################################################################
# External libraries
source $RING0_ROOT/scripts/common.sh
source $RING0_ROOT/scripts/management/install-bmaas.sh

print_milestone "Deploying the BMaaS"

################################################################################
# Testing variables
print_check "Checking variables"

if [[ -z "$BMAAS_NAMESPACE" ]]; then
	echo "BMAAS_NAMESPACE must be defined"
	return 1
fi
if [[ -z "$INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR" ]]; then
	echo "INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR must be defined"
	return 1
fi

################################################################################
# Starting the tasks

if ! is_hook_synced; then
	build_hook
	copy_hook_to_bootstrap
fi

create_announcement_configuration
install_registry_api_gateway

if ! helm list -n $BMAAS_NAMESPACE | awk '{print $1}' | grep -qw zot; then
	install_zot
	populate_zot
else
	print_check "Zot is already installed"
fi

if ! helm list -n $BMAAS_NAMESPACE | awk '{print $1}' | grep -qw tinkerbell; then
	install_tinkerbell
else
	print_check "Tinkerbell is already installed"
fi

if ! helm list -n $BMAAS_NAMESPACE | awk '{print $1}' | grep -qw coredns; then
	install_coredns
else
	print_check "CoreDNS is already installed"
fi

install_kamaji

install_cluster_api

rm -rf $BUFFER
