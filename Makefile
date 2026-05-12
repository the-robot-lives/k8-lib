INSTALL_DIR ?= $(HOME)/.local/share/k8-lib
SHELL_FILES := $(wildcard *.sh)

.PHONY: compile test install

compile:
	@true

test:
	@for f in $(SHELL_FILES); do \
		bash -n "$$f" && echo "✓ $$f" || exit 1; \
	done

install:
	@mkdir -p $(INSTALL_DIR)
	@for f in $(SHELL_FILES); do \
		install -m 644 "$$f" "$(INSTALL_DIR)/$$f"; \
	done
	@if [ -f config.env.example ]; then \
		install -m 644 config.env.example "$(INSTALL_DIR)/config.env.example"; \
	fi
	@echo "✓ Installed k8-lib to $(INSTALL_DIR)"
