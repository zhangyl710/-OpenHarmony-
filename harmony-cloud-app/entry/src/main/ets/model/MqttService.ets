import { MqttAsync, MqttClient, MqttConnectOptions, MqttMessage } from '@ohos/mqtt'
import hilog from '@ohos.hilog'
import { DevicePayload, Snapshot } from './Types'
import { WindowBuffer, FeatureSummary } from './Features'
import { ClassifyResult, classifyByRule, CLASS_NAMES } from './Baseline'
import { BaselineLearner, LearnedBaseline, predictAlarmSec } from './Adaptive'
import { MsModel } from './MsModel'
import { DeepSeekClient, LlmAdvice, LlmAnswer, UNKNOWN_TOP1, UNKNOWN_MARGIN } from './DeepSeek'

const DOMAIN: number = 0x0000
const TAG: string = 'SparkHubMqtt'

/**
 * MQTT 服务：直连本地 broker，收发设备数据。
 *
 * 链路：Nano 2 ──MQTT──> 本地 broker（Mosquitto / EMQX）──MQTT──> 本应用
 * 全程局域网，不需要任何云平台和认证。
 */

/** ⚠️ 改成你跑 broker 那台机器的局域网 IP 和端口 */
export const BROKER_URL: string = 'tcp://192.168.87.43:1883'

/** 客户端 ID 必须全局唯一，重复会导致双方互相踢下线 */
export const CLIENT_ID: string = 'sparkhub_purple_pi'

/**
 * broker 的账号密码。
 * Mosquitto 默认是匿名访问（allow_anonymous true），这两项留空即可。
 * 如果你给 broker 加了密码认证，在这里填上。
 *
 * 注意：MqttConnectOptions 里 userName / password 是必填字段，
 *       所以即使匿名也必须传空字符串，不能省略。
 */
export const MQTT_USER: string = ''
export const MQTT_PASS: string = ''

/** 设备上报数据的主题 */
export const TOPIC_DATA: string = 'sparkhub/data'

/** 下发控制命令的主题 */
export const TOPIC_CMD: string = 'sparkhub/cmd'

/** 烟雾报警阈值（ppm） */
export const SMOKE_THRESHOLD: number = 300

export type DataHandler = (snap: Snapshot) => void
export type StatusHandler = (connected: boolean, info: string) => void

export class MqttService {
  private client: MqttClient | null = null
  private dataHandler: DataHandler | null = null
  private statusHandler: StatusHandler | null = null

  /**
   * 每个节点最近一次的原始 payload。
   *
   * 两块板分工不同（IA1 测温湿度/光照，SF1 测烟雾），各自会把自己
   * 没测的字段发成 0。如果每条消息都整体替换 Snapshot，后到的消息
   * 就会把另一块板的真实数据抹成 0 —— 表现就是"有烟雾数据，没有温湿度"。
   * 所以这里按 node 分别保留，再合并出界面用的快照。
   */
  private lastByNode: Map<string, DevicePayload> = new Map<string, DevicePayload>()

  /**
   * 60 秒滑窗（12 点 @ 5 秒采样）—— 给 AI 模型 / 规则基线用
   *
   * ⚠️ 窗口点数在 Features.ets 的 WINDOW_SEC 里定义（=12），
   *    它和 ai/train.py 的 SEQ_LEN 必须一致。
   */
  private windowBuf: WindowBuffer = new WindowBuffer()

  /**
   * 本底学习器 + 学到的本底
   *
   * 开机后先攒 15 个窗口（约 15 分钟）统计本底，之后阈值按
   * "本底 ± kσ" 动态算 —— 换环境不用改代码。
   */
  private learner: BaselineLearner = new BaselineLearner()
  private baseline: LearnedBaseline = new LearnedBaseline()

  /**
   * 本地模型（第 2 层推理）—— 由外部（Index.ets）加载好后注入
   *
   * 没注入、或者加载失败时，infer() 返回 null，自动降级到规则基线。
   */
  private msModel: MsModel | null = null

