/**
 * 星枢 SparkHub · 端侧特征计算
 *
 * 从 MQTT 上报的传感器数据里，滚出 60 秒滑窗，算成 8 通道特征矩阵，
 * 喂给 AI 模型（或规则基线）。
 *
 * ══════════════════════════════════════════════════════════
 *  ⚠️ 这个文件里的「通道顺序」和「归一化量程」必须和
 *     ai/train.py 里的 NORM 完全一致。
 *
 *     不一致的话 —— 模型不会报错、不会崩溃、不会打印警告，
 *     只会静默输出垃圾结果。这是最难查的一类问题。
 *
 *     改动任一侧的量程时，另一侧必须同步改。
 * ══════════════════════════════════════════════════════════
 */

/** 通道数 / 窗口点数
 *
 * 窗口 60 秒 ÷ 5 秒采样 = 12 点
 * ⚠️ 必须和 ai/train.py 的 SEQ_LEN 一致
 */
export const N_CHANNELS: number = 8
export const WINDOW_SEC: number = 12

/** 通道名 —— 顺序即模型输入顺序 */
export const CH_NAMES: string[] = [
  '温度', '湿度', '光照', '烟雾',
  '温升速率', '湿降速率', '烟升斜率', '回落比'
]

/** 归一化量程 */
export interface ChRange {
  readonly min: number
  readonly max: number
}

/**
 * 8 个通道的归一化量程
 *
 * 顺序绝对不能改（改了训练和端侧就对不上）：
 *   ch0 温度 ℃        ch4 温升速率 ℃/s
 *   ch1 湿度 %        ch5 湿降速率 %/s
 *   ch2 光照 lux      ch6 烟升斜率 ppm/s
 *   ch3 烟雾 ppm      ch7 烟雾回落比
 */
export const NORM: ChRange[] = [
  { min: 0, max: 60 },      // ch0 温度
  { min: 0, max: 100 },     // ch1 湿度
  { min: 0, max: 1000 },    // ch2 光照
  { min: 0, max: 1000 },    // ch3 烟雾
  { min: -1, max: 1 },      // ch4 温升速率
  { min: -5, max: 5 },      // ch5 湿降速率
  { min: -10, max: 10 },    // ch6 烟升斜率
  { min: 0, max: 2 }        // ch7 回落比
]

/** 单个采样点 —— 两个节点的最新值合并成一条 */
export class Sample {
  ts: number = 0
  temp: number = 0
  humi: number = 0
  lux: number = 0
  smoke: number = 0

  copy(): Sample {
    const s = new Sample()
    s.ts = this.ts
    s.temp = this.temp
    s.humi = this.humi
    s.lux = this.lux
    s.smoke = this.smoke
    return s
  }
}

/** 归一化到 [0,1]，超出量程的截断 */
function norm(v: number, lo: number, hi: number): number {
  if (hi <= lo) {
    return 0
  }
  let t: number = (v - lo) / (hi - lo)
  if (t < 0) {
    t = 0
  }
  if (t > 1) {
    t = 1
  }
  return t
}

/**
 * 60 秒环形缓冲
 *
 * 两个节点的采样率可能不同（N01 温湿度、N02 烟雾），
 * 这里按「收到任一节点的数据 + 距上次采样 ≥ SAMPLE_MIN_GAP_MS」
 * 的节奏落一条 Sample，用最近值补齐缺的通道。
 */
export class WindowBuffer {
  private buf: Sample[] = []
  private lastTs: number = 0

  /** 两条 Sample 之间至少隔这么久（防止消息扎堆时刷爆窗口） */
  private static readonly SAMPLE_MIN_GAP_MS: number = 800

  /**
   * 采样间隔（秒）
   *
   * ⚠️ 设备端 PUB_INTERVAL_MS = 5000，即每 5 秒一个点。
   *    差分要除以它才能得到"每秒变化率"（℃/s、%/s、ppm/s）——
   *    也就是 Baseline.ets 里那些阈值的单位。
   *
   *    不除的话数值放大 5 倍，正常环境的噪声波动（温度 ±0.3℃、
   *    湿度 ±0.9%、烟雾 ±5ppm）会全部越过阈值，
   *    把平稳的读数判成「油烟」甚至「燃烧」。
   *
   *    改设备端的上报周期时，这里和 build_dataset.py 要同步改。
   */
  static readonly SAMPLE_SEC: number = 1

