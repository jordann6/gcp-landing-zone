# Compute baseline

One hardening role, three image pipelines, three enforcement points: Azure
Policy approved-image deny, GCP `compute.trustedImageProjects`, AWS Allowed
AMIs. This is the GCP third.

**Status (2026-10-06):** proven live, then destroyed. `make test-compute`
passed 20 of 20 on the deployed layers: image policy, golden boot, live
hardening, mirror-only apt, a SUCCEEDED OS Config patch job, and the COS and
Ubuntu GKE node pools running. Results and the not-proven list are in
[completion.md](completion.md).

## What it adds

| Piece | Where | What it does |
|---|---|---|
| Image project | `terraform/projects.tf` | `images` in the core folder: image family, mirror, bake VPC |
| `compute.trustedImageProjects` | `terraform/org_policies.tf` | Org-wide: only the image project plus `cos-cloud`, `gke-node-images`, `ubuntu-os-gke-cloud`. The image project alone also admits `ubuntu-os-cloud`, the stock image Packer hardens |
| `compute.requireOsConfig` | `terraform/org_policies.tf` | OS Config cannot be switched off on a VM |
| Ubuntu mirror | `image/registry.tf` | Artifact Registry remote repos for `jammy`, `jammy-updates`, `jammy-security` |
| Bake VPC | `image/network.tf` | No NAT, no default route. One route to `private.googleapis.com`, private DNS for `googleapis.com` and `pkg.dev`, egress denied otherwise |
| Golden image | `packer/`, `scripts/build-image.py` | Ubuntu 22.04 + `cis_baseline` at azure-vm-hardening `v2.0.1` (commit `b5ce929`), checked after a reboot before publishing |
| Management VM | `compute/main.tf` | e2-micro in `app-prod` on the restricted Shared VPC subnet: golden family, shielded, OS Login, IAP only, no external IP, own service account |
| Patching | `compute/patching.tf` | Weekly OS Config `apt upgrade`, label-targeted, reading the same mirror |
| GKE | `workload/gke.tf` | Weekend maintenance window; optional one-node `UBUNTU_CONTAINERD` pool to prove the GKE allowlist |

The probe VM in `network/` now boots from the golden family too, because a
stock image is rejected everywhere outside the image project.

## The private bake

The sibling `gcp-supply-chain-security` bake gave its VM a public IP for apt.
That is not allowed here, and Private Google Access alone does not reach
`archive.ubuntu.com`. Artifact Registry remote repositories close the gap:
apt reads the Ubuntu archive through Artifact Registry, which Private Google
Access (bake) and the restricted PSC endpoint (prod) both reach.

Clients need `apt-transport-artifact-registry` for `ar+https` sources, and
that package is only published on `packages.cloud.google.com`. The workstation
fetches it, `build-image.py` checks it against a pinned SHA256, and Packer
uploads it. The bake VM never has egress to fetch it itself.

Ansible runs from the workstation over Packer's IAP tunnel, so the role needs
no package source. Only apt does.

## Placement and VPC Service Controls

The management VM is inside the perimeter, on purpose: it is the operator's
foothold on the restricted tier and the target of the incident handler in `incident/`,
which quarantines it on a Security Command Center finding (proven live with a
sample finding, see [completion.md](completion.md)). It reaches
Google APIs only through the restricted `vpc-sc` PSC bundle. Artifact Registry
is not a restricted service in the perimeter, so the VM reads the mirror in the
image project, which is outside the perimeter, without an egress rule.

The image project is outside the perimeter. It holds no data, and the bake
needs the stock Ubuntu image from `ubuntu-os-cloud`.

## Session order

```sh
make bootstrap
make deploy
make deploy-image
make build-image
make deploy-network
make deploy-workload WORK_VARS='-var enable_ubuntu_node_pool=true -var enable_cross_region_replica=false'
make deploy-compute
make test
make test-compute
make destroy
```

## Risks the first live run had to clear

- **Remote repo path.** The mirror uses `ubuntu/dists/<suite>` with the suite
  as the `sources.list` distribution. `packer/scripts/use-mirror.sh` fails the
  bake in its first minute if apt cannot read the indexes.
- **Signatures.** apt expects the remote repo to pass Ubuntu's signed
  `InRelease` through. If it does not, the same smoke check fails.
- **Packer Ansible over IAP** with `use_proxy = false` connects to Packer's
  local tunnel port. If it cannot, switch to the proxy adapter.
- **OS Config inside the perimeter.** Patch jobs go through the restricted PSC
  bundle. The patch-job check in `test-compute.sh` is the proof.
- **Project cap.** Five projects (seed, logging, images, net-prod-r,
  app-prod). The four from the 2026-09-28 run stay in `DELETE_REQUESTED` until
  about 2026-10-28 and count against the billing account's cap.
- **`compute.requireOsConfig` and GKE.** No interaction is expected. The
  workload apply is the proof.

Inventory reporting needs guest attributes, which the org disables
(`compute.disableGuestAttributesAccess`). Patch jobs do not need them.
