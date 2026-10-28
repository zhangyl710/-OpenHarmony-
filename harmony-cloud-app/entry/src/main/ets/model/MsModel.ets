/**
 * 星枢 SparkHub · 本地模型推理（MindSpore Lite）
 *
 * ══════════════════════════════════════════════════════════
 *  这是三层架构的第 2 层
 * ══════════════════════════════════════════════════════════
 *
 *   第 1 层  规则基线      Baseline.ets    ✅ 在跑，保底
 *   第 2 层  本地模型      MsModel.ets     ← 本文件
 *   第 3 层  云端          (未实现)
 *
 * ══════════════════════════════════════════════════════════
 *  怎么用
 * ══════════════════════════════════════════════════════════
 *
 *   1) 训练模型（PC 上）
 *        cd ai && python train.py --data data.npz --export
 *        → fire_model.mindir
 *
 *   2) 转成端侧格式
 *        ./converter_lite --fmk=MINDIR --modelFile=fire_model.mindir \
 *            --outputFile=fire_model --inputShape="x:1,8,12"
 *        → fire_model.ms
 *
 *   3) 放进应用
 *        entry/src/main/resources/rawfile/fire_model.ms
 *
 *   4) 声明 syscap（**这个文件不会自动生成，要手动建**）
 *        entry/src/main/syscap.json
 *        {
 *          "development": {
 *            "addedSysCaps": ["SystemCapability.AI.MindSporeLite"]
 *          }
 *        }
 *
 *   5) 在 MqttService 里加载并调用（见下方「接入点」注释）
 *
 * ══════════════════════════════════════════════════════════
 *  ⚠️ 三个易踩的坑（OpenHarmony 官方文档列的）
 * ══════════════════════════════════════════════════════════
 *
 *   ① context.target 是**数组** —— 写 ['cpu']，写 'cpu' 会失败
 *   ② MSTensor 的 shape / dtype 是**属性不是方法**（没有 getShape()）
 *   ③ 输出只能从 predict() 的**返回值**取 —— 没有 getOutputs()
 *
 *   还有：预处理（归一化）**要自己写**，而且必须和训练时用同一套系数。
 *   这一点已经在 Features.ets 里对齐了（它的 NORM 和 train.py 的 NORM 一致）。
 */

import { mindSporeLite } from '@kit.MindSporeLiteKit'
import hilog from '@ohos.hilog'
import resourceManager from '@ohos.resourceManager'
import { ClassifyResult } from './Baseline'
import { N_CHANNELS, WINDOW_SEC } from './Features'

const DOMAIN: number = 0x0000
const TAG: string = 'SparkHubModel'

/** 模型文件名（放在 resources/rawfile/ 下） */
const MODEL_FILE: string = 'fire_model.ms'

/**
 * 模型输入的张量元素个数 —— 必须和训练时一致
 *
 * 8 通道 × 12 点 = 96，对应 train.py 的 SEQ_LEN=12 和 Features.ets 的 WINDOW_SEC=12
 */
const INPUT_ELEMS: number = N_CHANNELS * WINDOW_SEC

/**
 * softmax 温度 —— 在训练集上按 NLL 标定得到（见 infer() 的注释）。
 * 只改概率数值、不改 argmax，因此不影响准确率，但让概率有绝对意义。
 */
const TEMPERATURE: number = 0.25

export class MsModel {
  private model: mindSporeLite.Model | null = null
  private ready: boolean = false
  private loadError: string = ''
  private inferCount: number = 0
  private lastInferMs: number = 0

  /** 模型是否已加载好 —— 没好的话上层应该降级到规则基线 */
  get isReady(): boolean {
    return this.ready
  }

  /** 加载失败的原因（界面可显示） */
  get error(): string {
    return this.loadError
  }

  /** 最近一次推理耗时（毫秒）—— 答辩时可以展示 */
  get inferMs(): number {
    return this.lastInferMs
  }

  get calls(): number {
    return this.inferCount
  }

