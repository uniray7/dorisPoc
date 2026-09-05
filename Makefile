# dorisPoc — see docs/plan.md for phases and docs/decisions.md for why.
#
# One node stack per VM (ADR-008). Bring-up is two steps because the Nomad client
# cannot run in a container (ADR-001):
#
#     make init      render this VM's node.hcl files
#     make up        start the Consul + Nomad servers
#     make client    install and start the native Nomad client (needs sudo)
#     make verify    assert the Phase 1 exit criteria
#
# Scaling out to a second and third VM: on each VM,
#     BOOTSTRAP_EXPECT=3 RETRY_JOIN="10.0.0.1 10.0.0.2 10.0.0.3" DORIS_CLUSTER=b make init
#     make up && make client

DOCKER  ?= sg docker -c
NOMAD   := $(DOCKER) "docker exec nomad-server nomad"
CONSUL  := $(DOCKER) "docker exec consul-server consul"
NOMAD_IMAGE := hashicorp/nomad:2.0.5

.PHONY: help init up down client verify status fmt fmt-check plan-a plan-b run-a run-b stop-a stop-b logs clean

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

init: ## Render this VM's node.hcl files from the .example templates
	@./scripts/init-node.sh

up: ## Start the Consul and Nomad servers
	@$(DOCKER) "docker compose up -d"

down: ## Stop the control plane (keeps volumes)
	@$(DOCKER) "docker compose down"

client: ## Install and start the native Nomad client
	@sudo ./scripts/install-client.sh

verify: ## Assert the Phase 1 exit criteria
	@./scripts/verify.sh

status: ## Show cluster status
	@echo "== consul members ==";      $(CONSUL) members
	@echo "== nomad server members =="; $(NOMAD) server members
	@echo "== nomad node status ==";    $(NOMAD) node status
	@echo "== nomad job status ==";     $(NOMAD) job status

fmt: ## Format the job specs
	@$(DOCKER) "docker run --rm -v $(CURDIR)/jobs:/jobs $(NOMAD_IMAGE) fmt /jobs"

fmt-check: ## Check job spec formatting
	@$(DOCKER) "docker run --rm -v $(CURDIR)/jobs:/jobs $(NOMAD_IMAGE) fmt -check -list /jobs" && echo "clean"

plan-a: ## Dry-run Doris cluster A
	@$(DOCKER) "docker exec -i nomad-server nomad job plan -" < jobs/doris-cluster-a.nomad.hcl

plan-b: ## Dry-run Doris cluster B
	@$(DOCKER) "docker exec -i nomad-server nomad job plan -" < jobs/doris-cluster-b.nomad.hcl

run-a: ## Submit Doris cluster A  (needs a VM that can actually run Doris)
	@$(DOCKER) "docker exec -i nomad-server nomad job run -" < jobs/doris-cluster-a.nomad.hcl

run-b: ## Submit Doris cluster B
	@$(DOCKER) "docker exec -i nomad-server nomad job run -" < jobs/doris-cluster-b.nomad.hcl

stop-a: ## Stop Doris cluster A
	@$(NOMAD) job stop -purge doris-a

stop-b: ## Stop Doris cluster B
	@$(NOMAD) job stop -purge doris-b

logs: ## Tail the control plane logs
	@$(DOCKER) "docker compose logs -f --tail=50"

clean: ## Stop the control plane and delete its data volumes
	@$(DOCKER) "docker compose down -v"
