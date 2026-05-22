#! /usr/bin/env bash

set -euo pipefail

# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"

if [[ -z "${WORKER_HOSTNAME:-}" ]]; then
	echo "WORKER_HOSTNAME must be defined"
	exit 1
fi

if [[ -z "${WORKER_MAC:-}" ]]; then
	echo "WORKER_MAC must be defined"
	exit 1
fi

if [[ -z "${RING0_ROOT:-}" ]]; then
	echo "RING0_ROOT must be defined"
	exit 1
fi

if [[ -z "${GITOPS_ROOT:-}" ]]; then
	echo "GITOPS_ROOT must be defined"
	exit 1
fi

if [[ -z "${BOOTSTRAP_IPADDR:-}" ]]; then
	echo "BOOTSTRAP_IPADDR must be defined"
	exit 1
fi

if [[ -z "${TALOS_FACTORY_URL:-}" ]]; then
	echo "TALOS_FACTORY_URL must be defined"
	exit 1
fi

if [[ -z "${WORKER_TALOS_FACTORY_UUID:-}" ]]; then
	echo "WORKER_TALOS_FACTORY_UUID must be defined"
	exit 1
fi

# Resolve the management node's Tailscale IP at runtime so the worker can reach
# the API server before Tailscale DNS is operational on first boot.
MGMT_TS_IP="$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="management") | .TailscaleIPs[0]')"
export MGMT_TS_IP

if [[ -z "$MGMT_TS_IP" ]]; then
	echo "Could not resolve management node Tailscale IP — is tailscale connected?"
	exit 1
fi

WORKER_CONFIG="$RING0_ROOT/dist/$WORKER_HOSTNAME.yaml"
WORKER_PATCH="$RING0_ROOT/dist/worker-$WORKER_HOSTNAME-patch.yaml"
WORKER_PROFILE_FILE="$RING0_ROOT/dist/talos-profile-$WORKER_HOSTNAME.json"
WORKER_GROUP_FILE="$RING0_ROOT/dist/talos-$WORKER_HOSTNAME.json"

TALOS_ASSETS_TMPDIR=""

function cleanup() {
	[[ -n "$TALOS_ASSETS_TMPDIR" ]] && rm -rf "$TALOS_ASSETS_TMPDIR"
}

trap cleanup EXIT

function fetch_talos_version() {
	print_milestone "Fetching Talos version from management node"

	local version_output
	version_output="$(talosctl --talosconfig "$RING0_ROOT/dist/talosconfig" version --short 2>/dev/null)" || true
	TALOS_VERSION="$(awk '/Talos/{print $2; exit}' <<<"$version_output")"
	export TALOS_VERSION

	if [[ -z "$TALOS_VERSION" ]]; then
		echo "Failed to determine Talos version from management node"
		exit 1
	fi

	print_check "Talos version: $TALOS_VERSION"
}

function fetch_talos_assets() {
	print_milestone "Downloading Talos $TALOS_VERSION PXE assets"

	local base_url="$TALOS_FACTORY_URL/image/$WORKER_TALOS_FACTORY_UUID/$TALOS_VERSION"

	incus exec bootstrap -- mkdir -p "/var/lib/matchbox/assets/talos/$WORKER_TALOS_FACTORY_UUID"

	if ! incus exec bootstrap -- test -f "/var/lib/matchbox/assets/talos/$WORKER_TALOS_FACTORY_UUID/kernel-amd64"; then
		incus exec bootstrap -- curl -fsSL -o "/var/lib/matchbox/assets/talos/$WORKER_TALOS_FACTORY_UUID/kernel-amd64" "$base_url/kernel-amd64"
	fi
	if ! incus exec bootstrap -- test -f "/var/lib/matchbox/assets/talos/$WORKER_TALOS_FACTORY_UUID/initramfs-amd64.xz"; then
		incus exec bootstrap -- curl -fsSL -o "/var/lib/matchbox/assets/talos/$WORKER_TALOS_FACTORY_UUID/initramfs-amd64.xz" "$base_url/initramfs-amd64.xz"
	fi

	print_check "PXE assets available in matchbox (kernel-amd64, initramfs-amd64.xz)"
}

function create_worker_patch() {
	print_milestone "Rendering worker patch for $WORKER_HOSTNAME"

	local per_machine_patch="$GITOPS_ROOT/ring0/workers/$WORKER_HOSTNAME/patch.yaml"
	if [[ ! -f "$per_machine_patch" ]]; then
		echo "Per-machine patch not found: $per_machine_patch"
		exit 1
	fi

	INSTALL_IMAGE="$TALOS_FACTORY_URL/installer/$WORKER_TALOS_FACTORY_UUID:$TALOS_VERSION"
	export INSTALL_IMAGE
	export MGMT_TS_IP

	envsubst <"$per_machine_patch" >"$WORKER_PATCH"

	print_check "Patch rendered: $WORKER_PATCH"
	cat "$WORKER_PATCH"
}

