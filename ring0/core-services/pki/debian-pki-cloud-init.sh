#! /usr/bin/env bash

source /etc/cloud.sh

if [[ -z "$SUFFIX" ]]; then
	echo "SUFFIX must be present in /etc/cloud.sh"
	exit 1
fi

function main() {
	set -e

	prepare

	if ! which go; then
		install_go
	fi

	if ! which cfssl; then
		install_cfssl
	fi

	configure_multirootca

	echo "✔ cloud-init ended successfully"
}

function prepare() {
	echo "#####################"
	echo "👷 Preparing the environment"

	apt update
	apt -y install jq
	export HOME=/root
	export pki=/var/lib/pki/files
}

function install_go() {
	echo "#####################"
	echo "👷 Installing go"

	apt install -y make wget

	export PATH=$PATH:/usr/local/go/bin
	export GO_ARCHIVE=go1.24.4.linux-amd64.tar.gz

	if [[ ! -f "$GO_ARCHIVE" ]]; then
		cd ~
		wget "https://go.dev/dl/$GO_ARCHIVE"
		rm -rf /usr/local/go && tar -C /usr/local -xzf "$GO_ARCHIVE"
		cd -
	fi

	echo "export PATH=$PATH:/usr/local/go/bin" >>/etc/profile

	rm -rf /tmp/go-build*

	echo
	echo "✔ Checking binaries and services"
	which go
	go version
	echo
}

function install_cfssl() {
	echo "#####################"
	echo "👷 Installing cfssl"

	apt install -y git make

	cd ~
	if [[ ! -d cfssl ]]; then
		git clone https://github.com/wikimedia/cfssl.git
		cd cfssl
		git switch wmf
		make all
		cp bin/* /usr/local/bin
		rm -rf /tmp/go-build*
	fi

	mkdir -p $pki/{root,intermediate,config,certificates}
}

function configure_multirootca() {
	echo "#####################"
	echo "👷 Configuring multirootca"

	cat <<EOF >$pki/config/multiroot-profile.ini
[microcloud]
private = file://$pki/intermediate/intermediate-ca-key.pem
certificate = $pki/intermediate/intermediate-ca.pem
config = $pki/config/config.json
EOF

	cat <<EOF >/etc/systemd/system/multirootca.service
[Unit]
Description=CFSSL PKI Certificate Authority
After=network-online.target

[Service]
ExecStart=/usr/local/bin/multirootca -a 0.0.0.0:8000 -l microcloud -roots $pki/config/multiroot-profile.ini -tls-cert $pki/certificates/pki.$SUFFIX.pem -tls-key $pki/certificates/pki.$SUFFIX-key.pem -loglevel 0
Restart=on-failure
Type=simple

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload

	echo "#####################"
	echo "✔ Checking binaries and services"
	which cfssl
	which multirootca
	echo
}

main
