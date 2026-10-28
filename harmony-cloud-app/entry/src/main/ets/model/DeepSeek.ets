/**
 * DeepSeek 客户端 —— 三层架构的「第 3 层：云端增强」
 *
 * ══════════════════════════════════════════════════════════════
 *  分工（这是整个设计的关键）
 * ══════════════════════════════════════════════════════════════
 *   CNN 负责它**学过的** —— 4 类模式识别，3 ms，离线可用
 *   DeepSeek 负责它**没学过的** —— 常识推理、未知事件、自然语言交互
 *
 *   所以本文件提供三件事：
 *     ① askAdvice()   —— 处置建议（已知四类的场景）
 *     ② askUnknown()  —— 零样本识别（CNN 四类都不像时，用常识判断"这是什么"）
 *     ③ askQuestion() —— 自然语言问答（"刚才为什么报警？"）
 *
 *   ⚠️ 三者都不参与判类 —— probs 始终来自本地 CNN / 规则基线。
 *
 *   降级：网络不通 / Key 未配置 / 超时 / 非 200 → 返回 ok=false，
 *         界面继续用本地结果，主流程完全不受影响。
 */
import http from '@ohos.net.http'
import hilog from '@ohos.hilog'
import { FeatureSummary } from './Features'

const DOMAIN: number = 0x0000
const TAG: string = 'SparkHubLLM'

/**
 * ⚠️ 演示用 API Key。
 *
 * 生产环境应该：① 放 rawfile 读取（提高逆向门槛）；② 走自建中转，Key 不下发端侧。
 * 答辩若被问，如实说明这是演示配置。
 */
const API_KEY: string = 'sk-30aa63f253364f1ba56f6be20c66642e'
const API_URL: string = 'https://api.deepseek.com/chat/completions'
const MODEL: string = 'deepseek-chat'

/** 单次请求超时（毫秒）—— 必须设，否则弱网会挂住 */
const TIMEOUT_MS: number = 20000

/** 同一判定下最短刷新间隔：类别不变时最多 30 秒问一次 */
const REFRESH_MS: number = 30000

/** CNN 四类都不像的判据：top1 低于此值（或与 top2 差距过小）→ 走零样本识别 */
export const UNKNOWN_TOP1: number = 0.50
export const UNKNOWN_MARGIN: number = 0.12

/* ---------------- 请求 / 响应结构（ArkTS 不允许匿名对象）---------------- */

class LlmMessage {
  role: string = 'user'
  content: string = ''
}

class LlmReqBody {
  model: string = MODEL
  messages: LlmMessage[] = []
  max_tokens: number = 160
  temperature: number = 0.3
  stream: boolean = false
}

class LlmChoice {
  message: LlmMessage = new LlmMessage()
}

class LlmResp {
  choices: LlmChoice[] = []
}

/* ---------------- 对外结果 ---------------- */

export class LlmAdvice {
  ok: boolean = false
  text: string = ''
  ms: number = 0
  err: string = ''
}

/** 自然语言问答的结果 */
export class LlmAnswer {
  ok: boolean = false
  question: string = ''
  answer: string = ''
  ms: number = 0
  err: string = ''
}

function mkMsg(role: string, content: string): LlmMessage {
  const m = new LlmMessage()
  m.role = role
  m.content = content
  return m
}

export class DeepSeekClient {
  private busy: boolean = false
  private lastClass: string = ''
  private lastCallMs: number = 0
  private callCount: number = 0
  private failCount: number = 0

  lastOk: boolean = false
  lastMs: number = 0

  isConfigured(): boolean {
    return API_KEY.length > 20 && API_KEY.indexOf('请替换') < 0
  }

  isBusy(): boolean {
    return this.busy
  }

  totalCalls(): number {
    return this.callCount
  }

  totalFails(): number {
    return this.failCount
  }

  /**
   * 是否该发起一次「自动」请求（处置建议 / 未知识别）
   *
   * 策略：正在请求中不发；类别变了立刻发；类别没变至少隔 REFRESH_MS。
   * 注意：用户主动提问（askQuestion）**不走这个节流**。
   */
  shouldAsk(key: string, now: number): boolean {
    if (this.busy) {
      return false
    }
    if (key !== this.lastClass) {
      return true
    }
    return (now - this.lastCallMs) >= REFRESH_MS
  }

