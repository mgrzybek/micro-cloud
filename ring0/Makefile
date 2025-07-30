.PHONY: help
help: ## This help message
	@awk -F: \
		'/^([a-z\.-]+): *.* ## (.+)$$/ {gsub(/: .*?\s*##/, "\t");print}' \
		Makefile \
	| expand -t20 \
	| sort

.PHONY: dist-clean
dist-clean: ## Removes the distribution artifacts
	rm -f dist/*

dist/intermediate-fullchain.pem: ## Deploy the PKI and creates the root CA
	bash ./scripts/deploy-pki.sh

.PHONY: bootstrap
bootstrap: dist/intermediate-fullchain.pem ## Deploy the bootstrap instance
	bash ./scripts/deploy-bootstrap.sh

.PHONY: management
management: dist/intermediate-fullchain.pem ## Deploy the management instance
	bash ./scripts/deploy-management.sh

.PHONY: destroy-management
destroy-management: ## Destroy the management instance
	if incus list | grep -q management ; then incus delete -f management ; fi
	kubectl config delete-context admin@management
