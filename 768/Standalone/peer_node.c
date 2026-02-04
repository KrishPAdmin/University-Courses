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