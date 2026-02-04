#!/usr/bin/env bash
set -Eeuo pipefail

# ================================================================
# Project: COE768 Lab 4 - Localhost Bootstrap & Verifier
# Author: Krish Patel (KrishAdmin) - https://krishadmin.com
# NOTICE: This script and all files it generates are the sole
# property of Krish Patel; Unauthorized copying, distribution, 
# is prohibited without permission.
# ================================================================

# ---- helpers ---------------------------------------------------------------
quiet_kill_and_wait() {
  # Kill PID if alive, then wait to reap; suppress job messages
  local pid="${1:-}"
  [[ -z "$pid" ]] && return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

ts_pid=""
fs_pid=""
cleanup() {
  quiet_kill_and_wait "$ts_pid"
  quiet_kill_and_wait "$fs_pid"
}
trap cleanup EXIT

# ---- sources ---------------------------------------------------------------
echo "[1/8] Writing time_server.c (verbatim)"
cat > time_server.c <<'EOF'
/*
 * ================================================================
 * File: time_server.c
 * ================================================================
 */

/* time_server.c - main */

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <netdb.h>
#include <stdio.h>
#include <time.h>

/*------------------------------------------------------------------------
 * main - Iterative UDP server for TIME service
 *------------------------------------------------------------------------
 */
int
main(int argc, char *argv[])
{
	struct  sockaddr_in fsin;	/* the from address of a client */
	char	buf[100];		/* "input" buffer; any size > 0 */
	char    *pts;
	int	sock;			/* server socket */
	time_t	now;			/* current time */
	int	alen;			/* from-address length */
	struct  sockaddr_in sin; /* an Internet endpoint address */
        int     s, type;        /* socket descriptor and socket type */
	int 	port=32500;

	switch(argc){
		case 1:
			break;
		case 2:
			port = atoi(argv[1]);
			break;
		default:
			fprintf(stderr, "Usage: %s [port]\n", argv[0]);
			exit(1);
	}

        memset(&sin, 0, sizeof(sin));
        sin.sin_family = AF_INET;
        sin.sin_addr.s_addr = INADDR_ANY;
        sin.sin_port = htons(port);

    /* Allocate a socket */
        s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0)
		fprintf(stderr, "can't creat socket\n");

    /* Bind the socket */
        if (bind(s, (struct sockaddr *)&sin, sizeof(sin)) < 0)
		fprintf(stderr, "can't bind to %d port\n",port);
        listen(s, 5);
	alen = sizeof(fsin);

	while (1) {
		if (recvfrom(s, buf, sizeof(buf), 0,
				(struct sockaddr *)&fsin, &alen) < 0)
			fprintf(stderr, "recvfrom error\n");

		(void) time(&now);
        	pts = ctime(&now);

		(void) sendto(s, pts, strlen(pts), 0,
			(struct sockaddr *)&fsin, sizeof(fsin));
	}
}

/* =========================== End of File ================================ */
EOF

echo "[2/8] Writing time_client.c (verbatim)"
cat > time_client.c <<'EOF'
/*
 * ================================================================
 * File: time_client.c
 * ================================================================
 */

/* time_client.c - main */

#include <sys/types.h>

#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <netdb.h>

#define	BUFSIZE 64
#define	MSG		"Any Message \n"

/*------------------------------------------------------------------------
 * main - UDP client for TIME service that prints the resulting time
 *------------------------------------------------------------------------
 */
int
main(int argc, char **argv)
{
	char	*host = "localhost";
	int	port = 32500;
	char	now[100];		/* 32-bit integer to hold time */
	struct hostent	*phe;	/* pointer to host information entry */
	struct sockaddr_in sin;	/* an Internet endpoint address */
	int	s, n, type;	/* socket descriptor and socket type */

	switch (argc) {
	case 1:
		break;
	case 2:
		host = argv[1];
	case 3:
		host = argv[1];
		port = atoi(argv[2]);
		break;
	default:
		fprintf(stderr, "usage: UDPtime [host [port]]\n");
		exit(1);
	}

	memset(&sin, 0, sizeof(sin));
        sin.sin_family = AF_INET;
        sin.sin_port = htons(port);

    /* Map host name to IP address, allowing for dotted decimal */
        if ( phe = gethostbyname(host) ){
                memcpy(&sin.sin_addr, phe->h_addr, phe->h_length);
        }
        else if ( (sin.sin_addr.s_addr = inet_addr(host)) == INADDR_NONE )
		fprintf(stderr, "Can't get host entry \n");

    /* Allocate a socket */
        s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0)
		fprintf(stderr, "Can't create socket \n");

    /* Connect the socket */
        if (connect(s, (struct sockaddr *)&sin, sizeof(sin)) < 0)
		fprintf(stderr, "Can't connect to %s %s \n", host, "Time");

	(void) write(s, MSG, strlen(MSG));

	/* Read the time */
	n = read(s, (char *)&now, sizeof(now));
	if (n < 0)
		fprintf(stderr, "Read failed\n");
	write(1, now, n);
	exit(0);
}

