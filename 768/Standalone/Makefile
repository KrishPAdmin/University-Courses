# Watermark: Krish Patel (KrishAdmin) — Makefile
CC = gcc
CFLAGS = -Wall -Wextra -O2 -std=c89

TARGETS := directory_server peer_node

.PHONY: all clean help

all: $(TARGETS)

directory_server: directory_server.c protocol.h
	$(CC) $(CFLAGS) directory_server.c -o directory_server

peer_node: peer_node.c protocol.h
	$(CC) $(CFLAGS) peer_node.c -o peer_node

clean:
	rm -f $(TARGETS)

help:
	@echo "make        Build directory_server and peer_node in current directory"
	@echo "make clean  Remove binaries"
# Watermark: End of Makefile — KrishAdmin