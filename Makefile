TF_BOOT ?= bootstrap
TF_GOV  ?= terraform
TF_NET  ?= network
TF_WORK ?= workload
ROOTS   := $(TF_GOV) $(TF_NET) $(TF_WORK)

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
# deploy-network (hourly: NAT, PSC, probe VM) -> deploy-workload (hourly: GKE,
# Cloud SQL HA + replica). Destroy runs the reverse, then verifies.
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

.PHONY: deploy-network
deploy-network: ## Network root (HOURLY: NAT, PSC endpoints, probe VM; about $$0.10-0.15/hr)
	@echo "==> HOURLY resources. Torn down by make destroy-network / make destroy."
	terraform -chdir=$(TF_NET) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_NET) apply

.PHONY: deploy-workload
deploy-workload: ## Workload root (HOURLY: GKE nodes, Cloud SQL HA + DR replica; about $$0.40-0.50/hr)
	@echo "==> HOURLY resources. Torn down by make destroy-workload / make destroy."
	terraform -chdir=$(TF_WORK) init -backend-config=backend.hcl -reconfigure
	terraform -chdir=$(TF_WORK) apply

.PHONY: test
test: ## Prove the governance + network controls deny (as you and as sa-terraform)
	scripts/test-guardrails.sh

.PHONY: test-workload
test-workload: ## Prove the paved road: admission, WI, segmentation, CMEK, failover
	scripts/test-workload.sh

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
	bash scripts/destroy-session.sh "$(TF_WORK)" "$(TF_NET)" "$(TF_GOV)"
