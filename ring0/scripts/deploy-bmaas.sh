#! /usr/bin/env bash

set -euo pipefail

BUFFER="$(mktemp -d)"
RING0_ROOT="$(find "$PWD" -type d -name ring0 | head -n1)"

cleanup() { rm -rf "${BUFFER}"; }
trap cleanup EXIT

################################################################################
# External libraries
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/management/install-bmaas.sh"

print_milestone "Deploying the BMaaS"

################################################################################
# Testing variables
print_check "Checking variables"

if [[ -z "${BMAAS_NAMESPACE:-}" ]]; then
	echo "BMAAS_NAMESPACE must be defined"
	return 1
fi
if [[ -z "${INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR:-}" ]]; then
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

if ! helm list -n "$BMAAS_NAMESPACE" -o json | jq -e '.[] | select(.name=="zot")' >/dev/null 2>&1; then
	install_zot
	populate_zot
else
	print_check "Zot is already installed"
fi

if ! helm list -n "$BMAAS_NAMESPACE" -o json | jq -e '.[] | select(.name=="tinkerbell")' >/dev/null 2>&1; then
	install_tinkerbell
else
	print_check "Tinkerbell is already installed"
fi

if ! kubectl get deployment --namespace "$BMAAS_NAMESPACE" coredns >/dev/null 2>&1; then
	install_coredns
else
	print_check "CoreDNS is already installed"
fi

install_kamaji

install_cluster_api
