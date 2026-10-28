# AI · 火情辨识模型（MindSpore 技术栈）

> 把传感器时序分成四类：**正常 / 油烟 / 水汽 / 燃烧**
> 解决单阈值烟感"做饭必响、洗澡也响"的误报问题。

**技术栈**：MindSpore 训练 → `.mindir` → `converter_lite` 转 `.ms` → Purple Pi 上 MindSpore Lite 推理。**全程华为技术栈，不碰 PyTorch / ONNX。**

---

## 一、整体流程

```
① 采集数据      ai/collect/  →  data.npz
                      ↓
② 训练          train.py     →  fire_model.mindir
                      ↓
③ 转换          converter_lite →  fire_model.ms
                      ↓
④ 部署          放 harmony-cloud-app 的 resources/rawfile/
                      ↓
⑤ 推理          Purple Pi 上 @kit.MindSporeLiteKit
```

---

## 二、环境

### 本地（Ubuntu 虚拟机）

```bash
pip install mindspore numpy
```

> MindSpore 的 Linux x86_64 CPU 版可以直接 pip 装。**Windows 版本支持较差**，建议在你的 Ubuntu 虚拟机上跑。

### 或者用 ModelArts Notebook（推荐）

```
ModelArts 控制台 → 开发空间 → Notebook → 创建
→ 镜像选 **MindSpore**（不用自己装环境）
→ 规格选免费 CPU 规格
```

**云上的好处**：环境现成、不占本地资源。**但要先过委托授权那一关**（见 `docs/07`）。

---

## 三、先验证流程（不需要任何数据）

```bash
cd ai
python train.py
```

**会用合成数据跑一遍完整流程**，你应该看到：

```
[data] 合成数据 (800, 8, 60)  ⚠️ 仅用于验证流程
[data] 训练 640  验证 160
[model] FireCNN 参数量 3xxxx
[epoch   1] loss=1.2xxx  val_acc=0.5xxx
[epoch   5] loss=0.3xxx  val_acc=0.8xxx
...
[done] 最佳验证准确率 0.9xxx
[per-class]
  正常: 0.9xx  (n=40)
  油烟: 0.9xx  (n=40)
  水汽: 0.9xx  (n=40)
  燃烧: 0.9xx  (n=40)
```

**合成数据上准确率高是必然的**（因为是我按规则造的）—— **这一步只是为了确认代码能跑通，不代表模型有效。**

⚠️ **真实效果只能靠真实数据验证。**

---

## 四、采集真实数据

### 4.1 数据格式

```python
# data.npz
X : (N, 8, 60)  float32    8 通道 × 60 秒（1 Hz）
y : (N,)        int32      0=正常 1=油烟 2=水汽 3=燃烧
```

### 4.2 8 个通道的定义

**⚠️ 训练和端侧必须完全一致 —— 这是最容易出错的地方。**

| 通道 | 内容 | 单位 | 来源 |
|---|---|---|---|
| ch0 | 温度 | ℃ | N01 SHT30 |
| ch1 | 湿度 | % | N01 SHT30 |
| ch2 | 光照 | lux | N01 BH1750 |
| ch3 | 烟雾 | ppm | N02 MQ-2 |
| ch4 | 温升速率 | ℃/s | ch0 一阶差分 |
| ch5 | 湿降速率 | %/s | ch1 一阶差分 |
| ch6 | 烟升斜率 | ppm/s | ch3 一阶差分 |
| ch7 | 烟雾回落比 | 无量纲 | 近 10s 均值 / 窗口峰值 |

**归一化的做法要固定下来**（比如按各自量程缩放到 `[0, 1]`），**训练和端侧用同一套参数**。建议把归一化系数也写进 `.npz`，端侧读取。

### 4.3 每类采多少

| 类别 | 怎么采 | 目标 |
|---|---|---|
| 正常 | 房间放一整晚 | 2~3 小时 |
| 油烟 | 实际炒几次菜，传感器放厨房 | 3~5 次烹饪 |
| 水汽 | 加湿器 / 喷壶对着传感器 | 20 分钟 |
| 燃烧 | **安全环境下点一支香** | 10 次 |

**目标量：每类 200~500 个 60 秒窗口**（用滑动窗口从几小时数据里切，不用真录 200 次）。

### 4.4 采集建议

- **采样率 1 Hz**（设备端 `PUB_INTERVAL_MS` 改 1000）
- **MQTT 直接录到文件**：PC 上 `mosquitto_sub -v -t sparkhub/data > raw.log`，再离线切窗
- **标好时间戳和类别**，别事后靠回忆
- **两个节点的时间要对齐**（温湿度来自 N01、烟雾来自 N02，错位会让斜率算错）

---

## 五、训练

```bash
python train.py --data data.npz --epochs 60 --export
```

**输出**：

```
fire_model.mindir
```

**关注的重点不是总准确率，而是「水汽」这一类**：

| 类别 | 为什么重要 |
|---|---|
| **水汽** | **这是要解决的核心问题** —— 传统烟感在这类上必误报 |
| 燃烧 | 漏报代价最高（不能漏） |
| 油烟 | 误报最多的一类 |

**答辩时展示「水汽」的混淆矩阵** —— 如果水汽被判成燃烧的比例很低，说明模型确实学到了该学的东西。

---

