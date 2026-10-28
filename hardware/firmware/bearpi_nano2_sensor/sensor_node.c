/**
 * 星枢 SparkHub · 传感器节点主程序（小熊派 Nano 2 / Hi3861）
 *
 * 实现一个完整的"感知 → 上报 → 接收指令 → 执行"闭环，
 * 并额外加入主机失联时的本地自治 —— 对应方案里"房间级规则自治"的设计。
 *
 * 阶段 1 只跑采集与串口打印；阶段 2 加上行；阶段 3 加执行器；
 * 阶段 4 把 udp_link 换成星闪 SLE，本文件的业务逻辑不需要改动。
 */

#include <stdio.h>
#include <string.h>

#include "cmsis_os2.h"
#include "ohos_init.h"

#include "config.h"
#include "relay.h"
#include "sht40.h"
#include "udp_link.h"

/* 节点 ID、采集周期、超时阈值、阈值开关等可调项全部集中在 config.h，
 * 现场改参数只动那一个文件。 */

/* 浮点转定点：上报用 ×100 的整数，避免依赖精简 libc 的 %f 支持 */
#define CENTI(v)  ((int)((v) * 100.0f + ((v) >= 0.0f ? 0.5f : -0.5f)))

static const UdpLinkConfig g_cfg = {
    WIFI_SSID, WIFI_PSK, HOST_IP, HOST_PORT
};

/* 最近一次收到主机指令的时刻，用于判断主机是否在线 */
static volatile unsigned int g_lastHostCmdTick = 0;

/* ---------------------------------------------------------------- 指令处理 */

static void HandleCommand(const char *cmd)
{
    printf("[cmd] recv: %s\n", cmd);
    g_lastHostCmdTick = osKernelGetTickCount();

    /* 格式：CMD,LIGHT,0 或 CMD,LIGHT,1 */
    if (strncmp(cmd, "CMD,LIGHT,", 10) == 0) {
        int on = (cmd[10] == '1') ? 1 : 0;
        RelaySet(on);
        printf("[cmd] relay -> %d\n", on);
    }
}

/* ------------------------------------------------------------ 主机在线判定 */

static int HostOnline(void)
{
    unsigned int now;

    if (g_lastHostCmdTick == 0) {
        return 0; /* 从未收到过指令 */
    }
    now = osKernelGetTickCount();
    return (now - g_lastHostCmdTick) < HOST_TIMEOUT_MS;
}

/* ---------------------------------------------------------------- 采集任务 */

static void SensorTask(void *arg)
{
    Sht40Reading r;
    char line[128];
    unsigned int tick;

    (void)arg;

    for (;;) {
        if (Sht40Read(&r) != 0) {
            printf("[sensor] SHT40 read failed\n");
            osDelay(SAMPLE_INTERVAL_MS);
            continue;
        }

        tick = osKernelGetTickCount();

        /*
         * 本地自治兜底：主机失联时按阈值自行动作。
         * 这是方案里"去中心化"的最小可演示形态 ——
         * 演示时把主机关掉，节点依旧会按本地规则点亮灯。
         */
        if (!HostOnline()) {
            int want = (r.temperature > CONTROL_TEMP_HIGH) ? 1 : 0;
            if (want != RelayGet()) {
                RelaySet(want);
                printf("[local] host offline, autonomous relay -> %d\n", want);
            }
        }

        (void)snprintf(line, sizeof(line), "NODE,%s,T=%d,H=%d,UP=%d,TS=%u",
                       NODE_ID, CENTI(r.temperature), CENTI(r.humidity),
                       UdpLinkIsUp(), tick);

        /* 串口始终打印一份 —— 阶段 1 的验收就靠这行日志 */
        printf("[sensor] %s\n", line);

        if (UdpLinkIsUp()) {
            if (UdpSendStr(line) < 0) {
                printf("[sensor] send failed\n");
            }
        }

        osDelay(SAMPLE_INTERVAL_MS);
    }
}

/* ---------------------------------------------------------------- 指令任务 */

static void CommandTask(void *arg)
{
    char buf[128];
    int n;

    (void)arg;

    for (;;) {
        n = UdpRecvStr(buf, sizeof(buf));
        if (n > 0) {
            HandleCommand(buf);
        }
        osDelay(CMD_POLL_MS);
    }
}

/* -------------------------------------------------------------------- 启动 */

static void SensorNodeInit(void)
{
    osThreadAttr_t attr = {0};
    int ret;

    printf("\n[node] SparkHub sensor node booting...\n");

    if (Sht40Init() != 0) {
        printf("[node] SHT40 init FAILED (check I2C wiring on the E53 header)\n");
    } else {
        printf("[node] SHT40 ok\n");
    }

    if (RelayInit() != 0) {
        printf("[node] relay init FAILED (check GPIO number)\n");
    } else {
        printf("[node] relay ok\n");
    }

    ret = UdpLinkInit(&g_cfg);
    if (ret != 0) {
        /* 链路失败不阻塞启动：本地采集与自治仍要能工作 */
        printf("[node] link init failed: %d (will keep running locally)\n", ret);
    } else {
        printf("[node] link up, reporting to %s:%d\n", HOST_IP, HOST_PORT);
    }

    attr.name = "sensorTask";
    attr.stack_size = 4096;
    attr.priority = osPriorityNormal;
    (void)osThreadNew(SensorTask, NULL, &attr);

    attr.name = "cmdTask";
    attr.stack_size = 4096;
    attr.priority = osPriorityNormal;
    (void)osThreadNew(CommandTask, NULL, &attr);

    printf("[node] boot done\n");
}

APP_FEATURE_INIT(SensorNodeInit);
