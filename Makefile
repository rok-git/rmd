PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
PRODUCT := rmd

.PHONY: build release install uninstall run clean

build:
	swift build

release:
	swift build -c release

install: release
	install -d "$(BINDIR)"
	install ".build/release/$(PRODUCT)" "$(BINDIR)/$(PRODUCT)"

uninstall:
	rm -f "$(BINDIR)/$(PRODUCT)"

run:
	swift run $(PRODUCT) lists

clean:
	swift package clean