  /** 把 FeatureSummary 转成人类可读的特征描述（给 LLM 的不是裸数字） */
  private describeFeatures(f: FeatureSummary): string {
    const l: string[] = []
    l.push(`温度 ${f.temp.toFixed(1)}℃（变化率 ${f.dTemp.toFixed(2)} ℃/s）`)
    l.push(`湿度 ${f.humi.toFixed(1)}%（变化率 ${f.dHumi.toFixed(2)} %/s）`)
    l.push(`光照 ${f.lux.toFixed(0)} lx`)
    l.push(`烟雾 ${f.smoke.toFixed(0)} ppm（变化率 ${f.dSmoke.toFixed(1)} ppm/s，回落比 ${f.fallRatio.toFixed(2)}）`)
    return l.join('\n')
  }

  /* ══════════════════ 底层 HTTP ══════════════════ */

  private async post(system: string, user: string, maxTokens: number): Promise<LlmAdvice> {
    const r = new LlmAdvice()
    if (this.busy) {
      r.err = '忙'
      return r
    }
    if (!this.isConfigured()) {
      r.err = '未配置 API Key'
      return r
    }

    this.busy = true
    this.callCount++
    const t0: number = Date.now()

    const body = new LlmReqBody()
    body.max_tokens = maxTokens
    body.messages = [mkMsg('system', system), mkMsg('user', user)]

    const req = http.createHttp()
    try {
      hilog.info(DOMAIN, TAG, 'POST %{public}s tokens=%{public}d', API_URL, maxTokens)
      const resp: http.HttpResponse = await req.request(API_URL, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + API_KEY
        },
        extraData: JSON.stringify(body),
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS
      })
      r.ms = Date.now() - t0

      if (resp.responseCode !== 200) {
        r.err = 'HTTP ' + resp.responseCode
        hilog.error(DOMAIN, TAG, '%{public}s', r.err)
        return r
      }

      const text: string = (typeof resp.result === 'string')
        ? resp.result as string
        : JSON.stringify(resp.result)

