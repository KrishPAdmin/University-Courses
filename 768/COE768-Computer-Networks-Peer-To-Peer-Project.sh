#!/usr/bin/env bash
# HOW TO RUN:
# 1) chmod +x P2P_Project.sh
# 2) ./P2P_Project.sh setup     # writes sources into p2p_project/src
# 3) ./P2P_Project.sh build     # builds server and peer binaries into p2p_project/bin
# 4) ./P2P_Project.sh start     # starts the directory server on UDP 15000, logs to p2p_project/logs
# 5) ./P2P_Project.sh peer Bob  # launches a peer named "Bob" in p2p_project/peers/Bob
# 6) ./P2P_Project.sh stop      # stops server and any peers started via this script
# 7) ./P2P_Project.sh clean     # cleans workspace
#
# ================================================================
# Project: COE768 Peer-To-Peer Project - Localhost Bootstrap
# Author: Krish Patel (KrishAdmin) - https://krishadmin.com
# NOTICE: This script and all files it generates are the sole
# property of Krish Patel; Unauthorized copying, distribution, 
# is prohibited without permission!
# ================================================================

set -Eeuo pipefail

PROJECT_DIR="${PWD}/p2p_project"
SRC_DIR="${PROJECT_DIR}/src"
BIN_DIR="${PROJECT_DIR}/bin"
LOG_DIR="${PROJECT_DIR}/logs"
PEERS_DIR="${PROJECT_DIR}/peers"
PID_DIR="${PROJECT_DIR}/.pids"

need_tools() {
  for t in gcc make pkill; do
    command -v "$t" >/dev/null 2>&1 || { echo "Missing tool: $t"; exit 1; }
  done
}

