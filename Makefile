PREFIX ?= $(HOME)/.local/bin

install:
	@mkdir -p $(PREFIX)
	ln -sf $(abspath bin/euler-agent-submit) $(PREFIX)/euler-agent-submit
	ln -sf $(abspath bin/euler-agent-run) $(PREFIX)/euler-agent-run
	@echo "Installed euler-agent-submit and euler-agent-run to $(PREFIX)"
	@echo "Make sure $(PREFIX) is on your PATH (add to ~/.bashrc if needed):"
	@echo "  export PATH=\"$(PREFIX):\$$PATH\""

uninstall:
	rm -f $(PREFIX)/euler-agent-submit $(PREFIX)/euler-agent-run
	@echo "Removed euler-agent-submit and euler-agent-run from $(PREFIX)"

.PHONY: install uninstall
