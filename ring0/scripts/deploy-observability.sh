#! /usr/bin/env bash

set -euo pipefail

################################################################################
# External libraries
RING0_ROOT="$(find "$PWD" -type d -name ring0 | head -n1)"

# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"

################################################################################
# Functions

function install_grafana_api_gateway() {
	print_milestone "Installing the api gateway used by Grafana"

	if ! tailscale status --json | jq -e '.Peer[] | select(.HostName=="grafana")' >/dev/null 2>&1; then
		print_step "First let's create the service without certificate to get the tailnet IP address"
		jinja2 --strict \
			-D ip_address= -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
			"$MANIFESTS_PATH/06-observability/api-gateway.yaml.j2" \
			-o "$RING0_ROOT/dist/grafana-api-gateway.yaml"
		kubectl apply --wait -f "$RING0_ROOT/dist/grafana-api-gateway.yaml"

		print_step "Then, get the tailnet IP address, create the certificate and configure the HTTPS endpoint"
		while ! tailscale status --json | jq -e '.Peer[] | select(.HostName=="grafana")' >/dev/null 2>&1; do
			sleep 5
		done
	fi

	local svc_ip_addr
	svc_ip_addr="$(tailscale status | awk '/\bgrafana\b/ {print $1}')"
	jinja2 --strict \
		-D "ip_address=$svc_ip_addr" -D "ts_suffix=$TS_SUFFIX" -D "pki_org=$PKI_ORG" \
		"$MANIFESTS_PATH/06-observability/api-gateway.yaml.j2" \
		-o "$RING0_ROOT/dist/grafana-api-gateway.yaml"
	kubectl apply --wait -f "$RING0_ROOT/dist/grafana-api-gateway.yaml"
}

################################################################################
# Starting the tasks
# Grafana and the VictoriaMetrics stack are installed by Flux (HelmRelease
# apps/06-observability). This script only creates the Tailscale API gateway
# needed to expose grafana.<ts_suffix>.

install_grafana_api_gateway
