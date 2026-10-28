/**
 * 星枢 SparkHub · MQTT 节点（小熊派 BearPi-HM Nano 2 / WS63）
 *
 * 链路：本节点 ──MQTT──> 本地 broker ──MQTT──> 鸿蒙看板
 *
 * 走华为 iot_link 的 MQTT 抽象层（mqtt_al）：
 *   - 实现由 SDK 的 libiot_link.a 提供（mqtt_al.c + paho_mqtt_port.c + paho MQTTClient-C）
 *   - 网络层（socket / 重连 / keepalive）华为已封好，我们只管收发
 *   - 这是 SDK 自带的、为 WS63 编好的，不依赖任何云平台
 *
 *   （弯路记录：SDK 的 libmqtt.a 是 paho 完整版，但 MQTTClient_create 在 WS63 上
 *     返回 -4 = PAHO_MEMORY_ERROR；自己编 paho MQTTClient-C 又会和 libiot_link.a
 *     里已有的同名符号冲突。mqtt_al 这层是唯一干净的路。）
 *
 * ── 两块板烧两份固件 ───────────────────────────────────
 *   装 E53_IA1 的那块：config.h 里定义 BOARD_IA1
 *   装 E53_SF1 的那块：config.h 里定义 BOARD_SF1
 *
 *   必须二选一！两个扩展板的头文件都定义了 CTL_OFF / CTL_ON 枚举，
 *   同时 include 会报重复定义。
 * ─────────────────────────────────────────────────────
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "ohos_init.h"        /* APP_FEATURE_INIT 定义在这里，缺了它启动流程不认识我们 */
#include "cmsis_os2.h"
#include <cJSON.h>

#include "config.h"

/* 华为 iot_link 的 MQTT 抽象层 —— 实现在 libiot_link.a 里 */
#include <mqtt_al.h>
#include "paho_mqtt_port.h"   /* mqtt_imp_init() */

#if defined(BOARD_IA1)
#include "E53_IA1.h"
#elif defined(BOARD_SF1)
#include "E53_SF1.h"
#else
#error "请在 config.h 里定义 BOARD_IA1 或 BOARD_SF1"
#endif

/* ==================== 改这里 ==================== */
#define MQTT_HOST       "192.168.87.43"      /* broker 地址（IP 或域名都行） */
#define MQTT_PORT       1883
#define TOPIC_DATA      "sparkhub/data"
#define TOPIC_CMD       "sparkhub/cmd"
/* ================================================ */

#define QOS             en_mqtt_al_qos_0
#define MQTT_TIMEOUT_MS 1000

/*
 * 上报周期
 *
 * ⚠️ 必须是 1000（1 Hz）。
 *
 *    AI 的 60 秒滑窗是按 1 Hz 设计的（见 ai/train.py 的 SEQ_LEN=60
 *    和端侧 harmony-cloud-app 的 Features.ets）。
 *    5 秒一轮的话，60 秒只能攒 12 个点，算出来的斜率/回落比全都不准。
 *
 *    两块板都要用这个值重编重烧。
 *    代价：MQTT 报文量 ×5（每块板 1 条/秒），局域网无压力。
 */
#define PUB_INTERVAL_MS 1000

/* 本地安全阈值 —— broker/主机断了也要能自保 */
#define SMOKE_ALARM_PPM   300.0f
#define TEMP_HIGH_C       45.0f

/* ============================================================
 * mqtt_al 的字符串字段是 char*，不能直接塞字符串字面量
 * ============================================================ */
static char g_host[]     = MQTT_HOST;
static char g_clientId[] = MQTT_CLIENTID;
static char g_topicData[] = TOPIC_DATA;
static char g_topicCmd[]  = TOPIC_CMD;

static void *g_handle = NULL;
static volatile int g_connected = 0;

/* 执行器状态（同时上报给看板） */
static volatile int g_lightOn = 0;
static volatile int g_motorOn = 0;
static volatile int g_beepOn = 0;

/* ============================================================
 * 传感器读取 —— 按板子角色分流
 * 没装对应扩展板的字段保持 0
 * ============================================================ */
