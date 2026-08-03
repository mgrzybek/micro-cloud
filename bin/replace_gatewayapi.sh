#! /usr/bin/env bash

for crd in $(kubectl get crd | awk '/gateway.networking.k8s.io/ {print $1}'); do
	kubectl get crd "$crd" -o yaml | kubectl replace -f -
done