/* =========================== End of File ================================ */
EOF

echo "[3/8] Writing udp_server.c (PDU C/D/F/E, 100B payload)"
cat > udp_server.c <<'EOF'
/*
 * ================================================================
 * File: udp_server.c
 * Author/Owner: Krish Patel (KrishAdmin) - https://krishadmin.com
 * Copyright (c) 2025 Krish Patel. All Rights Reserved.
 * NOTICE: Sole property of Krish Patel. Generated by 768-lab4.sh.
 * Purpose: UDP File Download Server (PDU: 'C','D','F','E'; 100B data)
 * ================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>

#define DATA_MAX 100

struct pdu { char type; char data[DATA_MAX]; };

static void die(const char *msg) { perror(msg); exit(1); }

static const char* baseptr(const char *path){
    const char *p = path, *last = path;
    while (*p){ if (*p=='/' || *p=='\\') last = p+1; p++; }
    return last;
}

static void basename_sanitized(const char *in, char *out, size_t outsz){
    const char *b = baseptr(in);
    size_t n = strlen(b);
    if (n >= outsz) n = outsz - 1;
    memcpy(out, b, n);
    out[n] = '\0';
}

int main(int argc, char **argv){
    int port = (argc >= 2) ? atoi(argv[1]) : 32501;

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) die("socket");

    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_addr.s_addr = htonl(INADDR_ANY);
    sin.sin_port = htons((unsigned short)port);

    if (bind(s, (struct sockaddr*)&sin, sizeof(sin)) < 0) die("bind");

    fprintf(stderr, "UDP file server listening on %d\n", port);

    for(;;){
        struct pdu req;
        struct sockaddr_in cli;
        socklen_t clen = sizeof(cli);
        ssize_t rn = recvfrom(s, &req, sizeof(req), 0, (struct sockaddr*)&cli, &clen);
        if (rn <= 0) continue;
        if (req.type != 'C') continue;

        char fname_req[256];
        size_t name_len = (rn > 1) ? (size_t)(rn - 1) : 0;
        if (name_len >= sizeof(fname_req)) name_len = sizeof(fname_req) - 1;
        memcpy(fname_req, req.data, name_len);
        fname_req[name_len] = '\0';

        char fname[256];
        basename_sanitized(fname_req, fname, sizeof(fname));

        struct stat st;
        struct pdu out;
        FILE *fp = NULL;

        if (stat(fname, &st) < 0 || (fp = fopen(fname, "rb")) == NULL){
            out.type = 'E';
            snprintf(out.data, DATA_MAX, "open %s", fname);
            sendto(s, &out, 1 + strlen(out.data), 0, (struct sockaddr*)&cli, clen);
            if (fp) fclose(fp);
            continue;
        }

        for(;;){
            size_t n = fread(out.data, 1, DATA_MAX, fp);
            if (n < DATA_MAX){
                if (ferror(fp)){
                    out.type = 'E';
                    strncpy(out.data, "read error", DATA_MAX-1);
                    out.data[DATA_MAX-1] = '\0';
                    sendto(s, &out, 1 + strlen(out.data), 0, (struct sockaddr*)&cli, clen);
                } else {
                    out.type = 'F';
                    sendto(s, &out, 1 + n, 0, (struct sockaddr*)&cli, clen);
                }
                break;
            } else {
                out.type = 'D';
                sendto(s, &out, 1 + n, 0, (struct sockaddr*)&cli, clen);
            }
        }
        fclose(fp);
    }
    return 0;
}

/* =========================== End of File ================================ */
EOF

