#include "udp_link.h"

#include <string.h>

#include "cmsis_os2.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"
#include "wifi_device.h"

#define WIFI_CONNECT_TIMEOUT_MS 15000
#define RECV_BUF_LEN            128

static int g_sock = -1;
static int g_wifiUp = 0;
static struct sockaddr_in g_dest;
static osSemaphoreId_t g_connectSem = NULL;

/* ---------------------------------------------------------------- Wi-Fi */

static void OnWifiConnectionChanged(int state, WifiLinkedInfo *info)
{
    (void)info;
    /* 注意：常量名 WIFI_STATE_AVALIABLE 在 OpenHarmony SDK 中就是这个拼写 */
    if (state == WIFI_STATE_AVALIABLE) {
        g_wifiUp = 1;
        if (g_connectSem != NULL) {
            osSemaphoreRelease(g_connectSem);
        }
    } else {
        g_wifiUp = 0;
    }
}

static void OnWifiScanStateChanged(int state, int size)
{
    (void)state;
    (void)size;
}

static int WifiConnect(const char *ssid, const char *psk)
{
    WifiEvent event = {0};
    WifiDeviceConfig config = {0};
    WifiErrorCode err;

    event.OnWifiConnectionChanged = OnWifiConnectionChanged;
    event.OnWifiScanStateChanged = OnWifiScanStateChanged;

    err = RegisterWifiEvent(&event);
    if (err != WIFI_SUCCESS) {
        return -1;
    }

    err = EnableWifi();
    if (err != WIFI_SUCCESS) {
        return -2;
    }

    strncpy(config.ssid, ssid, WIFI_MAX_SSID_LEN - 1);
    strncpy(config.preSharedKey, psk, WIFI_MAX_KEY_LEN - 1);
    config.securityType = WIFI_SEC_TYPE_PSK;

    err = ConnectTo(&config);
    if (err != WIFI_SUCCESS) {
        return -3;
    }

    if (osSemaphoreAcquire(g_connectSem, WIFI_CONNECT_TIMEOUT_MS) != osOK) {
        return -4; /* 超时：检查 SSID / 密码 / 信号强度 */
    }
    return 0;
}

/* --------------------------------------------------------------- UDP */

int UdpLinkInit(const UdpLinkConfig *cfg)
{
    struct sockaddr_in local;
    int flags;
    int ret;

    if (cfg == NULL) {
        return -1;
    }

    if (g_connectSem == NULL) {
        g_connectSem = osSemaphoreNew(1, 0, NULL);
        if (g_connectSem == NULL) {
            return -2;
        }
    }

    ret = WifiConnect(cfg->ssid, cfg->psk);
    if (ret != 0) {
        return ret;
    }

    g_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (g_sock < 0) {
        return -10;
    }

    /* 绑定本地端口，这样主机才可以把控制指令回发给我们 */
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons(cfg->port);
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(g_sock, (struct sockaddr *)&local, sizeof(local)) < 0) {
        return -11;
    }

    memset(&g_dest, 0, sizeof(g_dest));
    g_dest.sin_family = AF_INET;
    g_dest.sin_port = htons(cfg->port);
    g_dest.sin_addr.s_addr = inet_addr(cfg->host);

    /* 设为非阻塞，让接收轮询不卡住采集任务 */
    flags = fcntl(g_sock, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(g_sock, F_SETFL, flags | O_NONBLOCK);
    }

    return 0;
}

int UdpSendStr(const char *text)
{
    int len;

    if (g_sock < 0 || text == NULL) {
        return -1;
    }

    len = (int)strlen(text);
    return sendto(g_sock, text, (size_t)len, 0,
                  (struct sockaddr *)&g_dest, sizeof(g_dest));
}

int UdpRecvStr(char *buf, int maxLen)
{
    struct sockaddr_in from;
    socklen_t fromLen = sizeof(from);
    int n;

    if (g_sock < 0 || buf == NULL || maxLen <= 1) {
        return -1;
    }

    n = recvfrom(g_sock, buf, (size_t)(maxLen - 1), 0,
                 (struct sockaddr *)&from, &fromLen);
    if (n <= 0) {
        return 0; /* EAGAIN：暂无数据，不算错误 */
    }

    buf[n] = '\0';
    return n;
}

int UdpLinkIsUp(void)
{
    return g_wifiUp;
}
