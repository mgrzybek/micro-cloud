{
    pkgs ? import <nixpkgs> {},
}:

let
in {
	image = pkgs.dockerTools.buildImage {
		name = "debootstrap";
		tag = "latest";

		copyToRoot = pkgs.buildEnv {
			name = "binaries";
			paths = [
                pkgs.bash
                pkgs.coreutils
				pkgs.debootstrap
                pkgs.mount
                pkgs.umount
			];
			pathsToLink = [ "/bin" ];
		};

		config = {};
	};
}
