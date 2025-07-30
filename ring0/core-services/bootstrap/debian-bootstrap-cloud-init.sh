#! /usr/bin/env bash

function main() {
	set -e

	prepare

	install_kea

	install_go

	install_matchbox
	prepare_matchbox_ipxe
	prepare_matchbox_flatcar
	prepare_matchbox_talos

	install_machinecfg
	install_butane

	echo "✔ cloud-init ended successfully"
}

############################################################################
# Installing

function install_go() {
	echo "#####################"
	echo "👷 Installing go"

	export PATH=$PATH:/usr/local/go/bin
	export GO_ARCHIVE=go1.24.4.linux-amd64.tar.gz

	if ! which go ; then
		if [[ ! -f "$GO_ARCHIVE" ]] ; then
			cd ~
			wget "https://go.dev/dl/$GO_ARCHIVE"
			rm -rf /usr/local/go && tar -C /usr/local -xzf "$GO_ARCHIVE"
			cd -
		fi

		echo "export PATH=$PATH:/usr/local/go/bin" >> /etc/profile

		rm -rf /tmp/go-build*
	fi

	echo
	echo "✔ Checking binaries and services"
	which go
	go version

	echo
}

function install_kea() {
	echo "#####################"
	echo "👷 Installing kea dhcp server"

	if ! which /usr/sbin/kea-dhcp4 ; then
		mkdir -p /etc/systemd/system/kea-dhcp4-server.d
		cat <<EOF | tee /etc/systemd/system/kea-dhcp4-server.d/networking.conf
[Service]
After=bootstrap-network.service
EOF

		apt install -y kea

	   	cat <<EOF | tee /etc/kea/kea-dhcp4.conf
{
    "Dhcp4": {
        "valid-lifetime": 4000,
        "renew-timer": 1000,
        "rebind-timer": 2000,
        "interfaces-config": {
            "interfaces": [
                "eth1"
            ]
        },
        "lease-database": {
            "type": "memfile",
            "persist": true,
            "name": "/var/lib/kea/dhcp4.leases"
        },
        "client-classes": [
            {
                "name": "XClient_iPXE",
                "test": "substring(option[77].hex,0,4) == 'iPXE'",
                "boot-file-name": "http://$SERVER_ADDR:8080/boot.ipxe"
            },
            {
                "name": "HTTPClient",
                "test": "option[93].hex == 0x0010",
                "option-data": [
                    {
                        "name": "vendor-class-identifier",
                        "data": "HTTPClient"
                    }
                ],
                "boot-file-name": "http://$SERVER_ADDR:8080/assets/ipxe.efi"
            }
        ],
        "subnet4": [
            {
                "subnet": "$SERVER_CIDR",
                "pools": [
                    {
                        "pool": "192.168.2.100 - 192.168.2.150",
                        "option-data": [
                            {
                                "name": "ntp-servers",
                                "data": "$NTP_ADDR"
                            },
                            {
                                "name": "log-servers",
                                "data": "$LOG_ADDR"
                            }
                        ]
                    }
                ],
                "reservations": []
            }
        ]
    }
}
EOF
		systemctl daemon-reload

    	systemctl enable bootstrap-network.service
    	systemctl start bootstrap-network.service

		systemctl disable kea-ctrl-agent.service kea-dhcp-ddns-server.service
		systemctl stop kea-ctrl-agent.service kea-dhcp-ddns-server.service

		systemctl enable kea-dhcp4-server.service
		systemctl restart kea-dhcp4-server.service
	fi

	echo "✔ Checking services"
	systemctl status kea-dhcp4-server.service
	echo
}