  /**
   * 加载模型
   *
   * 从 rawfile 读进来 → 建 context → loadModelFromBuffer
   *
   * **失败不抛异常**，只记录错误并返回 false —— 让上层能安静降级到规则基线。
   */
  async load(resMgr: resourceManager.ResourceManager): Promise<boolean> {
    try {
      const raw: Uint8Array = await resMgr.getRawFileContent(MODEL_FILE)
      if (raw === undefined || raw.byteLength === 0) {
        this.loadError = `模型文件为空：${MODEL_FILE}`
        hilog.error(DOMAIN, TAG, '%{public}s', this.loadError)
        return false
      }

      const ctx: mindSporeLite.Context = {}
      /* ⚠️ 坑①：target 必须是数组 */
      ctx.target = ['cpu']
      ctx.cpu = {}
      ctx.cpu.threadNum = 2

      /* ⚠️ getRawFileContent 返回的 buffer 有时带偏移，slice(0) 拷一份干净的 */
      const buf: ArrayBuffer = raw.buffer.slice(0)

      this.model = await mindSporeLite.loadModelFromBuffer(buf, ctx)
      if (this.model === null) {
        this.loadError = 'loadModelFromBuffer 返回空'
        hilog.error(DOMAIN, TAG, '%{public}s', this.loadError)
        return false
      }

      /* 校验一下输入形状，和训练时对不上就别往下走了
       * （对不上不会报错，只会静默输出垃圾 —— 这是最难查的一类问题） */
      const inputs: mindSporeLite.MSTensor[] = this.model.getInputs()
      if (inputs.length < 1) {
        this.loadError = '模型没有输入张量'
        return false
      }
      const shape: number[] = inputs[0].shape
      const elems: number = shape.reduce((a: number, b: number) => a * b, 1)
      if (elems !== INPUT_ELEMS) {
        this.loadError = `输入元素个数不符：模型要 ${elems}，代码给 ${INPUT_ELEMS}`
        hilog.error(DOMAIN, TAG, '%{public}s', this.loadError)
        return false
      }

      this.ready = true
      this.loadError = ''
      hilog.info(DOMAIN, TAG, 'model loaded, input shape=%{public}s',
        JSON.stringify(shape))

      /* 启动自检 —— 模型能加载不代表能用。
       * converter_lite 在 layout 转换失败时不会报错，只会悄悄把模型
       * 变成一个常量输出，端侧就会一直给出同一组 logits。
       * 用两组差异极大的输入各推一次，输出必须明显不同。 */
      await this.selfCheck()
      return this.ready
    } catch (e) {
      const err = e as Error
      this.loadError = (err !== undefined && err.message !== undefined)
        ? err.message : '加载异常'
      hilog.error(DOMAIN, TAG, 'load FAILED: %{public}s', this.loadError)
      this.ready = false
      return false
    }
  }

  /**
   * 启动自检：两组差异极大的输入，输出必须明显不同。
   *
   * 不通过就把 ready 置回 false —— 上层会降级到规则基线，
   * 界面不会拿一组恒定 logits 去瞎报"油烟/燃烧"。
   */
  private async selfCheck(): Promise<void> {
    const za: Float32Array = new Float32Array(INPUT_ELEMS)
    const zb: Float32Array = new Float32Array(INPUT_ELEMS)
    for (let i = 0; i < INPUT_ELEMS; i++) {
      za[i] = 0.0
      zb[i] = 1.0
    }
    const ra: ClassifyResult | null = await this.infer(za)
    const rb: ClassifyResult | null = await this.infer(zb)
    if (ra === null || rb === null) {
      this.ready = false
      this.loadError = '模型自检推理失败'
      hilog.error(DOMAIN, TAG, '%{public}s', this.loadError)
      return
    }

    let diff: number = 0
    for (let i = 0; i < ra.probs.length; i++) {
      diff = Math.max(diff, Math.abs(ra.probs[i] - rb.probs[i]))
    }
    if (diff < 0.02) {
      this.ready = false
      this.loadError = `模型自检未通过（两组输入输出差仅 ${diff.toFixed(4)}），已降级到规则基线`
      hilog.error(DOMAIN, TAG, 'selfcheck FAILED: %{public}s', this.loadError)
    } else {
      hilog.info(DOMAIN, TAG, 'selfcheck OK, diff=%{public}s', diff.toFixed(4))
    }
  }

