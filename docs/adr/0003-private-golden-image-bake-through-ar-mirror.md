# ADR-0003: Private golden-image bake through an Artifact Registry mirror

- **Status:** accepted
- **Date:** 2026-10-06

## Context

The golden image is the one hardened Ubuntu image the organization allows
(`compute.trustedImageProjects`). The sibling `gcp-supply-chain-security` bake
gave its VM a public IP to run apt. That is not allowed here, since the
organization denies external IPs, and Private Google Access alone does not reach
`archive.ubuntu.com`, so a bake VM with no internet route cannot install
anything from the Ubuntu archive.

## Decision

Bake on a VPC with no NAT and no default route. Artifact Registry remote
repositories (`jammy`, `jammy-updates`, `jammy-security`) mirror the Ubuntu
archive, and apt reads through Artifact Registry over Private Google Access.
Ansible runs from the workstation over Packer's IAP tunnel, so the hardening
role needs no package source. The one package apt needs for `ar+https` sources
(`apt-transport-artifact-registry`) is published only on
`packages.cloud.google.com`, so the workstation downloads it, `build-image.py`
checks it against a pinned SHA256, and Packer uploads it. The role is pinned to
a commit of azure-vm-hardening, and the image is checked after a reboot before
it is published.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| A public IP on the bake VM | Violates the organization's external-IP policy and puts the bake on the internet |
| Cloud NAT on the bake VPC | Re-opens general egress for the one step that should be the most controlled, and bills while up |
| Bake from a pre-downloaded package set | The set goes stale and has to be maintained by hand; the mirror stays current |

## Consequences

The bake and the production VMs read the same mirror, so package provenance is
one path, and patching (OS Config) uses it too. The cost is an extra moving
part: the remote repositories must pass Ubuntu's signed `InRelease` through,
and `packer/scripts/use-mirror.sh` fails the bake early if apt cannot read the
indexes. The transport package is the one input that does not come from the
mirror, which is why it is pinned by digest. If Artifact Registry stops
supporting the Ubuntu layout, this decision has to be revisited.
