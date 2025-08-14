#! /usr/bin/env bash

set -e

################################################################################
# External libraries
RING0_ROOT="$(find $PWD -type d -name ring0)"

source $RING0_ROOT/scripts/common.sh
source $RING0_ROOT/scripts/management/install-platform-management.sh

################################################################################
# Starting the tasks

if ! helm list -n platform-management | grep authentik | grep -q deployed; then
	install_authentik
else
	print_check "Authentik has already been deployed. Nothing to do."
fi
