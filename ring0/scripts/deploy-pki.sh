#! /usr/bin/env bash

set -ex

INSTANCE=pki
PKI_ROOT=/var/lib/pki

RING0_ROOT="$(find $PWD -type d -name ring0)"

################################################################################
# External libraries
source $RING0_ROOT/scripts/common.sh

################################################################################
# Testing variables
if [[ -z "$PKI_COUNTRY" ]]; then
	echo "PKI_COUNTRY must be defined"
	exit 1
fi

if [[ -z "$PKI_LOCATION" ]]; then
	echo "PKI_LOCATION must be defined"
	exit 1
fi

if [[ -z "$PKI_ORG" ]]; then
	echo "PKI_ORG must be defined"
	exit 1
fi

if [[ -z "$PKI_ORG_UNIT" ]]; then
	echo "PKI_ORG_UNIT must be defined"
	exit 1
fi

if [[ -z "$PKI_STATE" ]]; then
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

	start_multirootca
}

function prepare() {
	export SUFFIX=$(tailscale dns status | awk '/MagicDNS:/ {gsub(")","") ; print $NF}')

	if [[ -z "$SUFFIX" ]]; then
		echo "Error getting Tailscale's SUFFIX"
		exit 1
	fi

}

function create_instance() {
	print_milestone "Deploying the PKI"

	incus list $INSTANCE -f yaml | grep -q name: || incus launch images:debian/12 $INSTANCE

	echo "echo SUFFIX=$SUFFIX | tee /etc/cloud.sh" | incus exec $INSTANCE -- bash
	incus exec $INSTANCE -- bash <$RING0_ROOT/core-services/$INSTANCE/debian-$INSTANCE-cloud-init.sh

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

	result=$(incus exec pki -- find $PKI_ROOT/files/intermediate/bundle.crt)

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

		BUFFER=$(mktemp)
		incus exec pki -- mkdir -p $PKI_ROOT

		cd $RING0_ROOT/core-services/pki
		tar cvf $BUFFER .
		cd -

		incus file push $BUFFER pki$PKI_ROOT/pki.tar
		echo "cd $PKI_ROOT && tar xf pki.tar" | incus exec pki -- bash
		rm -f $BUFFER

		print_milestone "CA fullchain"

		echo "make -C $PKI_ROOT files/intermediate/bundle.crt" | incus exec pki -- bash
	else
		print_check "$result already exist"
		print_check "The PKI has already been bootstrapped"
	fi

	print_milestone "Getting the intermediate CA"

	mkdir -p dist
	echo "cat $PKI_ROOT/files/intermediate/bundle.crt" | incus exec pki -- bash >$RING0_ROOT/dist/bundle.crt
	find $RING0_ROOT/dist/bundle.crt
}

function start_multirootca() {
	print_milestone "Create the auth key for the webservice"

	if [[ ! -f "$RING0_ROOT/dist/auth.key" ]]; then
		auth_key=$(openssl rand -hex 16)
		echo -n $auth_key >"$RING0_ROOT/dist/auth.key"
	else
		auth_key=$(cat "$RING0_ROOT/dist/auth.key")
	fi

	print_milestone "Configuring multirootca"

	cat <<EOF >$RING0_ROOT/dist/config.json
{
    "signing": {
        "default": {
            "expiry": "8760h"
        },
        "profiles": {
            "intermediate": {
                "usages": ["cert sign", "crl sign"],
                "expiry": "70080h",
                "ca_constraint": {
                    "is_ca": true,
                    "max_path_len": 1
                }
            },
            "host": {
                "usages": ["signing", "digital signing", "key encipherment", "server auth", "client auth"],
                "expiry": "8760h",
                "auth_key": "default"
            }
        }
    },
    "auth_keys": {
        "default": {
            "key": "$auth_key",
            "type": "standard"
        }
    }
}
EOF

	incus file push $RING0_ROOT/dist/config.json pki$PKI_ROOT/files/config/config.json

	echo "systemctl enable multirootca.service" | incus exec $INSTANCE -- bash
	incus restart $INSTANCE

	print_check "Checking multirootca status"
	sleep 5
	echo "systemctl status multirootca.service" | incus exec $INSTANCE -- bash
}

function create_pki_csr() {
	print_milestone "Creating the CSR profile for $INSTANCE.$SUFFIX"

	hosts=$(incus list | awk "/$INSTANCE/ {print \$6}")

	cat <<EOF >$RING0_ROOT/dist/$INSTANCE.$SUFFIX-csr.json
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
	incus file push $RING0_ROOT/dist/$INSTANCE.$SUFFIX-csr.json pki$PKI_ROOT/files/certificates/$INSTANCE.$SUFFIX.csr.json
}

function create_certificates() {
	print_milestone "Creating certificates"

	echo "$PKI_ROOT/create-certificates.sh $SUFFIX" | incus exec $INSTANCE -- bash
}

main "$@"