  /**
   * 第 3 层：DeepSeek 云端建议（可选增强）
   *
   * ⚠️ 它**不参与判类** —— 只把 CNN 的判定转成人类可读的处置建议。
   *    理由：LLM 处理 96 个浮点数的能力远不如 5124 参数的小 CNN，
   *    但"把结论讲成人话"是小 CNN 做不到的。
   *
   *    网络不通 / Key 未配置 / 超时 → 静默跳过，界面照常用本地结果。
   */
  private llm: DeepSeekClient = new DeepSeekClient()

  /* 云端建议的最近状态（存在服务侧，避免异步返回时快照已经过期） */
  private llmAdvice: string = ''
  private llmState: string = 'idle'
  private llmMs: number = 0

  /** 是否为未知事件（CNN 四类都不像 → 走零样本识别） */
  private llmUnknown: boolean = false
  private llmUnknownName: string = ''

  /** 问答状态 */
  private llmQaQuestion: string = ''
  private llmQaAnswer: string = ''
  private llmQaState: string = 'idle'
  private llmQaMs: number = 0

  /**
   * 判定变化历史（最近 30 条）—— 喂给 DeepSeek 做问答的上下文
   *
   * 只在**判定类别变化**时记一条，避免把每 1 秒的重复判定灌进去。
   * 这是"刚才为什么报警""今天有几次油烟"这类问题能答对的前提。
   */
  private judgeHistory: string[] = []
  private lastJudgeClass: string = ''
  private static readonly HISTORY_MAX: number = 30

  /** 最近一次推给界面的快照 —— 问答时用来组装上下文 */
  private lastSnap: Snapshot | null = null

  /** 记一条判定变化（供问答时引用） */
  private pushHistory(cls: string, prob: number, f: FeatureSummary, ts: number): void {
    if (cls === this.lastJudgeClass) {
      return
    }
    this.lastJudgeClass = cls
    const d: Date = new Date(ts)
    const hh: string = String(d.getHours()).padStart(2, '0')
    const mm: string = String(d.getMinutes()).padStart(2, '0')
    const ss: string = String(d.getSeconds()).padStart(2, '0')
    const line: string = `${hh}:${mm}:${ss} ${cls} 置信度${(prob * 100).toFixed(0)}%`
      + `（温${f.temp.toFixed(1)}℃/${f.dTemp.toFixed(2)}℃每秒 湿${f.humi.toFixed(0)}%`
      + `/${f.dHumi.toFixed(1)}%每秒 烟${f.smoke.toFixed(0)}ppm/${f.dSmoke.toFixed(1)}ppm每秒 回落${f.fallRatio.toFixed(2)}）`
    this.judgeHistory.push(line)
    while (this.judgeHistory.length > MqttService.HISTORY_MAX) {
      this.judgeHistory.shift()
    }
    hilog.info(DOMAIN, TAG, 'history + %{public}s', line)
  }

  /** 组装给 LLM 的当前状态文本 */
  private contextText(snap: Snapshot): string {
    const f: FeatureSummary = snap.features
    const top: number = MqttService.argmax(snap.probs)
    const l: string[] = []
    l.push(`当前判定：${CLASS_NAMES[top]}（置信度 ${(snap.probs[top] * 100).toFixed(1)}%）`)
    l.push(`判定来源：${snap.source === 'model' ? '端侧 MindSpore Lite 模型' : '规则基线'}`)
    l.push(`温度 ${f.temp.toFixed(1)}℃（变化率 ${f.dTemp.toFixed(2)} ℃/s）`)
    l.push(`湿度 ${f.humi.toFixed(1)}%（变化率 ${f.dHumi.toFixed(2)} %/s）`)
    l.push(`光照 ${f.lux.toFixed(0)} lx`)
    l.push(`烟雾 ${f.smoke.toFixed(0)} ppm（变化率 ${f.dSmoke.toFixed(1)} ppm/s，回落比 ${f.fallRatio.toFixed(2)}）`)
    l.push(`四类概率：正常 ${(snap.probs[0] * 100).toFixed(0)}% / 油烟 ${(snap.probs[1] * 100).toFixed(0)}%`
      + ` / 水汽 ${(snap.probs[2] * 100).toFixed(0)}% / 燃烧 ${(snap.probs[3] * 100).toFixed(0)}%`)
    l.push(`在线节点：${snap.deviceId}`)
    l.push(`本底学习：${snap.learnDesc}`)
    l.push(`窗口数据：${Math.round(snap.windowProgress * 100)}%`)
    return l.join('\n')
  }

