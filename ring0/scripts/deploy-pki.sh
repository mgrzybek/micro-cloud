#! /usr/bin/env bash

set -euo pipefail

INSTANCE=pki
PKI_ROOT=/var/lib/pki

RING0_ROOT="$(find "$PWD" -type d -name ring0 | head -n1)"

################################################################################
# External libraries
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"

################################################################################
# Testing variables
if [[ -z "${PKI_COUNTRY:-}" ]]; then
	echo "PKI_COUNTRY must be defined"
	exit 1
fi

if [[ -z "${PKI_LOCATION:-}" ]]; then
	echo "PKI_LOCATION must be defined"
	exit 1
fi

if [[ -z "${PKI_ORG:-}" ]]; then
	echo "PKI_ORG must be defined"
	exit 1
fi

if [[ -z "${PKI_ORG_UNIT:-}" ]]; then
	echo "PKI_ORG_UNIT must be defined"
	exit 1
fi

if [[ -z "${PKI_STATE:-}" ]]; then
	echo "PKI_STATE must be defined"
	exit 1
fi

################################################################################
# Functions
function main() {
	prepare

	create_instance

	create_ca_csr
	create_ca
	create_pki_csr
	create_certificates

	stop_multirootca
	init_openbao
	import_cas_to_openbao
	create_openbao_role
	configure_openbao_approle
	configure_openbao_eso_approle
	configure_autounseal
}

function prepare() {
	export SUFFIX
	SUFFIX="$(tailscale dns status | awk '/MagicDNS:/ {gsub(")","") ; print $NF}')"

	if [[ -z "$SUFFIX" ]]; then
		echo "Error getting Tailscale's SUFFIX"
		exit 1
	fi

}

function create_instance() {
	print_milestone "Deploying the PKI"

	incus list "$INSTANCE" -f yaml | grep -q "name:" || incus launch images:debian/12 "$INSTANCE"

	echo "echo SUFFIX=$SUFFIX | tee /etc/cloud.sh" | incus exec "$INSTANCE" -- bash
	incus exec "$INSTANCE" -- bash <"$RING0_ROOT/core-services/$INSTANCE/debian-$INSTANCE-cloud-init.sh"

	print_check "The PKI instance is ready to be configured"
}

function create_ca_csr() {
	mkdir -p "$RING0_ROOT/core-services/pki/files/intermediate"
	mkdir -p "$RING0_ROOT/core-services/pki/files/root"

	cat <<EOF >"$RING0_ROOT/core-services/pki/files/root/root-csr.json"
{
  "CN": "Root Certificate Authority",
  "key": {
    "algo": "ecdsa",
    "size": 256
  },
  "names": [
    {
      "C": "$PKI_COUNTRY",
      "ST": "$PKI_STATE",
      "L": "$PKI_LOCATION",
      "O": "$PKI_ORG",
      "OU": "$PKI_ORG_UNIT"
    }
  ],
  "ca": {
    "expiry": "87600h"
  }
}
EOF

	cat <<EOF >"$RING0_ROOT/core-services/pki/files/intermediate/intermediate-csr.json"
{
  "CN": "Intermediate Certificate Authority",
  "key": {
    "algo": "ecdsa",
    "size": 256
  },
  "names": [
    {
      "C": "$PKI_COUNTRY",
      "ST": "$PKI_STATE",
      "L": "$PKI_LOCATION",
      "O": "$PKI_ORG",
      "OU": "$PKI_ORG_UNIT"
    }
  ]
}
EOF
}

