TESTS_INIT=tests/minimal_init.lua
TESTS_DIR=tests/

HARNESS_NAME=outpost-test-harness
HARNESS_IMAGE=outpost-test-harness
HARNESS_HOST=127.0.0.1
HARNESS_PORT=2222
HARNESS_USER=outpost
HARNESS_PASS_USER=outpass
HARNESS_PASSWORD=fixture-password
HARNESS_KEY_DIR=tests/outpost/.keys
HARNESS_KEY=$(HARNESS_KEY_DIR)/id_ed25519
HARNESS_KNOWN_HOSTS=$(HARNESS_KEY_DIR)/known_hosts

.PHONY: test test-integration harness-up harness-down harness-logs harness-shell

test:
	@nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "PlenaryBustedDirectory ${TESTS_DIR} { minimal_init = '${TESTS_INIT}', sequential = true, keep_going = true }"

test-integration: harness-up
	@OUTPOST_TEST_HOST=$(HARNESS_HOST) \
	 OUTPOST_TEST_PORT=$(HARNESS_PORT) \
	 OUTPOST_TEST_USER=$(HARNESS_USER) \
	 OUTPOST_TEST_PASS_USER=$(HARNESS_PASS_USER) \
	 OUTPOST_TEST_PASSWORD=$(HARNESS_PASSWORD) \
	 OUTPOST_TEST_KEY=$(CURDIR)/$(HARNESS_KEY) \
	 OUTPOST_TEST_KNOWN_HOSTS=$(CURDIR)/$(HARNESS_KNOWN_HOSTS) \
	 nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "PlenaryBustedDirectory ${TESTS_DIR} { minimal_init = '${TESTS_INIT}', sequential = true, keep_going = true }"
	@$(MAKE) --no-print-directory harness-down

harness-up:
	@mkdir -p $(HARNESS_KEY_DIR)
	@test -f "$(HARNESS_KEY)" || ssh-keygen -t ed25519 -N "" -C outpost-test -f "$(HARNESS_KEY)" -q
	@docker build -q -t $(HARNESS_IMAGE) tests/outpost/ >/dev/null
	@docker rm -f $(HARNESS_NAME) >/dev/null 2>&1 || true
	@# fresh container => fresh host keys => pin a fresh known_hosts
	@rm -f $(HARNESS_KNOWN_HOSTS)
	@docker run -d --name $(HARNESS_NAME) \
		-p $(HARNESS_HOST):$(HARNESS_PORT):22 \
		-v "$(CURDIR)/$(HARNESS_KEY).pub:/home/outpost/.ssh/authorized_keys:ro" \
		$(HARNESS_IMAGE) >/dev/null
	@# Wait until sshd actually accepts connections: `docker run` returns
	@# long before sshd is listening, which would silently mark integration
	@# specs pending on a fast host (e.g. CI).
	@i=0; \
	until ssh -i $(HARNESS_KEY) -p $(HARNESS_PORT) \
		-o StrictHostKeyChecking=accept-new \
		-o UserKnownHostsFile=$(HARNESS_KNOWN_HOSTS) \
		-o BatchMode=yes -o ConnectTimeout=1 \
		$(HARNESS_USER)@$(HARNESS_HOST) true 2>/dev/null; do \
		i=$$((i+1)); \
		if [ $$i -ge 30 ]; then \
			echo "harness not ready after 15s" >&2; \
			docker logs $(HARNESS_NAME); \
			exit 1; \
		fi; \
		sleep 0.5; \
	done
	@echo "harness up: ssh://$(HARNESS_USER)@$(HARNESS_HOST):$(HARNESS_PORT)"

harness-down:
	@docker rm -f $(HARNESS_NAME) >/dev/null 2>&1 || true
	@echo "harness down"

harness-logs:
	@docker logs $(HARNESS_NAME)

harness-shell:
	@ssh -i $(HARNESS_KEY) -p $(HARNESS_PORT) \
		-o StrictHostKeyChecking=accept-new \
		-o UserKnownHostsFile=$(HARNESS_KNOWN_HOSTS) \
		$(HARNESS_USER)@$(HARNESS_HOST)
