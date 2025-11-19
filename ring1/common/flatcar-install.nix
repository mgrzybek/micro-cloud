{
    pkgs ? import <nixpkgs> {},
}:

let
	scriptUrl = "https://raw.githubusercontent.com/flatcar-linux/init/flatcar-master/bin/flatcar-install";
	scriptHash = "sha256-08j70nppql01008xbsfsvh3iqfqh42842ymk8g7b38lkgw6m5f1s";

	flatcarInstallScript = pkgs.runCommand "flatcar-install" { } ''
		${pkgs.wget}/bin/wget --no-check-certificate -O $out ${scriptUrl}
		chmod +x $out
	'';
	flatcarWrapper = pkgs.writeShellScriptBin "flatcar-install.sh" ''
		${pkgs.bash}/bin/bash ${flatcarInstallScript} $@
	'';
in {
	image = pkgs.dockerTools.buildImage {
		name = "flatcar-install";
		tag = "latest";

		copyToRoot = pkgs.buildEnv {
			name = "binaries";
			paths = [
				flatcarWrapper
				pkgs.bash
				pkgs.btrfs-progs
				pkgs.bzip2
				pkgs.coreutils
				pkgs.efibootmgr
				pkgs.gawk
				pkgs.gnused
				pkgs.gnugrep
				pkgs.gnupg
				pkgs.lvm2
				pkgs.systemdMinimal
				pkgs.udev
				pkgs.util-linux
				pkgs.wget
			];
			pathsToLink = [ "/bin" ];
		};

		config = {
			Cmd = [
				"${flatcarInstallScript}"
			];
		};
	};
}