function create_worker_config() {
	print_milestone "Generating Talos machine config for $WORKER_HOSTNAME"

	if [[ ! -f "$RING0_ROOT/dist/worker.yaml" ]]; then
		echo "dist/worker.yaml not found — run task management first to generate cluster configs"
		exit 1
	fi

	local worker_base="$RING0_ROOT/dist/worker.yaml"
	if grep -q "kind: HostnameConfig" "$worker_base"; then
		local worker_base_tmp
		worker_base_tmp="$(mktemp)"
		yq 'select(.kind != "HostnameConfig")' "$worker_base" >"$worker_base_tmp"
		worker_base="$worker_base_tmp"
	fi

	talosctl machineconfig patch "$worker_base" \
		--patch "@$WORKER_PATCH" \
		--output "$WORKER_CONFIG"

	talosctl validate --config "$WORKER_CONFIG" --mode metal

	print_check "Machine config generated: $WORKER_CONFIG"
}

function push_matchbox_config() {
	print_milestone "Pushing Talos config to Matchbox assets"

	incus file push "$WORKER_CONFIG" \
		"bootstrap/var/lib/matchbox/assets/talos/$WORKER_HOSTNAME.yaml"

	print_check "Config available at http://<bootstrap>:8080/assets/talos/$WORKER_HOSTNAME.yaml"
}

function create_worker_profile() {
	print_milestone "Creating Matchbox profile for $WORKER_HOSTNAME"

	cat <<EOF >"$WORKER_PROFILE_FILE"
{
  "id": "talos-$WORKER_HOSTNAME",
  "name": "Talos Linux - $WORKER_HOSTNAME",
  "boot": {
    "kernel": "/assets/talos/kernel-amd64",
    "initrd": [
      "/assets/talos/initramfs-amd64.xz"
    ],
    "args": [
      "talos.platform=metal",
      "talos.config=http://$BOOTSTRAP_IPADDR:8080/assets/talos/$WORKER_HOSTNAME.yaml",
      "console=tty0",
      "console=ttyS0",
      "init_on_alloc=1",
      "slab_nomerge",
      "pti=on",
      "consoleblank=0",
      "nvme_core.io_timeout=4294967295",
      "printk.devkmsg=on",
      "ima_template=ima-ng",
      "ima_appraise=fix",
      "ima_hash=sha512",
      "selinux=1"
    ]
  },
  "ignition_id": ""
}
EOF

	incus file push "$WORKER_PROFILE_FILE" \
		"bootstrap/var/lib/matchbox/profiles/talos-$WORKER_HOSTNAME.json"

	print_check "Profile pushed: talos-$WORKER_HOSTNAME"
}

function push_matchbox_group() {
	print_milestone "Creating Matchbox group for $WORKER_HOSTNAME (MAC: $WORKER_MAC)"

	cat <<EOF >"$WORKER_GROUP_FILE"
{
  "id": "talos-$WORKER_HOSTNAME",
  "name": "$WORKER_HOSTNAME worker node",
  "profile": "talos-$WORKER_HOSTNAME",
  "selector": {
    "mac": "$WORKER_MAC"
  },
  "metadata": {}
}
EOF

	incus file push "$WORKER_GROUP_FILE" \
		"bootstrap/var/lib/matchbox/groups/talos-$WORKER_HOSTNAME.json"

	print_check "Group file pushed"
	incus exec bootstrap -- cat "/var/lib/matchbox/groups/talos-$WORKER_HOSTNAME.json"
}

function wait_for_node() {
	print_milestone "Waiting for $WORKER_HOSTNAME to join the cluster"

	echo "Power on the physical node now and wait for PXE boot..."
	until kubectl get node "$WORKER_HOSTNAME" >/dev/null 2>&1; do
		sleep 10
	done

	kubectl wait node/"$WORKER_HOSTNAME" \
		--for=condition=Ready \
		--timeout=30m

	print_check "Node $WORKER_HOSTNAME is Ready"
	kubectl get node "$WORKER_HOSTNAME" -o wide
}

mkdir -p "$RING0_ROOT/dist"

fetch_talos_version
fetch_talos_assets
create_worker_patch
create_worker_config
push_matchbox_config
create_worker_profile
push_matchbox_group
wait_for_node
