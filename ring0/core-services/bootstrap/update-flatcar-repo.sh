#!/usr/bin/env bash

set -euo pipefail

function download_if_needed() {
	local base_url=$1
	local file=$2

	if [[ ! -f "$file" ]]; then
		wget "$base_url/$file"
	fi
}

function prepare_matchbox_flatcar() {
	echo "#####################"
	echo "👷 Installing flatcar assets for matchbox"

	base_url=https://flatcar.cdn.cncf.io/stable/amd64-usr/current
	version=$(curl -s $base_url/version.txt | awk -F= '/FLATCAR_VERSION=/ {print $2}')

	if [ -z "$version" ]; then
		echo "Cannot find flatcar version from $base_url/version.txt"
		return 1
	fi

	assets=/var/lib/matchbox/assets/flatcar
	groups=/var/lib/matchbox/groups
	profiles=/var/lib/matchbox/profiles
	ignition=/var/lib/matchbox/ignition

	mkdir -p "$assets" "$groups" "$profiles" "$ignition"

	echo
	echo "👷 Downloading flatcar assets"
	echo

	cd "$assets" || return 1
	if [ ! -d "$version" ]; then
		rm -f current
		mkdir -p "$assets/$version"
		ln -s "$version" current

		cd "$assets/$version" || return 1
		download_if_needed "$base_url" "version.txt"
		download_if_needed "$base_url" "flatcar_production_pxe.vmlinuz"
		download_if_needed "$base_url" "flatcar_production_pxe.vmlinuz.sig"
		download_if_needed "$base_url" "flatcar_production_pxe_image.cpio.gz"
		download_if_needed "$base_url" "flatcar_production_pxe_image.cpio.gz.sig"
		download_if_needed "$base_url" "flatcar_production_image.bin.bz2"
		download_if_needed "$base_url" "flatcar_production_image.bin.bz2.sig"
	fi

	echo "✔ Checking artifacts"
	find "$assets/$version"
	echo
}

prepare_matchbox_flatcar
