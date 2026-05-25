#! /usr/bin/env bash

set -euo pipefail

if [[ -z "${BMAAS_NAMESPACE:-}" ]]; then
	echo "BMAAS_NAMESPACE must be defined"
	return 1
fi

if [[ -z "${BUFFER:-}" ]]; then
	echo "BUFFER must be defined"
	return 1
fi

if [[ -z "${INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR:-}" ]]; then
	echo "INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR must be defined"
	return 1
fi

if [[ -z "${PKI_ORG:-}" ]]; then
	echo "PKI_ORG must be defined"
	return 1
fi

if [[ -z "${TS_SUFFIX:-}" ]]; then
	echo "TS_SUFFIX must be defined"
	return 1
fi

if [[ -z "${DNS_IP:-}" ]]; then
	echo "DNS_IP must be defined"
	return 1
fi

if [[ -z "${HOOKOS_IP:-}" ]]; then
	echo "HOOKOS_IP must be defined"
	return 1
fi

if [[ -z "${REGISTRY_IP:-}" ]]; then
	echo "REGISTRY_IP must be defined"
	return 1
fi

if [[ -z "${TINKERBELL_IP:-}" ]]; then
	echo "TINKERBELL_IP must be defined"
	return 1
fi

function build_hook() {
	if ! incus list -f json | jq -e '.[] | select(.name=="forge" and .status=="Running")' >/dev/null; then
		echo "ERROR: forge instance is not running" >&2
		return 1
	fi

	print_milestone "Building tinkerbell hookos"

	cat <<EOF | incus exec -t forge -- bash
    export DOCKER_ARCH=amd64

    cd /root

    if [ ! -d hook ]; then
        git clone https://github.com/tinkerbell/hook.git
        cd hook
    else
        cd hook
        git pull
    fi

    ./build.sh kernel hook-default-amd64
    ./build.sh build hook-default-amd64

    ./build.sh kernel hook-latest-lts-amd64
    ./build.sh build hook-latest-lts-amd64

    cd out
    sha512sum hook_x86_64.tar.gz hook_latest-lts-x86_64.tar.gz > checksum.txt
	exit
EOF

	print_check "Checking artifacts"
	incus exec forge -- find /root/hook/out -type f | grep tar.gz | grep hook
	echo
}

function is_hook_synced() {
	local result=1

	local forge_md5
	forge_md5="$(incus exec forge -- md5sum /root/hook/out/checksum.txt | awk '{print $1}')"
	local bootstrap_md5
	bootstrap_md5="$(incus exec bootstrap -- md5sum /var/lib/matchbox/assets/tinkerbell/checksum.txt | awk '{print $1}')"

	if [[ "$forge_md5" == "$bootstrap_md5" ]]; then
		result=0
	fi

	return $result
}

function copy_hook_to_bootstrap() {
	print_milestone "Copying hook artifacts to the bootstrap service"

	incus exec bootstrap -- mkdir -p /var/lib/matchbox/assets/tinkerbell

	for artifact in hook_latest-lts-x86_64.tar.gz hook_x86_64.tar.gz checksum.txt; do
		incus file pull "forge/root/hook/out/$artifact" "$BUFFER/$artifact"
		incus file push "$BUFFER/$artifact" "bootstrap/var/lib/matchbox/assets/tinkerbell/$artifact"
		rm -f "$BUFFER/$artifact"
	done

	print_check "Checking artifacts"
	incus exec bootstrap -- find /var/lib/matchbox/assets/tinkerbell -type f
	echo
}

function install_registry_api_gateway() {
	print_milestone "Installing the api gateway used by the registry"

	local dns_resolver
	dns_resolver="$(kubectl get svc -n kube-system | awk '/kube-dns/ {print $3}')"

	if ! tailscale status --json | jq -e '.Peer[] | select(.HostName=="registry")' >/dev/null 2>&1; then
		print_step "First let's create the service without certificate to get the tailnet IP address"
		jinja2 --strict \
			-D "namespace=$BMAAS_NAMESPACE" \
			-D "pki_org=$PKI_ORG" \
			-D "ts_suffix=$TS_SUFFIX" \
			-D "tailscale_ip_address=" \
			-D "external_ip=$REGISTRY_IP" \
			-D "dns_resolver=$dns_resolver" \
			"$MANIFESTS_PATH/05-zot/api-gateway.yaml.j2" \
			-o "$RING0_ROOT/dist/registry-api-gateway.yaml"
		kubectl apply --wait -f "$RING0_ROOT/dist/registry-api-gateway.yaml"

		print_step "Then, get the tailnet IP address, create the certificates and configure the HTTPS endpoints"
		while ! tailscale status --json | jq -e '.Peer[] | select(.HostName=="registry")' >/dev/null 2>&1; do
			sleep 5
		done
	fi

	local tailscale_ip_address
	tailscale_ip_address="$(tailscale status | awk '/registry/ {print $1}')"

	jinja2 --strict \
		-D "namespace=$BMAAS_NAMESPACE" \
		-D "pki_org=$PKI_ORG" \
		-D "ts_suffix=$TS_SUFFIX" \
		-D "tailscale_ip_address=$tailscale_ip_address" \
		-D "external_ip=$REGISTRY_IP" \
		-D "dns_resolver=$dns_resolver" \
		"$MANIFESTS_PATH/05-zot/api-gateway.yaml.j2" \
		-o "$RING0_ROOT/dist/registry-api-gateway.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/registry-api-gateway.yaml"
}

function populate_zot() {
	print_milestone "Copying tinkerbell actions into the registry"

	for image in $(yq '.oci[]' "$MANIFESTS_PATH/05-tinkerbell/registry.yaml"); do
		local new_name
		new_name="$(echo "$image" | awk '{gsub("^[a-z.]+/","");print}')"
		local source="docker://$image"
		local destination="docker://registry.$TS_SUFFIX:443/$new_name"

		print_step "Copying $source to $destination"

		skopeo copy --dest-tls-verify=false --override-arch=amd64 --override-os=linux "$source" "$destination"
	done
}

function install_cluster_api() {
	print_milestone "Installing cluster api"

	cat >~/.cluster-api/clusterctl.yaml <<EOF
providers:
- name: "tinkerbell"
  url: "https://github.com/tinkerbell/cluster-api-provider-tinkerbell/releases/v0.6.7/infrastructure-components.yaml"
  type: "InfrastructureProvider"
EOF

	if kubectl get deployment -n kamaji-system capi-kamaji-controller-manager >/dev/null 2>&1; then
		print_check "Cluster API is already installed"
	else
		clusterctl init --infrastructure tinkerbell --control-plane kamaji
	fi
}