write_sources() {
  mkdir -p "${SRC_DIR}" "${BIN_DIR}" "${LOG_DIR}" "${PID_DIR}" "${PEERS_DIR}"

  cat > "${SRC_DIR}/protocol.h" <<'EOF'
#ifndef PROTOCOL_H
#define PROTOCOL_H
/* Watermark: Krish Patel (KrishAdmin) — protocol.h */
/* Watermark: https://krishadmin.com */

typedef unsigned short u16;

#define UDP_BUFLEN   512
#define NAME_LEN     50
#define MAX_PEERS    100
#define MAX_CONTENT  100

#define T_REG      'R'
#define T_SEARCH   'S'
#define T_DEREG    'T'
#define T_LIST     'O'
#define T_LISTMID  'M'
#define T_LISTEND  'F'
#define T_ACK      'A'
#define T_ERR      'E'
#define T_BYE      'B'

#define T_REQ      'D'
#define T_CHUNK    'C'
#define T_FINAL    'Z'

#pragma pack(push, 1)
typedef struct {
    char type;
    char data[UDP_BUFLEN];
} UdpPDU;

typedef struct {
    char type;
    u16  len;
    char data[UDP_BUFLEN];
} TcpPDU;
#pragma pack(pop)

/* Watermark: End of protocol.h — KrishAdmin */
#endif
EOF

  cat > "${SRC_DIR}/directory_server.c" <<'EOF'
/* Watermark: Krish Patel (KrishAdmin) — directory_server.c */
/* Watermark: https://krishadmin.com */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

#include "protocol.h"

#ifndef INDEX_PORT
#define INDEX_PORT 15000
#endif

typedef struct {
    char  name[NAME_LEN + 1];
    char  ip[INET_ADDRSTRLEN];
    u16   tcp_port;
    int   ncontent;
    char  contents[MAX_CONTENT][NAME_LEN + 1];
    int   sent_count[MAX_CONTENT];
    int   in_use;
} Peer;

static Peer peers[MAX_PEERS];
static int  npeers = 0;
static FILE *glog = NULL;

static void mklogdir_if_missing(const char *dir) {
    struct stat st;
    if (stat(dir, &st) == -1) {
        mkdir(dir, 0775);
    }
}

static void open_log_file(int port) {
    const char *envd = getenv("P2P_LOG_DIR");
    const char *dir = envd && *envd ? envd : "logs";
    char ts[32];
    char path[512];
    time_t now = time((time_t*)0);
    struct tm *tmv = localtime(&now);

    mklogdir_if_missing(dir);
    if (tmv) {
        strftime(ts, sizeof(ts), "%Y%m%d-%H%M%S", tmv);
    } else {
        strcpy(ts, "now");
    }

    strcpy(path, dir);
    strcat(path, "/index-");
    strcat(path, ts);
    strcat(path, ".log");

    glog = fopen(path, "a");
    if (glog) {
        fprintf(glog, "=== index start (UDP port %d) ===\n", port);
        fflush(glog);
    }
}

static void log_msg(const char *msg) {
    time_t now;
    struct tm *tmv;
    char tbuf[32];
    if (!glog) return;
    now = time((time_t*)0);
    tmv = localtime(&now);
    if (tmv) strftime(tbuf, sizeof(tbuf), "%H:%M:%S", tmv);
    else strcpy(tbuf, "time");
    fprintf(glog, "[%s] %s\n", tbuf, msg);
    fflush(glog);
}

static int find_peer_by_name(const char *name) {
    int i;
    for (i = 0; i < MAX_PEERS; i++) {
        if (peers[i].in_use && strcmp(peers[i].name, name) == 0) return i;
    }
    return -1;
}
static int find_peer_by_ip(const char *ip) {
    int i;
    for (i = 0; i < MAX_PEERS; i++) {
        if (peers[i].in_use && strcmp(peers[i].ip, ip) == 0) return i;
    }
    return -1;
}
static int first_free_peer_slot(void) {
    int i;
    for (i = 0; i < MAX_PEERS; i++) if (!peers[i].in_use) return i;
    return -1;
}
static int find_content_index_in_peer(const Peer *p, const char *content) {
    int i;
    for (i = 0; i < p->ncontent; i++) {
        if (strcmp(p->contents[i], content) == 0) return i;
    }
    return -1;
}

static int parse_fields(const char *buf, size_t buflen, const char **out, int max_out) {
    int count = 0;
    size_t i = 0;
    while (i < buflen && count < max_out) {
        size_t start = i;
        while (i < buflen && buf[i] != '\0') i++;
        if (i >= buflen) break;
        out[count++] = buf + start;
        i++;
        if (i == buflen) break;
    }
    return count;
}

static void send_err(int sock, const struct sockaddr_in *cli, socklen_t clen, const char *msg) {
    UdpPDU p;
    memset(&p, 0, sizeof(p));
    p.type = T_ERR;
    sprintf(p.data, "%s", msg);
    sendto(sock, &p, sizeof(p), 0, (const struct sockaddr *)cli, clen);
}
static void send_ack(int sock, const struct sockaddr_in *cli, socklen_t clen, const char *msg) {
    UdpPDU p;
    memset(&p, 0, sizeof(p));
    p.type = T_ACK;
    sprintf(p.data, "%s", msg ? msg : "OK");
    sendto(sock, &p, sizeof(p), 0, (const struct sockaddr *)cli, clen);
}

int main(int argc, char **argv) {
    int port = (argc >= 2) ? atoi(argv[1]) : INDEX_PORT;
    int s;
    struct sockaddr_in srv;

    memset(peers, 0, sizeof(peers));

    s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { perror("socket"); exit(1); }

    memset(&srv, 0, sizeof(srv));
    srv.sin_family = AF_INET;
    srv.sin_addr.s_addr = htonl(INADDR_ANY);
    srv.sin_port = htons(port);

    if (bind(s, (struct sockaddr *)&srv, sizeof(srv)) < 0) {
        perror("bind");
        exit(1);
    }

    open_log_file(port);
    printf("Index server listening on UDP port %d\n", port);
    log_msg("Listening for peers");

    while (1) {
        UdpPDU in;
        UdpPDU out;
        struct sockaddr_in cli;
        socklen_t clen = sizeof(cli);
        ssize_t n;
        char cip[INET_ADDRSTRLEN];

        memset(&in, 0, sizeof(in));
        memset(&out, 0, sizeof(out));
        memset(&cli, 0, sizeof(cli));
        memset(cip, 0, sizeof(cip));

        n = recvfrom(s, &in, sizeof(in), 0, (struct sockaddr *)&cli, &clen);
        if (n < 0) { perror("recvfrom"); continue; }

        strcpy(cip, inet_ntoa(cli.sin_addr));

        if (in.type == T_REG) {
            const char *fields[3];
            int nf;
            const char *peerName;
            const char *contentName;
            const char *portStr;
            int tcp_port;
            int idx;
            int freei;
            Peer *p;
            int cidx;
            char msg[160];
            char logb[256];

            nf = parse_fields(in.data, sizeof(in.data), fields, 3);
            if (nf < 3) { send_err(s, &cli, clen, "Malformed R PDU"); continue; }

            peerName = fields[0];
            contentName = fields[1];
            portStr = fields[2];

            if (strlen(peerName) == 0 || strlen(peerName) > NAME_LEN ||
                strlen(contentName) == 0 || strlen(contentName) > NAME_LEN) {
                send_err(s, &cli, clen, "Name too long or empty");
                continue;
            }
            tcp_port = atoi(portStr);
            if (tcp_port <= 0 || tcp_port > 65535) { send_err(s, &cli, clen, "Invalid TCP port"); continue; }

            idx = find_peer_by_name(peerName);
            if (idx >= 0) {
                if (strcmp(peers[idx].ip, cip) != 0) {
                    send_err(s, &cli, clen, "Peer name already in use");
                    continue;
                }
                if (peers[idx].ncontent >= MAX_CONTENT) { send_err(s, &cli, clen, "Peer content table full"); continue; }
                cidx = find_content_index_in_peer(&peers[idx], contentName);
                if (cidx >= 0) { send_err(s, &cli, clen, "Content already registered by this peer"); continue; }
                strncpy(peers[idx].contents[peers[idx].ncontent], contentName, NAME_LEN);
                peers[idx].contents[peers[idx].ncontent][NAME_LEN] = '\0';
                peers[idx].sent_count[peers[idx].ncontent] = 0;
                peers[idx].ncontent++;
                peers[idx].tcp_port = (u16)tcp_port;
                sprintf(msg, "Registered content '%s' for peer '%s'", contentName, peerName);
                send_ack(s, &cli, clen, msg);
                sprintf(logb, "REG existing name=%s ip=%s tcp=%d content=%s", peerName, cip, tcp_port, contentName);
                log_msg(logb);
            } else {
                freei = first_free_peer_slot();
                if (freei < 0) { send_err(s, &cli, clen, "Peer table full"); continue; }
                p = &peers[freei];
                memset(p, 0, sizeof(*p));
                p->in_use = 1;
                strncpy(p->name, peerName, NAME_LEN);
                p->name[NAME_LEN] = '\0';
                strncpy(p->ip, cip, sizeof(p->ip) - 1);
                p->tcp_port = (u16)tcp_port;
                p->ncontent = 1;
                strncpy(p->contents[0], contentName, NAME_LEN);
                p->contents[0][NAME_LEN] = '\0';
                p->sent_count[0] = 0;
                npeers++;
                sprintf(msg, "Peer '%s' registered with content '%s'", peerName, contentName);
                send_ack(s, &cli, clen, msg);
                sprintf(logb, "REG new name=%s ip=%s tcp=%d content=%s", peerName, cip, tcp_port, contentName);
                log_msg(logb);
            }
        }
        else if (in.type == T_SEARCH) {
            const char *fields[1];
            int nf;
            const char *contentName;
            int best_peer = -1;
            int best_count = 0x7fffffff;
            int best_content_idx = -1;
            int i;

            nf = parse_fields(in.data, sizeof(in.data), fields, 1);
            if (nf < 1) { send_err(s, &cli, clen, "Malformed S PDU"); continue; }
            contentName = fields[0];
            if (strlen(contentName) == 0 || strlen(contentName) > NAME_LEN) {
                send_err(s, &cli, clen, "Invalid content name");
                continue;
            }

            for (i = 0; i < MAX_PEERS; i++) {
                if (!peers[i].in_use) continue;
                {
                    int cidx = find_content_index_in_peer(&peers[i], contentName);
                    if (cidx >= 0) {
                        int c = peers[i].sent_count[cidx];
                        if (c < best_count) {
                            best_count = c;
                            best_peer = i;
                            best_content_idx = cidx;
                        }
                    }
                }
            }
            if (best_peer < 0) {
                send_err(s, &cli, clen, "Content not found");
            } else {
                char pbuf[16];
                int off = 0;
                int iplen;
                int plen;
                memset(&out, 0, sizeof(out));
                out.type = T_SEARCH;
                iplen = (int)strlen(peers[best_peer].ip) + 1;
                memcpy(out.data + off, peers[best_peer].ip, iplen);
                off += iplen;
                sprintf(pbuf, "%u", peers[best_peer].tcp_port);
                plen = (int)strlen(pbuf) + 1;
                memcpy(out.data + off, pbuf, plen);
                sendto(s, &out, sizeof(out), 0, (struct sockaddr *)&cli, clen);

                if (best_content_idx >= 0 &&
                    peers[best_peer].sent_count[best_content_idx] < 0x7fffffff) {
                    peers[best_peer].sent_count[best_content_idx]++;
                }

                printf("S: '%s' -> %s:%u (peer=%s)\n",
                       contentName, peers[best_peer].ip, peers[best_peer].tcp_port, peers[best_peer].name);
            }
        }
        else if (in.type == T_DEREG) {
            const char *fields[1];
            int nf;
            const char *contentName;
            int pi;
            Peer *p;
            int ci;
            int k;
            char logb[256];

            nf = parse_fields(in.data, sizeof(in.data), fields, 1);
            if (nf < 1) { send_err(s, &cli, clen, "Malformed T PDU"); continue; }
            contentName = fields[0];

            pi = find_peer_by_ip(cip);
            if (pi < 0) { send_err(s, &cli, clen, "You are not registered"); continue; }

            p = &peers[pi];
            ci = find_content_index_in_peer(p, contentName);
            if (ci < 0) { send_err(s, &cli, clen, "Content not hosted by you"); continue; }

            for (k = ci + 1; k < p->ncontent; k++) {
                strcpy(p->contents[k - 1], p->contents[k]);
                p->sent_count[k - 1] = p->sent_count[k];
            }
            if (p->ncontent > 0) {
                memset(p->contents[p->ncontent - 1], 0, sizeof(p->contents[p->ncontent - 1]));
                p->sent_count[p->ncontent - 1] = 0;
                p->ncontent--;
            }

            if (p->ncontent == 0) {
                sprintf(logb, "DEREG peer %s removed entirely", p->name);
                log_msg(logb);
                memset(p, 0, sizeof(*p));
                p->in_use = 0;
                npeers--;
                send_ack(s, &cli, clen, "Content removed and peer de-registered");
            } else {
                sprintf(logb, "DEREG peer %s removed content '%s'", p->name, contentName);
                log_msg(logb);
                send_ack(s, &cli, clen, "Content de-registered");
            }
        }
        else if (in.type == T_BYE) {
            const char *fields[1];
            int nf;
            const char *peerName;
            int pi;
            nf = parse_fields(in.data, sizeof(in.data), fields, 1);
            if (nf < 1) { send_err(s, &cli, clen, "Malformed B PDU"); continue; }
            peerName = fields[0];
            pi = find_peer_by_name(peerName);
            if (pi >= 0) {
                char logb[128];
                sprintf(logb, "BYE peer %s removed", peers[pi].name);
                log_msg(logb);
                memset(&peers[pi], 0, sizeof(peers[pi]));
                npeers--;
                send_ack(s, &cli, clen, "Peer removed");
            } else {
                send_ack(s, &cli, clen, "No matching peer");
            }
        }
        else if (in.type == T_LIST) {
            char uniq[MAX_PEERS * MAX_CONTENT][NAME_LEN + 1];
            int  ucount = 0;
            int  i, j, k;
            int  bytes;
            UdpPDU page;

            memset(uniq, 0, sizeof(uniq));

            for (i = 0; i < MAX_PEERS; i++) {
                if (!peers[i].in_use) continue;
                for (j = 0; j < peers[i].ncontent; j++) {
                    const char *nm = peers[i].contents[j];
                    int seen = 0;
                    for (k = 0; k < ucount; k++) {
                        if (strcmp(uniq[k], nm) == 0) { seen = 1; break; }
                    }
                    if (!seen && ucount < (int)(sizeof(uniq) / sizeof(uniq[0]))) {
                        strncpy(uniq[ucount], nm, NAME_LEN);
                        uniq[ucount][NAME_LEN] = '\0';
                        ucount++;
                    }
                }
            }

            if (ucount == 0) {
                memset(&page, 0, sizeof(page));
                page.type = T_LISTEND;
                sendto(s, &page, sizeof(page), 0, (struct sockaddr *)&cli, clen);
            } else {
                char line[UDP_BUFLEN];
                int need, linelen;

                memset(&page, 0, sizeof(page));
                bytes = 0;

                for (i = 0; i < ucount; i++) {
                    memset(line, 0, sizeof(line));
                    strncpy(line, uniq[i], sizeof(line) - 1);
                    if (strlen(line) + 3 < sizeof(line)) strcat(line, " : ");
                    linelen = (int)strlen(line);

                    for (j = 0; j < MAX_PEERS; j++) {
                        if (!peers[j].in_use) continue;
                        if (find_content_index_in_peer(&peers[j], uniq[i]) >= 0) {
                            int extra = (linelen > (int)strlen(uniq[i]) + 3) ? 2 : 0;
                            int need_room = extra + (int)strlen(peers[j].name) + 1;
                            if (linelen + need_room >= (int)sizeof(line)) {
                                if (linelen + 4 < (int)sizeof(line)) strcat(line, "...");
                                break;
                            }
                            if (extra) { strcat(line, ", "); linelen += 2; }
                            strcat(line, peers[j].name);
                            linelen += (int)strlen(peers[j].name);
                        }
                    }

                    need = (int)strlen(line) + 1;
                    if (bytes + need > UDP_BUFLEN) {
                        page.type = T_LISTMID;
                        memcpy(page.data, page.data, 0);
                        sendto(s, &page, sizeof(page), 0, (struct sockaddr *)&cli, clen);
                        memset(&page, 0, sizeof(page));
                        bytes = 0;
                    }
                    memcpy(page.data + bytes, line, need);
                    bytes += need;
                }
                page.type = T_LISTEND;
                sendto(s, &page, sizeof(page), 0, (struct sockaddr *)&cli, clen);
            }
        }
        else {
            send_err(s, &cli, clen, "Unknown PDU type");
        }
    }
    return 0;
}
/* Watermark: End of directory_server.c — KrishAdmin */
EOF

  cat > "${SRC_DIR}/peer_node.c" <<'EOF'
/* Watermark: Krish Patel (KrishAdmin) — peer_node.c */
/* Watermark: https://krishadmin.com */
#define _POSIX_C_SOURCE 200112L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <ctype.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netdb.h>

#include "protocol.h"

#ifndef INDEX_PORT
#define INDEX_PORT 15000
#endif

static char peerName[NAME_LEN + 1];
static char contentList[MAX_CONTENT][NAME_LEN + 1];
static int  nContent = 0;

static int  udp_sock = -1;
static struct sockaddr_in index_addr;
static socklen_t index_addrlen;

static int  tcp_listen = -1;
static u16  listen_port = 0;
static pid_t host_pid = -1;

static void die(const char *msg) { perror(msg); exit(1); }

static void print_menu(void) {
    printf("\nOptions:\n");
    printf("  R : Register content\n");
    printf("  D : Download content\n");
    printf("  O : List available content (content : hosts)\n");
    printf("  T : De register content\n");
    printf("  Q : Quit (de register all)\n");
    printf("Choice: ");
    fflush(stdout);
}
static void print_menu_delayed(void) { sleep(3); print_menu(); }

static int recv_n(int fd, void *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t r = recv(fd, (char*)buf + got, len - got, 0);
        if (r <= 0) return 0;
        got += (size_t)r;
    }
    return 1;
}

