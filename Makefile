.PHONY: test test-unit test-integration lint install install-deps

BATS        := bats
SHELLCHECK  := shellcheck
INSTALL_DIR := /usr/local/bin

test: test-unit test-integration

test-unit:
	$(BATS) tests/unit/

test-integration:
	$(BATS) tests/integration/

lint:
	$(SHELLCHECK) jira-export.sh lib/*.sh

install:
	install -m 755 jira-export.sh $(INSTALL_DIR)/jira-export

install-deps:
	brew install bats-core jq pandoc shellcheck