  private static argmax(p: number[]): number {
    let best: number = 0
    for (let i = 1; i < p.length; i++) {
      if (p[i] > p[best]) {
        best = i
      }
    }
    return best
  }

  /** 注入模型（在 Index 里 load 成功后调） */
  setModel(m: MsModel): void {
    this.msModel = m
    hilog.info(DOMAIN, TAG, 'model injected, ready=%{public}s', String(m.isReady))
  }

  setHandlers(onData: DataHandler, onStatus: StatusHandler): void {
    this.dataHandler = onData
    this.statusHandler = onStatus
  }

  /** 建立连接并订阅数据主题 */
  async connect(): Promise<void> {
    const client = MqttAsync.createMqtt({
      url: BROKER_URL,
      clientId: CLIENT_ID,
      // 1 = 内存持久化，轻量设备推荐
      persistenceType: 1
    })
    this.client = client

    // ⚠️ messageArrived 必须在 connect 之前注册，
    //    否则「连接成功」到「注册回调」之间到达的消息会被丢掉
    client.messageArrived((err: Error, msg: MqttMessage) => {
      if (err) {
        return
      }
      this.handleMessage(msg)
    })

    // 被动断线（broker 挂了、网络断了）
    client.connectLost(() => {
      this.notify(false, '连接已断开')
    })

    const opts: MqttConnectOptions = {
      connectTimeout: 10,
      keepAliveInterval: 30,
      cleanSession: true,
      // 这两项在 MqttConnectOptions 里是必填的，匿名模式下传空字符串
      userName: MQTT_USER,
      password: MQTT_PASS
    }
    hilog.info(DOMAIN, TAG, 'connecting to %{public}s clientId=%{public}s',
      BROKER_URL, CLIENT_ID)
    try {
      await client.connect(opts)
    } catch (e) {
      // ArkTS 的 throw 只接受 Error 类型，所以这里重新包一个
      const err = e as Error
      let msg: string = 'connect failed'
      if (err !== undefined && err.message !== undefined && err.message.length > 0) {
        msg = err.message
      }
      hilog.error(DOMAIN, TAG, 'connect FAILED: %{public}s', msg)
      throw new Error(msg)
    }
    hilog.info(DOMAIN, TAG, 'connected OK')
    this.notify(true, '已连接')

    // 订阅数据主题。QoS 1 = 至少一次，避免丢数据
    try {
      await client.subscribe({ topic: TOPIC_DATA, qos: 1 })
      hilog.info(DOMAIN, TAG, 'subscribed %{public}s', TOPIC_DATA)
    } catch (e) {
      const err = e as Error
      hilog.error(DOMAIN, TAG, 'subscribe FAILED: %{public}s',
        (err !== undefined && err.message !== undefined) ? err.message : 'unknown')
    }
  }

  /** 断开并销毁。顺序不能反，否则 paho 线程可能崩 */
  async disconnect(): Promise<void> {
    const c = this.client
    if (c === null) {
      return
    }
    this.client = null
    try {
      await c.disconnect()
      await c.destroy()
    } catch (e) {
      // 断开时的异常可以忽略
    }
  }

  /** 下发控制命令给设备 */
  async send(target: string, value: string): Promise<void> {
    const c = this.client
    if (c === null) {
      throw new Error('MQTT 未连接')
    }
    const payload: string = JSON.stringify({ target: target, value: value })
    await c.publish({
      topic: TOPIC_CMD,
      payload: payload,
      qos: 1,
      retained: false
    })
  }

  // ---------------------------------------------------------- 内部

  private notify(connected: boolean, info: string): void {
    const h = this.statusHandler
    if (h !== null) {
      h(connected, info)
    }
  }

  /** 把 payload 统一成字符串 —— paho 可能给 string，也可能给 ArrayBuffer */
  private static payloadToText(p: string | ArrayBuffer): string {
    if (typeof p === 'string') {
      return p
    }
    const bytes = new Uint8Array(p as ArrayBuffer)
    let s: string = ''
    for (let i = 0; i < bytes.length; i++) {
      s += String.fromCharCode(bytes[i])
    }
    return s
  }

