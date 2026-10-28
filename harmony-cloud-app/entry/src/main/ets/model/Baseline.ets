/**
 * 星枢 SparkHub · 规则基线（第 1 层推理）
 *
 * 不依赖任何模型、不依赖任何云端 —— 纯本地统计判据。
 * 它是三层架构的保底层：模型丢了、云断了，这一层照常工作。
 *
 * ══════════════════════════════════════════════════════════
 *  判据来自四类场景的物理差异
 * ══════════════════════════════════════════════════════════
 *
 *   场景      温度      湿度              烟雾
 *   ─────────────────────────────────────────────────────
 *   正常      平稳      平稳              低、平稳
 *   水汽      基本不动  ★骤升             虚高后★快速回落
 *   油烟      缓升      升（蒸煮）        脉冲式（随烹饪节奏起伏）
 *   燃烧      ★快升     ★下降（水被烤干） ★持续单调上升，不回落
 *
 * ══════════════════════════════════════════════════════════
 *  阈值怎么调（现场用）
 * ══════════════════════════════════════════════════════════
 *
 * 演示水汽用**水蒸气**：10~20 秒内湿度涨 20~30%
 *   → dHumi（%/s）约 1 ~ 3。HUMI_RISE 定 0.8 留了余量。
 *
 * 打火机放气 / 点香：温度基本不动，烟雾会涨
 *   → 会被判成「油烟」而不是「燃烧」，这是对的（没有真实热源）。
 *
 * 真要点火（注意安全）：温度会以 0.5~1 ℃/s 上升
 *   → TEMP_RISE 定 0.3 能抓到。
 *
 * 每个阈值旁边的注释写了"什么情况下往上/往下调"。
 */

import { FeatureSummary } from './Features'
import { LearnedBaseline } from './Adaptive'

/** 分类结果 —— 和模型输出保持同一格式，方便上层无感切换 */
export class ClassifyResult {
  /** [正常, 油烟, 水汽, 燃烧] 四个概率，和为 1 */
  probs: number[] = [1, 0, 0, 0]
  /** 这一结果来自哪一层：rule / model / cloud */
  source: string = 'rule'
  /** 命中的判据，便于界面解释和现场调试 */
  reason: string = ''
}

export const CLASS_NAMES: string[] = ['正常', '油烟', '水汽', '燃烧']

/**
 * 阈值
 *
 * 单位都是「每秒的变化率」，由 FeatureSummary 的斜率提供。
 * 调法：如果某类总判不出来，把对应阈值调小；如果误判多，调大。
 *
 * ══════════════════════════════════════════════════════════
 *  ⚠️ 这些值的下界由「正常环境」的噪声决定 —— 实测一轮安静房间，
 *     整窗最小二乘斜率的 95 分位：
 *
 *       温升 0.003 ℃/s   湿升 0.013 %/s
 *       湿降 -0.020 %/s  烟升 0.025 ppm/s
 *
 *     噪声底极低，所以阈值可以放心压到 0.03~0.2 —— 仍留了 5~10 倍余量。
 *     压得越低，缓慢的事件（小火慢烧、香慢慢起烟）越容易被抓到。
 *
 *     ⚠️ 这几个数和「录制时长」强相关：事件只占录制的一小段，其余
 *        窗口本来就和正常一样。所以离线看"某类窗口准确率"会很低，
 *        那是标签噪声，不代表漏报 —— 要看**每次会话有没有检出**。
 *
 *     改设备端上报周期（PUB_INTERVAL_MS）时这些值全部要重标定。
 * ══════════════════════════════════════════════════════════
 */
