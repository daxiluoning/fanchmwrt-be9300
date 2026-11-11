# 严格保留原厂 OpenWrt 23.05：可行性与做法

> 结论先说：**在公开资料下做不到**。要保留原厂 23.05 用户空间并加载 OAF，必须拿到 GL.iNet 为 BE9300 4.10.1 发布的 GPL 源码/SDK（含内核头文件和工具链）。没有它，只能二选一：放弃 OAF，或刷本工程的 mainline（25.12 线）。

---

## 1. 为什么不能“只装一个 ipk”

OpenAppFilter 由三部分组成：

| 组件 | 形态 | 与内核的关系 |
|---|---|---|
| `kmod-oaf` | `oaf.ko` 内核模块 | **强绑定**：`vermagic` 必须与运行内核完全一致 |
| `appfilter` | 用户态 `oafd` + Lua | 依赖 `libubox/libubus/uci/json-c/sqlite3/curl` |
| `luci-app-oaf` | LuCI 页面 | 依赖 `luci-compat`、`luci-lib-jsonc` |

`vermagic` 由内核版本、SMP/ PREEMPT 配置、模块 ABI 等一起算出。原厂 4.10.1 是 QSDK 12.5 的 5.x 内核，本工程是 6.18；两者编出的 `oaf.ko` 不能互换。即使强行 `insmod -f`（多数内核已禁用），结构体布局差异也可能直接 panic。

所以“保留原厂 23.05 + 安装 OAF”只有一条路：**用 GL.iNet 的原厂内核源码/头文件，针对它编 `kmod-oaf`**。

---

## 2. GL.iNet 公开了什么

截至 2026-11，公开渠道能查到：

- `github.com/gl-inet/gl-openwrt`：只有 `openwrt-25.12` 分支；`README-glinet.md` 明确列出支持型号只有 **GL-BE10000 / GL-BE14000**，没有 BE9300。
- `github.com/gl-inet/sdk`：最后更新停留在 ipq807x/21.02 时代，没有 BE9300 的 SDK。
- GL.iNet 下载中心：提供固件 `.bin`，不提供 BE9300 4.10.1 的完整 BSP 源码包。
- 社区镜像（如 `fw.gl-inet.com` 的第三方镜像）只见到 4.7.11 的固件，没有源码。

GL.iNet 的 GPL 合规源码通常按型号/版本打包，需要走支持渠道索取；Wi-Fi 7/QSDK 12.5 的 BSP 还可能包含 NDA 组件，公开版本会缺预编译库。**没有源码就无法重编内核模块**，这是硬约束，不是配置问题。

---

## 3. 你的三个选项

| 选项 | 保留 23.05 | 有 OAF | 代价 |
|---|---|---|---|
| A. 保持原厂，不装 OAF | ✅ | ❌ | 没有应用过滤 |
| B. 向 GL.iNet 要 GPL 源码，只编 OAF ipk | ✅ | ✅ | 等源码；需要能复现原厂内核配置；可能需要处理模块签名 |
| C. 刷本工程（mainline 25.12 线 + OAF） | ❌ | ✅ | 替换系统；可回厂；见 `FLASHING.md` |

如果你选 B，下面是要做的事。

---

## 4. 向 GL.iNet 索取源码

走官方支持工单/售后邮箱，主题写清楚型号、固件版本、GPL 请求。模板：

```
Subject: GPL source code request — GL-BE9300 firmware 4.10.1 release1

Hello,

I own a GL.iNet GL-BE9300 (Flint 3), currently running firmware
4.10.1 release1 (QSDK 12.5, OpenWrt 23.05 based).

Under GPL-2.0 I request the complete corresponding source code for this
firmware, specifically:

1. the OpenWrt/BSP source tree used to build 4.10.1 release1 for GL-BE9300;
2. the kernel source and the .config / build artifacts needed to rebuild
   kernel modules with the same vermagic;
3. the toolchain/SDK (or exact toolchain versions) used for the build;
4. any GPL-covered userspace packages and their build scripts.

If some components are covered by a separate license, please point me to
the corresponding binary blobs and the exact source for the GPL parts.

Thank you.
```

同时把购买凭证、设备背面标签、`cat /etc/openwrt_release` 的输出附上，减少来回。

---

## 5. 拿到源码后怎么编 OAF

> 以下命令是通用 OpenWrt 构建流程；GL.iNet 的树可能有自己的 `make` 包装，以其 README 为准。

### 5.1 先确认能复现原厂内核

```sh
# 在原厂设备上
uname -r
cat /proc/version
zcat /proc/config.gz 2>/dev/null | head
```

在源码树里核对 `CONFIG_LOCALVERSION`、`CONFIG_MODVERSIONS`、SMP/PREEMPT 配置与设备一致。**只要有一项不同，vermagic 就不匹配。**

### 5.2 加入 OAF 并编译

```sh
cd <gl-inet-source>
git clone https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter

# 只编 OAF 三个包（首次仍需先编工具链/内核头）
make package/oaf/compile V=s
make package/open-app-filter/compile V=s
make package/luci-app-oaf/compile V=s
```

产物在 `bin/packages/<arch>/base/`（或 `packages/`）下：

- `kmod-oaf_*.ipk`
- `appfilter_*.ipk`
- `luci-app-oaf_*.ipk`

### 5.3 校验 vermagic

```sh
modinfo oaf.ko | grep vermagic
# 必须等于
uname -r
```

### 5.4 检查模块签名

```sh
zcat /proc/config.gz | grep -E 'CONFIG_MODULE_SIG|CONFIG_MODULE_SIG_FORCE'
```

- `CONFIG_MODULE_SIG_FORCE=y`：只能加载用原厂私钥签名的模块。没有私钥就**无解**，除非关掉安全启动/换内核。
- `CONFIG_MODULE_SIG=y` 但 `FORCE` 未开：未签名模块可加载（可能 taint 内核）。

### 5.5 安装与验证

```sh
scp kmod-oaf_*.ipk appfilter_*.ipk luci-app-oaf_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
opkg install /tmp/kmod-oaf_*.ipk /tmp/appfilter_*.ipk /tmp/luci-app-oaf_*.ipk
lsmod | grep '^oaf'
```

首次启动后关闭原厂硬件加速（GL.iNet 界面里的“硬件加速/Flow offload”，或 QSDK 的 ECM）：

```sh
# OAF 自带脚本会处理已知路径
/usr/bin/hnat.sh 1
```

并确认 `fwx.advanced.disable_hnat=1`。

---

## 6. 常见坑

1. **原厂内核没开 `CONFIG_NF_CONNTRACK` 的某些选项**：OAF 依赖 conntrack hook；缺选项时编译能过但运行无数据。
2. **QSDK HNAT/ECM 绕过 netfilter**：必须关硬件加速，否则只能看到每条流的前几个包。
3. **原厂 rootfs 空间小**：`/overlay` 可能放不下 `oafd` + sqlite + 特征库，先 `df -h /overlay`。
4. **LuCI 版本**：原厂 LuCI 可能改过；`luci-app-oaf` 依赖 `luci-compat`/`luci-lib-jsonc`，缺包要先补。
5. **升级固件会覆盖**：原厂 OTA 后内核可能变，`kmod-oaf` 需要重编。

---

## 7. 一句话建议

- 你要的是“原厂稳定 + 应用过滤”，且能拿到 GPL 源码 → 走 B，先发工单。
- 你要的是“现在就能编、能刷、能过滤” → 走 C，用本工程；刷机前备份 eMMC，随时可回厂。
- 你只是想要原厂，不需要过滤 → 什么都别刷。
