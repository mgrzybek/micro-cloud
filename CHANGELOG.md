# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Pre-releases `v0.0.1`–`v0.0.10` (2026-07-22) predate this changelog and are not
> itemised here — see the [git tags](https://github.com/mgrzybek/micro-cloud/tags).

## [0.1.0] - 2026-10-12

### Features

- CHANGELOG (git-cliff) + GitHub Release workflow ([#17](https://github.com/mgrzybek/micro-cloud/issues/17))
- Add VictoriaMetrics metrics stack ([#16](https://github.com/mgrzybek/micro-cloud/issues/16))
- Add initial support for truenas and snapshots ([#14](https://github.com/mgrzybek/micro-cloud/issues/14))
- Authenticate management cluster users via Authentik OIDC
- Authenticate management cluster users via Authentik OIDC

### Bug Fixes

- Add internal CA to Grafana ([#33](https://github.com/mgrzybek/micro-cloud/issues/33))
- Cleanup of OIDC URLs and Flux token ([#32](https://github.com/mgrzybek/micro-cloud/issues/32))
- Truenas-csi iSCSI on Talos (machine config, iscsid wrapper, IP portal) ([#23](https://github.com/mgrzybek/micro-cloud/issues/23))
- Run privileged DaemonSets under Pod Security (truenas-csi node, node-exporter) + Talos iscsi hostPath ([#22](https://github.com/mgrzybek/micro-cloud/issues/22))
- Local-path vendoring, PKI over bootstrap network, TrueNAS CSI v1.1 ([#21](https://github.com/mgrzybek/micro-cloud/issues/21))
- Bad syntax in openbao’s systemd unit

### Miscellaneous

- Set file system permissions for Grafana PVC ([#31](https://github.com/mgrzybek/micro-cloud/issues/31))
- Install operators before their CRs and migrate local-paths PVCs to Truenas CSI ([#28](https://github.com/mgrzybek/micro-cloud/issues/28))
- Create CRDs before using them. ([#27](https://github.com/mgrzybek/micro-cloud/issues/27))
- Helm cleanup  ([#26](https://github.com/mgrzybek/micro-cloud/issues/26))
- Install Grafana using the operator ([#25](https://github.com/mgrzybek/micro-cloud/issues/25))
- Adding GatewayAPI via Flux and upgrading scripts ([#24](https://github.com/mgrzybek/micro-cloud/issues/24))
- Mark pre-release tags as GitHub pre-releases ([#20](https://github.com/mgrzybek/micro-cloud/issues/20))
- Upgrade Kamaji using FluxCD ([#13](https://github.com/mgrzybek/micro-cloud/issues/13))
- Cleanup code


