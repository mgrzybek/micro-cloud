#! /usr/bin/env bash

set -euo pipefail

################################################################################
# External libraries
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"

################################################################################
# Prerequisites checks

for var in \
	TS_SUFFIX \
	PKI_ENDPOINT \
	PKI_ORG \
	TS_OPERATOR_CLIENT_ID \
	TS_OPERATOR_CLIENT_SECRET \
	DNS_IP \
	HOOKOS_IP \
	REGISTRY_IP \
	TINKERBELL_IP \
	ARTIFACTS_FILE_SERVER \
	DHCP_BIND_INTERFACE \
	BOOTSTRAP_ENDPOINT \
	ANNOUNCEMENTS_IFACE \
	GITHUB_ACTOR \
	GHCR_TOKEN \
	TRUENAS_HOSTNAME \
	TRUENAS_POOL; do
	if [[ -z "${!var:-}" ]]; then
		echo "ERROR: $var must be defined"
		exit 1
	fi
done

for file in \
	"$RING0_ROOT/dist/bundle.crt" \
	"$RING0_ROOT/dist/openbao-approle-role-id" \
	"$RING0_ROOT/dist/openbao-approle-secret-id" \
	"$RING0_ROOT/dist/openbao-eso-role-id" \
	"$RING0_ROOT/dist/openbao-eso-secret-id"; do
	if [[ ! -f "$file" ]]; then
		echo "ERROR: $file missing — run task intermediate-fullchain first"
		exit 1
	fi
done

print_milestone "Deploying FluxCD Operator and bootstrapping GitOps for ring0"

################################################################################
# Step 1 — Create ghcr.io pull secret so Flux can pull the OCI artifact

print_step "Creating ghcr-auth pull secret in flux-system"
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl get secret -n flux-system ghcr-auth >/dev/null 2>&1; then
	kubectl create secret docker-registry ghcr-auth \
		--namespace flux-system \
		--docker-server=ghcr.io \
		--docker-username="$GITHUB_ACTOR" \
		--docker-password="$GHCR_TOKEN"
fi
print_check "ghcr-auth pull secret created"

################################################################################
# Step 2 — Create per-namespace cluster-config ConfigMaps
#
# helm.toolkit.fluxcd.io/v2 HelmRelease.spec.valuesFrom does not support
# cross-namespace ConfigMap references (the referent must be in the same
# namespace as the HelmRelease), so each consuming namespace gets its own
# cluster-config ConfigMap with only the keys it needs.

openbao_ca_bundle="$(base64 <"$RING0_ROOT/dist/bundle.crt" | tr -d '\n')"

print_step "Creating cluster-config ConfigMap in flux-system"
kubectl create configmap cluster-config \
	--namespace flux-system \
	--from-literal="pki_endpoint=$PKI_ENDPOINT" \
	--from-literal="pki_org=$PKI_ORG" \
	--from-literal="openbao_ca_bundle=$openbao_ca_bundle" \
	--from-literal="dns_ip=$DNS_IP" \
	--from-literal="registry_ip=$REGISTRY_IP" \
	--from-literal="idp_hostname=idp.$TS_SUFFIX" \
	--dry-run=client -o yaml | kubectl apply -f -
print_check "cluster-config ConfigMap created in flux-system"

print_step "Creating cluster-config ConfigMap in kube-system"
kubectl create configmap cluster-config \
	--namespace kube-system \
	--from-literal="announcements_iface=$ANNOUNCEMENTS_IFACE" \
	--from-literal="management_hostname=management.$TS_SUFFIX" \
	--dry-run=client -o yaml | kubectl apply -f -
print_check "cluster-config ConfigMap created in kube-system"

print_step "Creating cluster-config ConfigMap in platform-management"
kubectl create namespace platform-management --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap cluster-config \
	--namespace platform-management \
	--from-literal="ts_suffix=$TS_SUFFIX" \
	--dry-run=client -o yaml | kubectl apply -f -
print_check "cluster-config ConfigMap created in platform-management"

print_step "Creating cluster-config ConfigMap in tinkerbell-system"
kubectl create namespace tinkerbell-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap cluster-config \
	--namespace tinkerbell-system \
	--from-literal="dhcp_bind_interface=$DHCP_BIND_INTERFACE" \
	--from-literal="bootstrap_endpoint=$BOOTSTRAP_ENDPOINT/assets/tinkerbell" \
	--from-literal="hookos_ip=$HOOKOS_IP" \
	--from-literal="tinkerbell_ip=$TINKERBELL_IP" \
	--from-literal="artifacts_file_server=$ARTIFACTS_FILE_SERVER" \
	--dry-run=client -o yaml | kubectl apply -f -
print_check "cluster-config ConfigMap created in tinkerbell-system"

################################################################################
# Step 3 — Create per-component secrets

print_step "Creating Tailscale operator OAuth secret"
kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl get secret -n tailscale tailscale-operator-oauth >/dev/null 2>&1; then
	kubectl create secret generic tailscale-operator-oauth \
		--namespace tailscale \
		--from-literal="clientId=$TS_OPERATOR_CLIENT_ID" \
		--from-literal="clientSecret=$TS_OPERATOR_CLIENT_SECRET"
fi
print_check "tailscale-operator-oauth secret created"

print_step "Creating cert-manager OpenBao AppRole secret"
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
approle_role_id="$(cat "$RING0_ROOT/dist/openbao-approle-role-id")"
approle_secret_id="$(cat "$RING0_ROOT/dist/openbao-approle-secret-id")"
if ! kubectl get secret -n cert-manager openbao-approle >/dev/null 2>&1; then
	kubectl create secret generic openbao-approle \
		--namespace cert-manager \
		--from-literal="secretId=$approle_secret_id"
