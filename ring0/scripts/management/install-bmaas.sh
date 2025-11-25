#! /usr/bin/env bash

if [[ -z "$BMAAS_NAMESPACE" ]]; then
	echo "BMAAS_NAMESPACE must be defined"
	return 1
fi

if [[ -z "$BUFFER" ]]; then
	echo "BUFFER must be defined"
	return 1
fi

if [[ -z "$INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR" ]]; then
	echo "INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR must be defined"
	return 1
fi

if [[ -z "$PKI_ORG" ]]; then
	echo "PKI_ORG must be defined"
	exit 1
fi

if [[ -z "$TS_SUFFIX" ]]; then
	echo "TS_SUFFIX must be defined"
	return 1
fi

if [[ -z "$DNS_IP" ]]; then
	echo "DNS_IP must be defined"
	return 1
fi

if [[ -z "$HOOKOS_IP" ]]; then
	echo "HOOKOS_IP must be defined"
	return 1
fi

if [[ -z "$REGISTRY_IP" ]]; then
	echo "REGISTRY_IP must be defined"
	return 1
fi

if [[ -z "$TINKERBELL_IP" ]]; then
	echo "TINKERBELL_IP must be defined"
	return 1
fi

function build_hook() {
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

	local forge_md5=$(incus exec forge -- md5sum /root/hook/out/checksum.txt | awk '{print $1}')
	local bootstrap_md5=$(incus exec bootstrap -- md5sum /var/lib/matchbox/assets/tinkerbell/checksum.txt | awk '{print $1}')

	if [[ "$forge_md5" == "$bootstrap_md5" ]]; then
		result=0
	fi

	return $result
}

function copy_hook_to_bootstrap() {
	print_milestone "Copying hook artifacts to the bootstrap service"

	incus exec bootstrap -- mkdir -p /var/lib/matchbox/assets/tinkerbell

	for artifact in hook_latest-lts-x86_64.tar.gz hook_x86_64.tar.gz checksum.txt; do
		incus file pull forge/root/hook/out/$artifact $BUFFER/$artifact
		incus file push $BUFFER/$artifact bootstrap/var/lib/matchbox/assets/tinkerbell/$artifact
		rm -f $BUFFER/$artifact
	done

	print_check "Checking artifacts"
	incus exec bootstrap -- find /var/lib/matchbox/assets/tinkerbell -type f
	echo
}

