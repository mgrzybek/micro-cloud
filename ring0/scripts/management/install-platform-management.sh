#! /usr/bin/env bash

if [[ -z "$TS_SUFFIX" ]]; then
	echo "TS_SUFFIX must be defined"
	return 1
fi

if [[ -z "$RING0_ROOT" ]]; then
	echo "RING0_ROOT must be defined"
	return 1
fi

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

	local PKI_AUTH_KEY_FILE="$RING0_ROOT/dist/auth.key"
	if [[ ! -f "$PKI_AUTH_KEY_FILE" ]]; then
		echo "$PKI_AUTH_KEY_FILE must be present"
		return 1
	fi
	local PKI_AUTH_KEY=$(cat $PKI_AUTH_KEY_FILE)

	cat <<EOF | yq >$RING0_ROOT/dist/cfssl.yaml
---
issuers:
  cfssl-internal-ca:
    kind: ClusterIssuer
    authSecretName: "cfssl-ca-secret"
    url: "$PKI_ENDPOINT"
    label: microcloud
    profile: host
    bundle: false
    authSecret:
      key: "$PKI_AUTH_KEY"
EOF

	helm install cert-manager jetstack/cert-manager --create-namespace --namespace cert-manager --set crds.enabled=true --set "extraArgs={--enable-gateway-api}"

	if ! kubectl get configmap --namespace=cert-manager | grep -q internal-ca-chain; then
		kubectl create configmap internal-ca-chain --namespace=cert-manager --from-file=key=$RING0_ROOT/dist/bundle.crt
	fi

	helm install cfssl-issuer-crds wikimedia-charts/cfssl-issuer-crds
	helm install cfssl-issuer wikimedia-charts/cfssl-issuer --namespace cert-manager --values $RING0_ROOT/dist/cfssl.yaml
	kubectl patch --namespace=cert-manager deployment cfssl-issuer \
		-p '{"spec":{"template":{"spec":{"$setElementOrder/containers":[{"name":"cfssl-issuer"}],"containers":[{"name":"cfssl-issuer","volumeMounts":[{"mountPath":"/etc/pki/tls/certs/","name":"internal-ca-chain"}]}],"volumes":[{"configMap":{"name":"internal-ca-chain"},"name":"internal-ca-chain"}]}}}}'
	kubectl rollout -n cert-manager restart deployment/cfssl-issuer
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

function install_cmdb_api_gateway() {
	print_milestone "Installing the api gateway used by the cmdb"

	# First let's create the service without certificate to get the tailnet IP address
	jinja2 --strict \
		-D ip_address= -D ts_suffix=$TS_SUFFIX -D pki_org="$PKI_ORG" \
		$MANIFESTS_PATH/04-cmdb/api-gateway.yaml.j2 \
		-o $RING0_ROOT/dist/cmdb-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/cmdb-api-gateway.yaml
	kubectl annotate -n platform-management svc/cilium-gateway-cmdb tailscale.com/hostname=cmdb
	kubectl annotate -n platform-management svc/cilium-gateway-cmdb tailscale.com/expose=true

	# Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint
	local svc_ip_addr=$(tailscale status | grep -w cmdb | awk '{print $1}')
	jinja2 --strict \
		-D ip_address=$svc_ip_addr -D ts_suffix=$TS_SUFFIX -D pki_org="$PKI_ORG" \
		$MANIFESTS_PATH/04-cmdb/api-gateway.yaml.j2 \
		-o $RING0_ROOT/dist/cmdb-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/cmdb-api-gateway.yaml
}

