{
    pkgs ? import <nixpkgs> {},
}:

let
in {
	image = pkgs.dockerTools.buildImage {
		name = "cloud-init";
		tag = "latest";

		copyToRoot = pkgs.buildEnv {
			name = "binaries";
			paths = [
				pkgs.cloud-init
			];
			pathsToLink = [ "/bin" ];
		};

		config = {
			Cmd = [
				"${pkgs.cloud-init}/bin/cloud-init"
			];
		};
	};
}