function create_ca() {
	print_milestone "Configuring the PKI"

	local result
	result="$(incus exec pki -- find "$PKI_ROOT/files/intermediate/bundle.crt" 2>/dev/null || true)"

	if [[ -z "$result" ]]; then
		print_milestone "Sending files to the PKI instance"

		if [[ ! -f "$RING0_ROOT/core-services/pki/files/root/root-csr.json" ]]; then
			echo "$RING0_ROOT/core-services/pki/files/root/root-csr.json must exist"
			return 1
		fi

		if [[ ! -f "$RING0_ROOT/core-services/pki/files/intermediate/intermediate-csr.json" ]]; then
			echo "$RING0_ROOT/core-services/pki/files/intermediate/intermediate-csr.json must exist"
			return 1
		fi

		local BUFFER
		BUFFER="$(mktemp)"
		# shellcheck disable=SC2064
		trap "rm -f '${BUFFER}'" RETURN

		incus exec pki -- mkdir -p "$PKI_ROOT"

		(cd "$RING0_ROOT/core-services/pki" && tar cvf "$BUFFER" .)

		incus file push "$BUFFER" "pki$PKI_ROOT/pki.tar"
		echo "cd $PKI_ROOT && tar xf pki.tar" | incus exec pki -- bash

		print_milestone "CA fullchain"

		echo "make -C $PKI_ROOT files/intermediate/bundle.crt" | incus exec pki -- bash
	else
		print_check "$result already exist"
		print_check "The PKI has already been bootstrapped"
	fi

	print_milestone "Getting the intermediate CA"

	mkdir -p dist
	echo "cat $PKI_ROOT/files/intermediate/bundle.crt" | incus exec pki -- bash >"$RING0_ROOT/dist/bundle.crt"
	find "$RING0_ROOT/dist/bundle.crt"
}

function create_pki_csr() {
	print_milestone "Creating the CSR profile for $INSTANCE.$SUFFIX"

	local hosts
	hosts="$(incus list | awk "/$INSTANCE/ {print \$6}")"

	cat <<EOF >"$RING0_ROOT/dist/$INSTANCE.$SUFFIX-csr.json"
{
  "CN": "$INSTANCE.$SUFFIX",
  "hosts": [
    "$hosts"
  ],
  "names": [
    {
      "C": "$PKI_COUNTRY",
      "ST": "$PKI_STATE",
      "L": "$PKI_LOCATION",
      "O": "$PKI_ORG",
      "OU": "$PKI_ORG_UNIT"
    }
  ]
}
EOF
	incus file push "$RING0_ROOT/dist/$INSTANCE.$SUFFIX-csr.json" "pki$PKI_ROOT/files/certificates/$INSTANCE.$SUFFIX.csr.json"
}

function create_certificates() {
	print_milestone "Creating certificates"

	echo "$PKI_ROOT/create-certificates.sh $SUFFIX" | incus exec "$INSTANCE" -- bash
}

function stop_multirootca() {
	print_milestone "Stopping multirootca"

	local result
	result="$(incus exec pki -- systemctl is-active multirootca.service 2>/dev/null || true)"

	if [[ "$result" == "active" ]]; then
		incus exec pki -- systemctl stop multirootca.service
		incus exec pki -- systemctl disable multirootca.service
		print_check "multirootca stopped and disabled"
	else
		print_check "multirootca was not running"
	fi
}

function _bao() {
	local root_token vault_addr
	vault_addr="$(incus exec pki -- ip -4 addr show dev eth0 </dev/null | awk '/inet/ {print $2}' | awk -F/ '{print $1}')"

	root_token="$(cat "$RING0_ROOT/dist/openbao-root.token")"
	incus exec pki \
		--env VAULT_ADDR="https://$vault_addr:8200" \
		--env VAULT_CACERT="$PKI_ROOT/files/intermediate/bundle.crt" \
		--env VAULT_TOKEN="$root_token" \
		-- bao "$@"
}

