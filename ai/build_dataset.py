"""
星枢 SparkHub · 把 MQTT 录制的 log 转成训练数据（data.npz）

────────────────────────────────────────────────────────
用法
────────────────────────────────────────────────────────
    # 默认读 ~/fire_data 下所有 *.log
    python build_dataset.py

    # 指定目录和输出
    python build_dataset.py --dir D:\fire_data --out data.npz

    # 先看看会切出多少窗口（不写文件）
    python build_dataset.py --dry-run

────────────────────────────────────────────────────────
文件名即标签
────────────────────────────────────────────────────────
    normal_01.log     → 正常 (0)
    oil_01.log        → 油烟 (1)
    incense_01.log    → 油烟 (1)      檀香也是"有烟无火"
    steam_01.log      → 水汽 (2)
    cooking_01.log    → 水汽 (2)      温湿度同升，归到水汽
    heat_01.log       → 燃烧 (3)      纯热源（电吹风），模拟"湿降 + 温升"
    burn_01.log       → 燃烧 (3)

    规则：取文件名第一个下划线之前的部分作为类别前缀。

────────────────────────────────────────────────────────
log 行的格式（mosquitto_sub -F "%I %p"）
────────────────────────────────────────────────────────
    2026-10-04T15:48:55+0800 {"node":"N02","temp":0.0,...}

    ⚠️ N01 和 N02 的行是**交替**的，要按时间对齐再切窗。
"""

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime

import numpy as np

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


# ══════════════════════════════════════════════════════════
# 配置（必须和 train.py / Features.ets 一致）
# ══════════════════════════════════════════════════════════

IN_CHANNELS = 8
SEQ_LEN = 12                 # 60 秒窗口 ÷ 5 秒采样
SAMPLE_INTERVAL_S = 5        # 设备端的上报间隔
CLASS_NAMES = ["正常", "油烟", "水汽", "燃烧"]

# 文件名前缀 → 类别下标
LABEL_MAP = {
    "normal": 0,
    "oil": 1,
    "incense": 1,       # 檀香 = 有烟无火，归油烟
    "steam": 2,
    "cooking": 2,       # 蒸煮 = 温湿度同升，归水汽
    "boil": 2,
    "heat": 3,          # 纯热源
    "burn": 3,
    "fire": 3,
}

# 一阶差分、回落比 用的参数
TAIL_POINTS = 4             # 近 4 点（20 秒）算回落比

# 传感器合理的量程（超出说明是异常值，丢弃整窗）
VALID_RANGE = {
    "temp": (-10.0, 100.0),
    "humi": (0.0, 100.0),
    "lux": (0.0, 200000.0),
    "smoke": (0.0, 2000.0),
}


# ══════════════════════════════════════════════════════════
# 解析
# ══════════════════════════════════════════════════════════

LINE_RE = re.compile(r"^(\S+)\s+(\S+)\s+(\{.*\})\s*$")


def open_log(path):
    """
    自动识别编码

    ⚠️ PowerShell 的 `>` 重定向默认写 **UTF-16 LE**（带 FF FE BOM），
       不是 UTF-8。所以不能写死 encoding="utf-8"。
    """
    with open(path, "rb") as f:
        head = f.read(4)
    if head.startswith(b"\xff\xfe") or head.startswith(b"\xfe\xff"):
        return open(path, "r", encoding="utf-16", errors="ignore")
    return open(path, "r", encoding="utf-8-sig", errors="ignore")


def parse_line(line):
    """
    解析一行，返回 (epoch_sec, payload_dict) 或 None

    兼容两种格式：
        2026-10-04T15:27:51+0800 {"node":"N02",...}              ← -F "%I %p"
        2026-10-04T15:27:51+0800 sparkhub/data {"node":...}      ← -F "%I %t %p"

    做法：从第一个 `{` 切开，前面按空白分词，**第一个词就是时间戳**。
    """
    line = line.strip()
    if not line:
        return None

    i = line.find("{")
    if i <= 0:
        return None

    head = line[:i].split()
    if not head:
        return None

    t = parse_ts(head[0])
    if t is None:
        return None

    try:
        payload = json.loads(line[i:])
    except Exception:
        return None

    return t, payload


