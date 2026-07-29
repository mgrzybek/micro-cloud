#! /usr/bin/env bash

set -euo pipefail

################################################################################
# External libraries
RING0_ROOT="$(find "$PWD" -type d -name ring0 | head -n1)"

# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"

################################################################################
# Starting the tasks
# Authentik (apps/03-idp) must already be running and an OAuth2/OpenID
# provider + application must already exist for this cluster (created
# manually in the Authentik admin UI, see ring0/README.md).

function render_oidc_patch() {
	print_milestone "Rendering the OIDC patch for the kube-apiserver"

	local CA="$RING0_ROOT/dist/bundle.crt"
	if [[ ! -f "$CA" ]]; then
		echo "Cannot find the CA file $CA"
		return 1
	fi

	jinja2 --strict \
		-D "ts_suffix=$TS_SUFFIX" \
		-D "oidc_slug=$OIDC_SLUG" \
		-D "oidc_client_id=$OIDC_CLIENT_ID" \
		"$RING0_ROOT/core-services/management/talos/oidc-patch.yaml.j2" \
		-o "$RING0_ROOT/dist/oidc-patch.yaml"

	# The kube-apiserver static pod does not mount the host's trust store, so
	# the CA that signs Authentik's certificate must be embedded and mounted
	# explicitly (see oidc-ca-file / extraVolumes / machine.files above).
	awk -v ca_file="$CA" '
		/OIDC_CA_BUNDLE_PLACEHOLDER/ {
			while ((getline line < ca_file) > 0) print "        " line
			next
		}
		{ print }
	' "$RING0_ROOT/dist/oidc-patch.yaml" >"$RING0_ROOT/dist/oidc-patch.yaml.tmp"
	mv "$RING0_ROOT/dist/oidc-patch.yaml.tmp" "$RING0_ROOT/dist/oidc-patch.yaml"

	print_check "dist/oidc-patch.yaml rendered"
}

function apply_oidc_patch() {
	print_milestone "Patching the management cluster's kube-apiserver"

	talosctl --talosconfig "$RING0_ROOT/dist/talosconfig" -n management -e management \
		patch mc --patch-file "$RING0_ROOT/dist/oidc-patch.yaml"

	print_check "kube-apiserver OIDC flags applied"
}

function apply_rbac() {
	print_milestone "Binding OIDC group ${OIDC_GROUP} to ClusterRole ${OIDC_CLUSTER_ROLE}"

	jinja2 --strict \
		-D "oidc_group=$OIDC_GROUP" \
		-D "oidc_cluster_role=$OIDC_CLUSTER_ROLE" \
		"$MANIFESTS_PATH/06-oidc/rbac.yaml.j2" \
		-o "$RING0_ROOT/dist/oidc-rbac.yaml"

	kubectl apply -f "$RING0_ROOT/dist/oidc-rbac.yaml"

	print_check "ClusterRoleBinding applied"
}

render_oidc_patch
apply_oidc_patch
apply_rbac