  /**
   * 喂入一条节点数据，必要时落一条 Sample
   *
   * @param partial 本次收到的字段（只填收到的部分，其余保持上次值）
   * @param now     当前时间戳（毫秒）
   * @returns 是否真的落了新 Sample
   */
  feed(partial: PartialSample, now: number): boolean {
    // 先合并到「当前值」
    if (partial.temp !== undefined) {
      this.cur.temp = partial.temp
    }
    if (partial.humi !== undefined) {
      this.cur.humi = partial.humi
    }
    if (partial.lux !== undefined) {
      this.cur.lux = partial.lux
    }
    if (partial.smoke !== undefined) {
      this.cur.smoke = partial.smoke
    }

    // 距上次采样太近就只更新当前值，不落点
    if (this.lastTs > 0 && (now - this.lastTs) < WindowBuffer.SAMPLE_MIN_GAP_MS) {
      return false
    }

    const s = this.cur.copy()
    s.ts = now
    this.buf.push(s)
    this.lastTs = now

    while (this.buf.length > WINDOW_SEC) {
      this.buf.shift()
    }
    return true
  }

  private cur: Sample = new Sample()

  /** 已积累多少个点 */
  get size(): number {
    return this.buf.length
  }

  /** 窗口是否够长（够长才够算特征） */
  get ready(): boolean {
    return this.buf.length >= WINDOW_SEC
  }

  /** 窗口填充进度 0~1，用于界面显示"数据积累中" */
  get progress(): number {
    return this.buf.length / WINDOW_SEC
  }

  clear(): void {
    this.buf = []
    this.lastTs = 0
  }

  /** 最近一次的原始读数 */
  latest(): Sample | null {
    return this.buf.length > 0 ? this.buf[this.buf.length - 1] : null
  }

  /**
   * 取某个通道的**原始值**序列（不归一化）—— 给界面画曲线用
   *
   * @param ch 0=温度 1=湿度 2=光照 3=烟雾
   */
  series(ch: number): number[] {
    const out: number[] = []
    for (let i = 0; i < this.buf.length; i++) {
      const s: Sample = this.buf[i]
      if (ch === 0) {
        out.push(s.temp)
      } else if (ch === 1) {
        out.push(s.humi)
      } else if (ch === 2) {
        out.push(s.lux)
      } else if (ch === 3) {
        out.push(s.smoke)
      } else {
        out.push(0)
      }
    }
    return out
  }

  /** 一次取齐四条曲线（温/湿/光/烟），避免界面上连续调 4 次 */
  allSeries(): number[][] {
    return [this.series(0), this.series(1), this.series(2), this.series(3)]
  }

  /**
   * 算 8 × N 特征矩阵（已归一化到 [0,1]）
   *
   * 返回 [通道][时间]，共 N_CHANNELS 行、size() 列。
   * 窗口不足 WINDOW_SEC 也返回（用现有长度），但调用方应该等 ready。
   */
  features(): number[][] {
    const n: number = this.buf.length
    if (n === 0) {
      return []
    }

    // 先取原始值
    const raw: number[][] = []
    for (let c = 0; c < N_CHANNELS; c++) {
      const row: number[] = []
      for (let i = 0; i < n; i++) {
        row.push(0)
      }
      raw.push(row)
    }

    for (let i = 0; i < n; i++) {
      const s = this.buf[i]
      raw[0][i] = s.temp
      raw[1][i] = s.humi
      raw[2][i] = s.lux
      raw[3][i] = s.smoke
    }

    // 一阶差分 —— 换算成「每秒变化率」
    //
    // ⚠️ 采样间隔是 SAMPLE_SEC（5 秒），不是 1 秒。
    //    不除的话：单位变成"每采样点"，比 ℃/s 大 5 倍，
    //    正常环境的噪声就会越过 Baseline.ets 的阈值。
    const dt: number = WindowBuffer.SAMPLE_SEC
    for (let i = 1; i < n; i++) {
      raw[4][i] = (raw[0][i] - raw[0][i - 1]) / dt
      raw[5][i] = (raw[1][i] - raw[1][i - 1]) / dt
      raw[6][i] = (raw[3][i] - raw[3][i - 1]) / dt
    }
    if (n > 1) {
      raw[4][0] = raw[4][1]
      raw[5][0] = raw[5][1]
      raw[6][0] = raw[6][1]
    }

    // ch7 烟雾回落比：最近 4 个点（20 秒）的均值 / 整个窗口的峰值
    //   > 1 说明还在高位（燃烧特征）
    //   ≪ 1 说明已经回落（水汽特征）
    //   ⚠️ 这个 "4" 必须和 ai/train.py 里的 smoke_seq[-4:] 一致
    const tailLen: number = Math.min(4, n)
    let tailSum: number = 0
    for (let i = n - tailLen; i < n; i++) {
      tailSum += raw[3][i]
    }
    const tailAvg: number = tailSum / tailLen
    let peak: number = 0
    for (let i = 0; i < n; i++) {
      const a: number = Math.abs(raw[3][i])
      if (a > peak) {
        peak = a
      }
    }
    const ratio: number = peak > 1e-6 ? (tailAvg / peak) : 1
    for (let i = 0; i < n; i++) {
      raw[7][i] = ratio
    }

    // 归一化
    for (let c = 0; c < N_CHANNELS; c++) {
      const lo: number = NORM[c].min
      const hi: number = NORM[c].max
      for (let i = 0; i < n; i++) {
        raw[c][i] = norm(raw[c][i], lo, hi)
      }
    }

    return raw
  }