static void create_udp_and_index(const char *host, int port) {
    struct hostent *he;
    udp_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp_sock < 0) die("socket(UDP)");
    memset(&index_addr, 0, sizeof(index_addr));
    index_addr.sin_family = AF_INET;
    index_addr.sin_port = htons(port);
    he = gethostbyname(host);
    if (!he || !he->h_addr_list || !he->h_addr_list[0]) { fprintf(stderr, "gethostbyname failed for %s\n", host); exit(1); }
    memcpy(&index_addr.sin_addr.s_addr, he->h_addr_list[0], he->h_length);
    index_addrlen = sizeof(index_addr);
}

static void ensure_tcp_listen(void) {
    int yes;
    struct sockaddr_in a;
    socklen_t alen;
    if (tcp_listen != -1) return;
    tcp_listen = socket(AF_INET, SOCK_STREAM, 0);
    if (tcp_listen < 0) die("socket(TCP)");
    yes = 1; setsockopt(tcp_listen, SOL_SOCKET, SO_REUSEADDR, (void*)&yes, sizeof(yes));
    memset(&a, 0, sizeof(a)); a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_ANY); a.sin_port = htons(0);
    if (bind(tcp_listen, (struct sockaddr*)&a, sizeof(a)) < 0) die("bind");
    if (listen(tcp_listen, 16) < 0) die("listen");
    alen = sizeof(a);
    if (getsockname(tcp_listen, (struct sockaddr*)&a, &alen) < 0) die("getsockname");
    listen_port = (u16)ntohs(a.sin_port);
    printf("Hosting TCP on port %u\n", (unsigned)listen_port);
}

