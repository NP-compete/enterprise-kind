SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
S := ./scripts

.PHONY: help create delete up install all down clean status urls smoke token trust-ca untrust-ca \
        demo demo-load demo-down logs dashboards reinstall gitops-bootstrap push k9s \
        hosts unhosts break-glass seal restore-drill

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "\n\033[1mkind production platform\033[0m\n\n"} \
	     /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2} \
	     /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0,5)}' $(MAKEFILE_LIST)
	@echo

##@ Lifecycle
create: up install trust-ca smoke ## Build the whole platform from nothing, trust its CA, and verify it
delete: clean ## Destroy the cluster, the registry and all build artifacts
all: create ## Alias for `make create`
up: ## Create the kind cluster and local registry
	@$(S)/cluster-up.sh
install: ## Install/upgrade the whole platform (idempotent)
	@$(S)/platform-install.sh
reinstall: ## Re-run the platform install after editing platform/
	@$(S)/platform-install.sh
down: ## Delete the cluster (registry and images survive)
	@$(S)/cluster-down.sh
clean: ## Delete the cluster, the registry and all build artifacts
	@$(S)/cluster-down.sh --all

##@ Operate
status: ## Health summary of the cluster and platform
	@$(S)/status.sh
urls: ## Print console URLs and credentials
	@$(S)/urls.sh
smoke: ## Run the end-to-end verification suite
	@$(S)/smoke-test.sh
restore-drill: ## Prove backups restore: back up, destroy, restore, verify
	@$(S)/restore-drill.sh
token: ## Mint a Headlamp login token (ROLE=admin|viewer)
	@$(S)/token.sh $(or $(ROLE),admin)
k9s: ## Open k9s against this cluster
	@k9s --context kind-$(or $(CLUSTER_NAME),kindprod)
logs: ## Tail platform logs (NS=observability)
	@kubectl --context kind-$(or $(CLUSTER_NAME),kindprod) -n $(or $(NS),observability) logs -l app.kubernetes.io/instance --all-containers --tail=100 -f

##@ Secrets
seal: ## Encrypt a Secret from stdin so it can be committed (see scripts/seal.sh)
	@$(S)/seal.sh

##@ Identity
break-glass: ## Emergency: re-enable local logins when Keycloak is down
	@$(S)/break-glass.sh on

##@ Host DNS
hosts: ## Add the platform hostnames to /etc/hosts (needs sudo)
	@$(S)/hosts.sh add
unhosts: ## Remove the platform hostnames from /etc/hosts
	@$(S)/hosts.sh remove

##@ Certificates
trust-ca: ## Trust the cluster CA in the macOS keychain
	@$(S)/trust-ca.sh trust
untrust-ca: ## Remove the cluster CA from the keychain
	@$(S)/trust-ca.sh untrust

##@ Workloads
demo: ## Deploy the reference workload into the apps namespace
	@$(S)/demo.sh apply
demo-load: ## Generate 60s of traffic against the demo workload
	@$(S)/demo.sh load
demo-down: ## Remove the reference workload
	@$(S)/demo.sh delete
push: ## Push a local image to the cluster registry (IMG=name:tag)
	@test -n "$(IMG)" || { echo "usage: make push IMG=myapp:1.0"; exit 1; }
	@$(S)/push.sh $(IMG)

##@ GitOps
gitops-bootstrap: ## Point Argo CD at a git repo (REPO=https://... [PATH=gitops])
	@$(S)/gitops-bootstrap.sh
