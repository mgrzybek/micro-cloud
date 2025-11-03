#! /usr/bin/env bash

if [[ -z "$BMAAS_NAMESPACE" ]]; then
	echo "BMAAS_NAMESPACE must be defined"
	exit 1
fi

if [[ -z "$TS_SUFFIX" ]]; then
	echo "TS_SUFFIX must be defined"
	exit 1
fi

if [[ -z "$TS_AUTHKEY" ]]; then
	echo "TS_AUTHKEY must be defined"
	exit 1
fi

if [[ -z "$TS_OPERATOR_CLIENT_ID" ]]; then
	echo "Missing TS_OPERATOR_CLIENT_ID env variable"
	return 1
fi

if [[ -z "$TS_OPERATOR_CLIENT_SECRET" ]]; then
	echo "Missing TS_OPERATOR_CLIENT_SECRET env variable"
	return 1
fi

if [[ -z "$BRIDGE_BOOTSTRAP_NAME" ]]; then
	echo "BRIDGE_BOOTSTRAP_NAME must be defined".
	exit 1
fi

if [[ -z "$BRIDGE_SERVICES_NAME" ]]; then
	echo "BRIDGE_SERVICES_NAME must be defined".
	exit 1
fi

if [[ -z "$PHYS_IFACE" ]]; then
	echo "PHYS_IFACE must be given"
	exit 1
fi

if [[ -z "$INSTANCE_BOOTSTRAP_IPADDR_CIDR" ]]; then
	echo "INSTANCE_BOOTSTRAP_IPADDR_CIDR must be given"
	exit 1
fi

if [[ -z "$INSTANCE_SERVICES_IPADDR_CIDR" ]]; then
	echo "INSTANCE_SERVICES_IPADDR_CIDR must be given"
	exit 1
fi

if [[ -z "$TALOS_FACTORY_URL" ]]; then
	echo "TALOS_FACTORY_URL must be given"
	exit 1
fi

if [[ -z "$TALOS_FACTORY_UUID" ]]; then
	echo "TALOS_FACTORY_UUID must be given"
	exit 1
fi

if [[ -z "$TALOS_VERSION" ]]; then
	echo "TALOS_VERSION must be given"
	exit 1
fi

function prepare() {
	if [[ "$(uname)" == "Darwin" ]]; then
		export SED=gsed
	else
		export SED=sed
	fi
	export TARGET_HOME=$(ssh $TARGET pwd)

	export INSTANCE_BOOTSTRAP_IPADDR=$(echo $INSTANCE_BOOTSTRAP_IPADDR_CIDR | awk -F/ '{print $1}')

	helm repo add jetstack https://charts.jetstack.io
	helm repo add cnpg https://cloudnative-pg.github.io/charts
	helm repo add authentik https://charts.goauthentik.io
	helm repo add clastix https://clastix.github.io/charts
	helm repo update
}

function install_ipxe() {
	print_milestone "Getting IPXE ISO image"

	local URL=https://boot.ipxe.org/ipxe.iso

	if ! incus storage volume list default | grep -q ipxe; then
		ssh $TARGET "curl -o /var/lib/iso/ipxe.iso $URL"
	fi

	print_check "Checking files"
	ssh $TARGET "find /var/lib/iso -type f"
}

function deploy_instance() {
	print_milestone "Deploying the machine"

	if [[ ! -f "$TALOS_YAML_CONFIG" ]]; then
		echo "The cloud-init config file $TALOS_YAML_CONFIG does not exist"
		return 1
	fi

	configure_bridge $BRIDGE_SERVICES_NAME $PHYS_IFACE $BRIDGE_SERVICES_VLAN

	if ! incus list "$NAME" -f yaml | grep -q name:; then
		incus init "$NAME" --empty --vm \
			-c limits.cpu=3 -c limits.memory=8GiB \
			-d root,size=50GiB

		# IPXE ISO
		incus config device add "$NAME" ipxe disk source=/var/lib/iso/ipxe.iso boot.priority=10

		# Add a data disk
		if ! incus storage volume info default "$DATA_DISK"; then
			incus storage volume create "$POOL" "$DATA_DISK" --type=block size=50GiB
		fi
		incus config device add "$NAME" "$DATA_DISK" disk pool="$POOL" source="$DATA_DISK"

		# Secure boot disabled
		incus config set "$NAME" security.secureboot=false

		# Bootstrap VLAN
		incus config device add "$NAME" eth1 nic network="$BRIDGE_BOOTSTRAP_NAME"

		# Management services VLAN
		incus config device add "$NAME" eth2 nic network="$BRIDGE_SERVICES_NAME"

		incus start "$NAME"
	fi

	print_check "Checking instance"
	incus info "$NAME" | yq
}

