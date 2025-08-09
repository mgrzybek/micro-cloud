#! /usr/bin/env bash

set -e

NAME=management
POOL=default
DATA_DISK=data
TALOS_YAML_CONFIG=$RING0_ROOT/dist/controlplane.yaml

TARGET=headnode-0

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

if [[ -z "$BRIDGE_NAME" ]]; then
	echo "BRIDGE_NAME must be defined".
	exit 1
fi

if [[ -z "$KUBEAPI_IPADDR" ]]; then
	echo "KUBEAPI_IPADDR must be given"
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

INSTALL_IMAGE=$TALOS_FACTORY_URL/$TALOS_FACTORY_UUID:$TALOS_VERSION

source common.sh

function main() {
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

	if ! helm list -n platform-management | grep -q zitadel; then
		install_zitadel
	fi

	if ! helm list -n platform-management | grep -q netbox; then
		install_netbox
	fi

	print_check "Deployment ended successfully"
}

function prepare() {
	if [[ "$(uname)" == "Darwin" ]]; then
		export SED=gsed
	else
		export SED=sed
	fi
	export TARGET_HOME=$(ssh $TARGET pwd)

	export PKI_AUTH_KEY=$(cat $RING0_ROOT/dist/auth.key)

	helm repo add jetstack https://charts.jetstack.io
	helm repo add cnpg https://cloudnative-pg.github.io/charts
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

	if ! incus list "$NAME" -f yaml | grep -q name:; then
		incus init "$NAME" --empty --vm \
			-c limits.cpu=2 -c limits.memory=8GiB \
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
		incus config device add "$NAME" eth1 nic network="$BRIDGE_NAME"

		incus start "$NAME"
	fi

	print_check "Checking instance"
	incus info "$NAME" | yq
}

function create_talos_config() {
	print_milestone "Creating the cloud-init userdata (controlplane.yaml)"

	if [[ ! -f $RING0_ROOT/dist/controlplane.yaml ]]; then
		talosctl gen config "$NAME" "https://$KUBEAPI_IPADDR:6443" \
			--config-patch @dist/patch.yaml \
			--config-patch-control-plane @core-services/management/talos/patch.yaml \
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

	local CA=$RING0_ROOT/dist/intermediate-fullchain.pem

	if [[ ! -f "$CA" ]]; then
		echo "Cannot find the CA file $CA"
		return 1
	fi

	cat <<EOF >$RING0_ROOT/dist/patch.yaml
apiVersion: v1alpha1
kind: TrustedRootsConfig
name: homelab-ca
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

	tailscale ping management
	while [[ ! $? ]]; do
		echo "Talos address on Tailscale is not set yet. Waiting..."
		sleep 30
		tailscale ping management
	done

	local talos_opts="-n management -e management --talosconfig=./dist/talosconfig"

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
		while ! talosctl $talos_opts kubeconfig /dev/null --merge=false; do
			echo "👷 Node not available yet. Waiting..."
			sleep 30
		done
	fi

	print_check "Checking Tailscale connectivity"
	while ! tailscale ping $NAME; do
		sleep 30
	done

	kubeapi_tailscale_ipaddr=$(tailscale status | grep -w linux | grep -w $NAME | awk '{print $1}')
	tailscale_suffix=$(tailscale dns status | awk '/suffix =/ {gsub(")","");print $NF}')

	print_step "Getting the kubeconfig and using the tailnet IP address"
	talosctl $talos_opts kubeconfig
	$SED -i "s,$KUBEAPI_IPADDR,management.$tailscale_suffix," ~/.kube/config

	print_step "Waiting for the API to respond..."
	while ! kubectl cluster-info 2>&1 >/dev/null; do
		echo -n .
		sleep 10
	done

	print_check "Cluster available"
	kubectl cluster-info
}

function create_namespaces() {
	print_milestone "Creating namespaces"

	kubectl apply -f $MANIFESTS_PATH/00-namespaces.yaml
}

function install_cilium() {
	print_milestone "Installing cilium"

	local GW_API_VERSION=v1.2.0

	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GW_API_VERSION/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GW_API_VERSION/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GW_API_VERSION/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GW_API_VERSION/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GW_API_VERSION/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml

	cilium install --values $MANIFESTS_PATH/01-cilium/values.yaml --wait

}

function install_cert_manager() {
	print_milestone "Installing cert-manager"

	cat <<EOF | yq >$RING0_ROOT/dist/cfssl.yaml
---
issuers:
  cfssl-internal-ca:
    kind: ClusterIssuer
    authSecretName: "cfssl-ca-secret"
    url: "$PKI_ENDPOINT"
    label: microdc
    profile: host
    bundle: false
    authSecret:
      key: "$PKI_AUTH_KEY"
EOF

	helm install cert-manager jetstack/cert-manager --create-namespace --namespace cert-manager --set crds.enabled=true --set "extraArgs={--enable-gateway-api}"

	if ! kubectl get configmap --namespace=cert-manager | grep -q internal-ca-chain; then
		kubectl create configmap internal-ca-chain --namespace=cert-manager --from-file=key=$RING0_ROOT/dist/intermediate-fullchain.pem
	fi

	helm install cfssl-issuer-crds wikimedia-charts/cfssl-issuer-crds
	helm install cfssl-issuer wikimedia-charts/cfssl-issuer --namespace cert-manager --values $RING0_ROOT/dist/cfssl.yaml
	kubectl patch --namespace=cert-manager deployment cfssl-issuer \
		-p '{"spec":{"template":{"spec":{"$setElementOrder/containers":[{"name":"cfssl-issuer"}],"containers":[{"name":"cfssl-issuer","volumeMounts":[{"mountPath":"/etc/pki/tls/certs/","name":"internal-ca-chain"}]}],"volumes":[{"configMap":{"name":"internal-ca-chain"},"name":"internal-ca-chain"}]}}}}'
	kubectl rollout -n cert-manager restart deployment/cfssl-issuer --wait
}

