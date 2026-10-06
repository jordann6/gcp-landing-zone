# Private compute baseline checkpoint

Azure's image and management VM passed live checks. GCP has not baked or
deployed its landing-zone management VM. The previous 39 tests cover the
historical governance and workload demo only.

The live GCP bake is paused by the operator's choice on 2026-10-05 until an
approved package mirror or egress path is available. Keep Packer's build VM
private with IAP and OS Login. Do not enable NAT, public IPs, GKE, or Cloud SQL.
The sibling `gcp-supply-chain-security` template uses a public IP for apt
downloads despite IAP SSH, so it is prior art rather than a ready private bake.
Private Google Access alone does not reach Ubuntu's public package repositories.

The mandatory cleanup also found that the configured Terraform impersonation
account has been deleted. Backend initialization and state inventory return
`NOT_FOUND`. No workaround or resource apply was attempted. Read-only operator
inventory found no active landing-zone projects and the three Google default
policies still present. Both cleanup and verification exited nonzero because
remote state could not be inspected. Restore bootstrap and impersonation access
through a reviewed plan before continuing; do not interpret the inventory result
as a full teardown pass.

Implementation still required after this gate:

- Vend a shared image project and enforce `compute.trustedImageProjects`, with
  managed GKE image projects allowed and a build-project stock-image exception.
- Enforce `compute.requireOsConfig`, supported by Google's constraint reference.
- Port the pinned `cis_baseline` role and the reboot hardening check into a
  private Packer bake after the package source is approved.
- Add a separate compute root for an e2-micro management VM in the prod Shared
  VPC, shielded boot, OS Login, IAP-only SSH, least-privilege identity and OS Config
  patching. Document its VPC Service Controls boundary.
- Add the GKE maintenance window and validate node changes statically.
- Add image-denial and live VM proof tests, then run the required static gates,
  build, general tests, live compute tests, full destroy and inventory verification.

The teardown helper uses fresh saved plans, continues after failed roots and
always invokes verification. It never deletes a namespace from the workstation's
current Kubernetes context. The verifier fails on unavailable state or API
inventory rather than treating an error as an empty result.

Only cleanup and read-only inventory are currently ready to run:

```sh
make -C /Users/jordannelson/gcp-landing-zone destroy
/Users/jordannelson/gcp-landing-zone/scripts/verify-teardown.sh
```

References: [Google's constraint catalog](https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints)
and [Packer's Google builder](https://developer.hashicorp.com/packer/integrations/hashicorp/googlecompute/latest/components/builder/googlecompute).
