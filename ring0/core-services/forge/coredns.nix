{
  pkgs ? import <nixpkgs> {}
}:

let
  version = "1.11.1";
  githubHash = "sha256-XZoRN907PXNKV2iMn51H/lt8yPxhPupNfJ49Pymdm9Y=";
  vendorHash = "sha256-7iDKLBzE7K1sYIqBjHFUbz5srGQlOe+c87C5sQi0xXM=";

  description = "CoreDNS with Netbox support";
  homepage = "https://coredns.io";
  license = pkgs.lib.licenses.asl20;

  coredns-package = pkgs.buildGoModule rec {
    inherit version;
    inherit vendorHash;

    pname = "coredns";

    meta = with pkgs.lib; {
      description = description;
      homepage = homepage;
      license = license;
    };

    src = pkgs.fetchFromGitHub {
      owner = "coredns";
      repo = "coredns";
      rev = "v${version}";
      sha256 = githubHash;
    };

    proxyVendor = true;
    doCheck = false;

    postPatch = ''
      echo netbox:github.com/oz123/coredns-netbox-plugin >> plugin.cfg
    '';

    preBuild = ''
      go get github.com/oz123/coredns-netbox-plugin
      go generate
    '';
  };

in {
  coredns-oci = pkgs.dockerTools.buildImage {
    name = "coredns-netbox";
    tag = version;
  
    copyToRoot = pkgs.buildEnv {
      name = "image-root-copy";
      paths = [
        coredns-package
  		  pkgs.cacert
      ];
    };

    config = {
      Cmd = [ "/bin/coredns" "-conf" "/etc/coredns/Corefile" ];

      ExposedPorts = {
        "53/tcp" = {};
        "53/udp" = {};
        "9153/tcp" = {};
      };

      Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];

      Labels = {
        "org.opencontainers.image.description" = description;
        "org.opencontainers.image.licenses" = license.fullName;
        "org.opencontainers.image.source" = homepage;
        "version" = version;
      };
    };
  };
}