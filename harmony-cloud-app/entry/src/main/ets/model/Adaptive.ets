/**
 * 星枢 SparkHub · 自适应阈值 + 趋势外推
 *
 * ══════════════════════════════════════════════════════════
 *  一、为什么需要自适应阈值
 * ══════════════════════════════════════════════════════════
 *
 * Baseline.ets 里的阈值是硬编码的（HUMI_HIGH = 75 之类）。
 * 问题是**不同环境的本底差很多**：
 *
 *     南方梅雨天         本底湿度 80%    → HUMI_HIGH=75 一直误报
 *     北方干燥房间       本底湿度 30%    → 喷半天够不到 75
 *     厨房（常开油烟机）  烟雾本底 50ppm  → SMOKE_BASE=30 一直"有烟"
 *
 * 这个模块做的事：**开机后先跑一段学习期，统计本底，之后阈值动态算。**
 *
 *     高湿门槛 = 本底湿度均值 + 2 × 标准差
 *     有烟门槛 = 本底烟雾均值 + 3 × 标准差
 *     骤升门槛 = max(0.8, 3 × 本底标准差)     ← 本底抖得厉害就抬高门槛
 *
 * **不需要任何标注数据** —— 只要系统正常运行就行。
 *
 * ══════════════════════════════════════════════════════════
 *  二、趋势外推
 * ══════════════════════════════════════════════════════════
 *
 * 按当前斜率算"还要多久触警"，界面上显示"预计 N 秒后触警"。
 * 纯数学，不需要训练，也不需要额外数据。
 */

import { FeatureSummary } from './Features'

/** 危险阈值 —— 外推预测的目标 */
export const TEMP_DANGER: number = 50.0      // ℃
export const SMOKE_ALARM: number = 300.0     // ppm

/** 学习期需要多少个窗口样本才开始判定 */
const LEARN_WINDOWS: number = 15

/**
 * 学到的本底
 *
 * 每个字段都是"这个环境的正常水平"，阈值由它推出来。
 */
export class LearnedBaseline {
  /** 学习是否完成 —— 没完成时判定应该走保守的固定阈值 */
  ready: boolean = false
  /** 学习进度 0~1 */
  progress: number = 0

  tempMean: number = 25.0
  tempStd: number = 1.0
  humiMean: number = 50.0
  humiStd: number = 3.0
  smokeMean: number = 20.0
  smokeStd: number = 3.0

  /* ── 由本底推导出来的门槛 ── */

  /** 湿度"偏高"的门槛（%）：本底 + 2σ，且不低于本底 +15 */
  humiHigh(): number {
    return Math.max(this.humiMean + 2 * this.humiStd, this.humiMean + 15)
  }

  /** 湿度"骤升"门槛（%/s）：本底波动的 3 倍，且不低于 0.8 */
  humiRise(): number {
    return Math.max(3 * this.humiStd, 0.8)
  }

  /** 烟雾"有烟"门槛（ppm）：本底 + 3σ，且不低于 30 */
  smokeBase(): number {
    return Math.max(this.smokeMean + 3 * this.smokeStd, 30)
  }

  /** 现在是否"湿度偏高" */
  humiIsHigh(v: number): boolean {
    return v > this.humiHigh()
  }

  /** 供界面显示的摘要 */
  describe(): string {
    if (!this.ready) {
      return `校准中 ${Math.round(this.progress * 100)}%`
    }
    return `本底 ${this.humiMean.toFixed(0)}% 湿度 / ${this.smokeMean.toFixed(0)}ppm 烟雾`
  }
}

/**
 * 本底学习器
 *
 * 每来一个窗口的 FeatureSummary 就喂一次；
 * 攒够 LEARN_WINDOWS 个之后算出均值和标准差。
 *
 * 之后**继续滑动更新** —— 环境缓慢变化（季节、开窗）也能跟上。
 */
export class BaselineLearner {
  private buf: FeatureSummary[] = []
  private static readonly MAX_SAMPLES: number = 40

  /** 喂一个窗口的特征 */
  feed(f: FeatureSummary, base: LearnedBaseline): void {
    this.buf.push(f)
    while (this.buf.length > BaselineLearner.MAX_SAMPLES) {
      this.buf.shift()
    }

    if (this.buf.length < LEARN_WINDOWS) {
      base.ready = false
      base.progress = this.buf.length / LEARN_WINDOWS
      return
    }

    this.recompute(base)
    base.ready = true
    base.progress = 1
  }

  /** 重新统计 */
  private recompute(base: LearnedBaseline): void {
    const n: number = this.buf.length
    if (n === 0) {
      return
    }

    let tempSum: number = 0
    let humiSum: number = 0
    let smokeSum: number = 0
    for (let i = 0; i < n; i++) {
      tempSum += this.buf[i].temp
      humiSum += this.buf[i].humi
      smokeSum += this.buf[i].smoke
    }
    const tMean: number = tempSum / n
    const hMean: number = humiSum / n
    const sMean: number = smokeSum / n

    let tVar: number = 0
    let hVar: number = 0
    let sVar: number = 0
    for (let i = 0; i < n; i++) {
      const dt: number = this.buf[i].temp - tMean
      const dh: number = this.buf[i].humi - hMean
      const ds: number = this.buf[i].smoke - sMean
      tVar += dt * dt
      hVar += dh * dh
      sVar += ds * ds
    }

    base.tempMean = tMean
    base.tempStd = Math.sqrt(tVar / n)
    base.humiMean = hMean
    base.humiStd = Math.sqrt(hVar / n)
    base.smokeMean = sMean
    base.smokeStd = Math.sqrt(sVar / n)
  }

  /** 环境大变（比如搬了位置）时重置学习 */
  reset(): void {
    this.buf = []
  }
}

/**
 * 趋势外推：按当前斜率预测还要多久触警
 *
 * @returns 秒数；-1 表示不会触警（斜率不够或方向不对）
 *
 * 取温度、烟雾两条线里更急的那个。
 * 只报 10 分钟以内的预测 —— 更远的没意义（环境早变了）。
 */
export function predictAlarmSec(f: FeatureSummary): number {
  let eta: number = -1

  /* 温度方向：还要多少秒到 TEMP_DANGER */
  if (f.dTemp > 0.05) {
    const s: number = (TEMP_DANGER - f.temp) / f.dTemp
    if (s > 0 && s <= 600) {
      eta = s
    }
  }

  /* 烟雾方向：还要多少秒到 SMOKE_ALARM */
  if (f.dSmoke > 1.0) {
    const s: number = (SMOKE_ALARM - f.smoke) / f.dSmoke
    if (s > 0 && s <= 600) {
      if (eta < 0 || s < eta) {
        eta = s
      }
    }
  }

  return eta
}
