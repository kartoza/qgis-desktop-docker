.PHONY: help build-docker run stop summary test clean

IMAGE_NAME := nix-xfce-kasm
IMAGE_TAG := latest

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build-docker: ## Build the Docker image using Nix
	@echo "Building Docker image..."
	nix build .#docker -o result
	nix store cat $$(nix build .#docker --print-out-paths) | docker load
	@echo ""
	@echo "Image built: $(IMAGE_NAME):$(IMAGE_TAG)"
	@docker images $(IMAGE_NAME):$(IMAGE_TAG) --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

run: ## Run the QGIS Desktop container
	docker run --rm -p 8443:8443 --name qgis-desktop $(IMAGE_NAME):$(IMAGE_TAG)

run-detached: ## Run the QGIS Desktop container in background
	docker run --rm -d -p 8443:8443 --name qgis-desktop $(IMAGE_NAME):$(IMAGE_TAG)
	@echo "Open http://localhost:8443"

run-persistent: ## Run with persistent home directory
	docker run --rm -d -p 8443:8443 --name qgis-desktop \
		-v qgis-home:/home/user \
		$(IMAGE_NAME):$(IMAGE_TAG)
	@echo "Open http://localhost:8443"

stop: ## Stop the running container
	docker stop qgis-desktop 2>/dev/null || true

test: ## Run the test suite (no Docker required)
	bash scripts/test-oidc-config.sh
	bash scripts/test-terminal-lockdown.sh
	bash scripts/test-renamed-variables.sh

summary: ## Generate build summary
	bash build-summary.sh $(IMAGE_NAME):$(IMAGE_TAG) build-summary.md

compose-up: ## Start with docker-compose
	docker compose up -d

compose-down: ## Stop docker-compose
	docker compose down

clean: ## Remove built artifacts
	rm -f result build-summary.md sbom.txt sbom.spdx.json cve-scan.json
