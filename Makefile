TF_BOOT ?= bootstrap
TF_GOV  ?= terraform
TF_NET  ?= network
TF_WORK ?= workload
TF_IMG  ?= image
TF_CMP  ?= compute
TF_OBS  ?= observability
TF_INC  ?= incident
ROOTS   := $(TF_GOV) $(TF_IMG) $(TF_NET) $(TF_WORK) $(TF_CMP) $(TF_OBS) $(TF_INC)

# Extra -var flags for the workload apply. The compute-baseline session uses
# WORK_VARS='-var enable_ubuntu_node_pool=true -var enable_cross_region_replica=false'.
WORK_VARS ?=

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

# ---- static gates (same as CI, credential-free) ----------------------------

.PHONY: fmt
fmt: ## Terraform format check, all roots
	terraform fmt -check -recursive

.PHONY: validate
validate: ## Terraform init (no backend) + validate, every root
	@for d in $(TF_BOOT) $(ROOTS); do \
		echo "==> $$d"; \
		terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; \
	done

.PHONY: policy
policy: ## conftest: shared platform-guardrails policy + this repo's policy/, every root
	@test -d .guardrails-src || git clone -q --depth 1 https://github.com/jordann6/platform-guardrails .guardrails-src
	@for d in $(TF_BOOT) $(ROOTS); do \
		echo "==> $$d"; \
		conftest test --parser hcl2 --combine --policy .guardrails-src/policy --policy policy \
			$$(find $$d -name '*.tf' -not -path '*/.terraform/*') || exit 1; \
	done

.PHONY: policy-fixture
policy-fixture: ## Prove this repo's rules still match: the violations fixture must fail
	@if conftest test --parser hcl2 --combine --policy policy policy/fixtures/violations.tf >/dev/null; then \
		echo "FAIL: policy/fixtures/violations.tf passed; the repo rules have gone vacuous"; exit 1; \
	else echo "OK: violations fixture blocked"; fi

.PHONY: diagram
diagram: ## Regenerate docs/architecture.png
	python3 docs/diagram.py

# ---- deploy / test / destroy ------------------------------------------------
#
# Order: bootstrap (once, as you) -> deploy (governance, nearly free) ->
# deploy-image (mirror + bake network) -> build-image (Packer, ~15 min) ->
# deploy-network (hourly: NAT, PSC, probe VM, which boots the golden image) ->
# deploy-workload (hourly: GKE, Cloud SQL HA + replica) -> deploy-compute
# (hourly: the management VM). Destroy runs the reverse, then verifies.
#
# Every root after bootstrap applies as sa-terraform through impersonation.
# Your own credentials only mint its tokens.

.PHONY: bootstrap
bootstrap: ## Seed project, state bucket, sa-terraform, GitHub WIF (runs as you)
	terraform -chdir=$(TF_BOOT) init
	terraform -chdir=$(TF_BOOT) apply
	@$(MAKE) --no-print-directory wire

.PHONY: wire
wire: ## Write backend.hcl + lz.auto.tfvars into each root from bootstrap outputs
	@B=$$(terraform -chdir=$(TF_BOOT) output -raw state_bucket); \
	 SA=$$(terraform -chdir=$(TF_BOOT) output -raw terraform_service_account); \
	 SEED=$$(terraform -chdir=$(TF_BOOT) output -raw seed_project_id); \
	 for d in $(ROOTS); do \
		printf 'bucket                      = "%s"\nimpersonate_service_account = "%s"\n' $$B $$SA > $$d/backend.hcl; \
		printf 'seed_project_id           = "%s"\nterraform_service_account = "%s"\n' $$SEED $$SA > $$d/lz.auto.tfvars; \
		[ $$d = $(TF_GOV) ] || printf 'state_bucket              = "%s"\n' $$B >> $$d/lz.auto.tfvars; \
	 done; \
	 gcloud auth application-default set-quota-project $$SEED >/dev/null 2>&1 || true; \
	 echo "wired: state bucket $$B, applying as $$SA"

.PHONY: deploy
deploy: ## Governance root: hierarchy, org policy, identity, logging, detect (nearly free)
	@SA=$$(terraform -chdir=$(TF_BOOT) output -raw terraform_service_account); \
	 SEED=$$(terraform -chdir=$(TF_BOOT) output -raw seed_project_id); \
	 ORG=$$(terraform -chdir=$(TF_BOOT) output -raw org_id 2>/dev/null || sed -n 's/^org_id *= *"\(.*\)"/\1/p' $(TF_GOV)/terraform.tfvars); \
	 echo "==> Provisioning the PAM org service agent (as $$SA)"; \
	 curl -sf -o /dev/null -H "Authorization: Bearer $$(gcloud auth print-access-token --impersonate-service-account=$$SA 2>/dev/null)" \
		-H "x-goog-user-project: $$SEED" \
		"https://privilegedaccessmanager.googleapis.com/v1/organizations/$$ORG/locations/global:checkOnboardingStatus" \
		|| echo "    (onboarding check failed; the pam_agent grant will fail next if the agent is missing)"
	terraform -chdir=$(TF_GOV) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_GOV) apply