  private handleMessage(msg: MqttMessage): void {
    hilog.info(DOMAIN, TAG, 'arrived topic=%{public}s', msg.topic)

    if (msg.topic !== TOPIC_DATA) {
      return
    }

    const text: string = MqttService.payloadToText(msg.payload)
    hilog.info(DOMAIN, TAG, 'payload=%{public}s', text)

    let payload: DevicePayload
    try {
      payload = JSON.parse(text) as DevicePayload
    } catch (e) {
      const err = e as Error
      hilog.error(DOMAIN, TAG, 'JSON.parse FAILED: %{public}s',
        (err !== undefined && err.message !== undefined) ? err.message : 'unknown')
      return
    }

    const node: string = (payload.node !== undefined && payload.node.length > 0)
      ? payload.node : 'default'
    hilog.info(DOMAIN, TAG, 'parsed node=%{public}s temp=%{public}s humi=%{public}s smoke=%{public}s',
      node,
      payload.temp !== undefined ? String(payload.temp) : '(none)',
      payload.humi !== undefined ? String(payload.humi) : '(none)',
      payload.smoke !== undefined ? String(payload.smoke) : '(none)')

    // 按节点记住最新一份，再合并给界面
    this.lastByNode.set(node, payload)

    // 喂进 60 秒滑窗
    //
    // ⚠️ 必须按节点过滤：设备端会把「自己没有的传感器」发成 0，
    //    无脑全喂的话 N02 的 temp:0 会污染温度通道。
    //
    //    N01（E53_IA1）→ 温湿度 + 光照
    //    N02（E53_SF1）→ 烟雾
    const now: number = Date.now()
    if (node === 'N01') {
      this.windowBuf.feed({ temp: payload.temp, humi: payload.humi, lux: payload.lux }, now)
    } else if (node === 'N02') {
      this.windowBuf.feed({ smoke: payload.smoke }, now)
    } else {
      this.windowBuf.feed({
        temp: payload.temp, humi: payload.humi, lux: payload.lux, smoke: payload.smoke
      }, now)
    }

    const h = this.dataHandler
    if (h !== null) {
      const merged: Snapshot = MqttService.merge(this.lastByNode)

      // 带上滑窗状态 —— 界面显示"数据积累中 xx%"和当前特征
      merged.windowProgress = this.windowBuf.progress
      merged.windowReady = this.windowBuf.ready
      merged.features = this.windowBuf.summary()

      // 推理 —— 当前跑第 1 层（规则基线 + 自适应阈值）
      //   将来接上本地模型/云端只需替换这一段，上层界面不用改
      if (merged.windowReady) {
        // 喂本底学习器（内部自己滑动更新，不用手动重置）
        this.learner.feed(merged.features, this.baseline)

        const r: ClassifyResult = classifyByRule(merged.features, this.baseline)
        merged.probs = r.probs
        merged.source = r.source
        merged.reason = r.reason

        // 趋势外推：按当前斜率还要多久触警
        merged.predictSec = predictAlarmSec(merged.features)
      } else {
        merged.probs = [1, 0, 0, 0]
        merged.source = 'rule'
        merged.reason = `窗口填充中 ${Math.round(merged.windowProgress * 100)}%`
      }

      // 本底学习状态（界面显示"校准中 xx%"）
      merged.learnProgress = this.baseline.progress
      merged.learnReady = this.baseline.ready
      merged.learnDesc = this.baseline.describe()

      // 曲线数据（四条：温/湿/光/烟）
      merged.series = this.windowBuf.allSeries()

      /* 第 3 层：带上云端建议的最近状态
         （存在服务侧而不是快照里 —— DeepSeek 是异步返回的，
           返回时界面可能已经在渲染新的快照了） */
      merged.llmAdvice = this.llmAdvice
      merged.llmState = this.llmState
      merged.llmMs = this.llmMs
      merged.llmUnknown = this.llmUnknown
      merged.llmUnknownName = this.llmUnknownName
      merged.llmQaQuestion = this.llmQaQuestion
      merged.llmQaAnswer = this.llmQaAnswer
      merged.llmQaState = this.llmQaState
      merged.llmQaMs = this.llmQaMs
      merged.llmCalls = this.llm.totalCalls()
      merged.llmFails = this.llm.totalFails()

      /* 记一条判定历史（只在类别变化时）—— 供问答时引用"刚才为什么报警" */
      this.lastSnap = merged
      const pTmp: number[] = merged.probs
      this.pushHistory(CLASS_NAMES[MqttService.argmax(pTmp)], pTmp[MqttService.argmax(pTmp)],
        merged.features, merged.ts)

      hilog.info(DOMAIN, TAG,
        'merged nodes=%{public}s temp=%{public}s humi=%{public}s smoke=%{public}s win=%{public}s%%',
        merged.deviceId, String(merged.temp), String(merged.humi), String(merged.smoke),
        String(Math.round(merged.windowProgress * 100)))

      // 判定结果单独打一行 —— 出问题时一眼看出是规则还是模型、命中了哪条判据
      const f = merged.features
      hilog.info(DOMAIN, TAG,
        'judge src=%{public}s probs=%{public}s dT=%{public}s dH=%{public}s dS=%{public}s fall=%{public}s cur=%{public}s',
        merged.source, JSON.stringify(merged.probs),
        f.dTemp.toFixed(4), f.dHumi.toFixed(4), f.dSmoke.toFixed(4),
        f.fallRatio.toFixed(3),
        `${f.temp}/${f.humi}/${f.smoke}`)
      hilog.info(DOMAIN, TAG, 'judge reason=%{public}s', merged.reason)

      /* 先推规则基线的结果（同步、零延迟），界面立刻有东西显示 */
      h(merged)

      /* 再异步跑本地模型，成功就覆盖。
         不 await —— 这里是 MQTT 回调线程，不能让推理把它堵住。 */
      this.inferWithModel(merged)

      /* 第 3 层：异步问 DeepSeek 要处置建议
         同样不 await —— LLM 延迟是秒级，绝不能让它堵住 MQTT 回调线程。
         类别没变时按 REFRESH_MS 节流，省 token。 */
      this.askLlm(merged)
    }
  }