export class Thresholds {
  /** 湿度上升率（%/s）—— 水汽的主判据 */
  static readonly HUMI_RISE: number = 0.08
  /**
   * 湿度已经偏高（%）
   *
   * 光看「变化率」有个盲区：喷完水蒸气几十秒后湿度会停在高位，
   * 变化率掉回 0，判定就退回「正常」了 —— 看起来像检测不到。
   * 所以再加一条：**湿度已经很高 且 仍在缓慢上升**，也算水汽。
   */
  static readonly HUMI_HIGH: number = 75
  /** 高湿度下的"仍在上升"门槛（%/s）—— 比骤升门槛低一档 */
  static readonly HUMI_SLOW_RISE: number = 0.025
  /** 湿度下降率（%/s，取正值比较）—— 燃烧的辅助判据（水被烤干） */
  static readonly HUMI_DROP: number = 0.10
  /** 温度上升率（℃/s）—— 燃烧的主判据 */
  static readonly TEMP_RISE: number = 0.03
  /**
   * 判定"温度基本不动"的更宽门槛（℃/s）—— 只给水汽/油烟用
   *
   * 烧水时最靠近热源的那部分空气也会被加热：实测 25~30cm 处温升
   * 约 0.1~0.3 ℃/s（整窗斜率），用水汽的主判据 `!tempRising` 会把
   * 它挡掉，所以这里放宽一档。
   *
   * 仍然远低于燃烧的水平，不会把真火误判成水汽。
   */
  static readonly TEMP_RISE_LOOSE: number = 1.0
  /** 烟雾上升率（ppm/s）—— 油烟 / 燃烧都要有 */
  static readonly SMOKE_RISE: number = 0.20
  /** 烟雾回落比低于这个值 → 判定为"已回落"（水汽特征） */
  static readonly FALL_LOW: number = 0.5
  /** 烟雾回落比高于这个值 → 判定为"仍在高位"（燃烧特征） */
  static readonly FALL_HIGH: number = 0.8
  /** 烟雾浓度绝对值超过这个值才算"有烟"（ppm），滤掉本底噪声 */
  static readonly SMOKE_BASE: number = 30

  /* ── 绝对量兜底（不依赖速率阈值）──────────────────
   *
   * 为什么需要这两条：
   *   `TEMP_RISE = 0.03 ℃/s` 是**相对**判据 —— 只要在升温就满足。
   *   但现场遇到近距离热源时，升温可达 3 ℃/s，远超训练数据里的
   *   0.67 ℃/s 上限，模型会认不出来（输入被归一化越界）。
   *   这时不能只靠"速率是否超过某个小阈值"，要加一条**绝对量**判据：
   *   温度本身已经很高（≥45℃，远超任何舒适工况）且仍在明显上升。
   */
  /** 绝对高温线（℃）—— 超过即视为危险工况，不再需要看相对趋势 */
  static readonly TEMP_ABS_FIRE: number = 45
  /** "明显上升"的硬门槛（℃/s）—— 远高于 TEMP_RISE，用于兜底触发 */
  static readonly TEMP_RISE_HARD: number = 0.30
}

/**
 * 规则基线分类
 *
 * @param f 当前窗口的特征摘要（都是**原始物理量**，不是归一化值）
 */
