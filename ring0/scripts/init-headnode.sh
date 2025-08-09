#! /usr/bin/env bash

set -e

function install_tailscale() {
	echo "#####################"
	echo "👷 Installing Tailscale"
	echo

	curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/plucky.noarmor.gpg |
		sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
	curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/plucky.tailscale-keyring.list |
		sudo tee /etc/apt/sources.list.d/tailscale.list
	sudo apt update
	sudo apt install tailscale

	echo "#####################"
	echo "👷 Connecting using QR code"
	echo

	tailscale login --qr

	echo
	echo "✔ Tailscale status"
	echo

	tailscale status | grep headnode

	echo
	echo "✔ Environment ready"
	echo
}

function install_incus() {
	echo "#####################"
	echo "👷 Installing Incus"
	echo

	TAILSCALE_IPADDR=$(tailscale status | grep $HOSTNAME | awk '{print $1}')

	sudo apt -y install incus
	sudo incus admin init
	sudo adduser $USER incus-admin
	newgrp incus-admin

	incus config set core.https_address $TAILSCALE_IPADDR

	echo
	echo "✔ Incus ready"
	echo
}

install_tailscale
install_incus
