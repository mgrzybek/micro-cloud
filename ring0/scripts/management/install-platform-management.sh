#! /usr/bin/env bash

set -euo pipefail

if [[ -z "${TS_SUFFIX:-}" ]]; then
	echo "TS_SUFFIX must be defined"
	return 1
fi

if [[ -z "${RING0_ROOT:-}" ]]; then
	echo "RING0_ROOT must be defined"
	return 1
fi

function create_namespaces() {
	print_milestone "Creating namespaces"

	kubectl apply -f "$MANIFESTS_PATH/00-namespaces.yaml"
}

function install_cilium() {
	print_milestone "Installing cilium"

	local gw_api_version=v1.2.0
	local management_services_interface
	management_services_interface="$(talosctl --talosconfig "$RING0_ROOT/dist/talosconfig" -n management -e management get addresses | grep "$INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR" | awk '{print $4}' | tail -n1 | awk -F/ '{print $1}')"

	kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw_api_version/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml"
	kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw_api_version/config/crd/standard/gateway.networking.k8s.io_gateways.yaml"
	kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw_api_version/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml"
	kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw_api_version/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml"
	kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw_api_version/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml"

	kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw_api_version/config/crd/experimental/gateway.networking.k8s.io_tcproutes.yaml"
	kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw_api_version/config/crd/experimental/gateway.networking.k8s.io_udproutes.yaml"
	kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw_api_version/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml"

	jinja2 --strict \
		-D "announcements_iface=$management_services_interface" \
		"$MANIFESTS_PATH/01-cilium/values.yaml.j2" \
		-o "$RING0_ROOT/dist/cilium-values.yaml"

	cilium install --values "$RING0_ROOT/dist/cilium-values.yaml"
	cilium status --wait --wait-duration=20m
}

function install_cert_manager() {
	print_milestone "Installing cert-manager"

	local approle_role_id
	approle_role_id="$(cat "$RING0_ROOT/dist/openbao-approle-role-id")"

	local approle_secret_id
	approle_secret_id="$(cat "$RING0_ROOT/dist/openbao-approle-secret-id")"

	local openbao_ca_bundle
	openbao_ca_bundle="$(base64 <"$RING0_ROOT/dist/bundle.crt" | tr -d '\n')"

	helm install cert-manager jetstack/cert-manager --create-namespace --namespace cert-manager --set crds.enabled=true --set "extraArgs={--enable-gateway-api}"

	if ! kubectl get configmap -n cert-manager internal-ca-chain >/dev/null 2>&1; then
		kubectl create configmap internal-ca-chain --namespace=cert-manager --from-file="key=$RING0_ROOT/dist/bundle.crt"
	fi

	if ! kubectl get secret -n cert-manager openbao-approle >/dev/null 2>&1; then
		kubectl create secret generic openbao-approle \
			--namespace=cert-manager \
			--from-literal="secretId=$approle_secret_id"
	fi

	kubectl apply -f - <<ISSUER
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao-internal-ca
spec:
  vault:
    path: pki_int/sign/microcloud-host
    server: $PKI_ENDPOINT
    caBundle: "$openbao_ca_bundle"
    auth:
      appRole:
        path: approle
        roleId: "$approle_role_id"
        secretRef:
          name: openbao-approle
          key: secretId
ISSUER

	print_check "ClusterIssuer openbao-internal-ca created"
}

function install_external_secrets() {
	print_milestone "Installing External Secrets Operator"

	local eso_role_id eso_secret_id openbao_ca_bundle

	eso_role_id="$(cat "$RING0_ROOT/dist/openbao-eso-role-id")"
	eso_secret_id="$(cat "$RING0_ROOT/dist/openbao-eso-secret-id")"
	openbao_ca_bundle="$(base64 <"$RING0_ROOT/dist/bundle.crt" | tr -d '\n')"

	helm repo add external-secrets https://charts.external-secrets.io
	helm repo update

	if ! helm list -n external-secrets -o json | jq -e '.[] | select(.name=="external-secrets" and .status=="deployed")' >/dev/null 2>&1; then
		helm install external-secrets external-secrets/external-secrets \
			--create-namespace --namespace external-secrets \
			--set installCRDs=true
	fi

	if ! kubectl get secret -n external-secrets openbao-eso-approle >/dev/null 2>&1; then
		kubectl create secret generic openbao-eso-approle \
			--namespace=external-secrets \
			--from-literal="secretId=$eso_secret_id"
	fi

	kubectl apply -f - <<STORE
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
spec:
  provider:
    vault:
      server: "$PKI_ENDPOINT"
      path: "secret"
      version: "v2"
      caBundle: "$openbao_ca_bundle"
      auth:
        appRole:
          path: approle
          roleId: "$eso_role_id"
          secretRef:
            namespace: external-secrets
            name: openbao-eso-approle
            key: secretId
STORE

	print_check "ClusterSecretStore openbao created"
}

function install_local_path_provisioner() {
	print_milestone "Installing local path provisioner"

	local PROVISIONER_VERSION=v0.0.32

	curl -o "$RING0_ROOT/dist/local-path-storage.yaml" "https://raw.githubusercontent.com/rancher/local-path-provisioner/$PROVISIONER_VERSION/deploy/local-path-storage.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/local-path-storage.yaml"

	kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
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
		--set-string "oauth.clientId=${TS_OPERATOR_CLIENT_ID}" \
		--set-string "oauth.clientSecret=${TS_OPERATOR_CLIENT_SECRET}" \
		--set-string ingressClass.enabled="false"
}

