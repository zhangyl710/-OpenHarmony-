# MQTT 节点固件（小熊派 BearPi-HM Nano 2 / WS63）

设备端代码。链路：

```
本节点 ──MQTT──> 本地 broker ──MQTT──> 鸿蒙看板（Purple Pi）
```

用 **SDK 自带的 paho.mqtt.c**（`sdk/open_source/mqtt/paho.mqtt.c`，已编成 `libmqtt.a`），标准 MQTT，**不需要任何云平台认证**。

---

## 文件

| 文件 | 说明 |
|---|---|
| `mqtt_node.c` | 主逻辑：连 Wi-Fi → 连 broker → 订阅控制 → 定时上报 → 本地安全兜底 |
| `config.h` | **部署配置，烧写前必须改**（板子角色、Wi-Fi、节点 ID） |
| `BUILD.gn` | 构建定义 |

---

## 用到的 SDK 接口（已按实际头文件对齐）

### E53_IA1（温湿度 + 光照 + 灯 + 电机）

```c
typedef struct {
    float Lux;            // 光照强度
    float Humidity;       // 湿度
    float Temperature;    // 温度
} E53IA1Data;

int  E53IA1Init(void);
int  E53IA1ReadData(E53IA1Data *ReadData);   // ⚠️ 传指针
void LightStatusSet(E53IA1Status status);    // ⚠️ 枚举，不是 int
void MotorStatusSet(E53IA1Status status);
```

### E53_SF1（烟感 + 蜂鸣器）

```c
void E53SF1Init(void);
void MQ2PPMCalibration(void);
int  GetMQ2PPM(float *ppm);                  // ⚠️ 返回状态码，ppm 走指针输出
void BeepStatusSet(E53SF1Status status);
```

### 一个必踩的坑

两个头文件**都定义了 `CTL_OFF` / `CTL_ON` 枚举**：

```c
typedef enum { CTL_OFF = 0, CTL_ON } E53IA1Status;
typedef enum { CTL_OFF = 0, CTL_ON } E53SF1Status;
```

**同时 `#include` 会报重复定义**。所以：

- 代码里用 `#if defined(BOARD_IA1)` 只 include 一个
- 两块板烧**不同的固件**，`config.h` 里切换 `BOARD_IA1` / `BOARD_SF1`

---

## 烧录前的准备

### ① 改 `config.h`

```c
#define BOARD_IA1        // 装 E53_IA1 的板子用这个
// #define BOARD_SF1     // 装 E53_SF1 的板子用这个

#define CONFIG_WIFI_SSID    "你的Wi-Fi名"
#define CONFIG_WIFI_PWD     "你的Wi-Fi密码"
```

`NODE_ID` 会按角色自动设成 `N01`（IA1）/ `N02`（SF1），不用手动改。

### ② 把驱动和依赖拷到本目录

```bash
cd /data/bearpi-hm_nano_2/device/board/bearpi/bearpi_hm_nano_2/app/

# 建目录
mkdir -p sparkhub_mqtt
cd sparkhub_mqtt

# 拷 E53 驱动
cp ../C2_e53_ia1_temp_humi_pls/include/E53_IA1.h .
cp ../C2_e53_ia1_temp_humi_pls/src/E53_IA1.c .
cp ../C1_e53_sf1_mq2/include/E53_SF1.h .
cp ../C1_e53_sf1_mq2/src/E53_SF1.c .

# 拷 mqtt_node.c 和 config.h（从你的工作区拷过来）
```

### ③ 补 `WifiConnect()`

`mqtt_node.c` 里调了 `WifiConnect(CONFIG_WIFI_SSID, CONFIG_WIFI_PWD)`，**这个函数不在 E53 驱动里**，得从官方例程拿。

先找到它：

```bash
cd /data/bearpi-hm_nano_2
grep -rn "WifiConnect" device/board/bearpi/bearpi_hm_nano_2/app/ | head -10
```

看它在哪个 `.c` 里实现的，把那段**拷成一个 `wifi_connect.c`** 放进本目录。

**如果它的实现依赖其他文件**（比如 wifi 事件回调），把那些也一起拷过来。

### ④ 改 `app/BUILD.gn`

```gn
features = [
    # "E1_sle_uart_client:example",
    # "E2_sle_uart_server:example",
    # ... 其他全部注释掉
    "sparkhub_mqtt:mqtt_node",
]
```

⚠️ **其他 example 一个都不能留**，否则会像之前那样报 `multiple definition`。

---

## 编译烧录

```bash
cd /data/bearpi-hm_nano_2
rm -rf out/          # 改了 BUILD.gn 必须清，否则旧的 .a 还在
hb build -f
find out -name "*.fwpkg"
```

用 BurnTool 烧 `ws63-liteos-app_all.fwpkg`。

**两块板各改一次 `config.h` 的角色宏，各编各烧一次。**

---

## 通信协议

**上报** `sparkhub/data`（QoS 1）：

```json
{"node":"N01","temp":25.4,"humi":58.0,"lux":320,"smoke":0,"light":"ON","motor":"OFF","beep":"OFF"}
```

装 IA1 的板子报温湿度光照，装 SF1 的板子报烟雾，**没接的字段是 0**。

**控制** `sparkhub/cmd`（QoS 1）：

```json
{"target":"light","value":"ON"}
```

`target` 取值：`light` / `motor` / `beep`

---

## 本地安全兜底

`LocalSafetyCheck()` 是刻意加的 —— **broker 挂了、主机离线了，设备自己也要能报警**：

```c
if (smoke >= 300 ppm || temp >= 45℃) {
    BeepStatusSet(CTL_ON);     // 蜂鸣器报警
    MotorStatusSet(CTL_ON);    // 自动排烟
}
```

演示时**把 broker 关掉**再点烟，设备照样响 —— 这就是方案里「去中心化」最直观的展示。

---

## 两个可选方案（如果链接不到 paho）

`mqtt_node.c` 用的是 **paho.mqtt.c 完整版 API**（`MQTTClient_create` / `MQTTClient_connect`）。

如果编译时报 `undefined reference to MQTTClient_create`，说明 `libmqtt.a` 没被带进最终镜像。两条退路：

**方案 A：改用 BearPi 自带的嵌入式版**

源码树里有另一套：

```
device/board/bearpi/bearpi_hm_nano_2/third_party/paho_mqtt/MQTTClient-C/
```

这是**嵌入式精简版**，API 完全不同：

| 完整版 | 嵌入式版 |
|---|---|
| `MQTTClient_create()` | `MQTTClientInit()` |
| `MQTTClient_connect()` | `MQTTConnect()` |
| `MQTTClient_publishMessage()` | `MQTTPublish()` |
| `MQTTClient_subscribe()` | `MQTTSubscribe()` |

好处是**源码在树里，可以直接编进来**，不依赖 `libmqtt.a`。

**方案 B：自己在 SDK 的 CMake 配置里打开 mqtt 模块**

确认 `open_source/mqtt` 参与最终链接，把 `libmqtt.a` 带上。

**先按现在的代码试**，链接报错再说。

---

## 需要按实际 SDK 核对的地方

| 位置 | 不确定什么 | 怎么查 |
|---|---|---|
| `wifi_connect.c` | 实现从哪拷 | `grep -rn "WifiConnect" app/` |
| `BUILD.gn` 的 `-lmqtt` | 库名对不对 | 看 `libmqtt.a` 所在目录 |
| `MQTTClient.h` | 用哪个版本 | 已确认：`sdk/open_source/mqtt/paho.mqtt.c/src/` |
| cJSON 路径 | 对不对 | `find . -name "cJSON.h"` |
