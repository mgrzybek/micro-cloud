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

	# `talosctl patch mc` appends to list fields (extraVolumes, machine.files)
	# instead of replacing them, so re-running this task would duplicate the
	# oidc-ca.pem entries and kubelet would then reject the kube-apiserver
	# static pod for having a non-unique volume mount. Instead, fetch the
	# live config and do a full `apply-config` (replace semantics): `yq`'s
	# `*` merge operator deep-merges maps but replaces arrays wholesale, so
	# extraVolumes/files end up with exactly one (updated) entry every time.

	local live="$RING0_ROOT/dist/oidc-live-mc.yaml"
	local live_active="$RING0_ROOT/dist/oidc-live-mc-active.yaml"
	local live_main="$RING0_ROOT/dist/oidc-live-mc-main.yaml"
	local live_rest="$RING0_ROOT/dist/oidc-live-mc-rest.yaml"
	local merged_main="$RING0_ROOT/dist/oidc-mc-merged-main.yaml"
	local merged="$RING0_ROOT/dist/oidc-mc-merged.yaml"

	talosctl --talosconfig "$RING0_ROOT/dist/talosconfig" -n management -e management \
		get mc -o yaml >"$live"

	# `get mc` can return several MachineConfigs resources (e.g. "persistent"
	# and the active "v1alpha1" one) — only the latter reflects what's
	# actually running, so it's the only one safe to patch and re-apply.
	awk '/^    id: v1alpha1$/{active=1} active' "$live" |
		awk '/^spec: \|/{found=1; next} found{ if (substr($0,1,4)=="    ") print substr($0,5); else print $0 }' \
			>"$live_active"

	# The active config is itself a multi-document YAML stream (the main
	# v1alpha1 config plus TrustedRootsConfig/ExtensionServiceConfig/...
	# documents). Only the first document is what we patch — merging across
	# the whole stream would inject "cluster"/"machine" keys into unrelated
	# documents, which Talos then rejects outright.
	awk '/^---$/{exit} {print}' "$live_active" >"$live_main"
	awk 'f{print} /^---$/{f=1}' "$live_active" >"$live_rest"

	yq eval-all 'select(fi == 0) * select(fi == 1)' "$live_main" "$RING0_ROOT/dist/oidc-patch.yaml" \
		>"$merged_main"

	cat "$merged_main" >"$merged"
	if [[ -s "$live_rest" ]]; then
		echo "---" >>"$merged"
		cat "$live_rest" >>"$merged"
	fi

	talosctl --talosconfig "$RING0_ROOT/dist/talosconfig" -n management -e management \
		apply-config -f "$merged"

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
