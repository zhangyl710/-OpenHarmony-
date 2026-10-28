/**
 * UDP 通信层：负责 Wi-Fi 接入与数据的收发。
 *
 * 阶段 4 换星闪时，这一层整体替换成 SLE 的收发接口即可，
 * 上层 sensor_node.c 的业务逻辑不用改动 —— 这是刻意做的分层。
 */

#ifndef UDP_LINK_H
#define UDP_LINK_H

#include <stdint.h>

typedef struct {
    const char *ssid;   /* Wi-Fi 名称 */
    const char *psk;    /* Wi-Fi 密码 */
    const char *host;   /* 主机（Purple Pi）IP */
    uint16_t port;      /* 主机 UDP 端口 */
} UdpLinkConfig;

/**
 * 连接 Wi-Fi 并创建 UDP socket。
 * @return 0 成功，非 0 失败
 */
int UdpLinkInit(const UdpLinkConfig *cfg);

/**
 * 发送一个以 '\0' 结尾的字符串。
 * @return 实际发送字节数，负值为错误
 */
int UdpSendStr(const char *text);

/**
 * 非阻塞接收一行指令。
 * @param buf    接收缓冲
 * @param maxLen 缓冲长度（含结尾 '\0'）
 * @return >0 收到的字节数；0 表示当前无数据；负值为错误
 */
int UdpRecvStr(char *buf, int maxLen);

/**
 * @return 1 Wi-Fi 已连接，0 未连接
 */
int UdpLinkIsUp(void);

#endif /* UDP_LINK_H */