static void send_tcp_err(int cs, const char *msg) {
    TcpPDU err;
    size_t tosend;
    size_t mlen = strlen(msg);
    memset(&err, 0, sizeof(err));
    err.type = T_ERR;
    err.len  = (u16)mlen;
    memcpy(err.data, msg, mlen);
    tosend = sizeof(char) + sizeof(u16) + mlen;
    send(cs, &err, tosend, 0);
}

static void hosting_loop(void) {
    printf("Content hosting started\n");
    while (1) {
        struct sockaddr_in cli; socklen_t clen = sizeof(cli); int cs;
        char cip[INET_ADDRSTRLEN]; char hdr_type; u16 hdr_len; char reqname[UDP_BUFLEN+1];
        int i, allowed, fd; char out_type; u16 out_len; char buf[UDP_BUFLEN]; ssize_t nr;

        memset(&cli, 0, sizeof(cli));
        cs = accept(tcp_listen, (struct sockaddr *)&cli, &clen);
        if (cs < 0) { perror("accept"); continue; }
        strcpy(cip, inet_ntoa(cli.sin_addr));

        if (!recv_n(cs, &hdr_type, sizeof(hdr_type)) || !recv_n(cs, &hdr_len, sizeof(hdr_len))) {
            send_tcp_err(cs, "Bad request"); close(cs); continue;
        }
        if (hdr_type != T_REQ || hdr_len == 0 || hdr_len > UDP_BUFLEN) {
            send_tcp_err(cs, "Bad request"); close(cs); continue;
        }
        memset(reqname, 0, sizeof(reqname));
        if (!recv_n(cs, reqname, hdr_len)) { close(cs); continue; }

        printf("Incoming download from %s for '%s'\n", cip, reqname);

        allowed = 0;
        for (i = 0; i < nContent; i++) {
            if (strcmp(contentList[i], reqname) == 0) { allowed = 1; break; }
        }
        if (!allowed) { send_tcp_err(cs, "Content not hosted here"); close(cs); continue; }

        fd = open(reqname, O_RDONLY);
        if (fd < 0) { send_tcp_err(cs, "File open failed"); close(cs); continue; }

        while (1) {
            nr = read(fd, buf, sizeof(buf));
            if (nr < 0) { perror("read"); break; }
            if (nr == 0) {
                out_type = T_FINAL; out_len = 0;
                send(cs, &out_type, sizeof(out_type), 0);
                send(cs, &out_len, sizeof(out_len), 0);
                break;
            }
            out_type = (nr < (ssize_t)sizeof(buf)) ? T_FINAL : T_CHUNK;
            out_len = (u16)nr;
            send(cs, &out_type, sizeof(out_type), 0);
            send(cs, &out_len, sizeof(out_len), 0);
            if (out_len) send(cs, buf, out_len, 0);
            if (out_type == T_FINAL) break;
        }
        close(fd);
        close(cs);
    }
}

