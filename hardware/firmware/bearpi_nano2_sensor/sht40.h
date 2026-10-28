/**
 * SHT40 温湿度传感器驱动（I²C）
 *
 * SHT40 是 Sensirion 的数字温湿度传感器，I²C 从地址 0x44（7 位）。
 * 单次高精度测量流程：写命令 0xFD → 等待约 10 ms → 读 6 字节
 *   字节 0-1: 温度原始值   字节 2: 温度 CRC
 *   字节 3-4: 湿度原始值   字节 5: 湿度 CRC
 * 转换公式（数据手册 4.8 节）：
 *   T  = -45 + 175 * rawT  / 65535    单位 ℃
 *   RH = -6  + 125 * rawRH / 65535    单位 %RH，需截断到 [0, 100]
 */

#ifndef SHT40_H
#define SHT40_H

#include <stdint.h>

typedef struct {
    float temperature;  /* ℃ */
    float humidity;     /* %RH */
} Sht40Reading;

/**
 * 初始化 I²C 控制器。
 * @return 0 成功，非 0 失败
 */
int Sht40Init(void);

/**
 * 触发一次测量并读回结果。
 * @param out 输出结果，不可为 NULL
 * @return 0 成功；-1 I²C 读写失败；-2 温度 CRC 校验失败；-3 湿度 CRC 校验失败
 */
int Sht40Read(Sht40Reading *out);

#endif /* SHT40_H */