echo "[4/8] Writing udp_client.c (interactive + one-shot, dir-safe output)"
cat > udp_client.c <<'EOF'
/*
 * ================================================================
 * File: udp_client.c
 * Author/Owner: Krish Patel (KrishAdmin) - https://krishadmin.com
 * Copyright (c) 2025 Krish Patel. All Rights Reserved.
 * NOTICE: Sole property of Krish Patel. Generated by 768-lab4.sh.
 * Purpose: UDP File Download Client (PDU: 'C','D','F','E'; 100B data)
 * ================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/stat.h>

#define DATA_MAX 100

struct pdu { char type; char data[DATA_MAX]; };

static void die(const char *m){ perror(m); exit(1); }

static void trim_nl(char *s){
    size_t n = strlen(s);
    if (n && s[n-1] == '\n') s[n-1] = '\0';
}

static const char* baseptr(const char *path){
    const char *p = path, *last = path;
    while (*p){ if (*p=='/' || *p=='\\') last = p+1; p++; }
    return last;
}

static int path_is_dir(const char *p){
    struct stat st;
    if (stat(p, &st) == 0 && S_ISDIR(st.st_mode)) return 1;
    size_t n = strlen(p);
    return (n && (p[n-1] == '/' || p[n-1] == '\\'));
}

static void build_local_path(const char *remote, const char *out_path, char *final, size_t cap){
    const char *base = baseptr(remote);
    if (!out_path || !*out_path){
        snprintf(final, cap, "%s", base);
    } else if (path_is_dir(out_path)){
        size_t L = strlen(out_path);
        if (L && (out_path[L-1] == '/' || out_path[L-1] == '\\'))
            snprintf(final, cap, "%s%s", out_path, base);
        else
#ifdef _WIN32
            snprintf(final, cap, "%s\\%s", out_path, base);
#else
            snprintf(final, cap, "%s/%s", out_path, base);
#endif
    } else {
        snprintf(final, cap, "%s", out_path);
    }
}

static int send_filename(int sd, const char *name){
    struct pdu req;
    req.type = 'C';
    strncpy(req.data, name, DATA_MAX-1);
    req.data[DATA_MAX-1] = '\0';
    size_t n = strlen(req.data);
    return (int)write(sd, &req, 1 + n);
}

static int recv_pdu(int sd, struct pdu *out){
    ssize_t rn = recv(sd, out, sizeof(*out), 0);
    if (rn < 0) return -1;
    if (rn == 0) return 0;
    return (int)rn;
}

static int download_one(int sd, const char *remote, const char *out_hint){
    char local[512];
    build_local_path(remote, out_hint, local, sizeof(local));

    if (send_filename(sd, remote) < 0){ perror("send filename"); return -1; }

    FILE *fp = NULL; int created = 0;

    for(;;){
        struct pdu resp;
        int rn = recv_pdu(sd, &resp);
        if (rn < 0){ perror("recv"); goto fail; }
        if (rn == 0){ fprintf(stderr, "Connection lost\n"); goto fail; }

        int payload = rn - 1; if (payload < 0) payload = 0;

        if (resp.type == 'E'){
            char msg[DATA_MAX+1];
            if (payload > DATA_MAX) payload = DATA_MAX;
            memcpy(msg, resp.data, (size_t)payload);
            msg[payload] = '\0';
            fprintf(stderr, "Server error: %s\n", msg);
            goto fail;
        }

        if (!created){
            fp = fopen(local, "wb");
            if (!fp){ perror("fopen output"); goto fail; }
            created = 1;
        }

        if (payload > 0){
            size_t w = fwrite(resp.data, 1, (size_t)payload, fp);
            if (w != (size_t)payload){ perror("fwrite"); goto fail; }
        }

        if (resp.type == 'F'){
            if (fp) fclose(fp);
            printf("Downloaded to %s\n", local);
            return 0;
        } else if (resp.type != 'D'){
            fprintf(stderr, "Protocol error: unexpected type %c\n", resp.type);
            goto fail;
        }
    }

fail:
    if (fp){ fclose(fp); remove(local); }
    return -1;
}

int main(int argc, char **argv){
    if (argc != 3 && argc != 5){
        fprintf(stderr, "usage:\n  %s HOST PORT                # interactive\n  %s HOST PORT REMOTE OUTPUT  # one-shot (OUTPUT may be a directory)\n",
                argv[0], argv[0]);
        return 1;
    }
    const char *host = argv[1]; int port = atoi(argv[2]);

    int sd = socket(AF_INET, SOCK_DGRAM, 0); if (sd < 0) die("socket");

    struct sockaddr_in sin; memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET; sin.sin_port = htons((unsigned short)port);

    struct hostent *hp = gethostbyname(host);
    if (hp) memcpy(&sin.sin_addr, hp->h_addr_list[0], (size_t)hp->h_length);
    else if (!inet_aton(host, &sin.sin_addr)){ fprintf(stderr, "bad host\n"); return 1; }

    if (connect(sd, (struct sockaddr*)&sin, sizeof(sin)) < 0) die("connect");

    if (argc == 5){
        return download_one(sd, argv[3], argv[4]) == 0 ? 0 : 1;
    }

    for(;;){
        char remote[512], out_hint[512];
        printf("\nEnter filename on server (or QUIT): ");
        if (!fgets(remote, sizeof(remote), stdin)) break; trim_nl(remote);
        if (!strcmp(remote, "QUIT")) break;
        if (remote[0] == '\0') continue;

        printf("Save as (file path or directory, blank = same name): ");
        if (!fgets(out_hint, sizeof(out_hint), stdin)) break; trim_nl(out_hint);

        (void)download_one(sd, remote, out_hint[0] ? out_hint : NULL);
    }
    return 0;
}

/* =========================== End of File ================================ */
EOF

