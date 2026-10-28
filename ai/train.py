"""
星枢 SparkHub · 火情辨识模型训练（MindSpore）

把传感器时序分成四类：正常 / 油烟 / 水汽 / 燃烧

────────────────────────────────────────────────────────
用法
────────────────────────────────────────────────────────
    # ① 先用合成数据验证流程能不能跑通
    python train.py

    # ② 用真实采集的数据训练
    python train.py --data data.npz --epochs 60

    # ③ 导出给端侧用的 .mindir
    python train.py --data data.npz --export

────────────────────────────────────────────────────────
数据格式（.npz）
────────────────────────────────────────────────────────
    X : (N, 8, 60)  float32    8 通道 × 60 秒
    y : (N,)        int32      0=正常 1=油烟 2=水汽 3=燃烧

    8 个通道（和端侧 Purple Pi 上算的完全一致，见
    entry/src/main/ets/model/Features.ets）：

      ch0  温度          ℃        N01 SHT30
      ch1  湿度          %        N01 SHT30
      ch2  光照          lux      N01 BH1750
      ch3  烟雾          ppm      N02 MQ-2
      ch4  温升速率      ℃/s      ch0 一阶差分
      ch5  湿降速率      %/s      ch1 一阶差分
      ch6  烟升斜率      ppm/s    ch3 一阶差分
      ch7  烟雾回落比    ——      近 10s 均值 / 窗口峰值

────────────────────────────────────────────────────────
环境
────────────────────────────────────────────────────────
    pip install mindspore numpy

    或者直接用 ModelArts Notebook（选 MindSpore 镜像，
    不用自己装）。
"""

import argparse
import os
import sys

import numpy as np

# Windows 控制台默认 GBK，输出中文/符号会崩 —— 强制走 UTF-8
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

import mindspore as ms
from mindspore import nn, ops, Tensor, dataset


# ══════════════════════════════════════════════════════════
# 常量
# ══════════════════════════════════════════════════════════

IN_CHANNELS = 8
SEQ_LEN = 12          # 60 秒窗口 ÷ 5 秒采样 = 12 点
N_CLASS = 4

CLASS_NAMES = ["正常", "油烟", "水汽", "燃烧"]

# ══════════════════════════════════════════════════════════
# 归一化量程
#
# ⚠️ 必须和端侧 harmony-cloud-app/entry/src/main/ets/model/Features.ets
#    里的 NORM 完全一致（顺序、上下界都不能差）。
#
#    不一致的话模型不会报错、不会崩溃、不会打警告，
#    只会静默输出垃圾结果。这是最难查的一类问题。
# ══════════════════════════════════════════════════════════

NORM = [
    (0.0, 60.0),      # ch0 温度 ℃
    (0.0, 100.0),     # ch1 湿度 %
    (0.0, 1000.0),    # ch2 光照 lux
    (0.0, 1000.0),    # ch3 烟雾 ppm
    (-1.0, 1.0),      # ch4 温升速率 ℃/s
    (-5.0, 5.0),      # ch5 湿降速率 %/s
    (-10.0, 10.0),    # ch6 烟升斜率 ppm/s
    (0.0, 2.0),       # ch7 烟雾回落比
]


def normalize(X):
    """
    把 (N, 8, 60) 的**原始物理量**归一化到 [0, 1]。

    和端侧 Features.ets 里的 norm() 做的是同一件事 ——
    按通道量程线性映射，超出量程的截断。
    """
    out = np.empty(X.shape, dtype=np.float32)
    for c in range(IN_CHANNELS):
        lo, hi = NORM[c]
        span = hi - lo
        if span <= 0:
            out[:, c, :] = 0.0
            continue
        out[:, c, :] = np.clip((X[:, c, :] - lo) / span, 0.0, 1.0)
    return out


# ══════════════════════════════════════════════════════════
# 模型
# ══════════════════════════════════════════════════════════

