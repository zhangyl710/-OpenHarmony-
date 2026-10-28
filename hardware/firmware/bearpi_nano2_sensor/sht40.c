#include "sht40.h"

#include <stddef.h>

#include "cmsis_os2.h"
#include "iot_errno.h"
#include "iot_i2c.h"

/*
 * I²C 端口与波特率。
 * WIFI_IOT_I2C_IDX_0 是 Hi3861 平台的 I²C 端口号宏，定义在 SDK 的 iot_i2c.h 中；
 * 若编译提示未定义，改成 SDK 中实际的端口宏名即可。
 *
 * ⚠️ 与小熊派 Nano 2 的实际连线对应关系，以官方原理图的 E53 接口定义为准。
 */
#define SHT40_I2C_IDX      WIFI_IOT_I2C_IDX_0
#define SHT40_I2C_BAUDRATE 400000

#define SHT40_ADDR         0x44
#define SHT40_CMD_MEASURE  0xFD
#define SHT40_MEASURE_MS   10
#define SHT40_RAW_LEN      6

/**
 * Sensirion CRC-8：多项式 0x31，初值 0xFF，无反射。
 * 数据手册 4.4 节给出的是逐位实现，这里按其等价形式编写。
 */
static uint8_t Sht40Crc(const uint8_t *data, uint16_t len)
{
    uint8_t crc = 0xFF;

    for (uint16_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (uint8_t bit = 0; bit < 8; bit++) {
            if ((crc & 0x80) != 0) {
                crc = (uint8_t)((crc << 1) ^ 0x31);
            } else {
                crc = (uint8_t)(crc << 1);
            }
        }
    }
    return crc;
}

int Sht40Init(void)
{
    unsigned int ret = IoTI2cInit(SHT40_I2C_IDX, SHT40_I2C_BAUDRATE);
    return (ret == IOT_SUCCESS) ? 0 : -1;
}

int Sht40Read(Sht40Reading *out)
{
    uint8_t cmd = SHT40_CMD_MEASURE;
    uint8_t raw[SHT40_RAW_LEN] = {0};
    uint16_t rawTemp;
    uint16_t rawRh;
    float rh;

    if (out == NULL) {
        return -1;
    }

    /* 1. 触发高精度测量 */
    if (IoTI2cWrite(SHT40_I2C_IDX, SHT40_ADDR, &cmd, 1) != IOT_SUCCESS) {
        return -1;
    }

    /* 2. 等待测量完成（高精度模式典型 8.3 ms，留 10 ms 余量） */
    osDelay(SHT40_MEASURE_MS);

    /* 3. 读回 6 字节 */
    if (IoTI2cRead(SHT40_I2C_IDX, SHT40_ADDR, raw, SHT40_RAW_LEN) != IOT_SUCCESS) {
        return -1;
    }

    /* 4. CRC 校验 —— 不做这一步的话，I²C 干扰会直接变成错误的温度值骗过上层 */
    if (Sht40Crc(raw, 2) != raw[2]) {
        return -2;
    }
    if (Sht40Crc(&raw[3], 2) != raw[5]) {
        return -3;
    }

    /* 5. 换算 */
    rawTemp = (uint16_t)((raw[0] << 8) | raw[1]);
    rawRh = (uint16_t)((raw[3] << 8) | raw[4]);

    out->temperature = -45.0f + 175.0f * ((float)rawTemp / 65535.0f);

    rh = -6.0f + 125.0f * ((float)rawRh / 65535.0f);
    if (rh < 0.0f) {
        rh = 0.0f;
    }
    if (rh > 100.0f) {
        rh = 100.0f;
    }
    out->humidity = rh;

    return 0;
}
