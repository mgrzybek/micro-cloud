{
    pkgs ? import <nixpkgs> {},
    version ? "unstable",
    tag ? "latest"
}:

let
  machinecfg-src = pkgs.fetchgit {
    url = "https://github.com/mgrzybek/machinecfg.git";
    hash = "sha256-Qrdb5cIgMBzTU5jeg40NaOKivD55BkrCLoHTGXqw8/A=";
  };

  machinecfg-package = pkgs.buildGo125Module {
    pname = "machinecfg";
    version = "${version}";
    src = machinecfg-src;

    # Let's create a static binary
    buildFlagsArray = [ "-ldflags" "-s -w" ]; 

    vendorHash = "sha256-aqp0BD5Wrrw50ioA6AAy2s4DQeubt4tuth2qwvEKUyU=";
  };

in {
  machinecfg-oci = pkgs.dockerTools.buildImage {
    name = "machinecfg";
    tag = "${tag}";

    copyToRoot = pkgs.buildEnv {
      name = "image-root-copy";
      paths = [
        machinecfg-package
      ];
    };

    config = {
      Cmd = [ "/bin/machinecfg/bin/machinecfg" ];
      User = "1000:1000"; 
    };
  };
}