function install_matchbox() {
	echo "#####################"
	echo "👷 Installing matchbox"

	if ! which matchbox ; then
		cd ~

		if ! grep -q matchbox /etc/group ; then
			groupadd matchbox
		fi
		if ! grep -q matchbox /etc/passwd ; then
			useradd -M -d /var/lib/matchbox -g matchbox matchbox
		fi

		mkdir -p /etc/matchbox /var/lib/matchbox/{profiles,groups,ignition,assets}
		chown -R matchbox:matchbox /var/lib/matchbox

		latest_tag=$(curl -v https://github.com/poseidon/matchbox/releases/latest/download/matchbox 2>&1 | awk -F/ '/location/ {print $(NF-1)}')
		if [[ ! -d matchbox ]] ; then
			git clone --branch "$latest_tag" https://github.com/poseidon/matchbox.git
		fi

		cd matchbox
		make build
		cp bin/matchbox /usr/local/bin
		sed "s/0.0.0.0/$SERVER_ADDR/" contrib/systemd/matchbox.service | tee /etc/systemd/system
		systemctl daemon-reload
		systemctl enable matchbox
		systemctl start matchbox
		cd -

		rm -rf /tmp/go-build*
	fi

	echo
	echo "✔ Checking binaries and services"
	systemctl status matchbox
	echo
}

function install_machinecfg() {
	echo "#####################"
	echo "👷 Installing machinecfg"

	cd ~

	if [[ ! -d machinecfg ]] ; then
		git clone https://github.com/mgrzybek/machinecfg.git
	fi

	cd machinecfg
	make
	cp machinecfg /usr/local/bin
	cd -

	rm -rf /tmp/go-build*

	echo
	echo "✔ Checking binaries"
	which machinecfg
	echo
}

function install_butane() {
	echo "#####################"
	echo "👷 Installing butane"

	cd ~

	if ! which butane ; then
		latest_tag=$(curl -v https://github.com/coreos/butane/releases/latest/download/butane 2>&1 | awk -F/ '/location/ {print $(NF-1)}')

		cd /usr/local/bin
		wget https://github.com/coreos/butane/releases/download/$latest_tag/butane-x86_64-unknown-linux-gnu
		chmod +x butane-x86_64-unknown-linux-gnu
		mv butane-x86_64-unknown-linux-gnu butane
	fi

	echo
	echo "✔ Checking binaries"
	which butane
	echo
}

function install_talosctl {
	echo "#####################"
	echo "👷 Installing talosctl"

	cd ~

	if ! which talosctl ; then
		latest_tag=$(curl -v https://github.com/siderolabs/talos/releases/latest/download/talosctl 2>&1 | awk -F/ '/location/ {print $(NF-1)}')

		cd /usr/local/bin
		wget https://github.com/siderolabs/talos/releases/download/$latest_tag/talosctl-linux-amd64
		mv talosctl-linux-amd64 talosctl
		chmod +x talosctl
	fi

	echo
	echo "✔ Checking binaries"
	which talosctl
	echo
}

############################################################################
# Preparing

function prepare() {
	echo "#####################"
	echo "👷 Preparing the environment"

    export HOME=/root

	CLOUD_CONFIG=/etc/cloud.sh

	if [[ ! -f "$CLOUD_CONFIG" ]] ; then
		echo "$CLOUD_CONFIG must be present"
		exit 1
	fi

	source "$CLOUD_CONFIG"

	if [[ -z "$SERVER_ADDR" ]] ; then
		echo "SERVER_ADDR must be given"
	fi

	if ! which curl ; then
		apt update
		apt -y install curl git make wget gcc liblzma-dev
	fi

	if ! ip addr show | grep -q "$SERVER_ADDR" ; then
		echo "#####################"
		echo "👷 Configuring the netboot iface"

		cat <<EOF | tee /etc/systemd/system/bootstrap-network.service
[Unit]
Description=Bootstrap network configuration
Wants=network-online.target
After=network-online.target

[Install]
RequiredBy=kea-dhcp4-server.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c "ip addr add dev eth1 $SERVER_CIDR"
EOF
	fi

}

function prepare_matchbox_ipxe() {
	echo "#####################"
	echo "👷 Installing iPXE assets for matchbox"

	assets=/var/lib/matchbox/assets

	mkdir -p $assets

	cd ~
	if [[ ! -d ipxe ]] ; then
		git clone https://github.com/ipxe/ipxe.git
	fi
	cd ipxe/src
	make -j$(nproc) bin-x86_64-efi/ipxe.efi
	cp bin-x86_64-efi/ipxe.efi /var/lib/matchbox/assets/ipxe.efi

	echo
	echo "✔ Checking binaries"
	find "$assets" -name ipxe.efi
	echo
}

function download_talos() {
	download_if_needed "$TALOS_FACTORY_URL/image/$TALOS_FACTORY_UUID/$TALOS_VERSION" "kernel-amd64"
	download_if_needed "$TALOS_FACTORY_URL/image/$TALOS_FACTORY_UUID/$TALOS_VERSION" "initramfs-amd64.xz"

	echo "VERSION=$TALOS_VERSION" > talos.conf
	echo "FACTORY_UUID=$TALOS_FACTORY_UUID" >> talos.conf
}

function download_if_needed() {
	local base_url=$1
	local file=$2

	if [[ ! -f "$file" ]] ; then
		wget "$base_url/$file"
	fi
}

function prepare_matchbox_talos() {
	echo "#####################"
	echo "👷 Installing talos assets for matchbox"

	assets=/var/lib/matchbox/assets
	groups=/var/lib/matchbox/groups
	profiles=/var/lib/matchbox/profiles

	mkdir -p $assets/talos
	cd $assets/talos

	if [ -f talos.conf ] ; then
		source talos.conf

		if [[ ! "$VERSION" == "$TALOS_VERSION" ]] ; then
			rm -f kerned-amd64 initramfs-amd64.xz
		fi

		if [[ ! "$FACTORY_UUID" == "$TALOS_FACTORY_UUID" ]] ; then
			rm -f kerned-amd64 initramfs-amd64.xz
		fi
	else
		rm -f kerned-amd64 initramfs-amd64.xz
	fi

	download_talos

  cat <<EOF > "$profiles/talos.json"
{
  "id": "talos",
  "name": "Talos Linux live instance",
  "boot": {
    "kernel": "/assets/talos/kernel-amd64",
    "initrd": [
		"/assets/talos/initramfs-amd64.xz"
    ],
    "args": [
		"talos.platform=metal",
		"talos.config=http://$SERVER_ADDR:8080/assets/talos/\${hostname}.yaml",
		"console=tty0",
		"console=ttyS0",
		"init_on_alloc=1",
		"slab_nomerge",
		"pti=on",
		"consoleblank=0",
		"nvme_core.io_timeout=4294967295",
		"printk.devkmsg=on",
		"ima_template=ima-ng",
		"ima_appraise=fix",
		"ima_hash=sha512",
		"selinux=0"
    ]
},
  "ignition_id": ""
}
EOF

  cat <<EOF > "$groups/talos.json"
{
  "id": "talos",
  "name": "Talos Linux",
  "profile": "talos",
  "selector": {},
  "metadata": {}
}
EOF

  echo
  echo "✔ Checking files"
  find /var/lib/matchbox
  echo
}

function prepare_matchbox_flatcar() {
	echo "#####################"
	echo "👷 Installing flatcar assets for matchbox"

	base_url=https://stable.release.flatcar-linux.net/amd64-usr/current
	version=$(curl -s $base_url/version.txt | awk -F= '/FLATCAR_VERSION=/ {print $2}')

	assets=/var/lib/matchbox/assets/flatcar
	groups=/var/lib/matchbox/groups
	profiles=/var/lib/matchbox/profiles
	ignition=/var/lib/matchbox/ignition

	mkdir -p "$assets" "$groups" "$profiles" "$ignition"

	echo
	echo "👷 Downloading flatcar assets"
	echo

	cd "$assets"
	mkdir -p "$assets/$version"
	if [[ ! -e current ]] ; then
		ln -s "$version" current
	fi

	cd "$assets/$version"
	download_if_needed "$base_url" "version.txt"
	download_if_needed "$base_url" "flatcar_production_pxe.vmlinuz"
	download_if_needed "$base_url" "flatcar_production_pxe.vmlinuz.sig"
	download_if_needed "$base_url" "flatcar_production_pxe_image.cpio.gz"
	download_if_needed "$base_url" "flatcar_production_pxe_image.cpio.gz.sig"
	download_if_needed "$base_url" "flatcar_production_image.bin.bz2"
	download_if_needed "$base_url" "flatcar_production_image.bin.bz2.sig"

  echo "✔ Checking binaries"
  find $assets
  echo
}


############################################################################
# Main

main