export function classifyByRule(f: FeatureSummary, base: LearnedBaseline): ClassifyResult {
  const r: ClassifyResult = new ClassifyResult()

  const dTemp: number = f.dTemp          // ℃/s
  const dHumi: number = f.dHumi          // %/s
  const dSmoke: number = f.dSmoke        // ppm/s
  const fall: number = f.fallRatio       // 近 20s 均值 / 窗口峰值
  const smoke: number = f.smoke          // 当前 ppm
  const humi: number = f.humi            // 当前湿度 %（判"高位"用）

  /* ── 门槛：优先用学到的本底，没学完就用固定值兜底 ──
   *
   * 学习完成前后用一套固定阈值，学完换成"本底 ± kσ"。
   * 这样换环境不用改代码，也让系统在梅雨天/干燥房间都能用。 */
  const humiHighTh: number = base.ready ? base.humiHigh() : Thresholds.HUMI_HIGH
  const humiRiseTh: number = base.ready ? base.humiRise() : Thresholds.HUMI_RISE
  const smokeBaseTh: number = base.ready ? base.smokeBase() : Thresholds.SMOKE_BASE
  const smokeRiseTh: number = base.ready
    ? Math.max(3.0 * base.smokeStd, Thresholds.SMOKE_RISE)
    : Thresholds.SMOKE_RISE

  const hasSmoke: boolean = smoke > smokeBaseTh
  const humiRising: boolean = dHumi > humiRiseTh
  /* 湿度已在高位、且仍在缓慢上升 —— 覆盖"喷完一会儿湿度停在高位"的情况 */
  const humiHighRising: boolean = humi > humiHighTh && dHumi > Thresholds.HUMI_SLOW_RISE
  const humiDropping: boolean = dHumi < -Thresholds.HUMI_DROP
  const tempRising: boolean = dTemp > Thresholds.TEMP_RISE
  /* "温度基本不动"—— 给水汽/油烟用的宽松版，容忍烧水时被烤热的那点温升 */
  const tempFlat: boolean = dTemp < Thresholds.TEMP_RISE_LOOSE
  const smokeRising: boolean = dSmoke > smokeRiseTh

  /* ── ⓪ 绝对量兜底：高温 + 明显升温 ──
   *
   * 放在所有相对判据之前，因为它处理的是「模型和相对阈值都可能失效」的场景：
   *   现场近距离热源升温可达 3 ℃/s，而训练数据里最大只有 0.67 ℃/s，
   *   模型对这类输入会给出错误结果（实测：燃烧 0.31 / 正常 0.48）。
   *   但 45℃ 以上的环境温度本身就是强信号 —— 不需要任何统计判断。
   *
   * 这条判据的优先级最高：**安全类结论不能依赖可能失效的模型**。 */
  if (f.temp >= Thresholds.TEMP_ABS_FIRE && dTemp > Thresholds.TEMP_RISE_HARD) {
    r.probs = [0.01, 0.02, 0.02, 0.95]
    r.reason = `高温 ${f.temp.toFixed(1)}℃ + 明显升温 ${dTemp.toFixed(2)}℃/s`
    return r
  }

  /* ── ① 燃烧：温度快升 + 湿度降 + 烟雾持续不回落 ──
   *    放在最前面，因为漏报代价最高。
   *    注意用 && 串联三个条件 —— 只要温度在快升就高度可疑，
   *    但加上湿度和烟雾能显著降误报。 */
  if (tempRising && (humiDropping || (hasSmoke && fall > Thresholds.FALL_HIGH))) {
    r.probs = [0.02, 0.03, 0.02, 0.93]
    r.reason = `温度快升 ${dTemp.toFixed(2)}℃/s` +
      (humiDropping ? ` + 湿度降 ${dHumi.toFixed(2)}%/s` : '') +
      (hasSmoke ? ` + 烟雾未回落 ${fall.toFixed(2)}` : '')
    return r
  }

  /* ── ② 水汽：湿度升高 + 温度不动 ──
   *    这是本方案要解决的**核心场景** —— 传统烟感在这类上必误报。
   *
   *    两种触发方式：
   *      a) 骤升（正在喷水蒸气的瞬间，dHumi 很大）
   *      b) 高位仍升（喷完一会儿，湿度停在 75%+ 还没散）
   *
   *    只判 a) 的话，湿度稳住后判定会退回「正常」，看起来像检测不到。 */
  if ((humiRising || humiHighRising) && tempFlat) {
    const alsoFalling: boolean = hasSmoke && fall < Thresholds.FALL_LOW
    r.probs = [0.03, 0.05, 0.90, 0.02]
    r.reason = humiRising
      ? `湿度骤升 ${dHumi.toFixed(2)}%/s + 温度不变 ${dTemp.toFixed(2)}℃/s`
      : `湿度高位 ${humi.toFixed(0)}% 仍在升 ${dHumi.toFixed(2)}%/s`
    if (alsoFalling) {
      r.reason += ` + 烟雾已回落 ${fall.toFixed(2)}`
    }
    return r
  }

  /* ── ③ 油烟：有烟在涨，但温度没快升 ──
   *    烟雾会随烹饪节奏起伏（脉冲），回落比通常在中间区间。 */
  if (smokeRising && !tempRising) {
    r.probs = [0.05, 0.88, 0.05, 0.02]
    r.reason = `烟雾上升 ${dSmoke.toFixed(1)}ppm/s + 温度平稳`
    return r
  }

  /* ── ④ 正常 ── */
  r.probs = [0.95, 0.03, 0.01, 0.01]
  r.reason = hasSmoke
    ? `烟雾 ${smoke.toFixed(0)}ppm 但无上升趋势`
    : '各通道平稳'
  return r
}

/** 取概率最大的类别名 */
export function topClass(probs: number[]): string {
  let best: number = 0
  for (let i = 1; i < probs.length; i++) {
    if (probs[i] > probs[best]) {
      best = i
    }
  }
  return CLASS_NAMES[best]
}

/**
 * 报警阈值：燃烧概率超过这个值就报警。
 *
 * ⚠️ 这个 0.35 是**在 softmax 温度标定之后**才有意义的。
 *    未标定时（T=1.0）模型对任何样本给出的燃烧概率都压不下去：
 *      正常样本 P(燃烧) 中位 0.233、max 0.288
 *      燃烧样本 P(燃烧) 中位仅 0.393   ← 连 0.7 都到不了，全漏报
 *    标定后（T=0.25，见 MsModel.TEMPERATURE）：
 *      正常样本 P(燃烧) max 0.199
 *      燃烧样本 P(燃烧) 中位 0.576
 *    两者之间取 0.35 —— 正常样本 0/1371 会被误报。
 *
 *    改动阈值时必须和 MsModel 的 TEMPERATURE 一起改。
 */
export const ALARM_THRESHOLD: number = 0.35

export function shouldAlarm(probs: number[]): boolean {
  return probs.length >= 4 && probs[3] >= ALARM_THRESHOLD
}
