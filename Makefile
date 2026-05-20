INSTALL_DIR ?= $(HOME)/.local/share/k8-lib
SHELL_FILES := $(wildcard bin/*.sh)

.PHONY: compile test install

compile:
	@true

test:
	@for f in $(SHELL_FILES); do \
		bash -n "$$f" && echo "✓ $$f" || exit 1; \
	done

install:
	@mkdir -p $(INSTALL_DIR)/bin
	@for f in $(SHELL_FILES); do \
		install -m 644 "$$f" "$(INSTALL_DIR)/$$f"; \
	done
	@if [ -f k8-util-config.yaml.example ]; then \
		install -m 644 k8-util-config.yaml.example "$(INSTALL_DIR)/k8-util-config.yaml.example"; \
	fi
	@if [ -f .k8-secrets.yaml.example ]; then \
		install -m 644 .k8-secrets.yaml.example "$(INSTALL_DIR)/.k8-secrets.yaml.example"; \
	fi
	@if [ -f config.env.example ]; then \
		install -m 644 config.env.example "$(INSTALL_DIR)/config.env.example"; \
	fi
	@if [ -f namespaces.conf ]; then \
		install -m 644 namespaces.conf "$(INSTALL_DIR)/namespaces.conf"; \
	fi
	@if [ -f tiers.yaml ]; then \
		install -m 644 tiers.yaml "$(INSTALL_DIR)/tiers.yaml"; \
	fi
	@echo "✓ Installed k8-lib to $(INSTALL_DIR)"