fi
if ! kubectl get configmap -n cert-manager internal-ca-chain >/dev/null 2>&1; then
	kubectl create configmap internal-ca-chain \
		--namespace cert-manager \
		--from-file="key=$RING0_ROOT/dist/bundle.crt"
fi
print_check "cert-manager secrets created"

print_step "Creating ESO OpenBao AppRole secret"
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
eso_role_id="$(cat "$RING0_ROOT/dist/openbao-eso-role-id")"
eso_secret_id="$(cat "$RING0_ROOT/dist/openbao-eso-secret-id")"
if ! kubectl get secret -n external-secrets openbao-eso-approle >/dev/null 2>&1; then
	kubectl create secret generic openbao-eso-approle \
		--namespace external-secrets \
		--from-literal="secretId=$eso_secret_id"
fi
print_check "ESO secrets created"

print_step "Creating Authentik secret_key"
kubectl create namespace platform-management --dry-run=client -o yaml | kubectl apply -f -
if [[ ! -f "$RING0_ROOT/dist/authentik-secret-key" ]]; then
	openssl rand -base64 50 | tr -d '\n' >"$RING0_ROOT/dist/authentik-secret-key"
fi
if ! kubectl get secret -n platform-management authentik-secret >/dev/null 2>&1; then
	kubectl create secret generic authentik-secret \
		--namespace platform-management \
		--from-literal="secret_key=$(cat "$RING0_ROOT/dist/authentik-secret-key")"
fi
print_check "authentik-secret created"

################################################################################
# Step 4 — Create ClusterIssuer and ClusterSecretStore (outside Flux management)

print_step "Creating cert-manager ClusterIssuer"
kubectl apply -f - <<ISSUER
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao-internal-ca
spec:
  vault:
    path: pki_int/sign/microcloud-host
    server: $PKI_ENDPOINT
    caBundle: "$openbao_ca_bundle"
    auth:
      appRole:
        path: approle
        roleId: "$approle_role_id"
        secretRef:
          name: openbao-approle
          key: secretId
ISSUER
print_check "ClusterIssuer openbao-internal-ca created"

print_step "Creating ESO ClusterSecretStore"
kubectl apply -f - <<STORE
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
spec:
  provider:
    vault:
      server: "$PKI_ENDPOINT"
      path: "secret"
      version: "v2"
      caBundle: "$openbao_ca_bundle"
      auth:
        appRole:
          path: approle
          roleId: "$eso_role_id"
          secretRef:
            namespace: external-secrets
            name: openbao-eso-approle
            key: secretId
STORE
print_check "ClusterSecretStore openbao created"

# The truenas-csi v1.1+ schema splits pool and dataset: defaultPool is the ZFS
# pool name alone, while the StorageClass datasetPath is the parent path
# relative to that pool (no pool prefix). TRUENAS_POOL stays the full dataset
# path (e.g. pool1/csi/nfs); split it into "pool1" and "csi/nfs" here.
truenas_default_pool="${TRUENAS_POOL%%/*}"
truenas_dataset_path=""
[[ "$TRUENAS_POOL" == */* ]] && truenas_dataset_path="${TRUENAS_POOL#*/}"

print_step "Creating truenas-csi-config ConfigMap"
kubectl create namespace truenas-csi --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap truenas-csi-config \
	--namespace truenas-csi \
	--from-literal="truenasURL=wss://$TRUENAS_HOSTNAME.$TS_SUFFIX/api/current" \
	--from-literal="truenasInsecure=true" \
	--from-literal="defaultPool=$truenas_default_pool" \
	--from-literal="nfsServer=$TRUENAS_HOSTNAME.$TS_SUFFIX" \
	--from-literal="iscsiPortal=$TRUENAS_HOSTNAME.$TS_SUFFIX:3260" \
	--dry-run=client -o yaml | kubectl apply -f -
print_check "truenas-csi-config ConfigMap created"

# StorageClass parameters are immutable, so `kubectl apply` fails (and aborts
# this script under `set -e`) whenever datasetPath changes — which also skips
# the truenas-iscsi block below. `replace --force` recreates the object instead;
# deleting a StorageClass does not affect already-bound PVs/PVCs.
print_step "Creating truenas-nfs StorageClass"
kubectl replace --force -f - <<STORAGECLASS
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-nfs
provisioner: csi.truenas.io
parameters:
  protocol: "nfs"
  datasetPath: "$truenas_dataset_path"
  compression: "LZ4"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
STORAGECLASS
print_check "truenas-nfs StorageClass created"

print_step "Creating truenas-iscsi StorageClass"
kubectl replace --force -f - <<STORAGECLASS
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-iscsi
provisioner: csi.truenas.io
parameters:
  protocol: "iscsi"
  datasetPath: "$truenas_dataset_path"
  compression: "LZ4"
  csi.storage.k8s.io/fstype: "ext4"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
STORAGECLASS
print_check "truenas-iscsi StorageClass created"

################################################################################
# Step 5 — Install Flux Operator via Helm

print_step "Installing FluxCD Operator"
helm repo add flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts >/dev/null 2>&1 || true
if ! helm list -n flux-system -o json | jq -e '.[] | select(.name=="flux-operator" and .status=="deployed")' >/dev/null 2>&1; then
	helm install flux-operator \
		oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
		--namespace flux-system \
		--create-namespace \
		--wait
fi
print_check "FluxCD Operator installed"

################################################################################
# Step 6 — Apply FluxInstance

print_step "Applying FluxInstance"
kubectl apply -f "$RING0_ROOT/flux/clusters/management/flux-system/flux-instance.yaml"
print_check "FluxInstance applied — Flux will now reconcile ring0 from OCI"

print_check "Bootstrap complete. Monitor with: flux get all -A"