function install_local_path_provisioner() {
	print_milestone "Installing local path provisioner"

	local PROVISIONER_VERSION=v0.0.31

	curl -o $MANIFESTS_PATH/01-storage/local-path-storage.yaml https://raw.githubusercontent.com/rancher/local-path-provisioner/$PROVISIONER_VERSION/deploy/local-path-storage.yaml
	kubectl apply --wait -k $MANIFESTS_PATH/01-storage/
}

function install_cnpg() {
	print_milestone "Installing cnpg"

	helm install cnpg --wait --create-namespace --namespace cnpg-system cnpg/cloudnative-pg
}

function install_tailscale() {
	print_milestone "Installing tailscale operator"

	helm install \
		tailscale-operator \
		tailscale/tailscale-operator \
		--create-namespace --namespace tailscale --wait \
		--set-string oauth.clientId="${TS_OPERATOR_CLIENT_ID}" \
		--set-string oauth.clientSecret="${TS_OPERATOR_CLIENT_SECRET}" \
		--set-string ingressClass.enabled="false"
}

function install_database() {
	print_milestone "Installing the database"

	kubectl apply --wait -f $MANIFESTS_PATH/02-pg-cluster.yaml
	kubectl wait --for=condition=Ready cluster/tooling -n platform-management --timeout=600s
}

function install_zitadel() {
	print_milestone "Installing zitadel"

	export LC_ALL=C

	if ! kubectl get secrets -n platform-management existing-zitadel-masterkey; then
		masterkey=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32 | base64)
		cat <<EOF | kubectl apply --wait -f -
apiVersion: v1
kind: Secret
metadata:
  name: existing-zitadel-masterkey
  namespace: platform-management
data:
    masterkey: $masterkey
EOF
	fi

	# First let's create the service without certificate to get the tailnet IP address
	jinja2 --strict \
		-D ip_address= -D ts_suffix=$TS_SUFFIX -D pki_org=$PKI_ORG \
		$MANIFESTS_PATH/99-zitadel/api-gateway.yaml \
		-o $RING0_ROOT/dist/idp-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/idp-api-gateway.yaml
	kubectl annotate -n platform-management svc/cilium-gateway-idp tailscale.com/hostname=idp
	kubectl annotate -n platform-management svc/cilium-gateway-idp tailscale.com/expose=true

	# Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint
	local svc_ip_addr=$(tailscale status | grep -w idp | awk '{print $1}')
	jinja2 --strict \
		-D ip_address=$svc_ip_addr -D ts_suffix=$TS_SUFFIX -D pki_org=$PKI_ORG \
		$MANIFESTS_PATH/99-zitadel/api-gateway.yaml.j2 \
		-o $RING0_ROOT/dist/idp-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/idp-api-gateway.yaml

	jinja2 --strict \
		-D ts_suffix=$TS_SUFFIX \
		-D username=admin@idp.$TS_SUFFIX \
		-D password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12 | base64) \
		$MANIFESTS_PATH/99-zitadel/values.yaml.j2 \
		-o $RING0_ROOT/dist/zitadel-values.yaml
	helm install idp zitadel/zitadel --namespace=platform-management --values $RING0_ROOT/dist/zitadel-values.yaml --timeout=600s
}

function install_netbox() {
	print_milestone "Installing netbox"

	# First let's create the service without certificate to get the tailnet IP address
	jinja2 --strict \
		-D ip_address= -D ts_suffix=$TS_SUFFIX -D pki_org=$PKI_ORG \
		$MANIFESTS_PATH/99-netbox/api-gateway.yaml.j2 \
		-o $RING0_ROOT/dist/cmdb-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/cmdb-api-gateway.yaml
	kubectl annotate -n platform-management svc/cilium-gateway-cmdb tailscale.com/hostname=cmdb
	kubectl annotate -n platform-management svc/cilium-gateway-cmdb tailscale.com/expose=true

	# Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint
	local svc_ip_addr=$(tailscale status | grep -w cmdb | awk '{print $1}')
	jinja2 --strict \
		-D ip_address=$svc_ip_addr -D ts_suffix=$TS_SUFFIX -D pki_org=$PKI_ORG \
		$MANIFESTS_PATH/99-netbox/api-gateway.yaml.j2 \
		-o $RING0_ROOT/dist/cmdb-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/cmdb-api-gateway.yaml

	helm install cmdb oci://ghcr.io/netbox-community/netbox-chart/netbox --wait \
		--namespace platform-management \
		--values $MANIFESTS_PATH/99-netbox/values.yaml \
		--timeout=600s
}

main "$@"