function install_idp_api_gateway() {
	print_milestone "Installing the api gateway used by the idp"

	# First let's create the service without certificate to get the tailnet IP address
	jinja2 --strict \
		-D ip_address= -D ts_suffix=$TS_SUFFIX -D pki_org="$PKI_ORG" \
		$MANIFESTS_PATH/03-idp/api-gateway.yaml.j2 \
		-o $RING0_ROOT/dist/idp-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/idp-api-gateway.yaml

	kubectl annotate -n platform-management svc/cilium-gateway-idp tailscale.com/hostname=idp
	kubectl annotate -n platform-management svc/cilium-gateway-idp tailscale.com/expose=true

	# Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint
	local svc_ip_addr=$(tailscale status | grep -w idp | awk '{print $1}')
	jinja2 --strict \
		-D ip_address=$svc_ip_addr -D ts_suffix=$TS_SUFFIX -D pki_org="$PKI_ORG" \
		$MANIFESTS_PATH/03-idp/api-gateway.yaml.j2 \
		-o $RING0_ROOT/dist/idp-api-gateway.yaml
	kubectl apply --wait -f $RING0_ROOT/dist/idp-api-gateway.yaml
}

function install_authentik() {
	print_milestone "Installing authentik"

	if [[ ! -f $RING0_ROOT/dist/authentik-values.yaml ]]; then
		jinja2 --strict \
			-D secret_key=$(openssl rand -base64 50 | tr -d '\n') -D ts_suffix=$TS_SUFFIX \
			$MANIFESTS_PATH/03-idp/authentik-values.yaml.j2 \
			-o $RING0_ROOT/dist/authentik-values.yaml
	fi

	helm install idp authentik/authentik \
		--namespace platform-management \
		--values $RING0_ROOT/dist/authentik-values.yaml
}

function create_remote_netbox_auth_secret() {
	print_milestone "Creating the netbox remote auth configmap"

	if [[ -z "$APPLICATION_SLUG" ]]; then
		echo "APPLICATION_SLUG must be defined"
		return 1
	fi

	if [[ -z "$CLIENT_ID" ]]; then
		echo "CLIENT_ID must be defined"
		return 1
	fi

	if [[ -z "$CLIENT_SECRET" ]]; then
		echo "CLIENT_SECRET must be defined"
		return 1
	fi

	jinja2 --strict \
		-D ts_suffix="$TS_SUFFIX" \
		-D application_slug="$APPLICATION_SLUG" \
		-D client_id="$CLIENT_ID" \
		-D client_secret="$CLIENT_SECRET" \
		$MANIFESTS_PATH/04-cmdb/netbox-remote-auth.py.j2 \
		-o $RING0_ROOT/dist/cmdb-netbox-remote-auth.py

	kubectl create secret generic cmdb-netbox-remote-auth \
		--from-file=netbox-remote-auth.py=$RING0_ROOT/dist/cmdb-netbox-remote-auth.py \
		--namespace platform-management
}

function install_netbox() {
	print_milestone "Installing netbox"

	print_step "Installing the SSO credintials"
	if ! kubectl get secrets -n platform-management | grep -q cmdb-netbox-remote-auth; then
		echo "cmdb-netbox-remote-auth secret not found. Did you run create_remote_netbox_auth_secret before?"
		return 1
	else
		echo "cmdb-netbox-remote-auth secret found. Nothing to do."
	fi
	print_check "SSO credentials have been added"

	print_step "Installing the internal ca bundle"
	if ! kubectl get configmap --namespace=platform-management | grep -q internal-ca-chain; then
		kubectl create configmap internal-ca-chain \
			--namespace=platform-management \
			--from-file=internal-ca.crt=$RING0_ROOT/dist/bundle.crt
	else
		echo "internal-ca-chain found. Nothing to do."
	fi
	print_check "The internal CA bundle has been added"

	print_step "Installing the helm chart"
	helm upgrade --install cmdb oci://ghcr.io/netbox-community/netbox-chart/netbox --wait \
		--namespace platform-management \
		--values $MANIFESTS_PATH/04-cmdb/netbox-values.yaml \
		--timeout=600s
	print_check "Netbox has been installed"

	kubectl wait -n platform-management --for=condition=Available deployment/cmdb-netbox
	kubectl wait -n platform-management --for=condition=Available deployment/cmdb-netbox-worker
	print_check "Netbox is ready"
}

