CC       ?= gcc
MUSL_CC  ?= musl-gcc
CFLAGS   := -O2 -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 \
            -Wformat-overflow=2 -Wformat-truncation=2 -Werror=implicit-function-declaration
LDFLAGS  :=

PREFIX   ?= /usr/local
BINDIR   := $(PREFIX)/sbin

SRC      := shm-unlink.c
BIN      := shm-unlink
BIN_STATIC := shm-unlink.static

.PHONY: all static install clean

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

# Static build with musl — zero runtime dependencies
static: $(BIN_STATIC)

$(BIN_STATIC): $(SRC)
	$(MUSL_CC) $(CFLAGS) -static -o $@ $<

install: $(BIN)
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)

clean:
	rm -f $(BIN) $(BIN_STATIC)
