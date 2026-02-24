{
    pkgs ? import <nixpkgs> {},
}:

let
  version = "0.25.0";
  tag = version ;
  coreos-installer-src = pkgs.fetchgit {
    url = "https://github.com/coreos/coreos-installer.git";
	  rev = "v${version}";
    hash = "sha256-vz55U3GSmBSp7jMREtwhE+mDbGkUOgOTlrG1F0oVVz8=";
  };

  coreos-installer-package = pkgs.rustPlatform.buildRustPackage {
    inherit version;

    pname = "coreos-installer";
    src = coreos-installer-src;
  	cargoLock.lockFile = "${coreos-installer-src}/Cargo.lock";

    nativeBuildInputs = [
      pkgs.pkg-config
    ];

    buildInputs = [
  		pkgs.openssl
  		pkgs.zstd
	  ];

  	OPENSSL_NO_VENDOR = 1;
    ZSTD_SYS_USE_PKG_CONFIG = 1;
  };

in {
  coreos-installer-oci = pkgs.dockerTools.buildImage {
    name = "coreos-installer";
    tag = "${tag}";

    copyToRoot = pkgs.buildEnv {
      name = "image-root-copy";
      paths = [
        coreos-installer-package
    		pkgs.openssl
		    pkgs.zstd
      ];
    };

    config = {
      Cmd = [ "/bin/coreos-installer/bin/coreos-installer" ];
      User = "1000:1000"; 
    };
  };
}