function init_openbao() {
	print_milestone "Initializing OpenBao"

	local vault_addr
	vault_addr="$(incus exec pki -- ip -4 addr show dev eth0 | awk '/inet/ {print $2}' | awk -F/ '{print $1}')"

	if ! incus exec pki -- grep -q VAULT_ADDR /etc/profile; then
		incus exec pki -- bash -c "echo VAULT_ADDR=https://$vault_addr:8200 >> /etc/profile"
		incus exec pki -- bash -c "echo VAULT_CACERT=$PKI_ROOT/files/intermediate/bundle.crt >> /etc/profile"
	fi

	incus exec pki -- systemctl enable openbao.service
	if ! incus exec pki -- systemctl is-active openbao.service; then
		incus exec pki -- systemctl start openbao.service
	fi
	sleep 3

	if incus exec pki --env VAULT_ADDR="https://$vault_addr:8200" --env VAULT_CACERT="$PKI_ROOT/files/intermediate/bundle.crt" -- bash -c "bao status -format=json 2>/dev/null | jq -r '.initialized' | grep false"; then
		print_milestone "Running OpenBao init"

		incus exec pki -- mkdir -p /var/lib/openbao
		incus exec pki -- chown openbao: /var/lib/openbao

		local init_output
		init_output="$(incus exec pki \
			--env "VAULT_ADDR=https://$vault_addr:8200" \
			--env "VAULT_CACERT=$PKI_ROOT/files/intermediate/bundle.crt" \
			-- bao operator init -key-shares=1 -key-threshold=1 -format=json)"

		echo "$init_output" | jq -r '.unseal_keys_b64[0]' >"$RING0_ROOT/dist/openbao-unseal.key"
		echo "$init_output" | jq -r '.root_token' >"$RING0_ROOT/dist/openbao-root.token"

		print_check "Unseal key: dist/openbao-unseal.key"
		print_check "Root token: dist/openbao-root.token"
	fi

	local sealed
	sealed="$(incus exec pki \
		--env VAULT_ADDR="https://$vault_addr:8200" \
		--env VAULT_CACERT="$PKI_ROOT/files/intermediate/bundle.crt" \
		-- bash -c "bao status -format=json 2>/dev/null | jq -r '.sealed'")"

	if [[ "$sealed" == "true" ]]; then
		local unseal_key
		unseal_key="$(cat "$RING0_ROOT/dist/openbao-unseal.key")"
		incus exec pki \
			--env VAULT_ADDR="https://$vault_addr:8200" \
			--env VAULT_CACERT="$PKI_ROOT/files/intermediate/bundle.crt" \
			-- bao operator unseal "$unseal_key"
	fi

	print_check "OpenBao is initialized and unsealed"
}

function import_cas_to_openbao() {
	print_milestone "Importing CA material into OpenBao"

	# Enable PKI mounts (idempotent)
	_bao secrets list -format=json | jq -e '."pki/"' >/dev/null 2>&1 ||
		_bao secrets enable -path=pki -max-lease-ttl=87600h pki

	_bao secrets list -format=json | jq -e '."pki_int/"' >/dev/null 2>&1 ||
		_bao secrets enable -path=pki_int -max-lease-ttl=70080h pki

	# Import root CA (key first, then cert — required format for OpenBao)
	local root_imported
	root_imported="$(_bao read -format=json pki/config/ca 2>/dev/null | jq -r '.data.certificate // ""' || true)"
	if [[ -z "$root_imported" ]]; then
		incus exec pki -- bash -c \
			"cat $PKI_ROOT/files/root/root-ca-key.pem $PKI_ROOT/files/root/root-ca.pem" |
			_bao write pki/config/ca pem_bundle=-
		print_check "Root CA imported"
	else
		print_check "Root CA already imported"
	fi

	# Import intermediate CA
	local int_imported
	int_imported="$(_bao read -format=json pki_int/config/ca 2>/dev/null | jq -r '.data.certificate // ""' || true)"
	if [[ -z "$int_imported" ]]; then
		incus exec pki -- bash -c \
			"cat $PKI_ROOT/files/intermediate/intermediate-ca-key.pem $PKI_ROOT/files/intermediate/intermediate-ca.pem" |
			_bao write pki_int/config/ca pem_bundle=-
		print_check "Intermediate CA imported"
	else
		print_check "Intermediate CA already imported"
	fi

	# Configure CRL and issuing certificate URLs
	local pki_addr="https://pki.$SUFFIX:8200"
	_bao write pki/config/urls \
		"issuing_certificates=$pki_addr/v1/pki/ca" \
		"crl_distribution_points=$pki_addr/v1/pki/crl"

	_bao write pki_int/config/urls \
		"issuing_certificates=$pki_addr/v1/pki_int/ca" \
		"crl_distribution_points=$pki_addr/v1/pki_int/crl"

	print_check "CA URLs configured"
}