def parse_log(path):
    """
    读一个 log，返回 [(epoch_sec, payload_dict), ...]（已按时间排序）

    坏行直接跳过 —— 录制过程里的杂音不该让整个文件作废。
    """
    out = []
    with open_log(path) as f:
        for line in f:
            r = parse_line(line)
            if r is not None:
                out.append(r)

    out.sort(key=lambda x: x[0])
    return out


def parse_ts(s):
    """解析 mosquitto_sub -F %I 打出的 ISO8601 时间戳"""
    s = s.strip()
    # 去掉末尾的 +0800 / Z
    s2 = re.sub(r"[+-]\d{4}$", "", s).replace("Z", "")
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(s2, fmt).timestamp()
        except ValueError:
            continue
    return None


def ok_range(key, v):
    lo, hi = VALID_RANGE.get(key, (-1e9, 1e9))
    return lo <= v <= hi


# ══════════════════════════════════════════════════════════
# 时间对齐 + 重采样
# ══════════════════════════════════════════════════════════

def resample(records, interval=SAMPLE_INTERVAL_S):
    """
    把交替到达的 N01 / N02 消息，对齐成固定间隔的采样序列

    做法：维护"每个节点的最新值"，按 interval 走时间轴，每到一点就把
    当前所有节点的最新值合成一条采样记录。

    返回 [(t, {node: payload}), ...]
    """
    if not records:
        return []

    t0 = records[0][0]
    t_end = records[-1][0]

    latest = {}
    out = []
    idx = 0
    n = len(records)

    t = t0
    while t <= t_end:
        # 把 t 之前的所有消息都吃进去
        while idx < n and records[idx][0] <= t:
            _, payload = records[idx]
            node = str(payload.get("node", "?"))
            latest[node] = payload
            idx += 1

        if latest:
            # 深拷贝一份快照（避免后续被覆盖）
            out.append((t, {k: dict(v) for k, v in latest.items()}))
        t += interval

    return out


def to_channels(sample):
    """
    把一条采样记录（含 N01 / N02 的最新值）转成 4 个原始通道

    ⚠️ 按节点取它真正有的通道 —— 设备端会把没有的传感器发成 0，
       无脑全取的话 N02 的 temp:0 会污染温度。
    """
    temp = humi = lux = smoke = np.nan

    for node, p in sample.items():
        if node == "N01":
            if p.get("temp") is not None and ok_range("temp", p["temp"]):
                temp = float(p["temp"])
            if p.get("humi") is not None and ok_range("humi", p["humi"]):
                humi = float(p["humi"])
            if p.get("lux") is not None and ok_range("lux", p["lux"]):
                lux = float(p["lux"])
        elif node == "N02":
            if p.get("smoke") is not None and ok_range("smoke", p["smoke"]):
                smoke = float(p["smoke"])

    # 补缺：用最近的有效值（前向填充在下面统一做）
    return temp, humi, lux, smoke


def fill_missing(arr):
    """对 (T, 4) 的矩阵做前向填充，再后向填充，最后剩下的填 0"""
    out = arr.copy()
    T = out.shape[0]
    for c in range(out.shape[1]):
        last = np.nan
        for i in range(T):
            if np.isnan(out[i, c]):
                if not np.isnan(last):
                    out[i, c] = last
            else:
                last = out[i, c]
        # 反向
        nxt = np.nan
        for i in range(T - 1, -1, -1):
            if np.isnan(out[i, c]):
                if not np.isnan(nxt):
                    out[i, c] = nxt
            else:
                nxt = out[i, c]
    return np.nan_to_num(out, nan=0.0)


CH_NAMES4 = ["温度", "湿度", "光照", "烟雾"]


def dead_channels(raw4):
    """
    找出「全程为 0」的通道

    ⚠️ 录制时的常见问题：某个节点没上线，payload 里的字段全是 0，
       前向填充也补不出东西来。这种数据会让模型学歪 ——
       同一类里一部分样本温湿度全 0、另一部分正常，模型就完全学不会这一类。

    典型症状：某一类在验证集上准确率 0，而其它类都是 1.0。
    """
    dead = []
    for c in range(4):
        if np.all(np.abs(raw4[:, c]) < 1e-9):
            dead.append(CH_NAMES4[c])
    return dead


