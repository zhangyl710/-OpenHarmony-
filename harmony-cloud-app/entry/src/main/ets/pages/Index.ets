import { MqttService } from '../model/MqttService'
import { Snapshot } from '../model/Types'
import { CLASS_NAMES, shouldAlarm } from '../model/Baseline'
import { MsModel } from '../model/MsModel'
import { Metric, Palette } from '../common/Theme'
import common from '@ohos.app.ability.common'

/**
 * 星枢 SparkHub · 全屋环境看板（MQTT 版）
 *
 * 应用本身是 MQTT 客户端，直连本地 broker 订阅设备数据。
 * 链路：Nano 2 ──MQTT──> broker ──MQTT──> 本界面
 */
@Entry
@Component
struct Index {
  @State snap: Snapshot = new Snapshot()
  @State connected: boolean = false
  @State errMsg: string = ''

  /**
   * 界面显示用的开关状态 —— 点击后立刻翻转，不等设备回包。
   *
   * fanWait / lightWait 表示"用户刚改过、还在等设备确认"：
   * 这期间收到设备数据不覆盖本地值，否则按钮会先跳过去又被拉回来。
   * 等设备上报的值和本地一致了，就撤掉等待标记，之后完全跟设备走。
   */
  @State fanUi: boolean = false
  @State lightUi: boolean = false
  private fanWait: boolean = false
  private lightWait: boolean = false
  private fanTimer: number = -1
  private lightTimer: number = -1

  /** 等设备确认的最长时间，超了就放弃本地期望值 */
  private static readonly CONFIRM_TIMEOUT_MS: number = 8000

  private mqtt: MqttService = new MqttService()

  /** 本地模型（MindSpore Lite）—— 加载失败会自动降级到规则基线 */
  private msModel: MsModel = new MsModel()
  /** 模型状态文字，界面上显示 */
  @State modelState: string = '加载中…'

  /** 问答输入框内容 */
  @State askText: string = ''

  /** 当前页签下标 —— 底部页签用它做选中高亮 */
  @State curTab: number = 0

  /** 预设问题（答辩时点一下就能问，不用打字） */
  private static readonly PRESET_QUESTIONS: string[] = [
    '现在家里什么情况？',
    '刚才有没有异常？',
    '今天一共出现过几次油烟？',
    '当前判定是怎么得出来的？'
  ]

  /** 曲线画布 —— ArkUI Canvas 自绘，无第三方依赖 */
  private trendCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(
    new RenderingContextSettings(true))

  /** 画布是否已就绪（onReady 之后才能画） */
  private canvasReady: boolean = false

  aboutToAppear(): void {
    this.mqtt.setHandlers(
      (s: Snapshot) => {
        this.snap = s
        this.errMsg = ''
        this.syncSwitchState(s)
        this.redrawTrend()
      },
      (ok: boolean, info: string) => {
        this.connected = ok
        if (!ok) {
          this.errMsg = info
        }
      }
    )
    this.loadModel()
    this.start()
  }

