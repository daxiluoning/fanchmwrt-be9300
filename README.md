# FanchmWrt for GL-BE9300

**给 GL.iNet Flint 3（GL-BE9300 / IPQ5332）的可复现固件工程：OpenWrt mainline（25.12 线）底座 + OpenAppFilter 深度包检测。**

- 云编译：GitHub Actions，一键出 `factory.bin` / `sysupgrade.bin`
- 本地编译：Ubuntu 22.04/24.04 一条命令
- 板级支持：`qualcommbe/ipq53xx`，内核 6.18
- 应用过滤：OpenAppFilter 7.0.2（`oaf` 内核模块 + `appfilter` 守护进程 + LuCI）
- 默认关闭 flow offload，保证 DPI 能看到每一条转发流

---

## 0. 先读这三件事

### 0.1 它不保留原厂 23.05 用户空间

原厂 4.10.1 release1 是 **OpenWrt 23.05 + QSDK 12.5** 的闭源 BSP。公开渠道没有找到这套 BE9300 源码；公开的 `gl-openwrt` 只有 25.12 分支，而且只支持 BE10000/BE14000。OAF 是**内核模块**，`vermagic` 必须和固件内核逐字节匹配，所以不可能把 25.12 编出来的 `kmod-oaf` 装进原厂 23.05 系统。

本工程刷入后是 **OpenWrt mainline（25.12 线，内核 6.18；树内版本号默认 `SNAPSHOT`）**，会替换原厂系统。可逆：分区布局、ART/无线校准数据保留，按 `docs/FLASHING.md` 可以回原厂。若“必须保留 23.05 用户空间”是硬性要求，先看 [`docs/STOCK-23.05.md`](docs/STOCK-23.05.md)，那条路需要你向 GL.iNet 索取 GPL 源码/SDK。

### 0.2 刷机有变砖风险

这台机器没有可用的串口，Wi-Fi 7 的 ath12k 固件在持续负载下仍可能崩溃（社区移植的已知问题）。刷机前**必须**备份 eMMC（含 ART 分区）。不要跳过第 6 节。

### 0.3 这是“可编译工程”，不是已经编好的镜像

当前工作机是 Windows，没有 WSL/Docker，开启 WSL 需要重启，因此我无法在本机完成 2–4 小时的 Linux 交叉编译。工程把版本、feed、配置、补丁、CI 全部固定好，**第一次真实编译发生在 GitHub Actions**。如果 OAF 在 6.18 内核上遇到 API 变化，CI 日志会定位到具体文件和行号，按 `docs/TROUBLESHOOTING.md` 修即可。

---

## 1. 这套固件是什么

```
flint3 社区移植（qualcommbe/ipq53xx, kernel 6.18）
        ├── 板级：IPQ5332、RTL8372N DSA、RTL8221B 2.5G WAN、ath12k Wi-Fi 7
        ├── 路由：firewall4/nftables、dnsmasq、odhcpd、PPPoE
        ├── Web：LuCI + uhttpd + HTTPS
        └── OpenAppFilter 7.0.2
              ├── kmod-oaf        内核态 DPI/过滤
              ├── appfilter       oafd + rule_manager
              └── luci-app-oaf    仪表盘/应用过滤/行为管理/上网记录
```

### 和 FanchmWrt 的关系

