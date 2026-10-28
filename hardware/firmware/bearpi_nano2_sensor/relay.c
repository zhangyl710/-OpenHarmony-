#include "relay.h"

#include "iot_errno.h"
#include "iot_gpio.h"

/*
 * ⚠️ 引脚号以官方原理图为准。
 * 这里给的是 E53 接口上一个常见的可用 GPIO，实际接线前务必对照原理图确认，
 * 并确保该 GPIO 没有被 I²C / UART 等复用功能占用。
 */
#define RELAY_GPIO 7

static int g_relayOn = 0;

int RelayInit(void)
{
    unsigned int ret;

    IoTGpioInit(RELAY_GPIO);
    ret = IoTGpioSetDir(RELAY_GPIO, IOT_GPIO_DIR_OUT);
    if (ret != IOT_SUCCESS) {
        return -1;
    }

    /* 上电默认断开，避免断电重启时执行器误动作 */
    IoTGpioSetOutputVal(RELAY_GPIO, IOT_GPIO_VALUE0);
    g_relayOn = 0;
    return 0;
}

void RelaySet(int on)
{
    IoTGpioSetOutputVal(RELAY_GPIO, on ? IOT_GPIO_VALUE1 : IOT_GPIO_VALUE0);
    g_relayOn = on ? 1 : 0;
}

int RelayGet(void)
{
    return g_relayOn;
}