function install_kamaji() {
	print_milestone "Installing kamaji"

	helm upgrade --install --namespace platform-management kamaji-crds clastix/kamaji-crds
	kubectl apply -f $MANIFESTS_PATH/05-kamaji/
	kubectl wait -n platform-management --for=condition=Available deployment/kamaji --timeout=600s
}

function install_metal3() {
	export IRONIC_DATA_DIR=$RING0_ROOT/dist/ironic
	export IRONIC_HOST_IP=$(talosctl --talosconfig=$RING0_ROOT/dist/talosconfig -n management -e management get address | awk '/enp7s0/ && ! /fe80/ {gsub("\/[0-9]+",""); print $6}')
	DHCP_FIRST_IP="$(echo $IRONIC_HOST_IP | sed -E 's/[0-9]+$//')100"
	DHCP_LAST_IP="$(echo $IRONIC_HOST_IP | sed -E 's/[0-9]+$//')200"

	BOOTSTRAP_INTERNAL_IP=$(incus info bootstrap | grep global | head -n1 | awk '/inet:/ {gsub("\/[0-9]+","") ; print $2}')

	if ! kubectl get ns | grep -q capi-system; then
		clusterctl init --core cluster-api:v1.10.0 \
			--bootstrap kubeadm:v1.10.0 \
			--control-plane kubeadm:v1.10.0 -v5
		clusterctl init --infrastructure metal3
	fi

	cd $RING0_ROOT/dist
	if [[ ! -d baremetal-operator ]]; then
		git clone https://github.com/metal3-io/baremetal-operator.git
	fi
	cd -

	if ! kubectl get ns | grep -q baremetal-operator-system; then
		kubectl create namespace baremetal-operator-system
		kubectl annotate ns baremetal-operator-system pod-security.kubernetes.io/enforce=privileged
	fi

	mkdir -p $RING0_ROOT/dist/baremetal-operator/config/default
	cat <<EOF >$RING0_ROOT/dist/baremetal-operator/config/default/ironic.env
HTTP_PORT=6180
PROVISIONING_INTERFACE=enp7s0
USE_IRONIC_INSPECTOR=true
DHCP_RANGE=$DHCP_FIRST_IP,$DHCP_LAST_IP
CACHEURL=http://$BOOTSTRAP_INTERNAL_IP:8080/assets/ironic
DEPLOY_KERNEL_URL=http://$IRONIC_HOST_IP:6180/images/ironic-python-agent.kernel
DEPLOY_RAMDISK_URL=http://$IRONIC_HOST_IP:6180/images/ironic-python-agent.initramfs
IRONIC_BASE_URL=http://$IRONIC_HOST_IP:6385
IRONIC_ENDPOINT=http://$IRONIC_HOST_IP:6385/v1/
IRONIC_KERNEL_PARAMS=console=tty0
IRONIC_INSPECTOR_VLAN_INTERFACES=all
IPA_BASEURI=https://tarballs.opendev.org/openstack/ironic-python-agent/dib
IPA_BRANCH=stable-2025.1
IPA_FLAVOR=centos9
EOF

	cp $RING0_ROOT/dist/baremetal-operator/config/default/ironic.env $RING0_ROOT/dist/baremetal-operator/ironic-deployment/default/ironic_bmo_configmap.env

	cd $RING0_ROOT/dist/baremetal-operator
	kustomize build config/default | kubectl apply -f -
	cd -

	cd $RING0_ROOT/dist/baremetal-operator/tools

	if [[ "$(uname)" == "Darwin" ]]; then
		git checkout -- deploy.sh
		gsed -i "s/sudo//" deploy.sh
		gsed -i "s/sed/gsed/" deploy.sh
	fi
	./deploy.sh -in
	cd -
}
