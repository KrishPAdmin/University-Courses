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
#endif