static int register_content_udp(const char *content) {
    UdpPDU p, r;
    int off = 0;
    int n1, n2, n3;
    char pbuf[16];

    ensure_tcp_listen();
    memset(&p, 0, sizeof(p));
    p.type = T_REG;

    n1 = (int)strlen(peerName) + 1;
    n2 = (int)strlen(content) + 1;
    sprintf(pbuf, "%u", (unsigned)listen_port);
    n3 = (int)strlen(pbuf) + 1;

    if (n1 + n2 + n3 > UDP_BUFLEN) { fprintf(stderr, "Register payload too large\n"); return 0; }
    memcpy(p.data + off, peerName, n1); off += n1;
    memcpy(p.data + off, content,  n2); off += n2;
    memcpy(p.data + off, pbuf,     n3);

    if (sendto(udp_sock, &p, sizeof(p), 0, (struct sockaddr *)&index_addr, index_addrlen) < 0) { perror("sendto"); return 0; }
    memset(&r, 0, sizeof(r));
    if (recvfrom(udp_sock, &r, sizeof(r), 0, NULL, NULL) < 0) { perror("recvfrom"); return 0; }
    if (r.type == T_ERR) { printf("Register error: %s\n", r.data); return 0; }
    printf("%s\n", r.data);
    return 1;
}

