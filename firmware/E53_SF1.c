/*
 * Copyright (c) 2020 Nanjing Xiaoxiongpai Intelligent Technology Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "iot_adc.h"
#include "iot_errno.h"
#include "iot_gpio.h"
#include "iot_gpio_ex.h"
#include "iot_pwm.h"
#include "E53_SF1.h"


#define CAL_PPM 20 // 校准环境中PPM值
#define RL 1       // RL阻值

#define E53_SF1_BEEP_GPIO 11
#define PWM_PORT_PWM3 3
#define PWM_DUTY 50
#define PWM_FREQ 4000

#define ADC_CHANNEL 5           // 对应GPIO12

static float R0; // 元件在洁净空气中的阻值

/***************************************************************
 * 函数名称: E53SF1Init
 * 说    明: 初始化E53_SF1扩展板
 * 参    数: 无
 * 返 回 值: 无
 ***************************************************************/
void E53SF1Init(void)
{
    IoTGpioInit(E53_SF1_BEEP_GPIO);                                     // 初始化GPIO
    IoTGpioSetFunc(E53_SF1_BEEP_GPIO, IOT_GPIO_FUNC_GPIO_11_PWM3_OUT);  // 设置GPIO_11引脚复用功能为PWM
    IoTGpioSetDir(E53_SF1_BEEP_GPIO, IOT_GPIO_DIR_OUT);                 // 设置GPIO_11引脚为输出模式
    IoTPwmInit(PWM_PORT_PWM3);      
}
/***************************************************************
* 函数名称: GetVoltage
* 说    明: 获取电压值函数
* 参    数: 无
*
* 返 回 值: 无
***************************************************************/
static unsigned int GetVoltage(void)
{
    unsigned int ret;
    unsigned int data;

    ret = IoTAdcRead(ADC_CHANNEL, &data, IOT_ADC_EQU_MODEL_8, IOT_ADC_CUR_BAIS_DEFAULT, 0xff);
    if (ret != IOT_SUCCESS) {
        printf("ADC Read Fail\n");
    }
    return data ;
}
/***************************************************************
 * 函数名称: GetMQ2PPM
 * 说    明: 获取PPM函数
 * 参    数: ppm 烟雾浓度
 * 返 回 值: 0 成功; -1 失败
 ***************************************************************/
int GetMQ2PPM(float *ppm)
{
    unsigned int ret;
    unsigned int data;
    unsigned int  voltage;

    ret = IoTAdcRead(ADC_CHANNEL, &data, IOT_ADC_EQU_MODEL_8, IOT_ADC_CUR_BAIS_DEFAULT, 0xff);
    if (ret != 0) {
        printf("ADC Read Fail\n");
        return -1;
    }

    voltage = data;

    float RS = (float)((5000.0 - voltage)*1000.0 / voltage * RL);   //计算RS
    *ppm = 613.9f * pow(RS / R0, -2.074f); //计算ppm
    return 0;
}

/***************************************************************
 * 函数名称: MQ2PPMCalibration
 * 说    明: 传感器校准函数
 * 参    数: 无
 * 返 回 值: 无
 ***************************************************************/
void MQ2PPMCalibration(void)
{
    unsigned int voltage = GetVoltage();

    float RS = (float)((5000 - voltage)*1000 / voltage) * RL;

    R0 = (float)(RS / pow(CAL_PPM / 613.9f, 1 / -2.074f));
}

/***************************************************************
 * 函数名称: BeepStatusSet
 * 说    明: 蜂鸣器报警与否
 * 参    数: status,ENUM枚举的数据
 *									OFF,蜂鸣器
 *									ON,开蜂鸣器
 * 返 回 值: 无
 ***************************************************************/
void BeepStatusSet(E53SF1Status status)
{
    if (status == CTL_ON) {
        IoTPwmStart(PWM_PORT_PWM3, PWM_DUTY, PWM_FREQ); // 输出PWM波
    }
    if (status == CTL_OFF) {
        IoTPwmStop(PWM_PORT_PWM3);
    }
}