  /**
   * 加载本地模型
   *
   * 失败**不抛异常** —— 只是让 modelState 显示原因，
   * 推理会自动降级到规则基线，界面照常工作。
   */
  private async loadModel(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
      const ok: boolean = await this.msModel.load(ctx.resourceManager)
      this.mqtt.setModel(this.msModel)
      this.modelState = ok ? '已加载' : ('不可用：' + this.msModel.error)
    } catch (e) {
      this.modelState = '加载异常，用规则基线'
    }
  }

  aboutToDisappear(): void {
    this.mqtt.disconnect()
  }

  private async start(): Promise<void> {
    try {
      await this.mqtt.connect()
    } catch (err) {
      this.connected = false
      //this.errMsg = '连不上 broker —— 检查 MqttService.ets 里的 BROKER_URL'
    }
  }

  /**
   * 下发命令。
   *
   * 不再用全局 busy 阻塞：以前 busy 期间按钮是 enabled(false)，
   * 而且 send 会直接 return —— MQTT publish 稍慢一点，用户就会觉得
   * "点了没反应、也没法再点"。现在界面靠乐观更新立刻响应，
   * 这里只负责把命令送出去。
   */
  private async send(target: string, value: string): Promise<void> {
    try {
      await this.mqtt.send(target, value)
    } catch (err) {
      this.errMsg = '下发命令失败，检查 MQTT 连接'
    }
  }

  // ------------------------------------------------ 开关：乐观更新

  /** 收到设备数据 —— 同步界面开关状态 */
  private syncSwitchState(s: Snapshot): void {
    if (!this.fanWait) {
      this.fanUi = s.fanOn
    } else if (s.fanOn === this.fanUi) {
      // 设备确认了，撤掉等待标记，之后完全跟设备走
      this.fanWait = false
      this.cancelTimer(this.fanTimer)
      this.fanTimer = -1
    }

    if (!this.lightWait) {
      this.lightUi = s.lightOn
    } else if (s.lightOn === this.lightUi) {
      this.lightWait = false
      this.cancelTimer(this.lightTimer)
      this.lightTimer = -1
    }
  }

  private cancelTimer(id: number): void {
    if (id !== -1) {
      clearTimeout(id)
    }
  }

  /** 风扇开关：先翻转界面，再下发；最多等 8 秒设备确认 */
  private toggleFan(): void {
    const next: boolean = !this.fanUi
    this.fanUi = next
    this.fanWait = true
    this.cancelTimer(this.fanTimer)
    this.fanTimer = setTimeout(() => {
      this.fanWait = false
      this.fanUi = this.snap.fanOn
    }, Index.CONFIRM_TIMEOUT_MS)
    this.send('motor', next ? 'ON' : 'OFF')
  }

  /** 灯光开关：同上 */
  private toggleLight(): void {
    const next: boolean = !this.lightUi
    this.lightUi = next
    this.lightWait = true
    this.cancelTimer(this.lightTimer)
    this.lightTimer = setTimeout(() => {
      this.lightWait = false
      this.lightUi = this.snap.lightOn
    }, Index.CONFIRM_TIMEOUT_MS)
    this.send('light', next ? 'ON' : 'OFF')
  }

  // ------------------------------------------------------------ 工具

  private fmt(v: number, digits: number): string {
    return isNaN(v) ? '--' : v.toFixed(digits)
  }

  // ------------------------------------------------------- 端侧判定

  /** 取概率最大的类别下标 */
  private topIdx(): number {
    const p: number[] = this.snap.probs
    let best: number = 0
    for (let i = 1; i < p.length; i++) {
      if (p[i] > p[best]) {
        best = i
      }
    }
    return best
  }

  /** 判定结果文字 */
  private aiLabel(): string {
    if (!this.snap.windowReady) {
      return '数据积累中'
    }
    return CLASS_NAMES[this.topIdx()]
  }

  /** 最高那一类的概率 —— 界面上作为"置信度"展示 */
  private topProb(): number {
    const p: number[] = this.snap.probs
    if (p.length < 1) {
      return 0
    }
    return p[this.topIdx()]
  }

  /** 判定结果颜色：正常绿 / 油烟·水汽黄 / 燃烧红 */
  private aiColor(): string {
    if (!this.snap.windowReady) {
      return Palette.textMute
    }
    const i: number = this.topIdx()
    if (i === 0) {
      return Palette.good
    }
    if (i === 3) {
      return Palette.bad
    }
    return Palette.warn
  }

  /** 副标题 */
  private aiSubTitle(): string {
    if (!this.snap.windowReady) {
      return '窗口数据 ' + Math.round(this.snap.windowProgress * 100) + '%'
    }
    if (this.snap.source === 'model') {
      return '推理来源：MindSpore Lite 本地模型'
    }
    if (this.snap.source === 'cloud') {
      return '推理来源：云端模型'
    }
    if (this.snap.source === 'rule+model') {
      return '规则基线判定 · 本地模型结论未被采信（安全优先）'
    }
    if (!this.snap.learnReady) {
      return '规则基线 · 正在校准本底 ' + Math.round(this.snap.learnProgress * 100) + '%'
    }
    return '规则基线 · 阈值已按本底自适应'
  }

  private pct(v: number): string {
    return Math.round(v * 100) + '%'
  }

  // ------------------------------------------------------- 曲线

  private redrawTrend(): void {
    if (!this.canvasReady) {
      return
    }
    this.drawSeries(this.snap.series)
  }

  /**
   * 画四条曲线（温/湿/光/烟）
   *
   * 各通道量程差很多（温度 25 左右、光照 50~800），所以**分通道归一化**
   * 到画布高度 —— 这里看的是**趋势形状**，不是绝对值。
   * 绝对值在卡片下方的图例里给。
   */
  private drawSeries(series: number[][]): void {
    const ctx = this.trendCtx
    const W: number = ctx.width
    const H: number = ctx.height
    const padT: number = 8
    const plotH: number = H - padT * 2

    ctx.clearRect(0, 0, W, H)

    /* 背景网格 */
    ctx.strokeStyle = Palette.border
    ctx.lineWidth = 1
    for (let i = 0; i <= 3; i++) {
      const y: number = padT + plotH * i / 3
      ctx.beginPath()
      ctx.moveTo(0, y)
      ctx.lineTo(W, y)
      ctx.stroke()
    }

    if (series.length < 4) {
      return
    }
    const n: number = series[0].length
    if (n < 2) {
      return
    }

    const colors: string[] = [Palette.bad, Palette.accent, Palette.warn, Palette.textDim]

    for (let c = 0; c < 4; c++) {
      const data: number[] = series[c]
      if (data.length !== n) {
        continue
      }

      let lo: number = data[0]
      let hi: number = data[0]
      for (let i = 1; i < n; i++) {
        if (data[i] < lo) {
          lo = data[i]
        }
        if (data[i] > hi) {
          hi = data[i]
        }
      }
      const span: number = (hi - lo) > 1e-6 ? (hi - lo) : 1

      ctx.strokeStyle = colors[c]
      ctx.lineWidth = 2
      ctx.beginPath()
      for (let i = 0; i < n; i++) {
        const x: number = W * i / (n - 1)
        const y: number = padT + plotH * (1 - (data[i] - lo) / span)
        if (i === 0) {
          ctx.moveTo(x, y)
        } else {
          ctx.lineTo(x, y)
        }
      }
      ctx.stroke()
    }
  }

  private smokeColor(): string {
    const lv: string = this.snap.smokeLevel
    if (lv === 'alarm') {
      return Palette.bad
    }
    if (lv === 'near') {
      return Palette.warn
    }
    if (lv === 'normal') {
      return Palette.good
    }
    return Palette.textMute
  }

  private smokeLabel(): string {
    const lv: string = this.snap.smokeLevel
    if (lv === 'alarm') {
      return '超标 · 报警'
    }
    if (lv === 'near') {
      return '接近阈值'
    }
    if (lv === 'normal') {
      return '正常'
    }
    return '等待数据'
  }

  private linkText(): string {
    if (this.errMsg.length > 0) {
      return '连接异常'
    }
    return this.connected ? '已连接' : '连接中…'
  }

  private linkColor(): string {
    if (this.errMsg.length > 0) {
      return Palette.bad
    }
    return this.connected ? Palette.good : Palette.textMute
  }

  private updatedAt(): string {
    if (this.snap.ts <= 0) {
      return '--'
    }
    const d = new Date(this.snap.ts)
    const p = (n: number): string => (n < 10 ? '0' + n : '' + n)
    return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
  }

  // ------------------------------------------------------------ 页面

  build() {
    Column({ space: Metric.gap }) {
      this.HeaderBar()

      if (this.errMsg.length > 0) {
        this.ErrBar()
      }

      /* ── 功能分页 ────────────────────────────────────
         一页塞满所有卡片时，评委找不到重点，滚轮也容易长。
         按「看什么」拆成 4 页，每页只讲一件事：
           系统总览  —— 判定 + 云端建议（最常看）
           环境感知  —— 温湿度 + 光照 + 趋势曲线
           安全联动  —— 烟雾 + 风扇 + 灯光
           智能问答  —— DeepSeek 自然语言问答
         ─────────────────────────────────────────────── */
      Tabs({ barPosition: BarPosition.End }) {

        /* ① 总览：端侧判定 + DeepSeek 建议 */
        TabContent() {
          Scroll() {
            Column({ space: Metric.gap }) {
              this.AiCard()
              this.LlmCard()
            }
            .width('100%')
            .padding({ bottom: Metric.gap })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
        }
        .tabBar(this.TabLabel('系统总览', 0))

        /* ② 温湿度：环境读数 + 趋势曲线 */
        TabContent() {
          Scroll() {
            Column({ space: Metric.gap }) {
              this.EnvCard()
              this.TrendCard()
            }
            .width('100%')
            .padding({ bottom: Metric.gap })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
        }
        .tabBar(this.TabLabel('环境感知', 1))

        /* ③ 安全与控制：烟雾 + 风扇 + 灯光 */
        TabContent() {
          Scroll() {
            Column({ space: Metric.gap }) {
              this.SmokeCard()

              Row({ space: Metric.gap }) {
                Column() {
                  this.FanCard()
                }.layoutWeight(1)

                Column() {
                  this.LightCard()
                }.layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
            .width('100%')
            .padding({ bottom: Metric.gap })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
        }
        .tabBar(this.TabLabel('安全联动', 2))

        /* ④ 智能问答：DeepSeek 自然语言问答 */
        TabContent() {
          Scroll() {
            Column({ space: Metric.gap }) {
              this.AskCard()
            }
            .width('100%')
            .padding({ bottom: Metric.gap })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
        }
        .tabBar(this.TabLabel('智能问答', 3))
      }
      .layoutWeight(1)
      .width('100%')
      .barMode(BarMode.Fixed)
      .barHeight(56)
      .barBackgroundColor(Palette.surface)
      .onChange((index: number) => {
        this.curTab = index
      })
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor(Palette.bg)
  }

  /**
   * 底部页签文字
   *
   * ⚠️ text / idx 只传常量；选中态靠内部读 this.curTab（@State），
   *    这样切换页签时 @Builder 会跟着重建 —— 参数传布尔值则不会刷新。
   */
  @Builder
  TabLabel(text: string, idx: number) {
    Column() {
      Text(text)
        .fontSize(Metric.bodySize)
        .fontWeight(this.curTab === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.curTab === idx ? Palette.accent : Palette.textMute)

      /* 选中指示条：宽度为 0 时仍占位，避免切换时文字上下跳 */
      Row()
        .width(this.curTab === idx ? 18 : 0)
        .height(3)
        .backgroundColor(Palette.accent)
        .borderRadius(2)
        .margin({ top: 5 })
    }
    .height(44)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  HeaderBar() {
    Row() {
      Column() {
        Text('星枢 SparkHub')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
        if (this.snap.deviceId.length > 0) {
          Text('在线节点：' + this.snap.deviceId)
            .fontSize(Metric.smallSize)
            .fontColor(Palette.textMute)
            .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column() {
        Row({ space: 6 }) {
          Circle({ width: 7, height: 7 }).fill(this.linkColor())
          Text(this.linkText())
            .fontSize(Metric.smallSize)
            .fontColor(Palette.textDim)
        }
        .alignItems(VerticalAlign.Center)

        Text('更新 ' + this.updatedAt())
          .fontSize(Metric.smallSize)
          .fontColor(Palette.textMute)
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }

  @Builder
  ErrBar() {
    Text(this.errMsg)
      .fontSize(Metric.smallSize)
      .fontColor(Palette.bad)
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(Palette.surfaceAlt)
      .borderRadius(8)
      .border({ width: 1, color: Palette.bad })
  }

  // ---------------------------------------------------------- 卡片

  @Builder
  CardHead(title: string, sub: string) {
    Column() {
      Text(title)
        .fontSize(Metric.titleSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.text)
      if (sub.length > 0) {
        Text(sub)
          .fontSize(Metric.subSize)
          .fontColor(Palette.textMute)
          .margin({ top: 4 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /**
   * 端侧判定卡片 —— 全场视觉焦点
   *
   * ⚠️ 这里的 Text 必须**直接引用 this.snap**，不能走 @Builder 传参。
   *    ArkUI 的 @Builder 是「按值传递」的：参数变了内部不会重建，
   *    会永远停在首次渲染的值（见 docs/06 第六节记的这个坑）。
   */
  @Builder
  AiCard() {
    Column({ space: 14 }) {
      this.CardHead('端侧判定', this.aiSubTitle())

      Row({ space: 12 }) {
        Circle({ width: 12, height: 12 }).fill(this.aiColor())
        Text(this.aiLabel())
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.aiColor())
        /* 置信度 = 最高那一类的概率。
           温度标定后这个数才有绝对意义（未标定时永远在 0.6 附近，
           看着像"模型没把握"，其实只是没校准）。
           ⚠️ 这里不用 Blank() —— 它在 Row 里强制占满剩余空间，
              会干扰 Scroll 的滚轮命中测试。用 SpaceBetween 代替。 */
        Text(this.snap.windowReady ? ('置信度 ' + this.pct(this.topProb())) : '')
          .fontSize(Metric.smallSize)
          .fontColor(Palette.textDim)
      }
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .hitTestBehavior(HitTestMode.None)

      Text(this.snap.reason)
        .fontSize(Metric.smallSize)
        .fontColor(Palette.textDim)
        .maxLines(2)
        .width('100%')

      /* 告警 —— 只有燃烧概率真的越过阈值才出现，平时不占视觉 */
      if (this.snap.windowReady && shouldAlarm(this.snap.probs)) {
        Row({ space: 8 }) {
          Circle({ width: 8, height: 8 }).fill(Palette.bad)
          Text('检测到燃烧特征，请立即查看')
            .fontSize(Metric.bodySize)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.bad)
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .backgroundColor(Palette.surfaceAlt)
        .borderRadius(8)
      }

      /* 趋势外推 —— 有预测才显示，避免平时噪音 */
      if (this.snap.predictSec > 0) {
        Text('按当前趋势，预计 ' + Math.round(this.snap.predictSec) + ' 秒后触警')
          .fontSize(Metric.smallSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.warn)
          .width('100%')
      }

      Row({ space: 8 }) {
        this.ProbCell('正常', 0, Palette.good)
        this.ProbCell('油烟', 1, Palette.warn)
        this.ProbCell('水汽', 2, Palette.accent)
        this.ProbCell('燃烧', 3, Palette.bad)
      }
      .width('100%')

      /* 本底 + 模型状态 */
      Text('本底：' + this.snap.learnDesc + '　　模型：' + this.modelState)
        .fontSize(Metric.smallSize)
        .fontColor(Palette.textMute)
        .maxLines(2)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Metric.cardPad)
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }

  /**
   * 第 3 层：DeepSeek 云端建议卡片
   *
   * 设计要点（都是为了"演示时一眼看出接了 DeepSeek"）：
   *   ① 标题右侧常驻「DeepSeek」标签 + 调用计数，一眼看出是外部模型
   *   ② 建议文字用较大字号，是这张卡的主角
   *   ③ 状态行显示 请求中 / 已返回(耗时) / 不可用
   *   ④ 底部小字说明分工：本地判类、云端出建议
   */
  @Builder
  LlmCard() {
    Column({ space: 10 }) {
      Row() {
        Column() {
          Text(this.llmTitle())
            .fontSize(Metric.titleSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          if (this.snap.llmUnknown) {
            Text('四类都不像 → 交给大模型用常识判断')
              .fontSize(Metric.subSize)
              .fontColor(Palette.textMute)
          }
        }
        .alignItems(HorizontalAlign.Start)

        Text(this.snap.llmUnknown ? 'DeepSeek · 零样本' : 'DeepSeek')
          .fontSize(Metric.subSize)
          .fontColor(Palette.accent)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Palette.surfaceAlt)
          .borderRadius(6)
      }
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      .width('100%')

      /* 状态行 —— 演示时能看出"确实在调云端" */
      Row({ space: 6 }) {
        Circle({ width: 7, height: 7 }).fill(this.llmColor())
        Text(this.llmStatusText())
          .fontSize(Metric.smallSize)
          .fontColor(Palette.textDim)
      }
      .alignItems(VerticalAlign.Center)
      .width('100%')

      /* 建议正文 —— 这张卡的主角 */
      Text(this.llmBodyText())
        .fontSize(Metric.bodySize)
        .fontColor(Palette.text)
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Metric.cardPad)
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }

  /** 卡片标题：未知事件时突出识别结果 */
  private llmTitle(): string {
    if (this.snap.llmUnknown && this.snap.llmUnknownName.length > 0) {
      return 'DeepSeek 发现：' + this.snap.llmUnknownName
    }
    if (this.snap.llmUnknown) {
      return 'DeepSeek 未知识别'
    }
    return 'DeepSeek 建议'
  }

  /** 云端状态颜色：请求中=蓝 / 成功=绿 / 失败=黄 / 未调用=灰 */
  private llmColor(): string {
    const s: string = this.snap.llmState
    if (s === 'loading') {
      return Palette.accent
    }
    if (s === 'ok') {
      return Palette.good
    }
    if (s === 'err') {
      return Palette.warn
    }
    return Palette.textMute
  }

  /** 云端状态文字（带调用次数，作为"接入了云端"的痕迹） */
  private llmStatusText(): string {
    const s: string = this.snap.llmState
    const n: number = this.snap.llmCalls
    const f: number = this.snap.llmFails
    const stat: string = (f > 0) ? (`调用 ${n} 次 / 失败 ${f}`) : (`已调用 ${n} 次`)
    if (s === 'loading') {
      return '正在请求 DeepSeek…　' + stat
    }
    if (s === 'ok') {
      return '已返回 · ' + String(this.snap.llmMs) + ' ms　' + stat
    }
    if (s === 'err') {
      return '云端不可用（已降级到本地判定）　' + stat
    }
    return this.snap.windowReady ? ('等待首次调用　' + stat) : '等待数据积累'
  }

  /** 建议正文：没有时给明确的占位说明，不留空白 */
  private llmBodyText(): string {
    if (this.snap.llmAdvice.length > 0) {
      return this.snap.llmAdvice
    }
    if (!this.snap.windowReady) {
      return '窗口数据积累中…'
    }
    if (this.snap.llmState === 'loading') {
      return '正在生成建议…'
    }
    if (this.snap.llmState === 'err' || this.snap.llmFails > 0) {
      return '云端建议不可用，本地判定与告警不受影响。'
    }
    return '判定类别变化时自动请求一句处置建议。'
  }

  /**
   * DeepSeek 自然语言问答卡片
   *
   * 这是答辩现场的"杀手锏"：评委可以当场提问，系统基于
   * 当前传感器状态 + 判定历史作答。
   *
   * 交互设计：
   *   - 顶部输入框（鼠标点击即可输入）
   *   - 4 个预设问题按钮 —— 演示时点一下就能问，不用打字
   *   - 下方回答区，带耗时
   */
  @Builder
  AskCard() {
    Column({ space: 10 }) {
      Row() {
        Column() {
          Text('智能问答')
            .fontSize(Metric.titleSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
        }
        .alignItems(HorizontalAlign.Start)

        Text('DeepSeek')
          .fontSize(Metric.subSize)
          .fontColor(Palette.accent)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Palette.surfaceAlt)
          .borderRadius(6)
      }
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      .width('100%')

      /* 输入行：鼠标点击输入框，回车或点发送 */
      Row({ space: 8 }) {
        TextInput({ text: this.askText, placeholder: '例如：刚才为什么报警？' })
          .layoutWeight(1)
          .fontSize(Metric.bodySize)
          .height(38)
          .backgroundColor(Palette.surfaceAlt)
          .borderRadius(8)
          .onChange((v: string) => {
            this.askText = v
          })
          .onSubmit(() => {
            this.sendAsk()
          })

        Button('发送')
          .fontSize(Metric.bodySize)
          .height(38)
          .backgroundColor(Palette.accent)
          .fontColor(Color.White)
          .enabled(this.snap.llmQaState !== 'loading')
          .onClick(() => {
            this.sendAsk()
          })
      }
      .width('100%')

      /* 预设问题 —— 演示时不用打字 */
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(Index.PRESET_QUESTIONS, (q: string) => {
          Text(q)
            .fontSize(Metric.smallSize)
            .fontColor(Palette.accent)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .margin({ right: 8, bottom: 8 })
            .backgroundColor(Palette.surfaceAlt)
            .borderRadius(14)
            .onClick(() => {
              if (this.snap.llmQaState !== 'loading') {
                this.mqtt.ask(q)
              }
            })
        })
      }
      .width('100%')

      /* 回答区 */
      if (this.snap.llmQaState !== 'idle') {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Circle({ width: 7, height: 7 }).fill(this.qaColor())
            Text(this.qaStatusText())
              .fontSize(Metric.smallSize)
              .fontColor(Palette.textDim)
          }
          .alignItems(VerticalAlign.Center)
          .width('100%')

          Text(this.snap.llmQaQuestion)
            .fontSize(Metric.smallSize)
            .fontColor(Palette.textMute)
            .width('100%')

          Text(this.qaAnswerText())
            .fontSize(Metric.bodySize)
            .fontColor(Palette.text)
            .lineHeight(20)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 10, right: 10, top: 10, bottom: 10 })
        .backgroundColor(Palette.surfaceAlt)
        .borderRadius(8)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Metric.cardPad)
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }

  /** 发起一次提问（不阻塞界面：拿到 Promise 就走） */
  private sendAsk(): void {
    const q: string = this.askText.trim()
    if (q.length === 0 || this.snap.llmQaState === 'loading') {
      return
    }
    this.askText = ''
    this.mqtt.ask(q)
  }

  private qaColor(): string {
    const s: string = this.snap.llmQaState
    if (s === 'loading') {
      return Palette.accent
    }
    if (s === 'ok') {
      return Palette.good
    }
    if (s === 'err') {
      return Palette.warn
    }
    return Palette.textMute
  }

  private qaStatusText(): string {
    const s: string = this.snap.llmQaState
    if (s === 'loading') {
      return '正在解读当前态势…'
    }
    if (s === 'ok') {
      return '解读完成 · ' + String(this.snap.llmQaMs) + ' ms'
    }
    return '解读失败'
  }

  private qaAnswerText(): string {
    if (this.snap.llmQaState === 'loading') {
      return '……'
    }
    return this.snap.llmQaAnswer
  }

  /**
   * 单个概率格
   *
   * ⚠️ 只传**常量**参数（label / 下标 / 颜色），数值靠 idx 自己去
   *    this.snap 里取 —— 否则又踩「按值传参不刷新」的坑。
   *
   * 视觉上**只有 top1 用彩色**，其余灰掉：四类等权展示会让"燃烧 3%"
   * 看起来像风险提示，而实际决策依据是 argmax 和标定后的 0.35 阈值。
   */
  @Builder
  ProbCell(label: string, idx: number, color: string) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(Metric.smallSize)
        .fontColor(this.topIdx() === idx ? Palette.text : Palette.textMute)
      Text(this.pct(this.snap.probs[idx]))
        .fontSize(16)
        .fontWeight(this.topIdx() === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.topIdx() === idx ? color : Palette.textDim)

      /* 细条：一眼看出相对大小，不抢注意力 */
      Row() {
        Row()
          .width(this.pct(this.snap.probs[idx]))
          .height(3)
          .backgroundColor(this.topIdx() === idx ? color : Palette.border)
          .borderRadius(2)
      }
      .width('100%')
      .height(3)
      .backgroundColor(Palette.surface)
      .borderRadius(2)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .backgroundColor(Palette.surfaceAlt)
    .borderRadius(8)
  }

  /**
   * 实时趋势卡片
   *
   * 四条曲线**分通道归一化**显示趋势形状；绝对值在下方图例里。
   */
  @Builder
  TrendCard() {
    Column({ space: 10 }) {
      this.CardHead('实时趋势', '最近 12 个采样点（约 60 秒）')

      Canvas(this.trendCtx)
        .width('100%')
        .height(140)
        .backgroundColor(Palette.surfaceAlt)
        .borderRadius(8)
        /* 不吃手势/滚轮 —— 否则父级的 Scroll 收不到滚动事件 */
        .hitTestBehavior(HitTestMode.None)
        .onReady(() => {
          this.canvasReady = true
          this.redrawTrend()
        })

      Row({ space: 10 }) {
        this.Legend('温度', 0, '℃', Palette.bad)
        this.Legend('湿度', 1, '%', Palette.accent)
        this.Legend('光照', 2, 'lx', Palette.warn)
        this.Legend('烟雾', 3, 'ppm', Palette.textDim)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Metric.cardPad)
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }

  /** 图例 —— 同样只传常量，数值靠 idx 取 */
  @Builder
  Legend(label: string, idx: number, unit: string, color: string) {
    Column({ space: 2 }) {
      Row({ space: 4 }) {
        Circle({ width: 6, height: 6 }).fill(color)
        Text(label)
          .fontSize(Metric.smallSize)
          .fontColor(Palette.textMute)
      }
      .alignItems(VerticalAlign.Center)

      Text(this.legendValue(idx) + unit)
        .fontSize(Metric.smallSize)
        .fontColor(Palette.text)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  private legendValue(idx: number): string {
    if (idx === 0) {
      return this.fmt(this.snap.temp, 1)
    }
    if (idx === 1) {
      return this.fmt(this.snap.humi, 0)
    }
    if (idx === 2) {
      return this.fmt(this.snap.lux, 0)
    }
    return this.fmt(this.snap.smoke, 0)
  }

  /**
   * 环境卡片（温湿度）
   *
   * ⚠️ 这里刻意**不用** @Builder 传参取数值。
   *
   * ArkUI 的 @Builder 是「按值传递」的：参数变了，@Builder 内部的 UI
   * 不会重建 —— 用 this.NumBox('温度', this.fmt(this.snap.temp, 1), '℃')
   * 这种写法，温度会永远停在首次渲染的 NaN（界面上就是 "--"），
   * 而烟雾能刷新只是因为 SmokeCard 里是直接内联 Text(this.fmt(...))。
   *
   * 所以这里的 Text 必须直接引用 this.snap，不能经 @Builder 参数中转。
   */
  @Builder
  EnvCard() {
    Column({ space: 12 }) {
      this.CardHead('环境', '')

      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('温度')
            .fontSize(Metric.smallSize)
            .fontColor(Palette.textMute)
          Row({ space: 3 }) {
            Text(this.fmt(this.snap.temp, 1))
              .fontSize(Metric.numSize)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.text)
            Text('℃')
              .fontSize(Metric.smallSize)
              .fontColor(Palette.textMute)
          }
          .alignItems(VerticalAlign.Bottom)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(Palette.surfaceAlt)
        .borderRadius(8)

        Column({ space: 4 }) {
          Text('湿度')
            .fontSize(Metric.smallSize)
            .fontColor(Palette.textMute)
          Row({ space: 3 }) {
            Text(this.fmt(this.snap.humi, 0))
              .fontSize(Metric.numSize)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.text)
            Text('%')
              .fontSize(Metric.smallSize)
              .fontColor(Palette.textMute)
          }
          .alignItems(VerticalAlign.Bottom)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(Palette.surfaceAlt)
        .borderRadius(8)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Metric.cardPad)
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }

  @Builder
  SmokeCard() {
    Column({ space: 12 }) {
      this.CardHead('烟雾浓度',
        '超过 ' + this.snap.smokeThreshold.toFixed(0) + ' ppm 判定为报警')

      Row({ space: 8 }) {
        Text(this.fmt(this.snap.smoke, 0))
          .fontSize(38)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.smokeColor())
        Text('ppm')
          .fontSize(Metric.smallSize)
          .fontColor(Palette.textMute)
      }
      .alignItems(VerticalAlign.Bottom)
      .width('100%')

      Text(this.smokeLabel())
        .fontSize(Metric.smallSize)
        .fontColor(this.smokeColor())
        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .borderRadius(20)
        .border({ width: 1, color: this.smokeColor() })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Metric.cardPad)
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }

  /**
   * 风扇卡片
   *
   * 只留开关：E53_IA1 的电机是 GPIO 通断驱动，硬件上没有调速能力，
   * 原来的三档按钮发的是 motor_level，设备端也不认（走 unknown target）。
   */
  @Builder
  FanCard() {
    Column({ space: 12 }) {
      this.CardHead('风扇', '')

      Row() {
        Text('开关')
          .fontSize(Metric.bodySize)
          .fontColor(Palette.textDim)
          .layoutWeight(1)
        Button(this.fanUi ? '已开启' : '已关闭')
          .fontSize(Metric.bodySize)
          .height(34)
          .padding({ left: 18, right: 18 })
          .fontColor(this.fanUi ? Palette.bg : Palette.text)
          .backgroundColor(this.fanUi ? Palette.accent : Palette.surfaceAlt)
          .borderRadius(8)
          .onClick(() => {
            this.toggleFan()
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Metric.cardPad)
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }

  /**
   * 灯光卡片
   *
   * 同样只留开关：E53_IA1 的灯是 GPIO 通断驱动（不是 PWM），
   * 调不了亮度；原来的滑条发的是 light_level，设备端也不认。
   */
  @Builder
  LightCard() {
    Column({ space: 12 }) {
      this.CardHead('灯光', '')

      Row() {
        Text('开关')
          .fontSize(Metric.bodySize)
          .fontColor(Palette.textDim)
          .layoutWeight(1)
        Button(this.lightUi ? '已开启' : '已关闭')
          .fontSize(Metric.bodySize)
          .height(34)
          .padding({ left: 18, right: 18 })
          .fontColor(this.lightUi ? Palette.bg : Palette.text)
          .backgroundColor(this.lightUi ? Palette.accent : Palette.surfaceAlt)
          .borderRadius(8)
          .onClick(() => {
            this.toggleLight()
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Metric.cardPad)
    .backgroundColor(Palette.surface)
    .borderRadius(Metric.radius)
    .border({ width: 1, color: Palette.border })
  }
}