## 六、转换成端侧模型

```bash
# MindSpore Lite 的转换工具（从官网下载预编译包，或源码编译）
./converter_lite --fmk=MINDIR \
    --modelFile=fire_model.mindir \
    --outputFile=fire_model \
    --inputShape="x:1,8,60"
```

**期望输出**：`CONVERT RESULT SUCCESS:0`

**量化（可选，体积减 75%）**：

```bash
# 需要校准数据
./converter_lite --fmk=MINDIR --modelFile=fire_model.mindir \
    --outputFile=fire_model_int8 \
    --configFile=quantization_config.cfg \
    --inputShape="x:1,8,60"
```

**⚠️ 量化后必须做精度比对** —— 同一份输入喂 float32 和 int8 模型，输出要接近。

---

## 七、部署到 Purple Pi

### 7.1 前置验证（**最先做这个**）

```bash
hdc shell "cat /system/etc/syscap.json" | Select-String "MindSpore"
```

**或者**在 DevEco 里新建页面加一行：

```typescript
import { mindSporeLite } from '@kit.MindSporeLiteKit'
```

**编译能过 = 有。** 没有的话这条路走不通，退到只用规则基线。

### 7.2 工程配置

**① `entry/src/main/syscap.json`（文件名固定，需手动创建）**

```json
{
  "development": {
    "addedSysCaps": ["SystemCapability.AI.MindSporeLite"]
  }
}
```

**② 模型放 `entry/src/main/resources/rawfile/fire_model.ms`**

### 7.3 推理代码要点

```typescript
import { mindSporeLite } from '@kit.MindSporeLiteKit'

const context: mindSporeLite.Context = {}
context.target = ['cpu']          // ⚠️ 数组，不是字符串
context.cpu = {}
context.cpu.threadNum = 2

const raw = await ctx.resourceManager.getRawFileContent('fire_model.ms')
const model = await mindSporeLite.loadModelFromBuffer(raw.buffer.slice(0), context)

const inputs = model.getInputs()
inputs[0].setData(float32Data.buffer)     // shape 必须匹配 (1, 8, 60)
const outputs = await model.predict(inputs)
const probs = new Float32Array(outputs[0].getData())
```

**三个坑**（官方文档列的）：

| 坑 | 说明 |
|---|---|
| `context.target` 是数组 | 写 `['cpu']`，写 `'cpu'` 会失败 |
| `MSTensor` 属性不是方法 | `tensor.shape` / `tensor.dtype`，**没有 `getShape()`** |
| **输出只能从 `predict()` 返回值取** | **没有 `getOutputs()`** |

**预处理（归一化）要自己写** —— 而且**必须和训练时用同一套系数**。

---

## 八、三层降级（`docs/07` 的核心设计）

**模型只是中间那层**，上下都有兜底：

```typescript
async function decide(window: number[][]): Promise<ClassifyResult> {
  // 第 3 层：云端（可选）
  if (cloudEnabled) {
    try { return { probs: await inferCloud(window), source: 'cloud' } }
    catch (e) { cloudEnabled = false }
  }
  // 第 2 层：本地模型
  if (localModel !== null) {
    try { return { probs: await inferLocal(localModel, window), source: 'model' } }
    catch (e) { /* 落到第 1 层 */ }
  }
  // 第 1 层：规则基线（永远在）
  return { probs: ruleBaseline(window), source: 'rule' }
}
```

**模型加载失败、推理抛异常、文件缺失 —— 都不影响系统工作。**

---

## 九、常见问题

| 问题 | 原因 | 处理 |
|---|---|---|
| `ModuleNotFoundError: mindspore` | 没装或装错平台 | Ubuntu 上 `pip install mindspore` |
| 训练准确率高但现场没用 | **用了合成数据 / 数据泄漏**（同一段数据切窗后跨 train/val） | **按"采集会话"切分数据集**，不能随机切 |
| 端侧推理结果和训练不一致 | 预处理归一化系数不同 / 通道顺序不同 | 把归一化参数写进文件，端侧读同一份 |
| `loadModelFromBuffer` 返回失败 | `syscap.json` 没声明 / `.ms` 版本不匹配 | 检查 syscap；重新用对应版本的 converter 转 |
| 推理很慢 | 输入 shape 没固定 / 线程数太少 | `--inputShape` 固定；`cpu.threadNum` 调大 |

**⚠️ 「数据泄漏」是最隐蔽的坑**：如果从同一段连续采集里随机切 60 秒窗口，训练集和验证集会有重叠 → **准确率虚高，现场完全不能用**。**必须按采集会话（session）切分。**

---

## 十、下一步

| 优先级 | 做什么 |
|---|---|
| **P0** | 验证 Purple Pi 有 `SystemCapability.AI.MindSporeLite` |
| **P0** | 设备端采样率 1 Hz |
| **P0** | Purple Pi 加 60 秒滑窗 + 特征计算（**和 `train.py` 的 8 通道一致**） |
| **P0** | 规则基线（不依赖模型就能演示） |
| P1 | 采数据 → `data.npz` |
| P2 | `python train.py --data data.npz --export` |
| P3 | `converter_lite` → `.ms` → 端侧接入 |

**P0 的四项做完，演示就能演了** —— 而且规则基线和模型用的是同一套特征，接模型时上层不用改。
