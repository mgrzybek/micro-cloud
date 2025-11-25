{
    pkgs ? import <nixpkgs> {},
}:

let
in {
	image = pkgs.dockerTools.buildImage {
		name = "butane";
		tag = "latest";

		copyToRoot = pkgs.buildEnv {
			name = "binaries";
			paths = [
				pkgs.butane
			];
			pathsToLink = [ "/bin" ];
		};

		config = {
			Cmd = [
				"${pkgs.butane}/bin/butane"
			];
		};
	};
}