function create_openbao_role() {
	print_milestone "Creating OpenBao issuance role"

	local role_exists
	role_exists="$(_bao read -format=json pki_int/roles/microcloud-host 2>/dev/null | jq -r '.data.name // ""' || true)"

	if [[ -z "$role_exists" ]]; then
		_bao write pki_int/roles/microcloud-host \
			allow_any_name=true \
			allow_ip_sans=true \
			"allowed_uri_sans=spiffe://cluster.local/*" \
			key_type=rsa \
			key_bits=2048 \
			max_ttl=8760h \
			ttl=2160h \
			require_cn=false \
			server_flag=true \
			client_flag=true
		print_check "Role microcloud-host created"
	else
		print_check "Role microcloud-host already exists"
	fi
}

function configure_openbao_approle() {
	print_milestone "Configuring AppRole authentication"

	# Enable AppRole if not already enabled
	_bao auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1 ||
		_bao auth enable approle

	# Create policy
	_bao policy write cert-manager-pki - <<'POLICY'
path "pki_int/sign/microcloud-host" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/microcloud-host" {
  capabilities = ["create", "update"]
}
POLICY

	# Create AppRole
	_bao write auth/approle/role/cert-manager \
		token_policies=cert-manager-pki \
		token_ttl=1h \
		token_max_ttl=4h \
		secret_id_ttl=0 \
		secret_id_num_uses=0

	local role_id
	role_id="$(_bao read -format=json auth/approle/role/cert-manager/role-id | jq -r '.data.role_id')"
	echo -n "$role_id" >"$RING0_ROOT/dist/openbao-approle-role-id"

	local secret_id
	secret_id="$(_bao write -format=json -f auth/approle/role/cert-manager/secret-id | jq -r '.data.secret_id')"
	echo -n "$secret_id" >"$RING0_ROOT/dist/openbao-approle-secret-id"

	print_check "AppRole role-id: $role_id"
	print_check "AppRole secret-id: dist/openbao-approle-secret-id"
}

function configure_openbao_eso_approle() {
	print_milestone "Configuring ESO AppRole"

	# Activate KV v2 if absent
	_bao secrets list -format=json | jq -e '."secret/"' >/dev/null 2>&1 ||
		_bao secrets enable -path=secret -version=2 kv

	_bao policy write eso-secrets - <<'POLICY'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY

	_bao write auth/approle/role/eso \
		token_policies=eso-secrets \
		token_ttl=1h \
		token_max_ttl=4h \
		secret_id_ttl=0 \
		secret_id_num_uses=0

	local role_id
	role_id="$(_bao read -format=json auth/approle/role/eso/role-id | jq -r '.data.role_id')"
	echo -n "$role_id" >"$RING0_ROOT/dist/openbao-eso-role-id"

	local secret_id
	secret_id="$(_bao write -format=json -f auth/approle/role/eso/secret-id | jq -r '.data.secret_id')"
	echo -n "$secret_id" >"$RING0_ROOT/dist/openbao-eso-secret-id"

	print_check "ESO AppRole configured: dist/openbao-eso-role-id"
}

function configure_autounseal() {
	print_milestone "Configuring auto-unseal"

	local unseal_key
	unseal_key="$(cat "$RING0_ROOT/dist/openbao-unseal.key")"

	incus exec pki -- bash -c "install -m 0400 -o root /dev/stdin /etc/openbao/unseal.key <<< '$unseal_key'"
	incus exec pki -- systemctl enable openbao-unseal.service

	print_check "Auto-unseal configured"
}

main "$@"