class MeanOverTime(nn.Cell):
    """
    沿时间轴取均值：[N,C,T] → [N,C,1]（1D）/ [N,C,1,T] → [N,C,1,1]（2D）。

    用来替代 AdaptiveAvgPool —— converter_lite 对 AdaptiveAvgPool
    支持不好，静态图里推不出输出尺寸时会退化成常量输出。
    这里输入长度固定，沿时间轴求均值与 AdaptiveAvgPool(1) 数学等价，
    且无参数。
    """

    def __init__(self, axis: int = 2):
        super().__init__()
        self.axis = axis

    def construct(self, x):
        return x.mean(axis=self.axis, keep_dims=True)


class FireCNN(nn.Cell):
    """
    1D-CNN 火情分类器（用 Conv2d 实现 1D 卷积）。

    为什么用 Conv2d 而不是 Conv1d：
      ⚠️ MindIR 里 Conv1d 会被表示成 Conv2D，converter_lite 需要插入
         Transpose 做 layout 转换，而这一步在静态图上会失败：
            GenTransposeNode] Convert abstract failed for node:
            .../0-Conv1d/Conv2D-op0_pre_0
         后果是数据布局错乱 —— 端侧表现为"输出恒为一组接近 0 的值"。
         直接在网络里写 Conv2d，MindIR 里就是原生 2D 卷积，无需任何转换。

    做法：把 8 个输入通道当成"高度"，时间轴当"宽度"
        x: [N, 8, 12] → reshape 成 [N, 1, 8, 12]
        第一个卷积 kernel 覆盖整个高度 (8)，于是等价于原来的 Conv1d(8→16, k=3)
        之后只在宽度方向卷积 / 池化

    参数量与 Conv1d 版一致，但**权重形状不同**（[16,1,8,3] vs [16,8,3]），
    所以要重新训练。
    """

    def __init__(self, in_ch: int = IN_CHANNELS, seq_len: int = SEQ_LEN,
                 n_class: int = N_CLASS):
        super().__init__()
        self.in_ch = in_ch
        self.seq_len = seq_len
        self.net = nn.SequentialCell([
            # 第一个卷积吃掉整个高度：等价于 Conv1d(in_ch → 16, k=3)
            # padding=(上,下,左,右) —— MindSpore Conv2d 的 pad 必须是 4 元组
            nn.Conv2d(1, 16, kernel_size=(in_ch, 3), pad_mode='pad', padding=(0, 0, 1, 1)),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=(1, 2)),     # 宽度 12 → 6

            nn.Conv2d(16, 32, kernel_size=(1, 3), pad_mode='pad', padding=(0, 0, 1, 1)),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=(1, 2)),     # 6 → 3

            nn.Conv2d(32, 32, kernel_size=(1, 3), pad_mode='pad', padding=(0, 0, 1, 1)),
            nn.ReLU(),
            MeanOverTime(axis=3),                 # [N,32,1,3] → [N,32,1,1]
            nn.Flatten(),
            nn.Dense(32, n_class),
        ])

    def construct(self, x):
        # [N, in_ch, seq_len] → [N, 1, in_ch, seq_len]
        x = x.reshape((x.shape[0], 1, self.in_ch, self.seq_len))
        return self.net(x)


# ══════════════════════════════════════════════════════════
# 合成数据（只为验证流程能跑通，不是真实特征）
# ══════════════════════════════════════════════════════════

