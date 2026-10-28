# 星枢 SparkHub · 全屋环境看板（OpenHarmony / MQTT 版）

原生 **ArkTS / ArkUI** 应用，跑在 **Purple Pi OH + 显示屏**上。

**应用本身是一个 MQTT 客户端**，直连局域网内的 broker 订阅设备数据 —— 全程不经过任何云平台，不需要任何认证。

---

## 架构

```
Nano 2 ──MQTT──> 本地 broker ──MQTT──> 本应用
（设备）        （Mosquitto/EMQX）      （Purple Pi）
                     ↑
                本应用也往这里 publish 控制命令
```

**为什么不用华为云**：那套走 IoTDA 需要 IAM 或 AK/SK 认证，而且应用侧只能 REST 轮询或 AMQP 订阅。自建 broker 完全在局域网内，零认证、实时推送、还能下发控制。

---

## 快速开始

### ① 先跑一个 broker

**Mosquitto（推荐先用它验证）**

```bash
# Ubuntu
sudo apt install mosquitto mosquitto-clients
sudo systemctl start mosquitto
```

Windows 去 [mosquitto.org/download](https://mosquitto.org/download/) 下安装包，装完会自动作为服务运行。

默认监听 `1883`，本地测试允许匿名连接。

**用命令行验证 broker 是通的**：

```bash
# 终端 A
mosquitto_sub -h localhost -t 'sparkhub/#' -v

# 终端 B（发一条假数据）
mosquitto_pub -h localhost -t 'sparkhub/data' -m '{"temp":25.4,"humi":58,"smoke":312,"light":"ON","motor":"OFF"}'
```

终端 A 能打印出来就说明 broker 没问题。

### ② 改应用里的 broker 地址

打开 `entry/src/main/ets/model/MqttService.ets`：

```ts
export const BROKER_URL: string = 'tcp://192.168.1.7:1883'
```

改成**跑 broker 那台机器的局域网 IP**。

### ③ 装依赖

```bash
cd entry
ohpm install
```

或者在 DevEco 里让它自动同步（`oh-package.json5` 里已经声明了 `@ohos/mqtt`）。

### ④ 编译运行

DevEco Studio + OpenHarmony SDK **API 14**，配置签名后运行。

> ⚠️ **必须在 ARM 真机上跑**（Purple Pi 是 ARM，没问题）。`@ohos/mqtt` 底层是 `.so` 原生库，官方只提供 ARM 版本，**x86 模拟器会报 `ERR_INSTALL_PARSE_NATIVE_SO_FAILED`**。

---

## 通信协议

### 设备 → 应用（上报）

| 项 | 值 |
|---|---|
| Topic | `sparkhub/data` |
| QoS | 1 |
| Payload | JSON |

```json
{
  "node": "N01",
  "temp": 25.4,
  "humi": 58.0,
  "smoke": 312,
  "light": "ON",
  "motor": "OFF",
  "beep": "OFF"
}
```

字段都是可选的，缺了界面显示 `--`。`light` / `motor` / `beep` 用字符串 `"ON"` / `"OFF"`。

### 应用 → 设备（控制）

| 项 | 值 |
|---|---|
| Topic | `sparkhub/cmd` |
| QoS | 1 |
| Payload | JSON |

```json
{ "target": "light", "value": "ON" }
```

`target` 可能是 `light` / `motor` / `light_level` / `motor_level`。

**设备端要做的事**：订阅 `sparkhub/cmd`，收到后按 `target` 分派到对应的 GPIO 控制。

---

## 界面

```
┌──────────────────────────────────────────────┐
│ 星枢 SparkHub · 全屋环境看板         ● 已连接 │
│ 数据来源：本地 MQTT broker     更新 14:23:05  │
├──────────────────────┬───────────────────────┤
│ 环境                  │ 烟雾浓度              │
│ 温度 25.4℃ 湿度 58%   │   312 ppm            │
│                      │  [超标 · 报警]        │
├──────────────────────┼───────────────────────┤
│ 风扇                  │ 灯光                  │
│ 开关 [已开启]         │ 开关 [已关闭]         │
│ 档位 [1] [2] [3]      │ 亮度 ━━●━━━━ 60       │
└──────────────────────┴───────────────────────┘
```

- **环境**：温度、湿度
- **烟雾浓度**：读数 + 三档状态（绿正常 / 黄接近 / 红超标报警）
- **风扇**：开关 + 档位（publish `motor` / `motor_level`）
- **灯光**：开关 + 亮度滑块（拖动只本地回显，**松手才 publish**，避免刷屏）

顶部还有连接状态灯和最后更新时间。

---

## 文件

```
entry/src/main/ets/
├── entryability/EntryAbility.ets   应用入口
├── common/Theme.ets                配色与尺寸
├── model/Types.ets                 DevicePayload + Snapshot
├── model/MqttService.ets           ★ MQTT 客户端 —— BROKER_URL 在这里改
└── pages/Index.ets                 主页面（顶栏 / 四张卡 / 页脚）
```

---

## 已知的坑（都来自官方问答）

| 现象 | 原因 | 处理 |
|---|---|---|
| 连接成功但收不到消息 | `messageArrived` 在 `connect` **之后**才注册 | 必须在创建 client 之后、`connect` 之前注册（代码里已经这么写了） |
| 模拟器报 `ERR_INSTALL_PARSE_NATIVE_SO_FAILED` | `@ohos/mqtt` 只有 ARM 的 `.so` | 用 ARM 真机 |
| 两个客户端互相踢下线 | `clientId` 重复 | 每个客户端用唯一 ID |
| 切到后台收不到消息 | 系统保活策略 | 需要申请长时任务 |
| 发布 QoS 高但收不到 | 实际投递 QoS = min(发布, 订阅) | 两边都设 QoS 1 |
| 崩溃 / use-after-free | 销毁顺序反了 | 必须先 `disconnect()` 再 `destroy()`（代码里已经这么写了） |

---

## 与华为云方案的关系

工作区里还有一套 `cloud-bridge/`（华为云 IoTDA 桥接服务）。两套是**互斥的替代方案**：

| | 华为云方案 | **本方案（MQTT）** |
|---|---|---|
| 认证 | 需要 IAM 或 AK/SK | **不需要** |
| 依赖公网 | 是 | 否 |
| 实时性 | 2 秒轮询 | 推送 |
| 数据出户 | 是 | **否，全在局域网** |
| 设备固件 | 不用改（已连华为云） | 要改成连本地 broker |

**比赛演示建议用本方案**：不依赖公网、现场不会因为网络问题翻车，而且「数据不出户」本身就是方案的设计主张。