echo "[5/8] Writing Makefile (adds -D_DEFAULT_SOURCE -D_BSD_SOURCE)"
cat > Makefile <<'EOF'
# ================================================================
# File: Makefile
# ================================================================

CC      := gcc
CFLAGS  := -std=c99 -Wall -Wextra -O2 -D_DEFAULT_SOURCE -D_BSD_SOURCE
LDFLAGS :=

all: time_server time_client udp_server udp_client

time_server: time_server.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

time_client: time_client.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

udp_server: udp_server.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

udp_client: udp_client.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f time_server time_client udp_server udp_client
	rm -f *.o

# =========================== End of File ================================
EOF

echo "[6/8] Building"
make clean >/dev/null 2>&1 || true
make -B

echo "[7/8] Preparing demo content"
mkdir -p downloads
cat > sample.txt <<'TXT'
# ================================================================
# File: sample.txt (test payload)
# Author/Owner: Krish Patel (KrishAdmin) - https://krishadmin.com
# Sole property of Krish Patel. Generated by 768-lab4.sh.
# ================================================================
The quick brown fox jumps over the lazy dog.
Pack my box with five dozen liquor jugs.
Sphinx of black quartz, judge my vow.
How vexingly quick daft zebras jump.
100 digits of pi:
3.1415926535897932384626433832795028841971693993751058209749445923078164062862089986280348253421170679
TXT
# Make multi-KB to exercise many packets
for i in $(seq 1 200); do
  printf "[%03d] The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n" "$i" >> sample.txt
done

echo "[8/8] Running local tests"

# --- TIME service test (localhost:32500) ---
./time_server 32500 >/tmp/time_srv.log 2>&1 &
ts_pid=$!
sleep 1
time_out="$(./time_client 127.0.0.1 32500 || true)"
if [[ -z "${time_out}" ]]; then
  echo "TIME test: FAIL"
  sed -n '1,80p' /tmp/time_srv.log || true
  exit 10
else
  echo "TIME test: PASS -> ${time_out%$'\n'}"
fi
quiet_kill_and_wait "$ts_pid"; ts_pid=""

# --- UDP file download test (localhost:32501) ---
./udp_server 32501 >/tmp/udp_srv.log 2>&1 &
fs_pid=$!
sleep 1

./udp_client 127.0.0.1 32501 sample.txt downloads/ >/tmp/udp_cli.log 2>&1 || {
  echo "UDP client run: FAIL"
  sed -n '1,120p' /tmp/udp_cli.log || true
  exit 20
}

if cmp -s sample.txt downloads/sample.txt; then
  echo "UDP download test: PASS (downloads/sample.txt matches)"
else
  echo "UDP download test: FAIL – files differ"
  sed -n '1,120p' /tmp/udp_srv.log || true
  exit 21
fi
quiet_kill_and_wait "$fs_pid"; fs_pid=""

echo
echo "All local tests PASSED ✅"
echo
echo "Manual run (separate terminals):"
echo "  # Terminal A"
echo "  ./time_server 32500"
echo "  ./udp_server 32501"
echo
echo "  # Terminal B"
echo "  ./time_client 127.0.0.1 32500"
echo "  ./udp_client 127.0.0.1 32501 sample.txt downloads/"
echo
echo "Banner: Built and owned by Krish Patel (KrishAdmin) — https://krishadmin.com"