  /**
   * 异步问 DeepSeek 要一句处置建议（第 3 层，可选增强）
   *
   * 与 inferWithModel 一样**不阻塞**：
   *   - 未配置 Key / 正在请求中 / 类别未变且未到刷新间隔 → 直接返回
   *   - 请求成功 → 把建议推给界面（并覆盖服务侧的最近状态）
   *   - 请求失败 → 只记日志，界面不受任何影响
   *
   * ⚠️ 它不参与判类 —— snap.probs 始终来自本地 CNN / 规则基线。
   */
  private async askLlm(snap: Snapshot): Promise<void> {
    if (!snap.windowReady) {
      return
    }
    const p: number[] = snap.probs
    const top: number = MqttService.argmax(p)
    const cls: string = CLASS_NAMES[top]

    /* ── 判断是「已知场景」还是「未知事件」──
       CNN 只学过 4 类，遇到香水/香烟/杀虫剂时四类都不像。
       这时才轮到 LLM 上场：用常识推断"这是什么"。
       这是 DeepSeek 补 CNN 短板的**核心场景**，而不只是生成一句建议。 */
    let second: number = -1
    for (let i = 0; i < p.length; i++) {
      if (i !== top && p[i] > second) {
        second = p[i]
      }
    }
    const isUnknown: boolean = (p[top] < UNKNOWN_TOP1) || ((p[top] - second) < UNKNOWN_MARGIN)

    /* 节流的 key 带上 unknown 标记 —— 已知/未知切换时立刻触发 */
    const askKey: string = (isUnknown ? 'U:' : 'K:') + cls
    if (!this.llm.shouldAsk(askKey, Date.now())) {
      return
    }

    this.llmState = 'loading'
    this.llmUnknown = isUnknown
    hilog.info(DOMAIN, TAG, 'ask DeepSeek: %{public}s class=%{public}s top=%{public}s gap=%{public}s',
      isUnknown ? '零样本识别' : '处置建议', cls, p[top].toFixed(3), (p[top] - second).toFixed(3))

    /* 请求中先推一次，让界面显示 loading —— 演示时能看出"确实在调云端" */
    this.pushLlm(snap)

    const r: LlmAdvice = isUnknown
      ? await this.llm.askUnknown(snap.features, p)
      : await this.llm.askAdvice(cls, p[top], snap.features)

    if (r.ok) {
      this.llmAdvice = r.text
      this.llmState = 'ok'
      this.llmMs = r.ms
      /* 未知识别时，第一行是事件名，单独抽出来给界面当标题用 */
      if (isUnknown) {
        const nl: number = r.text.indexOf('\n')
        this.llmUnknownName = (nl > 0) ? r.text.substring(0, nl).trim() : r.text
      } else {
        this.llmUnknownName = ''
      }
    } else {
      /* 失败不覆盖上一条建议，只改状态 —— 界面显示"云端不可用"但保留旧建议 */
      this.llmState = 'err'
      this.llmMs = r.ms
    }

    this.pushLlm(snap)
  }

