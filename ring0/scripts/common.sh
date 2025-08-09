#! /usr/bin/env bash

function print_milestone() {
	echo
	echo "##########################################"
	echo "👷 $1"
	echo
}

function print_step() {
	echo
	echo "👷 $1"
	echo
}

function print_check() {
	echo
	echo "✔ $1"
}

export RING0_ROOT="$(dirname $0)/.."
export MANIFESTS_PATH=$RING0_ROOT/core-services/management/manifests

export TS_SUFFIX=$(tailscale dns status | awk '/suffix =/ {gsub(")","");print $NF}')
export PKI_IPADDR=$(incus list | awk '/pki/ {print $6}')
export PKI_ENDPOINT=https://$PKI_IPADDR:8000
