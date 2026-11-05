PREFIX ?= $(HOME)/.local/bin

# Commands before the rename to hpc-agent-*: install and uninstall remove these links,
# which would otherwise point at files that no longer exist.
OLD_LINKS = $(PREFIX)/euler-agent-submit $(PREFIX)/euler-agent-run

install:
	@mkdir -p $(PREFIX)
	rm -f $(OLD_LINKS)
	ln -sf $(abspath bin/hpc-agent-submit) $(PREFIX)/hpc-agent-submit
	ln -sf $(abspath bin/hpc-agent-run) $(PREFIX)/hpc-agent-run
	ln -sf $(abspath bin/gpu-avail) $(PREFIX)/gpu-avail
	@echo "Installed hpc-agent-submit, hpc-agent-run, and gpu-avail to $(PREFIX)"
	@echo "Make sure $(PREFIX) is on your PATH (add to ~/.bashrc if needed):"
	@echo "  export PATH=\"$(PREFIX):\$$PATH\""

uninstall:
	rm -f $(PREFIX)/hpc-agent-submit $(PREFIX)/hpc-agent-run $(PREFIX)/gpu-avail $(OLD_LINKS)
	@echo "Removed hpc-agent-submit, hpc-agent-run and gpu-avail from $(PREFIX)"

.PHONY: install uninstall
