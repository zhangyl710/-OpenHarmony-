/**
 * MQTT 节点部署配置 —— 烧写前必须修改
 */

#ifndef CONFIG_H
#define CONFIG_H

/* ============================================================
 * 板子角色 —— 两块板烧不同固件，各定义一个，必须二选一
 *
 * 装 E53_IA1（温湿度 + 光照 + 灯 + 电机）的板子 → 用 BOARD_IA1
 * 装 E53_SF1（烟感 + 蜂鸣器）的板子           → 用 BOARD_SF1
 * ============================================================ */
/* #define BOARD_IA1 */
#define BOARD_SF1

/* ---------- 节点标识 ---------- */
/* 两块板要不一样，看板才能区分数据来源 */
#if defined(BOARD_IA1)
#define NODE_ID             "N01"
#else
#define NODE_ID             "N02"
#endif

/* ---------- Wi-Fi（必须和 broker 在同一局域网）---------- */
#define CONFIG_WIFI_SSID    "zzz"
#define CONFIG_WIFI_PWD     "Z123456789"

#endif /* CONFIG_H */
