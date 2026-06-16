# Deploy and verify the air-gapped Zarf package on a local KIND cluster.
CLUSTER      ?= zarf-e2e
KAFKA_NS     ?= kafka
DB_NS        ?= db
DB_PASSWORD  ?=
MSG          ?= hello air-gap

PKG_GLOB = zarf-package-kafka-pg-pipeline-*.tar.zst

# necessary Tools to install
EXECUTABLES = zarf kind kubectl
KCHECK := $(foreach exec,$(EXECUTABLES),\
        $(if $(shell Your_Path=$$(which $(exec) 2>/dev/null); echo $$Your_Path),,$(error "❌ Missing prerequisite binary: $(exec)")))

.DEFAULT_GOAL := help
.PHONY: help package cluster init deploy verify e2e all status logs remove clean _check-tools

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

package: ## Build the Zarf package (bundles charts + images)
	zarf package create . --confirm

cluster: ## Create a clean KIND cluster
	@kind get clusters | grep -qx "$(CLUSTER)" || kind create cluster --name "$(CLUSTER)"

init: cluster ## Install Zarf registry + agent (wants a running cluster)
	zarf init --confirm

deploy: ## Deploy the package (pass DB_PASSWORD=... or get prompted)
	@PKG=$$(ls $(PKG_GLOB) 2>/dev/null | head -n1); \
	if [ -z "$$PKG" ]; then echo "❌ No package found - run 'make package'"; exit 1; fi; \
	echo "🚀 Deploying $$PKG"; \
	if [ -n "$(DB_PASSWORD)" ]; then \
		ZARF_VAR_DB_PASSWORD='$(DB_PASSWORD)' zarf package deploy "$$PKG" --confirm; \
	else \
		zarf package deploy "$$PKG" --confirm; \
	fi

verify: ## Send a message and show it landed in Postgres (MSG="...")
	@KAFKA_NS="$(KAFKA_NS)" DB_NS="$(DB_NS)" ./scripts/verify.sh "$(MSG)"

# Dependencies
e2e: cluster init deploy verify ## Run full pipeline: cluster -> init -> deploy -> verify

all: package e2e ## Build the package, then run the full flow

status: ## Show pods + connector status 
	kubectl get pods -n $(DB_NS)
	kubectl get pods -n $(KAFKA_NS)
	@echo "--- Kafka Connect Status ---"
	@kubectl exec -n $(KAFKA_NS) deploy/kafka-connect -- wget -qO- http://localhost:8083/connectors/pg-sink/status 2>/dev/null \
		|| kubectl exec -n $(KAFKA_NS) deploy/kafka-connect -- curl -s http://localhost:8083/connectors/pg-sink/status 2>/dev/null \
		|| echo "⚠️ Could not fetch connector status (neither curl nor wget available in pod or pod not ready)"

logs: ## Tail Kafka Connect logs
	kubectl logs deploy/kafka-connect -n $(KAFKA_NS) --tail=80 -f

remove: ## Remove the deployed Zarf package
	zarf package remove kafka-pg-pipeline --confirm

clean: ## Delete the KIND cluster
	-kind delete cluster --name "$(CLUSTER)"