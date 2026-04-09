{
    pkgs ? import <nixpkgs> {},
}:

let
in {
    image = pkgs.dockerTools.buildImage {
        name = "tpm2-tools";
        tag = "latest";

        copyToRoot = pkgs.buildEnv {
            name = "binaries";
            paths = [
                pkgs.bash
                pkgs.coreutils
                pkgs.curl
                pkgs.tpm2-tools
                pkgs.tpm2-tss
            ];
            pathsToLink = [ "/bin" "/lib" "/etc" ];
        };

        config = {
            Cmd = [ "${pkgs.bash}/bin/bash" ];
        };
    };
}