static int dereg_content_udp(const char *content) {
    UdpPDU p, r;
    memset(&p, 0, sizeof(p)); p.type = T_DEREG; sprintf(p.data, "%s", content);
    if (sendto(udp_sock, &p, sizeof(p), 0, (struct sockaddr *)&index_addr, index_addrlen) < 0) { perror("sendto"); return 0; }
    memset(&r, 0, sizeof(r));
    if (recvfrom(udp_sock, &r, sizeof(r), 0, NULL, NULL) < 0) { perror("recvfrom"); return 0; }
    if (r.type == T_ERR) { printf("%s\n", r.data); return 0; }
    printf("%s\n", r.data);
    return 1;
}

static int search_udp(const char *content, char *out_ip, size_t iplen, u16 *out_port) {
    UdpPDU p, r;
    int i;
    memset(&p, 0, sizeof(p)); p.type = T_SEARCH; sprintf(p.data, "%s", content);
    if (sendto(udp_sock, &p, sizeof(p), 0, (struct sockaddr *)&index_addr, index_addrlen) < 0) { perror("sendto"); return 0; }
    memset(&r, 0, sizeof(r));
    if (recvfrom(udp_sock, &r, sizeof(r), 0, NULL, NULL) < 0) { perror("recvfrom"); return 0; }
    if (r.type == T_ERR) { printf("%s\n", r.data); return 0; }
    i = 0;
    strncpy(out_ip, r.data, iplen - 1);
    out_ip[iplen - 1] = '\0';
    while (i < UDP_BUFLEN && r.data[i] != '\0') i++;
    if (i >= UDP_BUFLEN) return 0;
    i++;
    *out_port = (u16)atoi(&r.data[i]);
    return 1;
}

static int tcp_download(const char *server_ip, u16 server_port, const char *content) {
    int cs;
    struct sockaddr_in sa;
    char hdr_type;
    u16 hdr_len;
    FILE *fp;
    char rh_type;
    u16 rh_len;
    char buf[UDP_BUFLEN];

    cs = socket(AF_INET, SOCK_STREAM, 0); if (cs < 0) { perror("socket"); return 0; }
    memset(&sa, 0, sizeof(sa)); sa.sin_family = AF_INET; sa.sin_port = htons(server_port);
    if (inet_pton(AF_INET, server_ip, &sa.sin_addr) != 1) { perror("inet_pton"); close(cs); return 0; }
    if (connect(cs, (struct sockaddr *)&sa, sizeof(sa)) < 0) { perror("connect"); close(cs); return 0; }

    hdr_type = T_REQ; hdr_len = (u16)(strlen(content) + 1);
    if (send(cs, &hdr_type, sizeof(hdr_type), 0) < 0 ||
        send(cs, &hdr_len, sizeof(hdr_len), 0) < 0 ||
        send(cs, content, hdr_len, 0) < 0) { perror("send"); close(cs); return 0; }

    fp = fopen(content, "wb"); if (!fp) { perror("fopen"); close(cs); return 0; }

    while (1) {
        if (!recv_n(cs, &rh_type, sizeof(rh_type)) || !recv_n(cs, &rh_len, sizeof(rh_len))) { perror("recv"); fclose(fp); close(cs); return 0; }
        if (rh_type == T_ERR) {
            if (rh_len > 0 && rh_len <= UDP_BUFLEN) {
                if (!recv_n(cs, buf, rh_len)) perror("recv");
                fwrite(buf, 1, rh_len, stdout); fputc('\n', stdout);
            }
            fclose(fp); close(cs); return 0;
        }
        if (rh_len > UDP_BUFLEN) { fprintf(stderr, "Bad length\n"); fclose(fp); close(cs); return 0; }
        if (rh_len > 0) {
            if (!recv_n(cs, buf, rh_len)) { perror("recv"); fclose(fp); close(cs); return 0; }
            fwrite(buf, 1, rh_len, fp);
        }
        if (rh_type == T_FINAL) break;
    }

    fclose(fp);
    close(cs);
    printf("File '%s' received\n", content);
    return 1;
}

