/**
 * 部署与调参配置 —— 现场要改的东西尽量都集中在这里。
 *
 * 改完这个文件之后：hb build -f（全量编译）→ 重新烧录。
 * 改了头文件必须全量编译，原因见 ../../开发流程.md 第 7 节。
 *
 * 建议把这个文件加进 .gitignore，不要把真实 Wi-Fi 密码提交到仓库。
 */

#ifndef CONFIG_H
#define CONFIG_H

/* ---------- 节点标识 ---------- */
/* 多节点演示时，每个节点的固件改这一行再烧一遍，用来区分数据来源 */
#define NODE_ID             "N01"

/* ---------- Wi-Fi ---------- */
#define WIFI_SSID   "your-wifi-ssid"
#define WIFI_PSK    "your-wifi-password"

/* ---------- 主机（Purple Pi OH）---------- */
/* 在 Purple Pi 上用 `ifconfig` 或 `ip addr` 查看实际 IP */
#define HOST_IP     "192.168.1.100"
#define HOST_PORT   8899

/* ---------- 运行节奏 ---------- */
#define SAMPLE_INTERVAL_MS  5000    /* 采集并上报的周期 */
#define CMD_POLL_MS         200     /* 轮询主机指令的周期 */
#define HOST_TIMEOUT_MS     15000   /* 多久没收到主机指令就判定主机失联，转本地自治 */

/* ---------- 演示阈值 ---------- */
/* 室温超过该值就吸合继电器点亮灯，用于展示"感知 → 动作"闭环 */
#define CONTROL_TEMP_HIGH   26.0f

#endif /* CONFIG_H */
