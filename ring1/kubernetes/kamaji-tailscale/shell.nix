{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Infrastructure as Code
    opentofu

    # Kubernetes
    kubectl
    kubernetes
    kubernetes-helm
    cmctl

    # Cloud & Mesh VPN
    google-cloud-sdk
    tailscale

    # Tooling
    jq
    yq-go
    openssl
    go-task
    jinja2-cli
  ];

  shellHook = ''
    echo "--- Kamaji / GCP / Tailscale ---"
    echo "Gcloud:   $(gcloud --version | head -n 1)"
    echo "OpenTofu: $(tofu --version | head -n 1)"
    echo "Kubectl:  $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    echo "----------------------------------------------"

    # Aliases
    alias k='kubectl'
    alias tf='tofu'

    # Checking GCP authentification
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
      echo "⚠️ Warning: you are not connected. You should use 'gcloud auth application-default login'"
    fi

    tofu init
  '';
}
