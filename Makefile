IMAGE := claude-code-dev:latest
PROXY_TEST_IMAGE := docker-socket-proxy-test:latest
PLATFORM ?= linux/$(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
INSTALL_DIR_DISPLAY := ~/.local/bin
INSTALL_DIR := $(HOME)/.local/bin

.PHONY: build test install clean

build:
	docker build --platform $(PLATFORM) -t $(IMAGE) .

test:
	docker build --platform $(PLATFORM) -t $(PROXY_TEST_IMAGE) docker-socket-proxy
	docker run --rm $(PROXY_TEST_IMAGE)

install: build
	mkdir -p "$(INSTALL_DIR)"
	install -m 755 claude-container "$(INSTALL_DIR)/claude-container"
	@echo "$(PATH)" | tr ":" "\n" | grep -Fqx -e "$(INSTALL_DIR)" -e "$(INSTALL_DIR_DISPLAY)" || { \
		if [ -t 1 ] && [ -z "$${NO_COLOR:-}" ] && [ "$$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then \
			c="$$(tput bold)$$(tput setaf 3)"; r="$$(tput sgr0)"; \
		else \
			c=""; r=""; \
		fi; \
		printf '%sAdd %s to your PATH if you want to run claude-container by name.%s\n' "$$c" "$(INSTALL_DIR_DISPLAY)" "$$r"; \
	}

clean:
	docker rmi $(IMAGE) 2>/dev/null || true
	docker rmi $(PROXY_TEST_IMAGE) 2>/dev/null || true
