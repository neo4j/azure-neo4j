.PHONY: help ha clean

HAFILES=ha/*

help: ## Print this help text
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

clean: ## Clean out directory
	rm -rf out

ha: out/ha.zip ## Build out/ha.zip ready to be uploaded to azure

out/ha.zip: ${HAFILES}
	@mkdir -p $(dir $@)
	zip --junk-paths $@ $^