.PHONY: deploy-image
deploy-image: ## Image root: Artifact Registry Ubuntu mirror, private bake VPC, bake identity
	terraform -chdir=$(TF_IMG) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_IMG) apply

.PHONY: build-image
build-image: ## Bake the pinned cis_baseline into the golden image family (private, over IAP)
	python3 scripts/build-image.py

.PHONY: deploy-network
deploy-network: ## Network root (HOURLY: NAT, PSC endpoints, probe VM; about $$0.10-0.15/hr)
	@echo "==> HOURLY resources. Torn down by make destroy-network / make destroy."
	terraform -chdir=$(TF_NET) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_NET) apply

.PHONY: deploy-workload
deploy-workload: ## Workload root (HOURLY: GKE nodes, Cloud SQL HA + DR replica; about $$0.40-0.50/hr)
	@echo "==> HOURLY resources. Torn down by make destroy-workload / make destroy."
	terraform -chdir=$(TF_WORK) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_WORK) apply $(WORK_VARS)

.PHONY: deploy-compute
deploy-compute: ## Compute root (HOURLY: e2-micro management VM + weekly patch deployment)
	@echo "==> HOURLY resources. Torn down by make destroy-compute / make destroy."
	terraform -chdir=$(TF_CMP) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_CMP) apply

.PHONY: deploy-observability
deploy-observability: ## Observability root (metrics scope + ops alert policies; about $$0, destroyed first)
	terraform -chdir=$(TF_OBS) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_OBS) apply

.PHONY: deploy-incident
deploy-incident: ## Incident root (SCC + ops alerts to a private Cloud Run handler; about $$0). Run twice: repo first, then after build-incident
	terraform -chdir=$(TF_INC) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_INC) apply

.PHONY: build-incident
build-incident: ## Build and push the handler image, write incident/image.auto.tfvars (needs docker)
	scripts/build-incident.sh

.PHONY: test-incident
test-incident: ## Publish a sample finding and alerts to the topics; prove the handler's decision and (live mode) the quarantine
	scripts/test-incident.sh

.PHONY: test-handler
test-handler: ## Unit tests for the incident handler (stubbed APIs, no credentials)
	python3 -m unittest tests.test_incident_handler

.PHONY: set-db-password
set-db-password: ## Set the app DB password in Cloud SQL and the empty Secret Manager shell, out of band (never in state)
	scripts/set-db-password.sh

.PHONY: test-secrets
test-secrets: ## Prove no secret in state, the rotation notification, and the stale-secret alert
	scripts/test-secrets.sh

.PHONY: test-observability
test-observability: ## Force an ops alert end to end and report the incident
	scripts/test-observability.sh

.PHONY: test-asset-history
test-asset-history: ## Make an IAM change, find it in the Asset Inventory feed and the BigQuery export, revert it
	scripts/test-asset-history.sh

.PHONY: test-compute
test-compute: ## Prove image policy, golden boot, live hardening, mirror-only apt, patching, GKE images
	scripts/test-compute.sh

.PHONY: test
test: ## Prove the governance + network controls deny (as you and as sa-terraform)
	scripts/test-guardrails.sh

.PHONY: test-workload
test-workload: ## Prove the paved road: admission, WI, segmentation, CMEK, failover
	scripts/test-workload.sh

.PHONY: destroy-incident
destroy-incident: ## Tear down the incident handler (after observability, before compute)
	terraform -chdir=$(TF_INC) plan -destroy -input=false -out=tfplan
	terraform -chdir=$(TF_INC) apply -input=false tfplan

.PHONY: destroy-observability
destroy-observability: ## Tear down ops alerts and the metrics scope (first, so no alert fires on teardown)
	terraform -chdir=$(TF_OBS) plan -destroy -input=false -out=tfplan
	terraform -chdir=$(TF_OBS) apply -input=false tfplan

.PHONY: destroy-compute
destroy-compute: ## Tear down the management VM (first)
	terraform -chdir=$(TF_CMP) plan -destroy -input=false -out=tfplan
	terraform -chdir=$(TF_CMP) apply -input=false tfplan

.PHONY: destroy-workload
destroy-workload: ## Tear down GKE, Cloud SQL, registry, keys (first)
	terraform -chdir=$(TF_WORK) plan -destroy -input=false -out=tfplan
	terraform -chdir=$(TF_WORK) apply -input=false tfplan

.PHONY: destroy-network
destroy-network: ## Tear down NAT, PSC, firewall policies, VPC-SC, probe
	terraform -chdir=$(TF_NET) plan -destroy -input=false -out=tfplan
	terraform -chdir=$(TF_NET) apply -input=false tfplan

.PHONY: destroy
destroy: ## Tear everything down in order, then verify nothing hourly survives
	bash scripts/destroy-session.sh "$(TF_OBS)" "$(TF_INC)" "$(TF_CMP)" "$(TF_WORK)" "$(TF_NET)" "$(TF_IMG)" "$(TF_GOV)"