function create_talos_config() {
	print_milestone "Creating the cloud-init userdata (controlplane.yaml)"

	local instance_bootstrap_ipaddr="$(echo $INSTANCE_BOOTSTRAP_IPADDR_CIDR | awk -F/ '{print $1}')"
	local instance_services_ipaddr="$(echo $INSTANCE_SERVICES_IPADDR_CIDR | awk -F/ '{print $1}')"

	jinja2 --strict \
		-D bootstrap_ipaddr="$instance_bootstrap_ipaddr" \
		-D services_ipaddr="$instance_services_ipaddr" \
		-D bootstrap_cidr="$INSTANCE_BOOTSTRAP_IPADDR_CIDR" \
		-D services_cidr="$INSTANCE_SERVICES_IPADDR_CIDR" \
		-D bmaas_namespace="$BMAAS_NAMESPACE" \
		-D ts_suffix="$TS_SUFFIX" \
		$RING0_ROOT/core-services/management/talos/patch.yaml.j2 \
		-o $RING0_ROOT/dist/cp-patch.yaml

	if [[ ! -f $RING0_ROOT/dist/controlplane.yaml ]]; then
		talosctl gen config "$NAME" "https://$INSTANCE_BOOTSTRAP_IPADDR:6443" \
			--config-patch @$RING0_ROOT/dist/patch.yaml \
			--config-patch-control-plane @$RING0_ROOT/dist/cp-patch.yaml \
			--install-image "$INSTALL_IMAGE" \
			-o $RING0_ROOT/dist
	else
		echo "$RING0_ROOT/dist/controlplane.yaml already exists"
	fi

	ssh $TARGET mkdir -p $TARGET_HOME/dist
	scp $RING0_ROOT/dist/talosconfig $TARGET:$TARGET_HOME/dist

	incus file push $RING0_ROOT/dist/controlplane.yaml bootstrap/var/lib/matchbox/assets/talos/management.yaml
}

function create_patch() {
	print_milestone "Creating the patch (CA, LLDP, UserVolume)"

	local CA=$RING0_ROOT/dist/bundle.crt

	if [[ ! -f "$CA" ]]; then
		echo "Cannot find the CA file $CA"
		return 1
	fi

	cat <<EOF >$RING0_ROOT/dist/patch.yaml
apiVersion: v1alpha1
kind: TrustedRootsConfig
name: microdc-ca
certificates: |-
EOF
	awk '{print "    "$0}' "$CA" >>dist/patch.yaml

	cat <<EOF >>dist/patch.yaml
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - TS_AUTHKEY=$TS_AUTHKEY
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: lldpd
configFiles:
  - content: |
      configure lldp portidsubtype ifname
      unconfigure lldp management-addresses-advertisements
      unconfigure lldp capabilities-advertisements
      configure system description "Management Node"
    mountPath: /usr/local/etc/lldpd/lldpd.conf
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: local-path-provisioner
provisioning:
  diskSelector:
    match: "!system_disk"
  minSize: 40GB
  maxSize: 60GB
EOF

	print_check "Checking YAML"
	cat $RING0_ROOT/dist/patch.yaml
}

function create_profile() {
	print_milestone "Creating the profile file for talos installer"

	incus file push $RING0_ROOT/core-services/bootstrap/matchbox/profiles/talos.json \
		bootstrap/var/lib/matchbox/profiles/talos.json

	print_check "Checking talos.json"
	echo "test -f /var/lib/matchbox/profiles/talos.json" | incus exec bootstrap -- bash
	incus exec bootstrap -- cat /var/lib/matchbox/profiles/talos.json
}

function create_group() {
	print_milestone "Creating the group file"

	incus file push $RING0_ROOT/core-services/bootstrap/matchbox/groups/talos-$NAME.json \
		bootstrap/var/lib/matchbox/groups/talos-$NAME.json

	print_check "Checking JSON"
	echo "test -f /var/lib/matchbox/groups/talos-$NAME.json" | incus exec bootstrap -- bash
	incus exec bootstrap -- cat /var/lib/matchbox/groups/talos-$NAME.json
}

function bootstrap_kubernetes() {
	print_milestone "Bootstrapping kubernetes"

	local MANAGEMENT_IPADDR=$(incus list | awk '/management/ {print $6}' | fgrep ".")

	while [[ -z "$MANAGEMENT_IPADDR" ]]; do
		echo "Talos address is not set yet. Waiting..."
		sleep 30
		MANAGEMENT_IPADDR=$(incus list | awk '/management/ {print $6}' | fgrep ".")
	done

	print_check "Talos internal address is: $MANAGEMENT_IPADDR"

	while ! tailscale status | grep -qw management; do
		echo "Talos address on Tailscale is not set yet. Waiting..."
		sleep 30
	done
	tailscale ping management

	local talos_opts="-n management -e management --talosconfig=$RING0_ROOT/dist/talosconfig"

	while ! talosctl $talos_opts get disks; do
		echo "👷 Node not available yet. Waiting..."
		sleep 30
	done

	print_step "Bootstrapping..."
	if talosctl $talos_opts bootstrap | grep -i already; then
		print_check "Bootstrap already done"
		talosctl $talos_opts etcd status
		echo "etcd status: $(talosctl $talos_opts etcd status | awk '!/NODE/ {if ($2 != $8) {print "learner"} else {print "leader"}}')"
	fi

	if ! kubectl cluster-info; then
		rm -f ~/.kube/config

		print_milestone "Getting kubeconfig..."
		while ! talosctl $talos_opts kubeconfig - --merge=false; do
			echo "👷 Node not available yet. Waiting..."
			sleep 30
		done
	fi

	print_check "Checking Tailscale connectivity"
	while ! tailscale ping $NAME | grep pong; do
		sleep 30
	done

	kubeapi_tailscale_ipaddr=$(tailscale status | grep -w linux | grep -w $NAME | awk '{print $1}')
	tailscale_suffix=$(tailscale dns status | awk '/suffix =/ {gsub(")","");print $NF}')

	print_step "Getting the kubeconfig and using the tailnet IP address"
	talosctl $talos_opts kubeconfig
	$SED -i "s,$INSTANCE_BOOTSTRAP_IPADDR,management.$tailscale_suffix," ~/.kube/config

	print_step "Waiting for the API to respond..."
	while ! kubectl cluster-info 2>&1 >/dev/null; do
		echo -n .
		sleep 10
	done

	print_check "Cluster available"
	kubectl cluster-info
}