int main(int argc, char **argv) {
    const char *host;
    int c;

    if (argc < 3) {
        fprintf(stderr, "Usage: %s <index_host> <peer_name>\n", argv[0]);
        return 1;
    }

    host = argv[1];
    memset(peerName, 0, sizeof(peerName));
    strncpy(peerName, argv[2], sizeof(peerName) - 1);
    if (strlen(peerName) == 0 || strlen(peerName) > NAME_LEN) {
        fprintf(stderr, "Peer name must be 1..%d chars\n", NAME_LEN);
        return 1;
    }

    create_udp_and_index(host, INDEX_PORT);
    print_menu();

    while (1) {
        c = getchar();
        if (c == '\n') continue;
        if (c == EOF) break;

        if (c == 'R' || c == 'r') {
            char fname[NAME_LEN + 2];
            int ch;
            int i;
            int dup = 0;
            struct stat st;

            memset(fname, 0, sizeof(fname));
            printf("Enter file name to register (max %d chars): ", NAME_LEN);
            if (scanf("%50s", fname) != 1) { printf("Input error\n"); print_menu_delayed(); continue; }
            while ((ch = getchar()) != '\n' && ch != EOF) {}

            if (stat(fname, &st) != 0 || !S_ISREG(st.st_mode)) {
                printf("File not found in this directory, cannot host\n");
                print_menu_delayed();
                continue;
            }

            for (i = 0; i < nContent; i++) if (strcmp(contentList[i], fname) == 0) dup = 1;
            if (dup) { printf("Already registered locally\n"); print_menu_delayed(); continue; }

            if (!register_content_udp(fname)) { print_menu_delayed(); continue; }

            if (nContent < MAX_CONTENT) {
                strncpy(contentList[nContent], fname, sizeof(contentList[nContent]) - 1);
                nContent++;
            }
            ensure_tcp_listen();
            if (host_pid <= 0) {
                host_pid = fork();
                if (host_pid == 0) { hosting_loop(); _exit(0); }
            }
            print_menu_delayed();
        }
        else if (c == 'D' || c == 'd') {
            char query[NAME_LEN + 2];
            char ip[INET_ADDRSTRLEN];
            u16 port;
            int ch;
            int already = 0;
            int i;

            memset(query, 0, sizeof(query));
            memset(ip, 0, sizeof(ip));
            printf("Enter file name to download: ");
            if (scanf("%50s", query) != 1) { printf("Input error\n"); print_menu_delayed(); continue; }
            while ((ch = getchar()) != '\n' && ch != EOF) {}

            if (!search_udp(query, ip, sizeof(ip), &port)) { print_menu_delayed(); continue; }
            if (!tcp_download(ip, port, query)) { print_menu_delayed(); continue; }

            for (i = 0; i < nContent; i++) if (strcmp(contentList[i], query) == 0) { already = 1; break; }
            if (!already && nContent < MAX_CONTENT) {
                strncpy(contentList[nContent], query, sizeof(contentList[nContent]) - 1);
                nContent++;
            }
            if (!register_content_udp(query)) {
            } else {
                ensure_tcp_listen();
                if (host_pid <= 0) { host_pid = fork(); if (host_pid == 0) { hosting_loop(); _exit(0); } }
            }
            print_menu_delayed();
        }
        else if (c == 'O' || c == 'o') {
            UdpPDU p, r;
            int i;

            memset(&p, 0, sizeof(p)); p.type = T_LIST;
            if (sendto(udp_sock, &p, sizeof(p), 0, (struct sockaddr *)&index_addr, index_addrlen) < 0) {
                perror("sendto"); print_menu_delayed(); continue;
            }
            printf("\nAvailable content on network (content : hosts):\n");
            while (1) {
                if (recvfrom(udp_sock, &r, sizeof(r), 0, NULL, NULL) < 0) { perror("recvfrom"); break; }
                if (r.type == T_LISTEND && r.data[0] == '\0') { printf("(none)\n"); break; }
                for (i = 0; i < UDP_BUFLEN; ) {
                    if (r.data[i] == '\0') break;
                    printf(" - %s\n", &r.data[i]);
                    while (i < UDP_BUFLEN && r.data[i] != '\0') i++;
                    if (i < UDP_BUFLEN && r.data[i] == '\0') i++;
                }
                if (r.type == T_LISTEND) break;
            }
            print_menu_delayed();
        }
        else if (c == 'T' || c == 't') {
            char fname[NAME_LEN + 2];
            int ch, i, pos;

            memset(fname, 0, sizeof(fname));
            printf("Enter file name to de register: ");
            if (scanf("%50s", fname) != 1) { printf("Input error\n"); print_menu_delayed(); continue; }
            while ((ch = getchar()) != '\n' && ch != EOF) {}

            if (dereg_content_udp(fname)) {
                pos = -1;
                for (i = 0; i < nContent; i++) if (strcmp(contentList[i], fname) == 0) { pos = i; break; }
                if (pos >= 0) {
                    for (i = pos + 1; i < nContent; i++) strcpy(contentList[i - 1], contentList[i]);
                    nContent--;
                    if (nContent >= 0) memset(contentList[nContent], 0, sizeof(contentList[nContent]));
                }
            }
            print_menu_delayed();
        }
        else if (c == 'Q' || c == 'q') {
            int i;
            UdpPDU bye;
            for (i = nContent - 1; i >= 0; i--) dereg_content_udp(contentList[i]);
            memset(&bye, 0, sizeof(bye)); bye.type = T_BYE;
            strncpy(bye.data, peerName, sizeof(bye.data) - 1);
            sendto(udp_sock, &bye, sizeof(bye), 0, (struct sockaddr *)&index_addr, index_addrlen);
            if (host_pid > 0) { kill(host_pid, SIGKILL); host_pid = -1; }
            if (tcp_listen != -1) close(tcp_listen);
            printf("Goodbye\n");
            break;
        }
        else {
            int ch2; while ((ch2 = getchar()) != '\n' && ch2 != EOF) {}
            print_menu_delayed();
        }
    }
    return 0;
}
/* Watermark: End of peer_node.c — KrishAdmin */
EOF

  cat > "${SRC_DIR}/Makefile" <<'EOF'