  /**
   * 推理
   *
   * @param input (1, 8, 12) 展平后的 Float32Array，**已归一化**
   *              由 Features.ets 的 windowBuf.toModelInput() 产出
   * @returns 四分类结果；失败返回 null（上层降级）
   */
  async infer(input: Float32Array): Promise<ClassifyResult | null> {
    if (!this.ready || this.model === null) {
      return null
    }
    if (input.length !== INPUT_ELEMS) {
      hilog.error(DOMAIN, TAG, 'input length %{public}d != %{public}d',
        input.length, INPUT_ELEMS)
      return null
    }

    const t0: number = Date.now()
    try {
      /* ⚠️ getInputs() 每次返回的引用可能不同，要重新取 */
      const inputs: mindSporeLite.MSTensor[] = this.model.getInputs()
      if (inputs === undefined || inputs.length < 1) {
        hilog.error(DOMAIN, TAG, 'getInputs() 返回空')
        return null
      }
      const in0: mindSporeLite.MSTensor = inputs[0]
      hilog.info(DOMAIN, TAG,
        'in tensor: name=%{public}s shape=%{public}s dtype=%{public}d dataSize=%{public}d',
        in0.name, JSON.stringify(in0.shape), in0.dtype, in0.dataSize)

      in0.setData(input.buffer)

      /* 回读校验 —— setData 到底有没有真的写进去（诊断用） */
      const echo: Float32Array = new Float32Array(in0.getData())
      hilog.info(DOMAIN, TAG,
        'in echo len=%{public}d e0=%{public}s e4=%{public}s e96=%{public}s eLast=%{public}s',
        echo.length,
        echo.length > 0 ? echo[0].toFixed(4) : 'x',
        echo.length > 4 ? echo[4].toFixed(4) : 'x',
        echo.length > 96 ? echo[96].toFixed(4) : 'x',
        echo.length > 0 ? echo[echo.length - 1].toFixed(4) : 'x')

      /* ⚠️ 坑③：输出只能从 predict 的返回值取，没有 getOutputs() */
      const outputs: mindSporeLite.MSTensor[] = await this.model.predict(inputs)
      if (outputs === undefined || outputs.length < 1) {
        return null
      }

      const raw: Float32Array = new Float32Array(outputs[0].getData())
      if (raw.length < 4) {
        hilog.error(DOMAIN, TAG, 'output length %{public}d < 4', raw.length)
        return null
      }
      hilog.info(DOMAIN, TAG,
        'out tensor: name=%{public}s shape=%{public}s dtype=%{public}d dataSize=%{public}d elems=%{public}d',
        outputs[0].name, JSON.stringify(outputs[0].shape), outputs[0].dtype,
        outputs[0].dataSize, outputs[0].elementNum)
      hilog.info(DOMAIN, TAG, 'out raw=[%{public}s]',
        [raw[0], raw[1], raw[2], raw[3]].map((v: number) => v.toFixed(6)).join(','))

      /* softmax —— 模型最后一层是 Dense 输出 logits。
       *
       * ⚠️ 温度 T 是在训练集上按 NLL 标定出来的（T=1.0 时 NLL=0.578，
       *    T=0.25 时 NLL=0.278）。它只缩放概率、不改 argmax，准确率不变。
       *
       *    标定前后「正常」样本的平均分布对比：
       *      T=1.00 → [0.568, 0.131, 0.094, 0.207]   燃烧被高估到 0.21
       *      T=0.25 → [0.943, 0.024, 0.001, 0.032]   接近直觉
       *
       *    标定后概率才有绝对意义，告警阈值也才站得住：
       *      正常样本 P(燃烧) max = 0.199
       *      燃烧样本 P(燃烧) 中位 = 0.576
       *    → 阈值取 0.35（见 Baseline.ALARM_THRESHOLD）
       */
      const probs: number[] = softmax([raw[0] / TEMPERATURE, raw[1] / TEMPERATURE,
        raw[2] / TEMPERATURE, raw[3] / TEMPERATURE])

      this.lastInferMs = Date.now() - t0
      this.inferCount++

      const r: ClassifyResult = new ClassifyResult()
      r.probs = probs
      r.source = 'model'
      r.reason = `MindSpore Lite 推理 ${this.lastInferMs}ms`
      return r
    } catch (e) {
      const err = e as Error
      hilog.error(DOMAIN, TAG, 'infer FAILED: %{public}s',
        (err !== undefined && err.message !== undefined) ? err.message : 'unknown')
      /* 推理出错就标记不可用，避免每次都等超时 —— 上层会降级到规则 */
      return null
    }
  }

  /** 释放 */
  async release(): Promise<void> {
    this.ready = false
    this.model = null
  }
}

/** 数值稳定的 softmax */
function softmax(logits: number[]): number[] {
  let max: number = logits[0]
  for (let i = 1; i < logits.length; i++) {
    if (logits[i] > max) {
      max = logits[i]
    }
  }
  const exps: number[] = []
  let sum: number = 0
  for (let i = 0; i < logits.length; i++) {
    const e: number = Math.exp(logits[i] - max)
    exps.push(e)
    sum += e
  }
  if (sum <= 0) {
    return [1, 0, 0, 0]
  }
  const out: number[] = []
  for (let i = 0; i < exps.length; i++) {
    out.push(exps[i] / sum)
  }
  return out
}

/* ══════════════════════════════════════════════════════════
 *  接入点（在 MqttService.ets 里改三处）
 * ══════════════════════════════════════════════════════════
 *
 *  ① 加成员
 *       private msModel: MsModel = new MsModel()
 *
 *  ② connect() 成功后加载（顺便把 ability context 传进来）
 *       const ok = await this.msModel.load(ctx.resourceManager)
 *       hilog.info(DOMAIN, TAG, 'msModel ready=%{public}s', String(ok))
 *
 *  ③ handleMessage 里换推理调用（三层降级）
 *       let r: ClassifyResult | null = null
 *       if (this.msModel.isReady) {
 *         r = await this.msModel.infer(this.windowBuf.toModelInput())
 *       }
 *       if (r === null) {
 *         r = classifyByRule(merged.features, this.baseline)   // 降级
 *       }
 *       merged.probs = r.probs
 *       merged.source = r.source
 *       merged.reason = r.reason
 *
 *  ⚠️ 注意 handleMessage 现在要改成 async —— 或者把推理挪到一个
 *     单独的异步函数里，别让 MQTT 回调线程等推理。
 */
