#! /usr/bin/env bash

# shellcheck source=/dev/null
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

	if ! which bao; then
		install_openbao
	fi

	configure_openbao

	echo "✔ cloud-init ended successfully"
}

function prepare() {
	echo "#####################"
	echo "👷 Preparing the environment"

	apt update
	apt -y install jq unzip wget
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

	if ! grep go/bin /etc/profile; then
		echo "export PATH=$PATH:/usr/local/go/bin" >>/etc/profile
	fi

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
		git clone https://github.com/cloudflare/cfssl
		cd cfssl
		make all
		cp bin/* /usr/local/bin
		rm -rf /tmp/go-build*
	fi

	mkdir -p $pki/{root,intermediate,config,certificates}
}

function install_openbao() {
	echo "#####################"
	echo "👷 Installing OpenBao"

	local openbao_version
	openbao_version="$(wget -qO- https://api.github.com/repos/openbao/openbao/releases/latest |
		jq -r '.tag_name' | sed 's/^v//')"

	if [[ -z "$openbao_version" ]]; then
		echo "Failed to fetch latest OpenBao version from GitHub API"
		return 1
	fi

	local openbao_archive="openbao_${openbao_version}_linux_amd64.deb"
	local openbao_url="https://github.com/openbao/openbao/releases/download/v${openbao_version}/${openbao_archive}"

	if ! dpkg -l openbao | grep ii | grep "$openbao_version"; then
		cd /tmp
		wget "$openbao_url"
		apt -y install "./$openbao_archive"
		rm -f "$openbao_archive"
	fi

	echo
	echo "✔ OpenBao installed"
	bao version
	echo
}

function configure_openbao() {
	echo "#####################"
	echo "👷 Configuring OpenBao"

	local vault_addr
	vault_addr="$(ip -4 addr show dev eth0 | awk '/inet/ {print $2}' | awk -F/ '{print $1}')"

	chown openbao: "$pki/certificates/pki.$SUFFIX.pem" "$pki/certificates/pki.$SUFFIX-key.pem"

	cat >/etc/openbao/openbao.hcl <<OPENBAO_CONFIG
ui = false

storage "file" {
  path = "/var/lib/openbao"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "$pki/certificates/pki.$SUFFIX.pem"
  tls_key_file  = "$pki/certificates/pki.$SUFFIX-key.pem"
}

api_addr = "https://pki.$SUFFIX:8200"
OPENBAO_CONFIG

	chown openbao:openbao /etc/openbao/openbao.hcl

	cat >/etc/systemd/system/openbao-unseal.service <<UNSEAL_UNIT
[Unit]
Description=OpenBao auto-unseal
Documentation=https://openbao.org/docs/
After=openbao.service
Requires=openbao.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=VAULT_ADDR="https://$vault_addr:8200
Environment=VAULT_CACERT=$pki/intermediate/bundle.crt
ExecStart=/bin/bash -c '/usr/bin/bao operator unseal \$(cat /etc/openbao/unseal.key)'

[Install]
WantedBy=multi-user.target
UNSEAL_UNIT

	systemctl daemon-reload

	echo "#####################"
	echo "✔ OpenBao service units written"
}

main