  /** 把云端相关字段写进快照并推送一次（避免等下一条 MQTT 消息） */
  private pushLlm(snap: Snapshot): void {
    const h = this.dataHandler
    if (h === null) {
      return
    }
    snap.llmAdvice = this.llmAdvice
    snap.llmState = this.llmState
    snap.llmMs = this.llmMs
    snap.llmUnknown = this.llmUnknown
    snap.llmUnknownName = this.llmUnknownName
    snap.llmQaQuestion = this.llmQaQuestion
    snap.llmQaAnswer = this.llmQaAnswer
    snap.llmQaState = this.llmQaState
    snap.llmQaMs = this.llmQaMs
    snap.llmCalls = this.llm.totalCalls()
    snap.llmFails = this.llm.totalFails()
    h(snap)
  }

  /**
   * 【对外】用户提问 —— 看板上输入或点预设问题
   *
   * 与自动请求不同：**不走节流**（用户主动问必须立刻答），
   * 但仍然异步 —— 调用方拿到 Promise 后自行 await，不要卡住 UI 或 MQTT 线程。
   */
  async ask(question: string): Promise<void> {
    const h = this.dataHandler
    this.llmQaQuestion = question
    this.llmQaState = 'loading'
    this.llmQaAnswer = ''

    /* 用最近的快照组装上下文 */
    const last: Snapshot | null = this.lastSnap
    if (last === null) {
      this.llmQaState = 'err'
      this.llmQaAnswer = '还没有收到任何传感器数据，无法回答。'
      hilog.warn(DOMAIN, TAG, 'ask: 无快照')
      if (h !== null) {
        this.pushQa(h)
      }
      return
    }

    if (!this.llm.isConfigured()) {
      this.llmQaState = 'err'
      this.llmQaAnswer = '未配置 API Key，无法使用云端问答。'
      if (h !== null) {
        this.pushQa(h)
      }
      return
    }

    if (h !== null) {
      this.pushQa(h)
    }

    hilog.info(DOMAIN, TAG, 'QA 提问: %{public}s', question)
    const ctx: string = DeepSeekClient.buildContext(this.contextText(last), this.judgeHistory)
    const a: LlmAnswer = await this.llm.askQuestion(question, ctx)

    this.llmQaMs = a.ms
    if (a.ok) {
      this.llmQaState = 'ok'
      this.llmQaAnswer = a.answer
    } else {
      this.llmQaState = 'err'
      this.llmQaAnswer = `云端回答失败：${a.err}`
    }
    if (h !== null) {
      this.pushQa(h)
    }
  }

  /** 推送问答状态 */
  private pushQa(h: DataHandler): void {
    const s: Snapshot | null = this.lastSnap
    if (s === null) {
      return
    }
    s.llmQaQuestion = this.llmQaQuestion
    s.llmQaAnswer = this.llmQaAnswer
    s.llmQaState = this.llmQaState
    s.llmQaMs = this.llmQaMs
    h(s)
  }

