.PHONY: help build-docker build-docker-qgis-latest run run-detached \
        run-persistent stop test summary compose-up compose-down clean

# The flake is the single source of truth for what gets built, what it is
# called, and which tests exist. Targets delegate to a `nix run` app rather
# than restating the recipe: an earlier copy of this file drifted out of sync
# with the flake — it still said `nix-xfce-kasm` long after the image was
# renamed to `kartoza`, and its test list had fallen a script behind — which
# is exactly what delegating prevents.
IMAGE_NAME := kartoza
IMAGE_TAG := latest

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

build-docker: ## Build the QGIS LTR image (kartoza:qgis-ltr, also tagged :latest)
	nix run .#build-docker

build-docker-qgis-latest: ## Build the current-QGIS image (kartoza:qgis-latest)
	nix run .#build-docker-qgis-latest

run: ## Run the QGIS Desktop container (Ctrl-C to stop)
	nix run .#run

run-detached: ## Run the QGIS Desktop container in background
	docker rm -f qgis-desktop 2>/dev/null || true
	docker run --rm -d -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
		$(IMAGE_NAME):$(IMAGE_TAG)
	@echo "Open http://localhost:8443"

run-persistent: ## Run with a persistent home directory
	docker rm -f qgis-desktop 2>/dev/null || true
	docker run --rm -d -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
		-v qgis-home:/home/user \
		$(IMAGE_NAME):$(IMAGE_TAG)
	@echo "Open http://localhost:8443"

stop: ## Stop the running container
	docker stop qgis-desktop 2>/dev/null || true

test: ## Run the test suite (no Docker required)
	nix run .#test

summary: ## Generate build summary
	nix run .#summary

compose-up: ## Start with docker-compose
	docker compose up -d

compose-down: ## Stop docker-compose
	docker compose down

clean: ## Remove built artifacts
	rm -f result build-summary.md sbom.txt sbom.spdx.json cve-scan.json