  /**
   * 取最近 WINDOW_SEC 个点，展平成模型输入形状 (1, 8, 60)
   *
   * 不足 60 个点时用**最早的那个点**往前补（避免用 0 补齐 ——
   * 0 在归一化后不是中性值，会让模型看到一段假数据）。
   */
  toModelInput(): Float32Array {
    const f: number[][] = this.features()
    const out: Float32Array = new Float32Array(N_CHANNELS * WINDOW_SEC)
    const n: number = f.length > 0 ? f[0].length : 0
    if (n === 0) {
      return out
    }

    for (let c = 0; c < N_CHANNELS; c++) {
      const base: number = c * WINDOW_SEC
      const pad: number = WINDOW_SEC - n
      const first: number = f[c][0]

      for (let i = 0; i < pad; i++) {
        out[base + i] = first
      }
      for (let i = 0; i < n; i++) {
        out[base + pad + i] = f[c][i]
      }
    }
    return out
  }

  /**
   * 当前特征的摘要（给界面显示，也供规则基线判据使用）
   *
   * ⚠️ 三个速率用的是**整窗最小二乘斜率**，不是最后两点的差分。
   *
   *    用最后两点的话，单点噪声直接决定判定：电吹风加热时整体在升，
   *    但只要某一步因为气流回落一下，`tempRising` 就是 false ——
   *    实测导致 407 个燃烧样本**全部漏报**。
   */
  summary(): FeatureSummary {
    const s: FeatureSummary = new FeatureSummary()
    const n: number = this.buf.length
    if (n === 0) {
      return s
    }

    const last: number = n - 1
    s.temp = this.buf[last].temp
    s.humi = this.buf[last].humi
    s.lux = this.buf[last].lux
    s.smoke = this.buf[last].smoke

    // 整窗最小二乘斜率，单位换算成「每秒」
    s.dTemp = this.slopePerSec(0)
    s.dHumi = this.slopePerSec(1)
    s.dSmoke = this.slopePerSec(3)
    s.fallRatio = this.fallRatio()
    return s
  }

  /**
   * 整窗线性拟合的斜率（每秒）
   *
   * 采样间隔用 SAMPLE_SEC 而不是各点的实际 ts 差 —— 因为对讲机
   * 抖动、丢包会让实际间隔不均匀，但"趋势"要的是均匀时间轴上的斜率。
   *
   * 最小二乘：slope = Σ((x-x̄)(y-ȳ)) / Σ((x-x̄)²)，x 取 0,1,2,...
   * 分母对 n 个点恒等于 n(n²-1)/12，可预先化简，省掉一次遍历。
   *
   * @param ch 0=温度 1=湿度 3=烟雾
   */
  private slopePerSec(ch: number): number {
    const series: number[] = this.series(ch)
    const n: number = series.length
    if (n < 2) {
      return 0
    }
    let sumY: number = 0
    for (let i = 0; i < n; i++) {
      sumY += series[i]
    }
    const meanY: number = sumY / n
    const meanX: number = (n - 1) / 2

    let num: number = 0
    for (let i = 0; i < n; i++) {
      num += (i - meanX) * (series[i] - meanY)
    }
    const den: number = n * (n * n - 1) / 12
    if (den < 1e-9) {
      return 0
    }
    // 斜率单位是「每采样点」→ 除以采样间隔得「每秒」
    return (num / den) / WindowBuffer.SAMPLE_SEC
  }

  /** 烟雾回落比：近 TAIL_POINTS 点均值 / 整窗峰值 */
  private fallRatio(): number {
    const smoke: number[] = this.series(3)
    const n: number = smoke.length
    if (n === 0) {
      return 1
    }
    const tailLen: number = Math.min(4, n)
    let tailSum: number = 0
    for (let i = n - tailLen; i < n; i++) {
      tailSum += smoke[i]
    }
    const tailAvg: number = tailSum / tailLen
    let peak: number = 0
    for (let i = 0; i < n; i++) {
      const a: number = Math.abs(smoke[i])
      if (a > peak) {
        peak = a
      }
    }
    return peak > 1e-6 ? (tailAvg / peak) : 1
  }
}

/** 只填收到的那几个字段 */
export interface PartialSample {
  temp?: number
  humi?: number
  lux?: number
  smoke?: number
}

/** 特征摘要（界面用） */
export class FeatureSummary {
  temp: number = 0
  humi: number = 0
  lux: number = 0
  smoke: number = 0
  /** ℃/s */
  dTemp: number = 0
  /** %/s */
  dHumi: number = 0
  /** ppm/s */
  dSmoke: number = 0
  /** 近 10s 均值 / 窗口峰值 */
  fallRatio: number = 1
}
