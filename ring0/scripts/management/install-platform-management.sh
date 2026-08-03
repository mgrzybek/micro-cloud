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

function install_prometheus_operator_crds() {
	print_milestone "Installing the Prometheus Operator CRDs"

	# monitoring.coreos.com CRDs (ServiceMonitor, PodMonitor, ...) must exist
	# before cilium/cert-manager/cnpg are installed with their monitoring options
	# enabled, otherwise the Helm installs fail with
	# "no matches for kind ServiceMonitor in version monitoring.coreos.com/v1".
	# CRDs are plain API registrations (no pods), so they can be applied before
	# the CNI is up. The release name/namespace match the Flux HelmRelease
	# (flux-system/prometheus-operator-crds) so Flux adopts it after bootstrap.
	helm install prometheus-operator-crds prometheus-community/prometheus-operator-crds \
		--wait --create-namespace --namespace flux-system
}

function install_cilium() {
	print_milestone "Installing cilium"

	local gw_api_version=v1.6.1
	local management_services_interface
	management_services_interface="$(talosctl --talosconfig "$RING0_ROOT/dist/talosconfig" -n management -e management get addresses | grep "$INSTANCE_MANAGEMENT_SERVICES_IPADDR_CIDR" | awk '{print $4}' | tail -n1 | awk -F/ '{print $1}')"

	kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$gw_api_version/standard-install.yaml"

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

	# prometheus.servicemonitor lets the VictoriaMetrics operator discover
	# cert-manager metrics (requires the Prometheus Operator CRDs installed above).
	helm install cert-manager jetstack/cert-manager --create-namespace --namespace cert-manager \
		--set crds.enabled=true \
		--set "extraArgs={--enable-gateway-api}" \
		--set prometheus.enabled=true \
		--set prometheus.servicemonitor.enabled=true

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

function install_local_path_provisioner() {
	print_milestone "Installing local path provisioner"

	local PROVISIONER_VERSION=v0.0.32

	curl -o "$RING0_ROOT/dist/local-path-storage.yaml" "https://raw.githubusercontent.com/rancher/local-path-provisioner/$PROVISIONER_VERSION/deploy/local-path-storage.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/local-path-storage.yaml"

	kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

function install_cnpg() {
	print_milestone "Installing cnpg"

	# monitoring.podMonitorEnabled exposes the operator metrics as a PodMonitor
	# discovered by the VictoriaMetrics operator (requires the Prometheus Operator
	# CRDs installed above). Per-database metrics are enabled on each Cluster CR.
	helm install cnpg --wait --create-namespace --namespace cnpg-system cnpg/cloudnative-pg \
		--set monitoring.podMonitorEnabled=true
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

	if ! tailscale status --json | jq -e '.Peer[] | select(.HostName=="cmdb")' >/dev/null 2>&1; then
		print_step "First let's create the service without certificate to get the tailnet IP address"
		jinja2 --strict \
			-D ip_address= -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
			"$MANIFESTS_PATH/04-cmdb/api-gateway.yaml.j2" \
			-o "$RING0_ROOT/dist/cmdb-api-gateway.yaml"
		kubectl apply --wait -f "$RING0_ROOT/dist/cmdb-api-gateway.yaml"

		print_step "Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint"
		while ! tailscale status --json | jq -e '.Peer[] | select(.HostName=="cmdb")' >/dev/null 2>&1; do
			sleep 5
		done
	fi

	local svc_ip_addr
	svc_ip_addr="$(tailscale status | awk '/ cmdb / {print $1}')"
	jinja2 --strict \
		-D "ip_address=$svc_ip_addr" -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
		"$MANIFESTS_PATH/04-cmdb/api-gateway.yaml.j2" \
		-o "$RING0_ROOT/dist/cmdb-api-gateway.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/cmdb-api-gateway.yaml"
}

function install_idp_api_gateway() {
	print_milestone "Installing the api gateway used by the idp"

	if ! tailscale status --json | jq -e '.Peer[] | select(.HostName=="idp")' >/dev/null 2>&1; then
		print_step "First let's create the service without certificate to get the tailnet IP address"
		jinja2 --strict \
			-D ip_address= -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
			"$MANIFESTS_PATH/03-idp/api-gateway.yaml.j2" \
			-o "$RING0_ROOT/dist/idp-api-gateway.yaml"
		kubectl apply --wait -f "$RING0_ROOT/dist/idp-api-gateway.yaml"

		print_step "Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint"
		while ! tailscale status --json | jq -e '.Peer[] | select(.HostName=="idp")' >/dev/null 2>&1; do
			sleep 5
		done
	fi

	local svc_ip_addr
	svc_ip_addr="$(tailscale status | awk '/ idp / {print $1}')"
	jinja2 --strict \
		-D "ip_address=$svc_ip_addr" -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
		"$MANIFESTS_PATH/03-idp/api-gateway.yaml.j2" \
		-o "$RING0_ROOT/dist/idp-api-gateway.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/idp-api-gateway.yaml"
}
