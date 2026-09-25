PREFIX ?= $(HOME)/Applications

.PHONY: build test app install uninstall clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install: app
	mkdir -p "$(PREFIX)"
	rm -rf "$(PREFIX)/ClaudeUnlimited.app"
	cp -R build/ClaudeUnlimited.app "$(PREFIX)/ClaudeUnlimited.app"
	@echo "Installed to $(PREFIX)/ClaudeUnlimited.app"
	@echo "Optional CLI: ln -sf \"$(PREFIX)/ClaudeUnlimited.app/Contents/Helpers/claude-unlimited\" /usr/local/bin/claude-unlimited"

uninstall:
	rm -rf "$(PREFIX)/ClaudeUnlimited.app"
	@echo "Profiles, sign-ins and launchers are kept. Remove them from the app first if you no longer need them."

clean:
	rm -rf .build build
