/**
 * 星枢 SparkHub · 数据模型（MQTT 版）
 *
 * 设备通过 MQTT 上报 JSON，格式由 DevicePayload 定义；
 * 解析后填进 Snapshot，界面只认 Snapshot。
 */

import { FeatureSummary } from './Features'

/** 设备上报的 JSON 结构 —— 设备端按这个格式发 */
export interface DevicePayload {
  /** 节点标识，可选 */
  node?: string
  /** 温度 ℃ */
  temp?: number
  /** 湿度 % */
  humi?: number
  /** 光照 lux */
  lux?: number
  /** 烟雾浓度 ppm */
  smoke?: number
  /** 灯：'ON' / 'OFF' */
  light?: string
  /** 风扇/电机：'ON' / 'OFF' */
  motor?: string
  /** 蜂鸣器：'ON' / 'OFF' */
  beep?: string
}

/** 解析后的设备状态快照（界面直接用这个） */
export class Snapshot {
  ok: boolean = false
  ts: number = 0
  error: string = ''
  deviceId: string = ''

  temp: number = NaN
  humi: number = NaN
  /** 光照 lux（只有 N01 有） */
  lux: number = NaN

  smoke: number = NaN
  /** normal / near / alarm / unknown */
  smokeLevel: string = 'unknown'
  smokeThreshold: number = 300

  lightOn: boolean = false
  fanOn: boolean = false
  beepOn: boolean = false

  /* ── 60 秒滑窗（给 AI / 规则基线用）─────────────── */

  /** 窗口填充进度 0~1，界面显示"数据积累中 xx%" */
  windowProgress: number = 0
  /** 窗口是否够长（满 12 点） */
  windowReady: boolean = false
  /** 当前特征摘要（界面显示"AI 在看什么"） */
  features: FeatureSummary = new FeatureSummary()

  /* ── 界面用 —— 分类结果与曲线 ─────────────────── */

  /** 四分类概率 [正常, 油烟, 水汽, 燃烧] */
  probs: number[] = [1, 0, 0, 0]
  /** 判定来源：rule / model / cloud */
  source: string = 'rule'
  /** 命中的判据（界面显示，便于解释和现场调试） */
  reason: string = ''
  /** 四条曲线 [温度, 湿度, 光照, 烟雾]，元素是原始物理量 */
  series: number[][] = []

  /* ── 自适应阈值 + 趋势外推 ─────────────────────── */

  /** 本底学习进度 0~1 */
  learnProgress: number = 0
  /** 本底是否学完（学完后阈值才自适应） */
  learnReady: boolean = false
  /** 本底摘要文字（界面显示） */
  learnDesc: string = ''
  /** 按当前斜率预计多少秒后触警；-1 = 不会触警 */
  predictSec: number = -1

  /* ── 第 3 层：DeepSeek 云端建议（可选增强）────────── */

  /** DeepSeek 返回的处置建议（一句话） */
  llmAdvice: string = ''
  /** 状态：idle=未调用 / loading=请求中 / ok=成功 / err=失败 */
  llmState: string = 'idle'
  /** 最近一次调用耗时（毫秒） */
  llmMs: number = 0
  /** 累计调用次数 / 失败次数（界面展示"接入了云端"的证据） */
  llmCalls: number = 0
  llmFails: number = 0

  /* ── DeepSeek ②：零样本识别未知事件 ────────────── */

  /** 是否为"CNN 四类都不像"的未知事件（此时 llmAdvice 里是识别结果） */
  llmUnknown: boolean = false
  /** 识别出的事件名（如"香烟/香薰类气溶胶"）；空串表示没识别 */
  llmUnknownName: string = ''

  /* ── DeepSeek ③：自然语言问答 ──────────────────── */

  /** 最近一次提问 */
  llmQaQuestion: string = ''
  /** 最近一次回答 */
  llmQaAnswer: string = ''
  /** 问答状态：idle / loading / ok / err */
  llmQaState: string = 'idle'
  /** 最近一次问答耗时 */
  llmQaMs: number = 0
}