function install_tinkerbell() {
	print_milestone "Installing tinkerbell"

	# Get the iface holding the given ip addr
	local management_services_interface=$(talosctl --talosconfig $RING0_ROOT/dist/talosconfig -n management -e management get addresses | grep $INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR | awk '{print $4}' | tail -n1 | awk -F/ '{print $1}')

	# Get the pod CIDRs to set as trusted proxies
	local trusted_proxies=$(kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' | tr ' ' ',')

	# Specify the Tinkerbell Helm chart version, here we use the latest release.
	local tinkerbell_chart_version=v0.19.1

	local instance_bootstrap_ipaddr="$(incus list | awk '/bootstrap/ && /eth1/ {print $6}')"

	# Creating the helm values from template
	jinja2 --strict \
		-D dhcp_bind_interface=$management_services_interface \
		-D registry_ip=$REGISTRY_IP \
		-D bootstrap_endpoint=http://$instance_bootstrap_ipaddr:8080/assets/tinkerbell \
		-D hookos_ip=$HOOKOS_IP \
		-D tinkerbell_ip=$TINKERBELL_IP \
		-D artifacts_file_server=http://$HOOKOS_IP:7173 $MANIFESTS_PATH/05-tinkerbell/values.yaml.j2 \
		-o $RING0_ROOT/dist/tinkerbell-values.yaml

	create_namespace

	helm install tinkerbell oci://ghcr.io/tinkerbell/charts/tinkerbell \
		--version $tinkerbell_chart_version \
		--namespace $BMAAS_NAMESPACE \
		--set "trustedProxies={${trusted_proxies}}" \
		--values $RING0_ROOT/dist/tinkerbell-values.yaml
	kubectl label -n $BMAAS_NAMESPACE service hookos ring0/services="true"

	# TODO: publish bundle.crt
	ls $RING0_ROOT/dist/bundle.crt

	print_check "Checking the deployment"
	if kubectl -n $BMAAS_NAMESPACE wait --timeout=600s --for=condition=Available deployment/hookos; then
		echo "hookos: OK"
	fi
	if kubectl -n $BMAAS_NAMESPACE wait --for=condition=Available deployment/tinkerbell; then
		echo "tinkerbell: OK"
	fi
	echo
}

function install_zot() {
	print_milestone "Installing zot registry"

	create_namespace

	print_step "Installing the helm chart"
	if ! helm repo list | grep -qw zot; then
		helm repo add project-zot http://zotregistry.dev/helm-charts
		helm repo update
	fi
	helm install zot project-zot/zot --namespace $BMAAS_NAMESPACE --values $MANIFESTS_PATH/05-zot/values.yaml

	install_registry_api_gateway

	print_check "Checking the deployment"
	if kubectl -n $BMAAS_NAMESPACE wait --for=condition=Ready --timeout=600s pod/zot-0; then
		echo "zot: OK"
	fi
	echo
}

function create_namespace() {
	# Creating privileged namespace
	if ! kubectl get ns $BMAAS_NAMESPACE 2>&1 >/dev/null; then
		kubectl create ns $BMAAS_NAMESPACE
		kubectl annotate ns $BMAAS_NAMESPACE pod-security.kubernetes.io/enforce=privileged
	fi
}

function install_registry_api_gateway() {
	print_milestone "Installing the api gateway used by the registry"

	local dns_resolver="$(kubectl get svc -n kube-system | awk '/kube-dns/ {print $3}')"

	if ! tailscale status | grep -qw management; then
		print_step "First let's create the service without certificate to get the tailnet IP address"
		jinja2 --strict \
			-D namespace=$BMAAS_NAMESPACE \
			-D pki_org="$PKI_ORG" \
			-D ts_suffix="$TS_SUFFIX" \
			-D tailscale_ip_address="" \
			-D external_ip="$REGISTRY_IP" \
			-D dns_resolver="$dns_resolver" \
			$MANIFESTS_PATH/05-zot/api-gateway.yaml.j2 \
			-o $RING0_ROOT/dist/registry-api-gateway.yaml
		kubectl apply --wait -f $RING0_ROOT/dist/registry-api-gateway.yaml

		print_step "Then, get the tailnet IP address, create the certificates and configure the HTTPS endpoints"
		while ! tailscale status | grep -qw registry; do
			sleep 5
		done
	fi

	local tailscale_ip_address="$(tailscale status | awk '/registry/ {print $1}')"

	jinja2 --strict \
		-D namespace=$BMAAS_NAMESPACE \
		-D pki_org="$PKI_ORG" \
		-D ts_suffix="$TS_SUFFIX" \
		-D tailscale_ip_address="$tailscale_ip_address" \
		-D external_ip="$REGISTRY_IP" \
		-D dns_resolver="$dns_resolver" \
		$MANIFESTS_PATH/05-zot/api-gateway.yaml.j2 \
		-o $RING0_ROOT/dist/registry-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/registry-api-gateway.yaml
}

function populate_zot() {
	print_milestone "Copying tinkerbell actions into the registry"

	for image in $(yq '.oci[]' $MANIFESTS_PATH/05-tinkerbell/registry.yaml); do
		local new_name=$(echo $image | awk '{gsub("^[a-z.]+/","");print}')
		local source="docker://$image"
		local destination="docker://registry.$TS_SUFFIX:443/$new_name"

		print_step "Copying $source to $destination"

		skopeo copy --dest-tls-verify=false --override-arch=amd64 --override-os=linux $source $destination
	done
}

function install_coredns() {
	print_milestone "Installing core dns"

	local management_services_ipaddr="$(echo $INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR | awk -F/ '{print $1}')"

	print_step "Creating values.yaml"
	jinja2 --strict \
		-D services_iface_ip_address=$management_services_ipaddr \
		-D coredns_ip=$DNS_IP \
		-D registry_ip=$REGISTRY_IP \
		$MANIFESTS_PATH/05-coredns/values.yaml.j2 \
		-o $RING0_ROOT/dist/coredns-values.yaml

	print_step "Installing the helm chart"
	if ! helm repo list | grep -qw coredns; then
		helm repo add coredns https://coredns.github.io/helm
	fi
	helm install coredns coredns/coredns \
		--namespace=$BMAAS_NAMESPACE \
		--values $RING0_ROOT/dist/coredns-values.yaml
}

function create_announcement_configuration() {
	print_milestone "Create Cilium L2 announcement"

	local management_services_interface=$(talosctl --talosconfig $RING0_ROOT/dist/talosconfig -n management -e management get addresses | grep $INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR | awk '{print $4}' | tail -n1 | awk -F/ '{print $1}')

	jinja2 --strict \
		-D dns_ip=$DNS_IP \
		-D hookos_ip=$HOOKOS_IP \
		-D registry_ip=$REGISTRY_IP \
		-D tinkerbell_ip=$TINKERBELL_IP \
		-D announcement_interface=$management_services_interface \
		$MANIFESTS_PATH/01-cilium/l2-announcement.yaml.j2 \
		-o $RING0_ROOT/dist/l2-announcement.yaml
	kubectl apply -f $RING0_ROOT/dist/l2-announcement.yaml
}

function install_kamaji() {
	print_milestone "Installing kamaji"

	helm upgrade --install kamaji-crds clastix/kamaji-crds --namespace kamaji-system
	helm upgrade --install kamaji-etcd clastix/kamaji-etcd --namespace kamaji-system --set replicas=1 --set datastore.name=microcloud

	kubectl apply -f $MANIFESTS_PATH/05-kamaji/
	kubectl wait -n kamaji-system --for=condition=Available deployment/kamaji --timeout=600s
}

function install_cluster_api() {
	print_milestone "Installing cluster api"

	cat >~/.cluster-api/clusterctl.yaml <<EOF
providers:
- name: "tinkerbell"
  url: "https://github.com/tinkerbell/cluster-api-provider-tinkerbell/releases/v0.6.7/infrastructure-components.yaml"
  type: "InfrastructureProvider"
EOF

	clusterctl init --infrastructure tinkerbell --control-plane kamaji
}
