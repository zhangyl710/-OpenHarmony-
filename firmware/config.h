/**
 * MQTT 节点部署配置 —— 烧写前必须修改
 */

#ifndef CONFIG_H
#define CONFIG_H

/* ============================================================
 * 板子角色 —— 两块板烧不同固件，各定义一个，必须二选一
 *
 * 装 E53_IA1（温湿度 + 光照 + 灯 + 电机）的板子 → BOARD_IA1
 * 装 E53_SF1（烟感 + 蜂鸣器）的板子           → BOARD_SF1
 * ============================================================ */
/*#define BOARD_IA1*/
#define BOARD_SF1 

/* ---------- 节点标识 ----------
 * ⚠️ 按板型自动区分，避免手工改漏导致两块板 clientId 撞车
 *    （撞车会被 broker 互相踢下线，表现为"只有一块板有数据"）
 */
#if defined(BOARD_IA1)
#define NODE_ID             "N01"
#define MQTT_CLIENTID       "bearpi_node_01"
#else
#define NODE_ID             "N02"
#define MQTT_CLIENTID       "bearpi_node_02"
#endif

/* ---------- Wi-Fi（必须和 broker 在同一局域网）---------- */
#define CONFIG_WIFI_SSID    "zzz"
#define CONFIG_WIFI_PWD     "Z123456789"

#endif /* CONFIG_H */
