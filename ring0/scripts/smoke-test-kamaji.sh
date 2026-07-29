#! /usr/bin/env bash

set -euo pipefail

################################################################################
# External libraries
# shellcheck source=/dev/null
source "$RING0_ROOT/scripts/common.sh"

################################################################################
# Smoke-tests the kamaji + kamaji-etcd pipeline by provisioning a throwaway
# TenantControlPlane backed by the "microcloud" DataStore, waiting for it to
# become Ready, then tearing it down. Useful after any change to the kamaji
# HelmReleases (ring0/flux/apps/05-bmaas/kamaji/) to confirm the control
# plane and its etcd backend still bootstrap end to end.

NAMESPACE="kamaji-smoke-test"
TCP_NAME="smoke-test"
# The deployed kamaji chart/image versions are printed as part of this
# script's output — cross-check them against
# ring0/flux/apps/05-bmaas/kamaji/helmrelease.yaml before bumping this
# default, since Kamaji rejects TenantControlPlanes above certain versions.
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.30.2}"
MANIFEST="$(mktemp)"

function cleanup() {
	kubectl delete -f "$MANIFEST" --ignore-not-found >/dev/null 2>&1 || true
	kubectl delete namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
	rm -f "$MANIFEST"
}
trap cleanup EXIT

print_step "Checking kamaji + kamaji-etcd HelmReleases are Ready"
for release in kamaji kamaji-etcd; do
	if ! kubectl -n kamaji-system wait "helmrelease/$release" \
		--for=condition=Ready --timeout=60s >/dev/null 2>&1; then
		echo "ERROR: HelmRelease $release is not Ready" >&2
		kubectl -n kamaji-system get "helmrelease/$release" -o yaml
		exit 1
	fi
done

print_step "Deployed kamaji controller image"
kubectl -n kamaji-system get deployment kamaji \
	-o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

print_step "Creating $NAMESPACE namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

print_step "Provisioning throwaway TenantControlPlane $TCP_NAME"
cat >"$MANIFEST" <<EOF
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: $TCP_NAME
  namespace: $NAMESPACE
spec:
  controlPlane:
    deployment:
      replicas: 1
    service:
      serviceType: ClusterIP
  dataStore: microcloud
  kubernetes:
    version: "$KUBERNETES_VERSION"
    kubelet:
      cgroupfs: systemd
  networkProfile:
    port: 6443
    serviceCidr: 172.27.0.0/24
    podCidr: 172.28.0.0/16
    dnsServiceIPs:
      - 172.27.0.10
EOF
kubectl apply -f "$MANIFEST"

print_step "Waiting for TenantControlPlane to become Ready (timeout 300s)"
elapsed=0
timeout=300
while true; do
	status="$(kubectl -n "$NAMESPACE" get tcp "$TCP_NAME" -o jsonpath='{.status.kubernetesResources.version.status}' 2>/dev/null || true)"
	if [[ "$status" == "Ready" ]]; then
		break
	fi
	if [[ "$status" == "Failed" ]]; then
		echo "ERROR: TenantControlPlane reached status Failed"
		kubectl -n "$NAMESPACE" get tcp "$TCP_NAME" -o yaml
		exit 1
	fi
	if [[ $elapsed -ge $timeout ]]; then
		echo "ERROR: TenantControlPlane did not become Ready within ${timeout}s (last status: $status)"
		kubectl -n "$NAMESPACE" get tcp "$TCP_NAME" -o yaml
		exit 1
	fi
	sleep 5
	elapsed=$((elapsed + 5))
done

print_check "TenantControlPlane $TCP_NAME is Ready"
kubectl -n "$NAMESPACE" get tcp "$TCP_NAME"

print_step "Tearing down $TCP_NAME and $NAMESPACE"
# handled by the cleanup() trap on exit

print_check "kamaji + kamaji-etcd smoke test passed"