[FanchmWrt](https://github.com/fanchmwrt/fanchmwrt) 是 OpenWrt 25.12 的中文发行版，核心的 `fwx` 套件就是 OpenAppFilter 的衍生版。它自带的目标只有 x86_64 和 Rockchip RK3528，**没有** `qualcommbe/ipq53xx`，所以不能直接拿它的树编 BE9300。

本工程取两者的交集：

- **设备层**用唯一公开可编译的 BE9300 移植（flint3）
- **过滤引擎**用上游 OAF 7.0.2（FanchmWrt fwx 的上游，包更少、集成风险更低）
- UI 是 OAF 自带的 LuCI 页面，不是 FanchmWrt 那 19 个 `luci-app-fwx-*`

如果你要的是完整 FanchmWrt 外观/应用中心，属于第二阶段：把 `fanchmwrt-packages` 和 `package/fcm` 移植进来。当前阶段优先保证**能编、能刷、能过滤**。

---

## 2. 基线

| 项 | 值 |
|---|---|
| 设备 | GL.iNet GL-BE9300（Flint 3） |
| SoC | Qualcomm IPQ5332，4×Cortex-A53 |
| 交换 | Realtek RTL8372N（DSA，`kmod-rtl837x-dsa`） |
| WAN PHY | RTL8221B 2.5G（USXGMII） |
| 无线 | IPQ5332 2.4G + 2×QCN9274（5G/6G），ath12k |
| 存储 | eMMC |
| 底座 | [perceival/openwrt-flint3](https://github.com/perceival/openwrt-flint3) `ref-20260930`（commit `88d31e0`） |
| 内核 | 6.18 |
| 过滤 | [destan19/OpenAppFilter](https://github.com/destan19/OpenAppFilter) 7.0.2（commit `0814b87`） |
| 包管理 | apk（25.12 线） |

版本全部固定在 [`versions.env`](versions.env) 和 [`feeds.conf`](feeds.conf)，不跟随分支漂移。

---

## 3. 功能与默认行为

- **LuCI over HTTPS**：`luci-ssl-openssl`，首次登录 `https://192.168.1.1`
- **OAF**：应用识别、应用过滤、MAC 黑白名单、上网记录、流量统计、在线用户
- **默认关闭硬件/软件 flow offload**：`be9300-defaults` 在首次启动写入
  `firewall.@defaults[0].flow_offloading=0`、`flow_offloading_hw=0`，并把
  `fwx.advanced.disable_hnat` 设为 `1`
- **强制 conntrack 计数**：把 `CONFIG_NF_CONNTRACK_ACCT=y` 写进内核配置（`oaf/Makefile` 的 `KCONFIG` + 子目标 `config-default`）。该符号 Linux 默认关闭，不打开时 `nf_conn_acct_find()` 返回 NULL，OAF 会“模块加载成功但完全不识别”，很容易误判
- **保留回厂能力**：镜像包含 `dumpimage`，flint3 的 `glinet-upgrade.sh` 可以解包原厂 FIT
- **救援 initramfs**：配置开启 `CONFIG_TARGET_ROOTFS_INITRAMFS`，出 `.itb`

> 关闭 offload 会牺牲吞吐：PPE 硬件加速下 NAT 可达 ~2.3 Gbit/s，关闭后受 CPU 限制。DPI 必须看到每个包，这是功能前提，不是配置遗漏。想要满速就不要再开 OAF。

---

## 4. 快速开始：GitHub Actions 云编译

### 4.1 建仓库

把本目录推到你的 GitHub 仓库（公开仓库不消耗 Actions 额度）：

```bash
git init
git add .
git commit -m "FanchmWrt BE9300 + OpenAppFilter"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

私有仓库也可以，但一次构建约 200–300 分钟，会消耗账户额度。

### 4.2 运行

1. 打开仓库 **Actions** → **build-be9300** → **Run workflow**
2. 参数：
   - `release`：勾选后构建成功自动建 Release
   - `verbose`：`make V=s`，只在排错时开
   - `jobs`：默认 4；2 核 runner 选 2 更稳
3. 等待 2–4 小时（首次含工具链）

### 4.3 产物

Actions 运行页底部 **Artifacts** 下载 `be9300-oaf-*`：

| 文件 | 用途 |
|---|---|
| `*-factory.bin` | **从原厂刷**，`sysupgrade -F -n` |
| `*-sysupgrade.bin` | 从已有 OpenWrt 升级 |
| `*-initramfs-uImage.itb` | TFTP/RAM 救援启动 |
| `*.manifest` | 包清单，核对 OAF 是否在 |
| `sha256sums` | 校验 |

### 4.4 如果 CI 失败

先看 `build-logs-*` 里的 `build.log` 末尾和 `logs/`。常见问题：

- `kmod-oaf` 编译错误：6.18 内核 API 变化，日志会给出 `oaf/src/*.c:行号`
- `make download` 404：feed 快照或镜像临时不可达，重跑一次
- 磁盘不足：runner 清理后仍 <22 GiB，换 larger runner
- 超时：减少包或改用本地 8 核

详见 [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)。

---

## 5. 本地编译（Ubuntu）

```bash
sudo apt-get update
sudo apt-get install -y build-essential clang flex bison g++ gawk \
  gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
  python3 python3-setuptools python3-pyelftools rsync unzip zlib1g-dev \
  file wget curl ccache libelf-dev bc libtool automake autoconf \
  pkg-config time xsltproc cpio swig

git clone https://github.com/<you>/<repo>.git
cd <repo>
chmod +x scripts/*.sh
./scripts/build.sh --jobs "$(nproc)"
```

首次约 20–30 GB 磁盘。产物在 `out/<时间戳>/`。

只重编某个包（改 OAF 源码后）：

```bash
cd work/openwrt
make package/oaf/{clean,compile} V=s
make package/appfilter/{clean,compile} V=s
make package/luci-app-oaf/{clean,compile} V=s
make -j"$(nproc)"
```

---

## 6. 刷机

**完整步骤、备份命令、回厂流程见 [`docs/FLASHING.md`](docs/FLASHING.md)。** 这里只给最短路径：

### 6.1 先备份（必须）

SSH 到原厂系统，把 eMMC 整盘镜像写到 U 盘/网络共享：

```sh
cat /proc/partitions
dd if=/dev/mmcblk0 of=/mnt/usb/be9300-emmc-backup.img bs=4M status=progress
sync
```

ART 分区保存本机唯一的无线校准数据和 MAC，丢了无法从别处恢复。

### 6.2 从原厂刷

```sh
scp *-factory.bin root@192.168.1.1:/tmp/
ssh root@192.168.1.1
sysupgrade -F -n /tmp/*-factory.bin
```

原厂镜像检查要求 QSDK FIT，`-F` 是必须的；提示 `u-boot`/`tz`/`sb11` 缺 section 属预期。**不要**用普通 sysupgrade 镜像从原厂刷。

### 6.3 从 OpenWrt 升级

```sh
sysupgrade -n /tmp/*-sysupgrade.bin
```

### 6.4 回原厂

下载你机器对应版本的 GL.iNet 原厂 `.bin`，按设备页的 return-to-stock 流程操作。参考：[GL-BE9300 device page](https://openwrt.org/toh/gl.inet/gl-be9300)。

---

## 7. 首次登录与验证

```sh
ssh root@192.168.1.1
```

```sh
# 1. 内核模块加载
lsmod | grep -E '^oaf'

# 2. 守护进程
/etc/init.d/appfilter status
ps | grep -E 'oafd|rule_manager' | grep -v grep

# 3. offload 已关闭（应为 0）
uci get firewall.@defaults[0].flow_offloading
uci get firewall.@defaults[0].flow_offloading_hw

# 4. OAF 配置
uci get fwx.advanced.disable_hnat   # 1
```

LuCI → **应用过滤** 应能看到仪表盘、应用列表、在线用户。首次打开页面后产生流量，几十秒内仪表盘应有数据。

如果没有数据：

```sh
logread | grep -iE 'oaf|appfilter'
cat /proc/net/oaf_active_app 2>/dev/null | head
```

并确认 `fwx.global.lan_ifname` 与实际 LAN 接口一致（默认 `br-lan`）。

---

## 8. 已知限制与风险

1. **不是原厂 23.05**：见 0.1 和 `docs/STOCK-23.05.md`。
2. **ath12k 固件崩溃**：社区移植的已知问题，持续负载数小时后可能 Q6 fatal；2026-09-28 后会自动 coredump 并在数秒内恢复 radios。
3. **内核 netlink panic**：社区报告偶发，约 90 秒自动重启；根因仍在查。
4. **OAF 与 6.18 的编译兼容性**：OAF 7.0.2 的源码已有 6.15/6.16 适配，但 6.18 是更新内核；首次 CI 可能暴露 `nf_conntrack`/timer API 细节。属于可修问题，不是设计缺陷。
5. **吞吐下降**：关闭 offload 后 NAT 走 CPU。
6. **802.11r 与 MLO 不兼容**：不要在 MLO SSID 上开 11r；11k/11v 正常。
7. **没有串口**：变砖只能靠 U-Boot/TFTP 或 eMMC 备份恢复。

---

## 9. 目录结构

```
.
├── .github/workflows/build.yml     # 云编译
├── configs/be9300-oaf.config      # seed config（make defconfig 前）
├── feeds.conf                     # 固定到 2026-09-30 的 feed 快照
├── versions.env                   # 底座/OAF commit
├── package/be9300-defaults/       # 首启关闭 offload + /etc/config/fwx
├── scripts/
│   ├── build.sh                   # 本地/CI 共用
│   ├── verify-config.sh           # defconfig 后检查关键符号
│   └── verify-image.sh            # 产物/manifest/校验和
├── docs/
│   ├── FLASHING.md                # 备份、刷机、回厂
│   ├── STOCK-23.05.md             # 保留原厂的可行路径
│   └── TROUBLESHOOTING.md         # 编译/运行排错
└── work/ , out/                   # 构建目录（gitignore）
```

---

## 10. 版本与可复现性

| 输入 | 固定值 |
|---|---|
| flint3 | tag `ref-20260930` / `88d31e06…` |
| OAF | `0814b87f…`（7.0.2） |
| packages feed | `95d73ebc…`（2026-09-30） |
| luci feed | `32775cf3…`（2026-09-28） |
| routing | `4b9891b9…` |
| telephony | `5d68d53c…` |
| video | `2baec75e…` |

`scripts/build.sh` 会校验 `HEAD == BASE_COMMIT`，tag 被移动时直接失败，不会静默编出别的版本。

---

## 11. 许可与致谢

- 本工程脚本/配置：MIT（可自行改）
- OpenWrt：GPL-2.0
- flint3 移植：见其仓库许可；社区维护，非 GL.iNet/OpenWrt 官方
- OpenAppFilter：GPL-2.0，作者 destan19；商业使用需联系作者授权
- FanchmWrt：其授权条款要求转载固件时附上仓库地址

> 本项目与 GL.iNet、OpenWrt、FanchmWrt 均无隶属关系。刷机风险自负。
