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
# Zot, Tinkerbell, and Kamaji are installed by Flux (HelmReleases in apps/05-bmaas/).
# This script handles the steps that remain outside Flux:
#   - Build and sync HookOS artifacts to the bootstrap server
#   - Populate the Zot registry with Tinkerbell action images
#   - Install Cluster API (clusterctl init)

if ! is_hook_synced; then
	build_hook
	copy_hook_to_bootstrap
fi

if ! helm list -n "$BMAAS_NAMESPACE" -o json | jq -e '.[] | select(.name=="zot")' >/dev/null 2>&1; then
	echo "Zot not yet ready — waiting for Flux HelmRelease before populating the registry"
	# Wait on the HelmRelease rather than a pod name, which depends on chart internals.
	kubectl wait helmrelease/zot -n flux-system --for=condition=Ready --timeout=600s
fi
populate_zot

install_cluster_api
