# Bespoke Terraform vs the Google accelerators

Google publishes two ways to stand up a landing zone from code:

- **terraform-example-foundation** (the security foundations blueprint), a
  staged set of roots: bootstrap, org, environments, networks, projects.
- **Cloud Foundation Fabric FAST**, a more opinionated, stage-based framework
  built on Fabric's module library.

This repo uses neither, deliberately, and follows their design where it
matters. The same choice is recorded in the AWS repo (vs Landing Zone
Accelerator) and the Azure repo (vs Azure Verified Modules).

## What is taken from the blueprint

- Seed project outside the hierarchy, holding state and the CI identity.
- Environment folders, with prod governed more strictly by placement.
- Org policy at the root, not on folders that a project can be created around.
- Base and restricted Shared VPC per environment, with the restricted host
  inside a VPC Service Controls perimeter.
- Private Service Connect for Google APIs, with restricted-VIP semantics on the
  restricted tier.
- Org log sinks with `include_children` to a dedicated logging project.
- Terraform runs as a service account through impersonation; CI through WIF.

## Why bespoke

1. **Legibility.** The point of the repo is to show each control and why it is
   there. A reader can follow `terraform/` top to bottom in one sitting; the
   foundation's stages span hundreds of files across repos.
2. **Parity with the other two zones.** Three zones built to one design doc,
   with the same tiers, address plan, and pipeline, only work if the structure
   is the same shape in each. The accelerators each have their own shape.
3. **Cost posture.** The blueprint assumes standing infrastructure. This repo is
   deploy, test, destroy, with every hourly resource in a root that can be torn
   down alone.
4. **Constraints the blueprint does not expect.** No Cloud Identity directory
   (so workforce federation instead of Google Groups), and a billing account
   with a low project cap (so `vend` flags on every project).

## Where the accelerator is the better answer

- An organization with more than a handful of teams, where the project factory
  needs to be self-service with a request workflow.
- When the org wants Google's upgrade path and support expectations to apply.
- When a compliance auditor wants a recognized baseline rather than a bespoke
  one to read.

At that point the migration path is direct, because the design here already
matches the blueprint's layout: the folders, projects, and networks map one to
one onto its stages.