static void ReadSensors(float *temp, float *humi, float *lux, float *smoke)
{
    *temp = 0.0f;
    *humi = 0.0f;
    *lux = 0.0f;
    *smoke = 0.0f;

#if defined(BOARD_IA1)
    E53IA1Data d;
    if (E53IA1ReadData(&d) == 0) {
        *temp = d.Temperature;
        *humi = d.Humidity;
        *lux = d.Lux;
    }
#elif defined(BOARD_SF1)
    float ppm = 0.0f;
    if (GetMQ2PPM(&ppm) == 0) {
        *smoke = ppm;
    }
#endif
}

/* ============================================================
 * 执行器控制 —— 按板子角色分流
 * ============================================================ */
static void SetLight(int on)
{
#if defined(BOARD_IA1)
    LightStatusSet(on ? CTL_ON : CTL_OFF);
#else
    (void)on;
#endif
}

static void SetMotor(int on)
{
#if defined(BOARD_IA1)
    MotorStatusSet(on ? CTL_ON : CTL_OFF);
#else
    (void)on;
#endif
}

static void SetBeep(int on)
{
#if defined(BOARD_SF1)
    BeepStatusSet(on ? CTL_ON : CTL_OFF);
#else
    (void)on;
#endif
}

/* ============================================================
 * 收到下行控制消息
 * payload 形如：{"target":"light","value":"ON"}
 *
 * 注意：这个回调在 mqtt_al 的内部线程里跑，只改状态 + 动硬件，
 *       别做耗时操作。
 * ============================================================ */
static void OnMessage(void *arg, mqtt_al_msgrcv_t *msg)
{
    char payload[160];
    int len;

    (void)arg;

    if (msg == NULL || msg->msg.data == NULL) {
        return;
    }

    len = msg->msg.len;
    if (len > (int)sizeof(payload) - 1) {
        len = (int)sizeof(payload) - 1;
    }
    if (len < 0) {
        len = 0;
    }
    memcpy(payload, msg->msg.data, len);
    payload[len] = '\0';

    printf("[mqtt] recv: %s\r\n", payload);

    cJSON *root = cJSON_Parse(payload);
    if (root != NULL) {
        cJSON *jt = cJSON_GetObjectItem(root, "target");
        cJSON *jv = cJSON_GetObjectItem(root, "value");
        const char *target = (jt != NULL) ? cJSON_GetStringValue(jt) : NULL;
        const char *value  = (jv != NULL) ? cJSON_GetStringValue(jv) : NULL;

        if (target != NULL && value != NULL) {
            int on = (strcmp(value, "ON") == 0);

            if (strcmp(target, "light") == 0) {
                g_lightOn = on;
                SetLight(on);
            } else if (strcmp(target, "motor") == 0) {
                g_motorOn = on;
                SetMotor(on);
            } else if (strcmp(target, "beep") == 0) {
                g_beepOn = on;
                SetBeep(on);
            } else {
                printf("[mqtt] unknown target: %s\r\n", target);
            }
            printf("[mqtt] %s -> %s\r\n", target, value);
        }
        cJSON_Delete(root);
    }
}

/* ============================================================
 * 采集 + 上报
 * ============================================================ */
static void PublishData(void)
{
    char payload[256];
    mqtt_al_pubpara_t pub;
    float temp, humi, lux, smoke;

    ReadSensors(&temp, &humi, &lux, &smoke);

    snprintf(payload, sizeof(payload),
             "{\"node\":\"%s\",\"temp\":%.1f,\"humi\":%.1f,\"lux\":%.0f,"
             "\"smoke\":%.0f,\"light\":\"%s\",\"motor\":\"%s\",\"beep\":\"%s\"}",
             NODE_ID, temp, humi, lux, smoke,
             g_lightOn ? "ON" : "OFF",
             g_motorOn ? "ON" : "OFF",
             g_beepOn ? "ON" : "OFF");

    memset(&pub, 0, sizeof(pub));
    pub.topic.data = g_topicData;
    pub.topic.len  = (int)strlen(g_topicData);
    pub.msg.data   = payload;
    pub.msg.len    = (int)strlen(payload);
    pub.qos        = QOS;
    pub.retain     = 0;
    pub.timeout    = MQTT_TIMEOUT_MS;

    if (mqtt_al_publish(g_handle, &pub) != 0) {
        printf("[mqtt] publish failed\r\n");
        return;
    }
    printf("[mqtt] pub: %s\r\n", payload);
}

/* ============================================================
 * 本地安全兜底
 * 烟雾超标或温度过高时，不管 broker 在不在都报警 + 排烟
 * ============================================================ */