      const parsed: LlmResp = JSON.parse(text) as LlmResp
      if (parsed.choices === undefined || parsed.choices.length < 1) {
        r.err = '响应无 choices'
        return r
      }
      r.text = parsed.choices[0].message.content.trim()
      r.ok = true
      this.lastOk = true
      this.lastMs = r.ms
      hilog.info(DOMAIN, TAG, 'DeepSeek 返回(%{public}sms): %{public}s',
        String(r.ms), r.text)
      return r
    } catch (e) {
      r.ms = Date.now() - t0
      const err = e as Error
      r.err = (err !== undefined && err.message !== undefined) ? err.message : '请求异常'
      this.lastOk = false
      hilog.error(DOMAIN, TAG, '调用异常: %{public}s', r.err)
      return r
    } finally {
      req.destroy()
      this.busy = false
      if (!r.ok) {
        this.failCount++
      }
    }
  }

  /* ══════════════════ ① 处置建议 ══════════════════ */

  /**
   * 已知四类的场景 → 一句可执行的处置建议
   *
   * 调用方应**不 await**（放在独立流程里），绝不能让 MQTT 回调线程等它。
   */
  async askAdvice(className: string, prob: number, f: FeatureSummary): Promise<LlmAdvice> {
    const sys = '你是一套智能家居火情监测系统的助手。系统已用端侧 CNN 完成四分类'
      + '（正常/油烟/水汽/燃烧）。你的任务只有一个：根据判定和传感器特征，'
      + '给用户一句可执行的处置建议。'
      + '要求：口语化、具体、不超过 40 字；正常时简短说明即可；'
      + '油烟气说开窗/开抽油烟机；水汽说通风；燃烧要说清风险和动作。'
      + '不要输出多余解释，不要复述传感器数值。'

    const usr = `系统判定：${className}（置信度 ${(prob * 100).toFixed(1)}%）\n`
      + `传感器读数：\n${this.describeFeatures(f)}\n\n`
      + '请用一句话给出处置建议（不超过 40 字），直接说该做什么。'

    return await this.post(sys, usr, 120)
  }

  /* ══════════════════ ② 零样本识别未知事件 ══════════════════ */

  /**
   * CNN 四类都不像时，用常识判断"这是什么"
   *
   * 这是 LLM **补 CNN 短板**的核心场景：
   *   训练数据只有 4 类，但真实世界有香水、杀虫剂、香烟、艾灸、酒精……
   *   它们都会让烟雾/湿度变化，却落不到那 4 类里。
   *
   * 输出格式约定：第一行是简短名称，第二行起是理由和建议。
   * 例如：
   *   香烟 / 香薰类气溶胶
   *   烟雾缓慢上升但湿度与温度基本不变，不符合烹饪油烟……
   */
  async askUnknown(f: FeatureSummary, probs: number[]): Promise<LlmAdvice> {
    const sys = '你是一套火情监测系统的专家助手。端侧 CNN 只能识别四类'
      + '（正常/油烟/水汽/燃烧），当四类概率都不高时，说明遇到了它没学过的场景。'
      + '你的任务：根据传感器特征用常识推断这是什么。'
      + '常见可能：香烟、香薰、蚊香、艾灸、香水喷雾、杀虫剂、酒精挥发、'
      + '通风带入的室外污染、人体活动导致的温湿变化等。'
      + '\n输出格式（严格遵守，共 3 行以内）：'
      + '\n第 1 行：事件名称（不超过 12 字，例如"香烟/香薰类气溶胶"）'
      + '\n第 2 行：判断依据（不超过 45 字，说明为什么不是那四类）'
      + '\n第 3 行：建议（不超过 30 字）。'
      + '\n不要输出 JSON，不要加标题，不要复述数值。'

    const p4: string = `正常 ${(probs[0] * 100).toFixed(0)}% / 油烟 ${(probs[1] * 100).toFixed(0)}%`
      + ` / 水汽 ${(probs[2] * 100).toFixed(0)}% / 燃烧 ${(probs[3] * 100).toFixed(0)}%`

    const usr = `CNN 四类得分都很低，说明不属于已知四类：\n  ${p4}\n\n`
      + `传感器读数：\n${this.describeFeatures(f)}\n\n`
      + '请按约定格式推断这是什么事件。'

    return await this.post(sys, usr, 200)
  }

  /* ══════════════════ ③ 自然语言问答 ══════════════════ */

  /**
   * 用户提问（看板上输入，或点预设问题）
   *
   * @param question 用户问的话
   * @param context  由调用方组装的"当前状态 + 判定历史"文本
   *
   * ⚠️ 这个方法**不走节流**（用户主动问，必须立刻答），
   *    但仍然不能阻塞 MQTT 线程 —— 调用方要在独立流程里 await。
   */
  async askQuestion(question: string, context: string): Promise<LlmAnswer> {
    const a = new LlmAnswer()
    a.question = question

    const sys = '你是一套智能家居环境监测系统的助手，负责回答用户关于系统状态的问题。'
      + '你会拿到当前传感器读数、AI 判定结果和最近的判定历史。'
      + '要求：'
      + '\n1. 直接回答，不要客套，不要重复问题。'
      + '\n2. 回答控制在 80 字以内（数据类问题可列 2~3 条）。'
      + '\n3. 涉及时间/次数的问题，严格按给出的历史记录回答，不要编造。'
      + '\n4. 如果历史记录里没有相关信息，就直说"记录里没有"。'
      + '\n5. 语气自然，像在跟住户说话。'

    const usr = `【当前状态】\n${context}\n\n【用户提问】\n${question}`

    const r = await this.post(sys, usr, 300)
    a.ok = r.ok
    a.answer = r.text
    a.ms = r.ms
    a.err = r.err
    return a
  }

  /** 组装给 LLM 的上下文（当前状态 + 判定历史） */
  static buildContext(snapshotText: string, historyLines: string[]): string {
    const parts: string[] = []
    parts.push(snapshotText)
    if (historyLines.length > 0) {
      parts.push('')
      parts.push('【最近判定变化记录】（时间 / 判定 / 置信度 / 关键特征）')
      for (let i = 0; i < historyLines.length; i++) {
        parts.push('  ' + historyLines[i])
      }
    } else {
      parts.push('')
      parts.push('【最近判定变化记录】暂无（系统刚启动或一直平稳）')
    }
    return parts.join('\n')
  }
}
