/**
 * 继电器（执行器）控制 —— 阶段 3 用来展示"感知 → 动作"的物理闭环。
 *
 * 接线：继电器模块 VCC 接 5 V（线圈电流较大，别用 3.3 V），GND 共地，
 *       IN 接任意可用 GPIO。灯的市电侧接常开端 NO。
 *       演示建议用低压 LED 灯带，避免市电操作风险。
 */

#ifndef RELAY_H
#define RELAY_H

/**
 * 初始化继电器控制引脚为输出、默认断开。
 * @return 0 成功，非 0 失败
 */
int RelayInit(void);

/**
 * 设置继电器状态。
 * @param on 1 吸合（灯亮），0 断开
 */
void RelaySet(int on);

/**
 * @return 当前状态，1 吸合 / 0 断开
 */
int RelayGet(void);

#endif /* RELAY_H */
