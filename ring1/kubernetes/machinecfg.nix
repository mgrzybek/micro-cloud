{
    pkgs ? import <nixpkgs> {},
    version ? "unstable",
    tag ? "latest"
}:

let
  machinecfg-src = pkgs.fetchgit {
    url = "https://github.com/mgrzybek/machinecfg.git";
    hash = "sha256-5TyQRkVLgprjSGwuGMyudCJh8/oA49tPG11T5HPXbyQ=";
  };

  machinecfg-package = pkgs.buildGoModule {
    pname = "machinecfg";
    version = "${version}";
    src = machinecfg-src;

    # Let's create a static binary
    buildFlagsArray = [ "-ldflags" "-s -w" ]; 

    vendorHash = "sha256-Pfmvw1SAO/YssLTJwTfc/2DQKATnMA9srBTYBG7FYYU=";
    
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
