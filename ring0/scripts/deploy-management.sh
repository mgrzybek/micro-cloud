#! /usr/bin/env bash

set -euo pipefail

################################################################################
# External libraries
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/management/bootstrap-instance.sh"
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/management/install-platform-management.sh"

################################################################################
# Local constants — used by functions in bootstrap-instance.sh
# shellcheck disable=SC2034
NAME=management
# shellcheck disable=SC2034
POOL=default
# shellcheck disable=SC2034
DATA_DISK=data
# shellcheck disable=SC2034
TALOS_YAML_CONFIG="$RING0_ROOT/dist/controlplane.yaml"
# shellcheck disable=SC2034
TARGET=headnode-0
# shellcheck disable=SC2034
INSTALL_IMAGE="$TALOS_FACTORY_URL/metal-installer/$TALOS_FACTORY_UUID:$TALOS_VERSION"

################################################################################
# Starting the tasks
print_milestone "Deploying the management cluster using Talos Linux"

prepare

install_ipxe

create_patch
create_talos_config
create_profile
create_group

deploy_instance
bootstrap_kubernetes

desactivate_netboot_on_instance

create_namespaces

if ! helm list -n kube-system -o json | jq -e '.[] | select(.name=="cilium" and .status=="deployed")' >/dev/null 2>&1; then
	install_cilium
fi

if ! helm list -n cert-manager -o json | jq -e '.[] | select(.name=="cert-manager")' >/dev/null 2>&1; then
	install_cert_manager
fi

install_local_path_provisioner

if ! helm list -n cnpg-system -o json | jq -e '.[] | select(.name=="cnpg")' >/dev/null 2>&1; then
	install_cnpg
fi

if ! helm list -n tailscale -o json | jq -e '.[] | select(.name=="tailscale-operator")' >/dev/null 2>&1; then
	install_tailscale
fi

install_database

print_check "Deployment ended successfully"
