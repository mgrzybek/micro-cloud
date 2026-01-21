#! /usr/bin/env bash

function main() {
	set -e

	if ! which docker; then
		install_docker
	fi
}

function install_docker() {
	echo "#####################"
	echo "👷 Installing docker"

	for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove $pkg; done
	sudo apt-get update
	sudo apt-get install ca-certificates curl golang
	sudo install -m 0755 -d /etc/apt/keyrings
	sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
	sudo chmod a+r /etc/apt/keyrings/docker.asc
	echo \
		"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
		sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
	sudo apt-get update
	sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

	go install github.com/wagoodman/dive@latest
}

main