  /**
   * 异步跑本地模型，成功后把结果覆盖到快照上再推一次
   *
   * 模型没注入 / 没加载成功 / 推理失败 / 窗口没满 —— 全都安静返回，
   * 界面保持在规则基线的结果上。**这就是"降级"。**
   */
  private async inferWithModel(snap: Snapshot): Promise<void> {
    const m: MsModel | null = this.msModel
    if (m === null || !m.isReady || !snap.windowReady) {
      return
    }
    try {
      const input: Float32Array = this.windowBuf.toModelInput()
      hilog.info(DOMAIN, TAG, 'infer start, input len=%{public}d', input.length)
      const r: ClassifyResult | null = await m.infer(input)
      hilog.info(DOMAIN, TAG, 'infer done, result=%{public}s',
        (r === null) ? 'null(降级到规则)' : JSON.stringify(r.probs))
      if (r === null) {
        return
      }

      /* ── 冲突保护：安全类结论不能被模型单方面否决 ──
       *
       * 场景（现场实测过）：近距离热源让温度以 3 ℃/s 上升，
       * 远超训练数据里 0.67 ℃/s 的上限，模型输入被归一化越界，
       * 给出「正常 0.48 / 燃烧 0.31」—— 而规则基线正确判了「燃烧」。
       *
       * 处理原则：**两者都判燃烧 → 采信模型；只有规则判燃烧而模型判得低
       * → 保留规则的结论**。漏报的代价远高于一次多余的告警。
       */
      const ruleFire: number = snap.probs[3]
      const modelFire: number = r.probs[3]
      if (ruleFire >= 0.5 && modelFire < 0.5) {
        hilog.warn(DOMAIN, TAG,
          '模型否决燃烧但无把握，保留规则结论：rule=%{public}s model=%{public}s',
          ruleFire.toFixed(2), modelFire.toFixed(2))
        snap.source = 'rule+model'
        snap.reason = snap.reason + `（模型判 ${CLASS_NAMES[MqttService.argmax(r.probs)]}`
          + ` ${modelFire.toFixed(2)}，已被安全策略覆盖）`
        const h2 = this.dataHandler
        if (h2 !== null) {
          h2(snap)
        }
        return
      }

      snap.probs = r.probs
      snap.source = r.source
      snap.reason = r.reason

      const h = this.dataHandler
      if (h !== null) {
        h(snap)
      }
    } catch (e) {
      /* 推理异常不影响主流程 —— 界面上已经有规则结果了 */
      const err = e as Error
      hilog.error(DOMAIN, TAG, 'inferWithModel failed: %{public}s',
        (err !== undefined && err.message !== undefined) ? err.message : 'unknown')
    }
  }

  /**
   * 把各节点的最新数据合并成一个界面快照。
   *
   * 有效值判定：设备端没测的字段会发 0，所以温度 / 湿度只认 > 0 的；
   * 烟雾和三个开关量只要有就采纳（烟雾 0 是正常值）。
   */
  private static merge(byNode: Map<string, DevicePayload>): Snapshot {
    const snap = new Snapshot()
    snap.ok = true
    snap.ts = Date.now()
    snap.smokeThreshold = SMOKE_THRESHOLD

    const names: string[] = []
    byNode.forEach((p: DevicePayload, name: string) => {
      names.push(name)

      if (p.temp !== undefined && p.temp > 0) {
        snap.temp = p.temp
      }
      if (p.humi !== undefined && p.humi > 0) {
        snap.humi = p.humi
      }
      if (p.lux !== undefined && p.lux > 0) {
        snap.lux = p.lux
      }
      if (p.smoke !== undefined && p.smoke > 0) {
        // 同样是"N01 发 0、N02 发真值"的关系，只认 > 0
        snap.smoke = p.smoke
      }
      if (p.light !== undefined) {
        snap.lightOn = p.light === 'ON'
      }
      if (p.motor !== undefined) {
        snap.fanOn = p.motor === 'ON'
      }
      if (p.beep !== undefined) {
        snap.beepOn = p.beep === 'ON'
      }
    })

    snap.deviceId = names.length > 0 ? names.join(' + ') : ''
    snap.smokeLevel = MqttService.smokeLevel(snap.smoke, SMOKE_THRESHOLD)
    return snap
  }

  /** 烟雾三档分级（原来放在服务端算，现在改到应用里） */
  private static smokeLevel(v: number, threshold: number): string {
    if (isNaN(v)) {
      return 'unknown'
    }
    if (v >= threshold) {
      return 'alarm'
    }
    if (v >= threshold * 0.7) {
      return 'near'
    }
    return 'normal'
  }
}