def make_synthetic(n_per_class: int = 200, seed: int = 42):
    """
    按物理直觉造四类样本（**原始物理量**，归一化在 main 里统一做）。

    ⚠️ 这只是**流程验证用的占位数据**。
       真实数据必须按 docs/07 第五节 P1 去采。
    """
    rng = np.random.default_rng(seed)
    X, y = [], []

    for cls in range(N_CLASS):
        for _ in range(n_per_class):
            t = np.linspace(0, 1, SEQ_LEN)

            # 常态基准（室温、常态湿度、室内光照、本底烟雾）
            temp_seq = np.full(SEQ_LEN, 25.0 + rng.uniform(-2, 2))
            humi_seq = np.full(SEQ_LEN, 50.0 + rng.uniform(-5, 5))
            lux_seq = np.full(SEQ_LEN, 50.0 + rng.uniform(-20, 20))
            smoke_seq = np.full(SEQ_LEN, 10.0 + rng.uniform(0, 5))

            if cls == 0:                                    # 正常
                pass

            elif cls == 1:                                  # 油烟
                smoke_seq = smoke_seq + 400.0 * t           # 烟雾上升
                smoke_seq = smoke_seq * (1 + 0.25 * np.sin(2 * np.pi * 3 * t))  # 脉冲
                humi_seq = humi_seq + 20.0 * t              # 蒸煮 → 湿度升
                temp_seq = temp_seq + 12.0 * t              # 温度缓升

            elif cls == 2:                                  # 水汽
                humi_seq = humi_seq + 40.0 * t              # 湿度骤升（最强判据）
                # 12 点窗口：前 4 点虚高，后 8 点快速回落
                smoke_seq[:4] = smoke_seq[:4] + np.linspace(0, 250, 4)
                smoke_seq[4:] = smoke_seq[4:] + np.linspace(250, 30, 8)
                temp_seq = temp_seq + 1.0 * t               # 温度基本不动

            else:                                           # 燃烧
                temp_seq = temp_seq + 40.0 * t              # 温度快升 25 → 65
                humi_seq = humi_seq - 30.0 * t              # 湿度降（水被烤干）
                smoke_seq = smoke_seq + 800.0 * t           # 烟雾持续单调上升
                lux_seq = lux_seq + 700.0 * t               # 明火 → 光照升

            w = np.zeros((IN_CHANNELS, SEQ_LEN), dtype=np.float32)
            w[0] = temp_seq
            w[1] = humi_seq
            w[2] = lux_seq
            w[3] = smoke_seq
            # 一阶差分通道
            w[4] = np.gradient(temp_seq)
            w[5] = np.gradient(humi_seq)
            w[6] = np.gradient(smoke_seq)
            # 回落比：近 4 点（20 秒）均值 / 窗口峰值
            #   ⚠️ 这个 "4" 必须和端侧 Features.ets 里的 tailLen 一致
            tail = smoke_seq[-4:].mean()
            peak = np.abs(smoke_seq).max() + 1e-6
            w[7] = tail / peak

            # 传感器噪声
            w[0] += rng.normal(0, 0.15, SEQ_LEN)    # 温度 ±0.15 ℃
            w[1] += rng.normal(0, 0.5, SEQ_LEN)     # 湿度 ±0.5 %
            w[2] += rng.normal(0, 3.0, SEQ_LEN)     # 光照 ±3 lux
            w[3] += rng.normal(0, 5.0, SEQ_LEN)     # 烟雾 ±5 ppm

            X.append(w)
            y.append(cls)

    return np.stack(X).astype(np.float32), np.array(y, dtype=np.int32)


# ══════════════════════════════════════════════════════════
# 训练
# ══════════════════════════════════════════════════════════

def build_dataset(X: np.ndarray, y: np.ndarray, batch: int, shuffle: bool):
    ds = dataset.NumpySlicesDataset(
        {"data": Tensor(X, ms.float32), "label": Tensor(y, ms.int32)}, shuffle=shuffle
    )
    return ds.batch(batch, drop_remainder=False)


def evaluate(model, X, y, batch=64):
    model.set_train(False)
    correct = 0
    total = 0
    for i in range(0, len(X), batch):
        xb = Tensor(X[i:i + batch], ms.float32)
        logits = model(xb)
        pred = logits.argmax(axis=1).asnumpy()
        correct += int((pred == y[i:i + batch]).sum())
        total += len(pred)
    return correct / max(total, 1)