function install_database() {
	print_milestone "Installing the database"

	kubectl apply --wait -f "$MANIFESTS_PATH/02-pg-cluster.yaml"
	kubectl wait --for=condition=Ready clusters.postgresql.cnpg.io/tooling -n platform-management --timeout=600s
}

function install_cmdb_api_gateway() {
	print_milestone "Installing the api gateway used by the cmdb"

	# First let's create the service without certificate to get the tailnet IP address
	jinja2 --strict \
		-D ip_address= -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
		"$MANIFESTS_PATH/04-cmdb/api-gateway.yaml.j2" \
		-o "$RING0_ROOT/dist/cmdb-api-gateway.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/cmdb-api-gateway.yaml"

	# Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint
	local svc_ip_addr
	svc_ip_addr="$(tailscale status | awk '/\bcmdb\b/ {print $1}')"
	jinja2 --strict \
		-D "ip_address=$svc_ip_addr" -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
		"$MANIFESTS_PATH/04-cmdb/api-gateway.yaml.j2" \
		-o "$RING0_ROOT/dist/cmdb-api-gateway.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/cmdb-api-gateway.yaml"
}

function install_idp_api_gateway() {
	print_milestone "Installing the api gateway used by the idp"

	# First let's create the service without certificate to get the tailnet IP address
	jinja2 --strict \
		-D ip_address= -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
		"$MANIFESTS_PATH/03-idp/api-gateway.yaml.j2" \
		-o "$RING0_ROOT/dist/idp-api-gateway.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/idp-api-gateway.yaml"

	# Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint
	local svc_ip_addr
	svc_ip_addr="$(tailscale status | awk '/\bidp\b/ {print $1}')"
	jinja2 --strict \
		-D "ip_address=$svc_ip_addr" -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
		"$MANIFESTS_PATH/03-idp/api-gateway.yaml.j2" \
		-o "$RING0_ROOT/dist/idp-api-gateway.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/idp-api-gateway.yaml"
}

function install_authentik() {
	print_milestone "Installing authentik"

	if [[ ! -f "$RING0_ROOT/dist/authentik-values.yaml" ]]; then
		jinja2 --strict \
			-D "secret_key=$(openssl rand -base64 50 | tr -d '\n')" -D "ts_suffix=$TS_SUFFIX" \
			"$MANIFESTS_PATH/03-idp/values.yaml.j2" \
			-o "$RING0_ROOT/dist/authentik-values.yaml"
	fi

	helm install idp authentik/authentik \
		--namespace platform-management \
		--values "$RING0_ROOT/dist/authentik-values.yaml"

	print_check "Waiting for the deployments to succeed"
	kubectl wait -n platform-management --for=condition=Available deployment/idp-authentik-worker --timeout=600s
	kubectl wait -n platform-management --for=condition=Available deployment/idp-authentik-server --timeout=600s
}

function create_remote_netbox_auth_secret() {
	print_milestone "Creating the netbox remote auth configmap"

	if [[ -z "${APPLICATION_SLUG:-}" ]]; then
		echo "APPLICATION_SLUG must be defined"
		return 1
	fi

	if [[ -z "${CLIENT_ID:-}" ]]; then
		echo "CLIENT_ID must be defined"
		return 1
	fi

	if [[ -z "${CLIENT_SECRET:-}" ]]; then
		echo "CLIENT_SECRET must be defined"
		return 1
	fi

	jinja2 --strict \
		-D "ts_suffix=$TS_SUFFIX" \
		-D "application_slug=$APPLICATION_SLUG" \
		-D "client_id=$CLIENT_ID" \
		-D "client_secret=$CLIENT_SECRET" \
		"$MANIFESTS_PATH/04-cmdb/netbox-remote-auth.py.j2" \
		-o "$RING0_ROOT/dist/cmdb-netbox-remote-auth.py"

	kubectl create secret generic cmdb-netbox-remote-auth \
		--from-file="netbox-remote-auth.py=$RING0_ROOT/dist/cmdb-netbox-remote-auth.py" \
		--namespace platform-management
}

function install_netbox() {
	print_milestone "Installing netbox"

	print_step "Installing the SSO credintials"
	if ! kubectl get secrets -n platform-management cmdb-netbox-remote-auth >/dev/null 2>&1; then
		echo "cmdb-netbox-remote-auth secret not found. Did you run create_remote_netbox_auth_secret before?"
		return 1
	else
		echo "cmdb-netbox-remote-auth secret found. Nothing to do."
	fi
	print_check "SSO credentials have been added"

	print_step "Installing the internal ca bundle"
	if ! kubectl get configmap -n platform-management internal-ca-chain >/dev/null 2>&1; then
		kubectl create configmap internal-ca-chain \
			--namespace=platform-management \
			--from-file="internal-ca.crt=$RING0_ROOT/dist/bundle.crt"
	else
		echo "internal-ca-chain found. Nothing to do."
	fi
	print_check "The internal CA bundle has been added"

	print_step "Installing the helm chart"
	helm upgrade --install cmdb oci://ghcr.io/netbox-community/netbox-chart/netbox --wait \
		--namespace platform-management \
		--values "$MANIFESTS_PATH/04-cmdb/netbox-values.yaml" \
		--timeout=15m
	print_check "Netbox has been installed"

	kubectl wait -n platform-management --for=condition=Available deployment/cmdb-netbox
	kubectl wait -n platform-management --for=condition=Available deployment/cmdb-netbox-worker
	print_check "Netbox is ready"
}
