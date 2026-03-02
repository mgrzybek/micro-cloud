#! /usr/bin/env bash

set -euo pipefail

PKI_ROOT="$PWD"

if [[ ! -d files/certificates ]]; then
	PKI_ROOT=/var/lib/pki
fi

for json in "$PKI_ROOT"/files/certificates/*.json; do
	cn="$(jq -r '.CN' "$json")"
	echo "👷 Generating certificate for $cn."

	if [[ -f "$PKI_ROOT/files/certificates/$cn.pem" ]]; then
		echo "✔ Certificate already exists."
	else
		cfssl gencert \
			-ca "$PKI_ROOT/files/intermediate/intermediate-ca.pem" \
			-ca-key "$PKI_ROOT/files/intermediate/intermediate-ca-key.pem" \
			-config "$PKI_ROOT/files/config/config.json" \
			-profile host "$json" |
			cfssljson -bare "$PKI_ROOT/files/certificates/$cn"

		echo
		echo "✔ Certificate created."
	fi

	find "$PKI_ROOT/files/certificates" -type f -name "$cn*.pem"
	echo
done