# Watermark: Krish Patel (KrishAdmin) — Makefile
# Watermark: https://krishadmin.com
CC=gcc
CFLAGS=-Wall -Wextra -O2 -std=c89

all: directory_server peer_node

directory_server: directory_server.c protocol.h
	$(CC) $(CFLAGS) directory_server.c -o ../bin/directory_server

peer_node: peer_node.c protocol.h
	$(CC) $(CFLAGS) peer_node.c -o ../bin/peer_node

clean:
	rm -f ../bin/directory_server ../bin/peer_node
# Watermark: End of Makefile — KrishAdmin
EOF
}

build_all() {
  (cd "${SRC_DIR}" && make -s clean && make -s)
}

start_index() {
  mkdir -p "${LOG_DIR}" "${PID_DIR}"
  if pgrep -f "${BIN_DIR}/directory_server" >/dev/null 2>&1; then
    echo "Index already running."
    return
  fi
  P2P_LOG_DIR="${LOG_DIR}" nohup "${BIN_DIR}/directory_server" 15000 >/dev/null 2>&1 &
  echo $! > "${PID_DIR}/index.pid"
  sleep 0.3
  echo "Index started. PID $(cat "${PID_DIR}/index.pid")"
  echo "Logs in ${LOG_DIR}/index-YYYYMMDD-HHMMSS.log"
}

stop_all() {
  if [[ -f "${PID_DIR}/index.pid" ]] && kill -0 "$(cat "${PID_DIR}/index.pid")" 2>/dev/null; then
    kill "$(cat "${PID_DIR}/index.pid")" || true
    sleep 0.3 || true
  fi
  pkill -f "${BIN_DIR}/directory_server" >/dev/null 2>&1 || true
  pkill -f "${BIN_DIR}/peer_node"  >/dev/null 2>&1 || true
  rm -f "${PID_DIR}/index.pid" || true
  echo "Stopped index and peers."
}

clean_all() {
  stop_all || true
  (cd "${SRC_DIR}" && make -s clean) || true
  rm -rf "${BIN_DIR}" "${LOG_DIR}" "${PID_DIR}" "${PEERS_DIR}"
  mkdir -p "${BIN_DIR}" "${LOG_DIR}" "${PID_DIR}" "${PEERS_DIR}"
  echo "Cleaned workspace."
}

run_peer() {
  local name="${1:-Peer1}"
  mkdir -p "${PEERS_DIR}/${name}"
  echo "Launching peer '${name}'. Work dir: ${PEERS_DIR}/${name}"
  ( cd "${PEERS_DIR}/${name}" && "${BIN_DIR}/peer_node" 127.0.0.1 "${name}" )
}

usage() {
  echo "Usage: $0 {setup|build|start|peer <NAME>|stop|clean}"
}

cmd="${1:-build}"
need_tools
case "${cmd}" in
  setup) write_sources; echo "Sources written to ${SRC_DIR}" ;;
  build) write_sources; build_all; echo "Built to ${BIN_DIR}" ;;
  start) [[ -x "${BIN_DIR}/directory_server" ]] || { write_sources; build_all; }; start_index ;;
  peer)  shift || true; [[ -x "${BIN_DIR}/peer_node"  ]] || { write_sources; build_all; }; run_peer "${1:-Peer1}" ;;
  stop)  stop_all ;;
  clean) clean_all ;;
  *) usage; exit 1 ;;
esac

# Watermark: End of bootstrap script — Krish Patel (KrishAdmin) — https://krishadmin.com