# ══════════════════════════════════════════════════════════
# 特征（和 Features.ets 的 features() 一一对应）
# ══════════════════════════════════════════════════════════

def windows_to_features(raw4):
    """
    raw4: (T, 4) 原始四通道
    返回: (N, 8, SEQ_LEN) 未归一化的 8 通道

    8 通道顺序（必须和 Features.ets / train.py 一致）：
      0 温度 1 湿度 2 光照 3 烟雾 4 温升速率 5 湿降速率 6 烟升斜率 7 回落比
    """
    T = raw4.shape[0]
    if T < SEQ_LEN:
        return np.zeros((0, IN_CHANNELS, SEQ_LEN), dtype=np.float32)

    # 先整段算一遍差分和回落比，再切窗（比逐窗算快，且边界更自然）
    full = np.zeros((IN_CHANNELS, T), dtype=np.float64)
    full[0] = raw4[:, 0]
    full[1] = raw4[:, 1]
    full[2] = raw4[:, 2]
    full[3] = raw4[:, 3]

    # 差分（每秒变化率）
    #
    # ⚠️ 采样间隔 5 秒 —— 除以它才能得到 ℃/s、%/s、ppm/s。
    #    必须和 Features.ets 的 / WindowBuffer.SAMPLE_SEC 完全一致，
    #    否则端侧推理会静默输出垃圾（不报错、不崩溃）。
    full[4] = np.gradient(full[0], SAMPLE_INTERVAL_S)
    full[5] = np.gradient(full[1], SAMPLE_INTERVAL_S)
    full[6] = np.gradient(full[3], SAMPLE_INTERVAL_S)
    # 回落比：近 TAIL_POINTS 点均值 / 整段峰值（这里按窗口算更合理，下面覆盖）

    out = []
    for start in range(0, T - SEQ_LEN + 1):
        w = full[:, start:start + SEQ_LEN].copy()

        # 回落比按**窗口内**算（和 Features.ets 的语义一致）
        seg = w[3]
        tail_len = min(TAIL_POINTS, SEQ_LEN)
        tail_avg = seg[-tail_len:].mean()
        peak = np.abs(seg).max()
        ratio = tail_avg / peak if peak > 1e-6 else 1.0
        w[7] = ratio

        out.append(w)

    return np.stack(out).astype(np.float32)


# ══════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════

def label_of(filename):
    """从文件名推类别"""
    stem = os.path.splitext(os.path.basename(filename))[0]
    prefix = stem.split("_")[0].lower()
    return LABEL_MAP.get(prefix)


