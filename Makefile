SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
S := ./scripts

.PHONY: help create delete up install all down clean reset status urls secrets smoke token trust-ca untrust-ca \
        demo demo-load demo-down logs dashboards reinstall gitops-bootstrap push k9s openshell agent-stack agent-creds \
        hosts unhosts break-glass seal restore-drill sign lint failover-drill doctor _sudo

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "\n\033[1mkind production platform\033[0m\n\n"} \
	     /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2} \
	     /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0,5)}' $(MAKEFILE_LIST)
	@echo

##@ Lifecycle
# Ask for sudo once, up front, rather than ambushing an unattended build
# with a password prompt fifteen minutes in -- which is what `trust-ca` did.
# `hosts` and `trust-ca` are the only targets that need it.
#
# Refuses fast without a TTY instead of hanging forever on a prompt nobody
# can answer: `make up && make install && make smoke` is the unattended path.
_sudo:
	@if [ ! -t 0 ]; then \
	  echo "  'make all' needs sudo for 'hosts' and 'trust-ca' and there is no terminal."; \
	  echo "  Unattended, run:  make up && make install && make smoke"; \
	  exit 1; \
	fi
	@echo "  sudo is needed once, for /etc/hosts and the macOS keychain."
	@sudo -v

create: _sudo hosts up install trust-ca smoke ## Build everything from nothing: cluster, platform, host wiring, verification
delete: clean ## Destroy the cluster, the registry and all build artifacts
all: create ## Alias for `make create`
up: ## Create the kind cluster and local registry
	@$(S)/cluster.sh up
install: ## Install/upgrade the whole platform (idempotent)
	@$(S)/platform-install.sh
reinstall: ## Re-run the platform install after editing platform/
	@$(S)/platform-install.sh
down: ## Delete the cluster (registry and images survive)
	@$(S)/cluster.sh down
clean: ## Delete the cluster, the registry and build artifacts (.secrets/ is kept)
	@$(S)/cluster.sh down --all
	@echo "  .secrets/ kept -- the CA, etcd key and passwords survive. 'make reset' wipes them too."
reset: ## Delete everything INCLUDING .secrets/, for a genuinely fresh start
	@printf '  This deletes .secrets/: the root CA, the etcd encryption key,\n'
	@printf '  Vault unseal keys and every generated password. Type yes to confirm: '
	@read -r a && [ "$$a" = yes ] || { echo "  aborted"; exit 1; }
	@$(S)/cluster.sh down --all
	@rm -rf .secrets
	@echo "  gone. 'make all' rebuilds from nothing."
doctor: ## Diagnose a broken cluster and print the fix for each problem
	@$(S)/ops.sh doctor

##@ Operate
status: ## Health summary of the cluster and platform
	@$(S)/ops.sh status
urls: ## Print console URLs and the logins you need
	@$(S)/ops.sh urls
secrets: ## Print every generated credential
	@$(S)/ops.sh secrets
smoke: ## Run the end-to-end verification suite
	@$(S)/verify.sh smoke
restore-drill: ## Prove backups restore: back up, destroy, restore, verify
	@$(S)/verify.sh restore
failover-drill: ## Prove HA: cordon+drain a worker, check every component survives
	@$(S)/verify.sh failover
lint: ## Static checks, no cluster needed (ONLY=charts|manifests|shell|versions)
	@$(S)/lint.sh
token: ## Mint a Headlamp login token (ROLE=admin|viewer)
	@$(S)/ops.sh token $(or $(ROLE),admin)
k9s: ## Open k9s against this cluster
	@k9s --context kind-$(or $(CLUSTER_NAME),kindprod)
logs: ## Tail platform logs (NS=observability)
	@kubectl --context kind-$(or $(CLUSTER_NAME),kindprod) -n $(or $(NS),observability) logs -l app.kubernetes.io/instance --all-containers --tail=100 -f

##@ Secrets
seal: ## Encrypt a Secret from stdin so it can be committed (see scripts/ops.sh seal)
	@$(S)/ops.sh seal

##@ Identity
break-glass: ## Emergency: re-enable local logins when Keycloak is down
	@$(S)/ops.sh break-glass on

##@ Host DNS
hosts: ## Add the platform hostnames to /etc/hosts (needs sudo)
	@$(S)/host-setup.sh hosts add
unhosts: ## Remove the platform hostnames from /etc/hosts
	@$(S)/host-setup.sh hosts remove

##@ Certificates
trust-ca: ## Trust the cluster CA in the macOS keychain
	@$(S)/host-setup.sh trust-ca trust
untrust-ca: ## Remove the cluster CA from the keychain
	@$(S)/host-setup.sh trust-ca untrust

##@ Workloads
demo: ## Deploy the reference workload into the apps namespace
	@$(S)/ops.sh demo apply
demo-load: ## Generate 60s of traffic against the demo workload
	@$(S)/ops.sh demo load
demo-down: ## Remove the reference workload
	@$(S)/ops.sh demo delete
sign: ## Sign an image so Kyverno will admit it (IMG=name:tag)
	@test -n "$(IMG)" || { echo "usage: make sign IMG=myapp:1.0"; exit 1; }
	@$(S)/ops.sh sign $(IMG)
push: ## Push a local image to the cluster registry (IMG=name:tag)
	@test -n "$(IMG)" || { echo "usage: make push IMG=myapp:1.0"; exit 1; }
	@$(S)/ops.sh push $(IMG)

##@ Sandboxing
openshell: ## Fetch the OpenShell client mTLS bundle and port-forward the gateway
	@$(S)/ops.sh openshell

##@ Workloads (continued)
agent-stack: ## Build and deploy the Red Hat template-agent + template-ui stack
	@$(S)/ops.sh agent-stack
agent-creds: ## Install Google service account JSON for the agent (FILE=/path/to/key.json)
	@test -n "$(FILE)" || { echo "usage: make agent-creds FILE=/path/to/service-account.json"; exit 1; }
	@FILE=$(FILE) $(S)/ops.sh agent-creds

##@ GitOps
gitops-bootstrap: ## Point Argo CD at a git repo (REPO=https://... [PATH=gitops])
	@$(S)/ops.sh gitops