static void LocalSafetyCheck(void)
{
    float temp, humi, lux, smoke;
    ReadSensors(&temp, &humi, &lux, &smoke);

    int alarm = (smoke >= SMOKE_ALARM_PPM) || (temp >= TEMP_HIGH_C);
    if (!alarm) {
        return;
    }

    if (!g_beepOn) {
        g_beepOn = 1;
        SetBeep(1);
        printf("[safety] LOCAL ALARM smoke=%.0f temp=%.1f\r\n", smoke, temp);
    }
    if (!g_motorOn) {
        g_motorOn = 1;
        SetMotor(1);        /* 自动排烟 */
    }
}

/* ============================================================
 * MQTT 任务
 * ============================================================ */
static void *MqttTask(const char *arg)
{
    mqtt_al_conpara_t  conparam;
    mqtt_al_subpara_t  sub;
    int rc;

    (void)arg;

    /* 1. 连 Wi-Fi（和官方 E3/D9 例程一样的调用） */
    WifiConnect(CONFIG_WIFI_SSID, CONFIG_WIFI_PWD);
    osDelay(500);

    /* 2. 把 paho 实现注册进 mqtt_al 框架，再初始化。
     *    两个都是幂等/可重复调的，重复调最多返回非 0，不影响。 */
    rc = mqtt_imp_init();
    printf("[mqtt] mqtt_imp_init -> %d\r\n", rc);
    mqtt_al_init();

    /* 3. 填连接参数 */
    memset(&conparam, 0, sizeof(conparam));
    conparam.serveraddr.data  = g_host;
    conparam.serveraddr.len   = (int)strlen(g_host);
    conparam.serverport       = MQTT_PORT;
    conparam.security         = NULL;                    /* 无 TLS */
    conparam.version          = en_mqtt_al_version_3_1_1;
    conparam.clientid.data    = g_clientId;
    conparam.clientid.len     = (int)strlen(g_clientId);
    conparam.cleansession     = 1;
    conparam.keepalivetime    = 60;
    conparam.timeout          = MQTT_TIMEOUT_MS;

    g_handle = mqtt_al_connect(&conparam);
    if (g_handle == NULL) {
        printf("[mqtt] connect failed (conret=%d) 检查 broker 地址/端口\r\n",
               (int)conparam.conret);
        return NULL;
    }
    g_connected = 1;
    printf("[mqtt] connected to %s:%d\r\n", MQTT_HOST, MQTT_PORT);

    /* 4. 订阅控制主题 */
    memset(&sub, 0, sizeof(sub));
    sub.topic.data = g_topicCmd;
    sub.topic.len  = (int)strlen(g_topicCmd);
    sub.qos        = QOS;
    sub.dealer     = OnMessage;
    sub.arg        = NULL;
    sub.timeout    = MQTT_TIMEOUT_MS;

    rc = mqtt_al_subscribe(g_handle, &sub);
    printf("[mqtt] subscribe %s -> %d (subret=%d)\r\n", TOPIC_CMD, rc, (int)sub.subret);

    /* 5. 主循环 */
    for (;;) {
        if (g_connected) {
            PublishData();
            if (mqtt_al_check_status(g_handle) != en_mqtt_al_connect_ok) {
                g_connected = 0;
                printf("[mqtt] connection lost\r\n");
            }
        }
        LocalSafetyCheck();
        osDelay(PUB_INTERVAL_MS);
    }

    return NULL;
}

/* ============================================================
 * 启动
 * ============================================================ */
static void MqttNodeInit(void)
{
    osThreadAttr_t attr = {0};

    printf("\r\n[node] SparkHub MQTT node booting...\r\n");

#if defined(BOARD_IA1)
    E53IA1Init();
    printf("[node] role: E53_IA1 (temp/humi/lux/light/motor)\r\n");
#elif defined(BOARD_SF1)
    E53SF1Init();
    MQ2PPMCalibration();
    printf("[node] role: E53_SF1 (smoke/beep)\r\n");
#endif

    attr.name = "mqttTask";
    attr.stack_size = 8192;      /* JSON 解析吃栈，给大点 */
    attr.priority = osPriorityNormal;
    (void)osThreadNew((osThreadFunc_t)MqttTask, NULL, &attr);

    printf("[node] boot done\r\n");
}

APP_FEATURE_INIT(MqttNodeInit);
