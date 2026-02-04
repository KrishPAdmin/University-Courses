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
