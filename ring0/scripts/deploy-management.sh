#! /usr/bin/env bash

set -e

################################################################################
# External libraries
source $RING0_ROOT/scripts/common.sh

################################################################################
# External libraries
source $RING0_ROOT/scripts/common.sh
source $RING0_ROOT/scripts/management/bootstrap-instance.sh
source $RING0_ROOT/scripts/management/install-platform-management.sh

################################################################################
# Local constants
NAME=management
POOL=default
DATA_DISK=data
TALOS_YAML_CONFIG=$RING0_ROOT/dist/controlplane.yaml
TARGET=headnode-0
INSTALL_IMAGE=$TALOS_FACTORY_URL/metal-installer/$TALOS_FACTORY_UUID:$TALOS_VERSION

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

create_namespaces

if ! helm list -n kube-system | grep cilium | grep deployed; then
	install_cilium
fi

if ! helm list -n cert-manager | grep -q cert-manager; then
	install_cert_manager
fi

install_local_path_provisioner

if ! helm list -n cnpg-system | grep -q cnpg; then
	install_cnpg
fi

if ! helm list -n tailscale | grep -q tailscale; then
	install_tailscale
fi

install_database

if ! helm list -n platform-management | grep -q kamaji; then
	install_kamaji
fi

if ! helm list -n platform-management | grep -q authentik; then
	install_idp_api_gateway
fi

if ! helm list -n platform-management | grep -q netbox; then
	install_cmdb_api_gateway
fi

print_check "Deployment ended successfully"