def main():
    ap = argparse.ArgumentParser(description="SparkHub 火情辨识模型训练（MindSpore）")
    ap.add_argument("--data", type=str, default="",
                    help="真实数据 .npz；留空则用合成数据验证流程")
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--lr", type=float, default=3e-4)
    # 默认输出到脚本所在目录，避免落到当前工作目录
    _here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", type=str, default=os.path.join(_here, "fire_model"))
    ap.add_argument("--export", action="store_true",
                    help="训练完导出 .mindir（给 converter_lite 用）")
    ap.add_argument("--export-only", action="store_true", dest="export_only",
                    help="跳过训练，直接用 fire_model_best.ckpt 导出 .mindir"
                         "（改了网络结构但权重可复用时用）")
    ap.add_argument("--class-weight", action="store_true",
                    help="按逆频率给类别加权（默认关；实测对油烟类反而更差）")
    args = ap.parse_args()

    ms.set_context(mode=ms.PYNATIVE_MODE, device_target="CPU")

    # ── 数据 ─────────────────────────────────────────────
    sess = None
    if args.data:
        d = np.load(args.data, allow_pickle=True)
        X, y = d["X"].astype(np.float32), d["y"].astype(np.int32)
        if "session" in d.files:
            sess = d["session"].astype(np.int32)
        print(f"[data] 载入真实数据 {X.shape}")
        if sess is not None:
            print(f"[data] 来自 {len(np.unique(sess))} 个采集会话")
    else:
        X, y = make_synthetic()
        print(f"[data] 合成数据 {X.shape}  (仅用于验证流程)")

    # 归一化 —— 和端侧 Features.ets 走同一套量程
    X = normalize(X)
    print("[data] 已按 NORM 归一化到 [0,1]")

    # ── 训练 / 验证 切分 ─────────────────────────────────
    #
    # ⚠️ 滑窗步长是 1 个点 → 相邻窗口有 11/12 的重叠。
    #
    #    如果**随机**切分，训练集和验证集里就会出现几乎相同的样本，
    #    验证准确率虚高、现场完全不能用 —— 这是最典型的数据泄漏。
    #
    #    正确做法：**按会话（录制文件）切分**。
    #    同一个文件切出的所有窗口，只能进训练集或验证集之一。
    if sess is not None and len(np.unique(sess)) >= 4:
        rng = np.random.default_rng(0)
        all_sess = np.unique(sess)
        val_set = set()

        # ⚠️ 按类别分层 —— 每个类里各挑一部分会话进验证集。
        #    不能"随便挑 N 个会话"：会话按文件名排序，很可能挑到的
        #    全是同一类，验证集里没有其它类 → 模型没见过 → 准确率 0。
        for c in range(N_CLASS):
            c_sess = np.unique(sess[y == c])     # 这个类出现过哪些会话
            if len(c_sess) == 0:
                continue
            n_take = max(1, int(round(len(c_sess) * 0.25)))
            if n_take >= len(c_sess):
                n_take = len(c_sess) - 1          # 至少留 1 个会话给训练
            if n_take <= 0:
                continue
            picked = rng.choice(c_sess, size=n_take, replace=False)
            for s in picked:
                val_set.add(int(s))
            print(f"[split] {CLASS_NAMES[c]:4s}：{len(c_sess)} 个会话 → "
                  f"验证取 {n_take} 个，会话号 {sorted(int(x) for x in picked)}")

        if not val_set:
            print("[err] 分层切分失败 —— 每类都只有 1 个会话？需要多录几次")
            return

        val_mask = np.isin(sess, np.array(sorted(val_set), dtype=np.int32))
        X_tr, y_tr = X[~val_mask], y[~val_mask]
        X_va, y_va = X[val_mask], y[val_mask]

        print(f"[split] 验证集共 {len(val_set)}/{len(all_sess)} 个会话，类别分布：")
        for c in range(N_CLASS):
            n = int((y_va == c).sum())
            if n > 0:
                print(f"        {CLASS_NAMES[c]:4s} {n}")
    else:
        # 没有 session 信息（比如合成数据）→ 退回随机切分
        idx = np.random.default_rng(0).permutation(len(X))
        X, y = X[idx], y[idx]
        n_val = max(int(len(X) * 0.2), 1)
        X_tr, y_tr = X[:-n_val], y[:-n_val]
        X_va, y_va = X[-n_val:], y[-n_val:]
        print("[split] 随机切分（无会话信息）")

    print(f"[data] 训练 {len(X_tr)}  验证 {len(X_va)}")

    if len(X_va) == 0 or len(X_tr) == 0:
        print("[err] 切分后训练集或验证集为空 —— 检查 session 字段")
        return

    # ── 模型 ─────────────────────────────────────────────
    model = FireCNN()
    n_param = sum(int(np.prod(p.shape)) for p in model.get_parameters())
    print(f"[model] FireCNN 参数量 {n_param}")

    loss_fn = nn.SoftmaxCrossEntropyWithLogits(sparse=True, reduction="mean")
    optimizer = nn.Adam(model.trainable_params(), learning_rate=args.lr)

    # ⚠️ 类别加权（逆频率）—— 默认**关闭**
    #
    # 试过的结论：加权让结果更差（水汽 1.000 → 0.718，冒出 60 个正常被判成
    # 燃烧）。原因是油烟类的样本**本身**区分不开，加权只是把权重最高的类
    # 变成垃圾桶。真正的问题是数据和特征，不是权重。
    #
    # 留着这个开关，等油烟数据补足之后再试。
    if args.class_weight:
        _cnt = np.bincount(y_tr, minlength=N_CLASS).astype(np.float64)
        _w = 1.0 / np.maximum(_cnt, 1.0)
        _w = _w / _w.sum() * N_CLASS
        print("[loss] 各类样本数 " + str(_cnt.astype(int).tolist()))
        print("[loss] 类别权重   " + str(np.round(_w, 3).tolist()))
    else:
        _w = np.ones(N_CLASS, dtype=np.float64)
    class_w = Tensor(_w.astype(np.float32), ms.float32)

    def forward_fn(data, label):
        logits = model(data)
        # 手动加权交叉熵 —— SoftmaxCrossEntropyWithLogits 不支持 weight
        #
        # ⚠️ one_hot 的 on_value / off_value 必须显式传：
        #    MindSpore 2.10 有默认值，2.0.0 没有 —— 不传会报
        #    "Miss argument input for parameter: on_value"
        logp = ops.log_softmax(logits, axis=1)
        oh = ops.one_hot(label, N_CLASS, on_value=1.0, off_value=0.0)
        oh = ops.cast(oh, logp.dtype)
        nll = -(oh * logp).sum(axis=1)                   # (B,)
        w = ops.gather(class_w, label, 0)                # (B,)
        loss = (nll * w).sum() / ops.maximum(w.sum(), 1e-6)
        return loss, logits

    grad_fn = ms.value_and_grad(forward_fn, None, optimizer.parameters, has_aux=True)

    @ms.jit
    def train_step(data, label):
        (loss, _), grads = grad_fn(data, label)
        # ⚠️ 梯度裁剪 —— 不做的话学习率稍大就 loss=nan（梯度爆炸）
        grads = ops.clip_by_global_norm(grads, 1.0)
        optimizer(grads)
        return loss

    # ── 只导出，不重训 ───────────────────────────────────
    #
    # 用于「改了网络结构、但权重可复用」的场景：比如把 AdaptiveAvgPool1d
    # 换成 MeanOverTime —— 两者数学等价且都无参数，旧 ckpt 直接可用。
    # converter_lite 对 AdaptiveAvgPool 支持不好，会退化成常量输出，
    # 所以端侧跑出「换任何输入都是同一组 logits」时必须换掉这一层。
    if args.export_only:
        ckpt = os.path.join(_here, "fire_model_best.ckpt")
        if not os.path.exists(ckpt):
            print(f"[error] 找不到 {ckpt}，无法 export-only")
            return
        ms.load_checkpoint(ckpt, net=model)
        model.set_train(False)
        print(f"[load] export-only：{ckpt}")

        # 自检：换两条差异明显的输入，确认输出确实不同
        xa = Tensor(np.zeros((1, IN_CHANNELS, SEQ_LEN), np.float32), ms.float32)
        xb = Tensor(np.ones((1, IN_CHANNELS, SEQ_LEN), np.float32), ms.float32)
        la = model(xa).asnumpy()[0]
        lb = model(xb).asnumpy()[0]
        print(f"[check] zeros -> {np.round(la, 4).tolist()}")
        print(f"[check] ones  -> {np.round(lb, 4).tolist()}")
        if np.abs(la - lb).max() < 1e-3:
            print("[warn] 两条输入输出几乎相同 —— 模型可能已退化，先别往下转")

        path = os.path.abspath(args.out)
        ms.export(model, xa, file_name=path, file_format="MINDIR")
        print(f"[export] {path}.mindir")
        print()
        print("下一步（转成端侧 .ms，必须带 --inputShape）：")
        print(f"  converter_lite --fmk=MINDIR --modelFile={path}.mindir \\")
        print(f"      --outputFile={path} --inputShape=\"x:1,{IN_CHANNELS},{SEQ_LEN}\" \\")
        print(f"      --saveType=MINDIR_LITE")
        return

    # ── 训练循环 ─────────────────────────────────────────
    #
    # ⚠️ 保存**验证集上最好的**模型，而不是最后一个。
    #    训练后期可能 loss=nan（数值不稳），最后那个模型是废的。
    ds = build_dataset(X_tr, y_tr, args.batch, shuffle=True)
    model.set_train(True)

    best_acc = 0.0
    best_ckpt = os.path.join(_here, "fire_model_best.ckpt")
    bad_epochs = 0

    for ep in range(1, args.epochs + 1):
        losses = []
        for batch in ds.create_dict_iterator():
            loss = train_step(batch["data"], batch["label"])
            losses.append(float(loss.asnumpy()))

        cur_loss = float(np.mean(losses))
        acc = evaluate(model, X_va, y_va)

        if acc > best_acc:
            best_acc = acc
            ms.save_checkpoint(model, best_ckpt)
            bad_epochs = 0
        else:
            bad_epochs += 1

        if ep % 5 == 0 or ep == 1:
            print(f"[epoch {ep:3d}] loss={cur_loss:.4f}  val_acc={acc:.4f}"
                  f"  best={best_acc:.4f}")

        # NaN 就直接停 —— 后面的 epoch 都是废的
        if not np.isfinite(cur_loss):
            print(f"[warn] loss 变成 {cur_loss}（梯度爆炸），提前停止")
            break

        # 早停：连续 15 轮没进步就停
        if bad_epochs >= 15:
            print(f"[stop] 连续 {bad_epochs} 轮没提升，提前停止")
            break

    print(f"[done] 最佳验证准确率 {best_acc:.4f}")

    # 加载验证集上最好的那个模型
    if os.path.exists(best_ckpt):
        ms.load_checkpoint(best_ckpt, net=model)
        print(f"[load] 已加载最佳模型：{best_ckpt}")

    # 分类别看准确率（混淆情况比总准确率更有意义）
    model.set_train(False)
    pred = model(Tensor(X_va, ms.float32)).argmax(axis=1).asnumpy()
    print("[per-class]")
    for c in range(N_CLASS):
        m = (y_va == c)
        if m.sum() > 0:
            print(f"  {CLASS_NAMES[c]}: {(pred[m] == c).mean():.3f}  (n={int(m.sum())})")

    # 混淆矩阵 —— 行=真实，列=预测。光看 per-class 不知道错到哪去了
    print()
    print("[confusion]   行=真实  列=预测")
    print("             " + "".join(f"{CLASS_NAMES[i]:>7s}" for i in range(N_CLASS)))
    for c in range(N_CLASS):
        m = (y_va == c)
        if m.sum() == 0:
            continue
        row = [(pred[m] == i).sum() for i in range(N_CLASS)]
        print(f"  {CLASS_NAMES[c]:>5s}    " + "".join(f"{v:7d}" for v in row))

    # ── 导出 ─────────────────────────────────────────────
    if args.export:
        dummy = Tensor(np.zeros((1, IN_CHANNELS, SEQ_LEN), np.float32), ms.float32)
        path = os.path.abspath(args.out)
        ms.export(model, dummy, file_name=path, file_format="MINDIR")
        print(f"[export] {path}.mindir")
        print()
        print("下一步（转成端侧 .ms）：")
        print(f"  ./converter_lite --fmk=MINDIR --modelFile={path}.mindir \\")
        print(f"      --outputFile={path} --inputShape=\"x:1,{IN_CHANNELS},{SEQ_LEN}\"")


if __name__ == "__main__":
    main()