def main():
    ap = argparse.ArgumentParser(description="把录制 log 转成 data.npz")
    ap.add_argument("--dir", type=str,
                    default=os.path.join(os.path.expanduser("~"), "fire_data"),
                    help="log 所在目录")
    ap.add_argument("--out", type=str,
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "data.npz"),
                    help="输出 npz 路径")
    ap.add_argument("--stride", type=int, default=1,
                    help="切窗步长（点）；默认 1（最大重叠）")
    ap.add_argument("--min-smoke", type=float, default=30.0,
                    help="油烟类录制的烟雾峰值下限；低于它说明那次没冒烟，"
                         "直接丢弃（默认 30）")
    ap.add_argument("--dry-run", action="store_true", help="只统计，不写文件")
    args = ap.parse_args()

    logs = sorted(glob.glob(os.path.join(args.dir, "*.log")))
    if not logs:
        print(f"[err] {args.dir} 下没有 .log 文件")
        return

    print(f"[scan] {args.dir}")
    print(f"[scan] 找到 {len(logs)} 个 log")

    X_all, y_all, s_all = [], [], []
    per_class = {}
    sess_names = []

    for path in logs:
        name = os.path.basename(path)
        lab = label_of(name)
        if lab is None:
            print(f"  [skip] {name}  —— 文件名前缀不认，跳过")
            continue

        records = parse_log(path)
        if len(records) < 2:
            print(f"  [skip] {name}  —— 有效行太少（{len(records)}）")
            continue

        samples = resample(records)
        raw4 = np.zeros((len(samples), 4), dtype=np.float64)
        for i, (_, s) in enumerate(samples):
            raw4[i] = to_channels(s)
        raw4 = fill_missing(raw4)

        # ⚠️ 检查有没有"全程为 0"的通道 —— 说明那个节点没上线，
        #    这种数据会让同一类里出现两种完全不同的特征，模型学不会。
        dead = dead_channels(raw4)
        if len(dead) >= 2:
            print(f"  [skip] {name:22s} —— 通道 {dead} 全程为 0（节点没上线？）")
            continue
        if dead:
            print(f"  [warn] {name:22s} —— 通道 {dead} 全程为 0")

        # ⚠️ 油烟类靠**烟雾**区分，它没有温升、也没有湿降。
        #    如果那次录制烟雾根本没上来（点香没点着 / 放太远），
        #    这份数据就和"正常"类长得一样 —— 混进去只会让模型学歪。
        #    实测：incense_02 烟雾峰值只有 11（和正常 1~20 重合），
        #    结果模型把 60% 的油烟判成了正常。
        if lab == 1:
            pk = float(raw4[:, 3].max())
            if pk < args.min_smoke:
                print(f"  [skip] {name:22s} —— 油烟类但烟雾峰值只有 {pk:.0f}"
                      f"（< {args.min_smoke}），没冒烟，不算有效样本")
                continue

        feats = windows_to_features(raw4)
        n_win = feats.shape[0]
        if n_win == 0:
            print(f"  [skip] {name}  —— 长度不够切窗（{len(samples)} 点 < {SEQ_LEN}）")
            continue

        # 按 stride 抽样
        feats = feats[::args.stride]

        # ⚠️ 记录每个窗口来自哪个文件（会话）—— 训练时按会话切分，
        #    避免相邻窗口高度重叠导致的"数据泄漏"
        sess_id = len(sess_names)
        sess_names.append(name)

        X_all.append(feats)
        y_all.append(np.full(feats.shape[0], lab, dtype=np.int32))
        s_all.append(np.full(feats.shape[0], sess_id, dtype=np.int32))

        per_class[lab] = per_class.get(lab, 0) + feats.shape[0]
        print(f"  [ok]   {name:22s} → {CLASS_NAMES[lab]:4s}  {len(samples):4d} 点 → {feats.shape[0]:4d} 窗")

    if not X_all:
        print("[err] 没有产出任何窗口 —— 检查文件名前缀和录制时长")
        return

    X = np.concatenate(X_all, axis=0)
    y = np.concatenate(y_all, axis=0)
    sess = np.concatenate(s_all, axis=0)

    print()
    print(f"[done] 总窗口数 {X.shape[0]}   形状 {X.shape}")
    print(f"[done] 来自 {len(sess_names)} 个会话（文件）")
    print("[dist] 各类分布：")
    for c in range(len(CLASS_NAMES)):
        n = int((y == c).sum())
        bar = "█" * min(40, n // 10)
        print(f"    {CLASS_NAMES[c]:4s}  {n:5d}  {bar}")

    # 数量失衡提醒
    counts = [int((y == c).sum()) for c in range(len(CLASS_NAMES))]
    if min(counts) == 0:
        missing = [CLASS_NAMES[i] for i, n in enumerate(counts) if n == 0]
        print(f"[warn] 有类别没有样本：{missing} —— 模型学不到这些类")
    elif max(counts) > 3 * max(min(counts), 1):
        print(f"[warn] 类别不均衡（最多 {max(counts)} / 最少 {min(counts)}）"
              f" —— 建议多录少的那几类")

    if args.dry_run:
        print("[dry-run] 没写文件")
        return

    # ⚠️ session 必须一起存 —— train.py 靠它按会话切分，防数据泄漏
    np.savez_compressed(args.out, X=X, y=y, session=sess,
                        session_names=np.array(sess_names))
    print(f"[save] {args.out}")
    print(f"[save] 字段：X {X.shape} / y {y.shape} / session {sess.shape}")
    print()
    print("下一步：")
    print(f"  python train.py --data {os.path.basename(args.out)} --epochs 60 --export")


if __name__ == "__main__":
    main()
