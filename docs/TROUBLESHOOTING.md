# 排错手册

按阶段定位，不要一上来就改代码。

| 阶段 | 典型现象 | 先看 |
|---|---|---|
| 配置 | `config verification failed` | `work/openwrt/.config` |
| 下载 | `make download` 404/超时 | `work/openwrt/dl`、网络 |
| 编译 | `make` 在某个包退出 | `out/*/build.log`、`work/openwrt/logs/` |
| 镜像 | 没有 factory/sysupgrade | `bin/targets/qualcommbe/ipq53xx/` |
| 启动 | 刷完不亮/无 DHCP | U-Boot/TFTP、eMMC 备份 |
| 运行 | OAF 页面无数据 | `lsmod`、offload、内核 config |

---

## 1. CI 失败先看哪里

Actions 运行页 → 失败的 job：

1. **Show failure context** 步骤：`build.log` 末尾 200 行
2. Artifacts → `build-logs-*`：完整 `build.log` + `logs/`
3. 本地复现：`./scripts/build.sh --jobs 4 --verbose`

`build.log` 里搜 `Error 1`，往上找最后一个 `make[3]` 进入的包目录。

---

## 2. `config verification failed`

脚本 `scripts/verify-config.sh` 会列出缺的符号。常见原因：

### 2.1 `CONFIG_PACKAGE_kmod-oaf` 不是 `=y`

说明依赖被解析成模块 `=m`，镜像不会带 `.ko`。在 `configs/be9300-oaf.config` 里已有显式 `=y`；如果仍失败，检查 OAF 包是否真的被 feeds 识别：

```bash
cd work/openwrt
./scripts/feeds list -r 2>/dev/null | grep -i oaf
ls package/OpenAppFilter/oaf/Makefile
grep -n 'KCONFIG' package/OpenAppFilter/oaf/Makefile
```

### 2.2 缺 `luci-app-oaf` / `luci-compat` / `luci-lib-jsonc`

OAF clone 失败，或 luci feed 没装：

```bash
ls package/OpenAppFilter
ls package/feeds/luci/luci-compat
```

重新跑 `./scripts/build.sh --refresh-feeds`。

### 2.3 缺 `firewall4` / `dnsmasq`

说明 `make defconfig` 没把它当路由器。检查 `.config` 里 target 三行是否都在：

```bash
grep '^CONFIG_TARGET_qualcommbe' .config
```

如果 target 对但 firewall4 仍 `not set`，多半是从别的配置残留了 `# CONFIG_PACKAGE_firewall4 is not set`。删掉 `.config` 重新 `make defconfig`，不要手工改生成后的 `.config`。

### 2.4 缺 `be9300-defaults`

overlay 没拷进去：

```bash
ls work/openwrt/package/be9300-defaults/Makefile
```

---

## 3. OAF 编译错误

OAF 是树外内核模块，内核 6.18 上的报错主要集中在三处。

### 3.1 `nf_conn_acct_find` 返回 NULL / 没有计数

**不是编译错误，是运行时空转。** 内核 `CONFIG_NF_CONNTRACK_ACCT` 默认 `n`，而 `kmod-nf-conntrack` 不会自动选它。没有它，`nf_conn_acct_find()` 返回 NULL，`fwx_hook_gateway_handle()` 直接 `return NF_ACCEPT`，模块加载正常但永远不识别。

本工程已经在两处强制打开：

- `package/OpenAppFilter/oaf/Makefile` 的 `KCONFIG:=CONFIG_NF_CONNTRACK_ACCT=y`
- `target/linux/qualcommbe/ipq53xx/config-default` 追加同名符号

验证（构建后）：

```bash
grep NF_CONNTRACK_ACCT work/openwrt/build_dir/target-*/linux-*/linux-*/.config
```

运行时无法直接看，但可以确认 `/proc/net/nf_conntrack` 的计数在增长，以及 OAF 仪表盘有数据。

### 3.2 `struct nf_conn has no member named 'mark'`

`ct->mark` 只在 `CONFIG_NF_CONNTRACK_MARK=y` 时存在。OpenWrt 的 `kmod-nf-conntrack` 已经设置该符号；如果你用的是自定义内核配置，补上：

```
CONFIG_NF_CONNTRACK_MARK=y
```

### 3.3 `nf_send_reset` 参数不匹配

OAF 用版本宏选择签名：

```c
#if LINUX_VERSION_CODE > KERNEL_VERSION(5,10,197)
	nf_send_reset(&init_net, skb->sk, skb, NF_INET_PRE_ROUTING);
#endif
```

6.18 的签名是 `nf_send_reset(struct net *, const struct sock *, struct sk_buff *, int)`，能对上。如果未来内核再改，按报错调整这一处即可。

### 3.4 `implicit declaration of function`

GCC 14 默认把隐式声明当错误。构建脚本已把 OAF 的

```
TARGET_CFLAGS +=-Werror=implicit-function-declaration
```

改成 `-Wno-error=...`。如果仍有某个函数没声明，正确做法是补 `#include`，不是长期关警告。

### 3.5 `modpost: undefined symbol`

通常是 `kmod-oaf` 的依赖没选全。确认：

```bash
grep -E 'CONFIG_PACKAGE_kmod-(nf-conntrack|nf-reject)=' .config
```

OAF 的 `oaf/Makefile` 已声明 `DEPENDS:=+kmod-nf-conntrack +kmod-nf-reject`。

### 3.6 迭代单包

改完源码不要重编整机：

```bash
cd work/openwrt
make package/oaf/{clean,compile} V=s
make package/appfilter/{clean,compile} V=s
make package/luci-app-oaf/{clean,compile} V=s
make -j"$(nproc)"
```

`V=s` 的输出直接指出 `oaf/src/xxx.c:行号`。

### 3.7 内核编译报 `-Werror`

如果内核开了 `CONFIG_WERROR=y`，OAF 的旧式代码会被拦。两个选择：

- 在 `oaf/Makefile` 的 `KCFLAGS` 末尾加 `-Wno-error`
- 或全局关 `CONFIG_WERROR`（不推荐，会掩盖其他问题）

---

## 4. feed / 下载问题

### 4.1 `make download` 404

feed 固定在 2026-09-30 的 commit；如果上游镜像临时不可达，重跑。仍失败：

```bash
cd work/openwrt
make -j1 download V=s
```

看是哪个 URL。若是 `git.openwrt.org` 的旧地址，检查 `feeds.conf.default` 是否被覆盖成了本工程的 GitHub 镜像版。

### 4.2 `fatal: could not read Username`

说明某个 feed/仓库变成私有或地址写错。本工程只用公开仓库；检查 `feeds.conf` 和 `versions.env` 是否被改。

### 4.3 下载很慢/挂住

OpenWrt 的 `download.pl` 会重试多个镜像。可以设：

```bash
export CURL_OPTIONS="--speed-limit 51200 --speed-time 60"
```

连续 60 秒低于 50 KB/s 就放弃当前镜像。

---

## 5. 磁盘与时间

- 完整构建约 20–30 GB。CI 清理后要求 ≥22 GiB。
- 本地磁盘不够：

```bash
cd work/openwrt
make dirclean          # 清 build_dir/staging_dir，保留 dl/
```

- CI 355 分钟超时：
  - 减包：去掉 `CONFIG_PACKAGE_tcpdump/iperf3/htop` 等
  - 关 initramfs：`# CONFIG_TARGET_ROOTFS_INITRAMFS is not set`（但失去救援镜像）
  - 用 larger runner 或本地 8 核

---

## 6. 镜像检查失败

### 6.1 没有 `*factory*.bin`

说明 `glinet_gl-be9300` profile 没选中，或 image 定义被改。检查：

```bash
grep '^CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_glinet_gl-be9300=y' .config
grep -n 'glinet_gl-be9300' target/linux/qualcommbe/image/ipq53xx.mk
```

### 6.2 `sha256sums verification failed`

复制不完整。重新下载 Artifacts，不要在浏览器里中断。

### 6.3 `KERNEL_SIZE` 超限

flint3 对 BE9300 有 `KERNEL_SIZE := 7168k` 保护（原厂 `0:HLOS` 分区只有 7 MiB）。OAF 是模块，一般不会把内核撑大；如果你开了 `CONFIG_DEBUG`/`gdbserver`/额外内核驱动，关掉再编。

---

## 7. 刷机后起不来

1. 等 5 分钟（首次启动会生成 SSH key、初始化 overlay）
2. 电脑设静态 `192.168.1.2/24`，访问 `https://192.168.1.1`
3. 看 LAN 口灯、路由器灯
4. 仍不行 → `docs/FLASHING.md` 第 5 节 U-Boot/TFTP

常见原因：

- 从原厂刷了 `sysupgrade.bin` 而不是 `factory.bin`
- 没加 `-F`
- 刷机过程中断电
- eMMC 分区被旧固件占用（回厂/恢复备份）

---

## 8. 运行期 OAF 没数据

按顺序排查：

### 8.1 模块是否加载

```bash
lsmod | grep '^oaf'
# 空 → 镜像里没有，或 modprobe 失败
modprobe oaf; dmesg | tail -n 30
```

### 8.2 服务是否在跑

```bash
/etc/init.d/appfilter status
ps | grep -E 'oafd|rule_manager' | grep -v grep
logread | grep -iE 'oaf|appfilter' | tail -n 50
```

`oafd` 起不来常见原因：缺 `libcurl`/`libsqlite3`（`ldd /usr/bin/oafd`）、`/tmp/oaf` 不可写、配置损坏。

### 8.3 offload 是否真的关了

```bash
uci show firewall | grep flow_offloading
```

必须是 `0`。改完 `uci commit firewall && /etc/init.d/firewall reload`。

### 8.4 LAN 接口名是否匹配

```bash
uci get fwx.global.lan_ifname     # 默认 br-lan
ip -br link | grep -E 'br-lan|lan'
```

如果 LAN 不是 `br-lan`（例如你改了 bridge 名），改成实际名称：

```bash
uci set fwx.global.lan_ifname='br-lan'
uci commit fwx
/etc/init.d/appfilter restart
```

### 8.5 流量路径是否经过路由器

OAF 只看**经过转发**的流量。同一交换机内客户端互访、或客户端走旁路网关，都不会出现在仪表盘。

### 8.6 内核 ACCT 是否生效

```bash
grep NF_CONNTRACK_ACCT work/openwrt/build_dir/target-*/linux-*/linux-*/.config
```

必须是 `=y`。若为 `n`，回到 3.1，检查构建脚本是否执行了追加。

---

## 9. LuCI 打不开 / 404

- 清浏览器缓存，换无痕窗口
- `https://192.168.1.1/cgi-bin/luci`
- 确认 `luci-compat`、`luci-lib-jsonc`、`luci-lib-nixio` 已安装：

```bash
apk list --installed 2>/dev/null | grep -E 'luci-(compat|lib-jsonc|lib-nixio)'
```

- 重启 Web 服务：

```bash
/etc/init.d/uhttpd restart
/etc/init.d/rpcd restart
```

---

## 10. 吞吐下降

这是关闭 offload 的预期结果。测速：

```bash
iperf3 -s          # 路由器
iperf3 -c 192.168.1.1 -t 30
```

如果确实需要满速且不需要过滤：

```bash
uci set fwx.appfilter.enable='0'
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit
/etc/init.d/firewall reload
/etc/init.d/appfilter restart
```

反过来，重新启用过滤时把 offload 关回去并重启 OAF。

---

## 11. 需要更多帮助

收集这些再发：

```bash
cat /etc/openwrt_release
uname -a
lsmod | grep '^oaf'
logread | tail -n 200
uci show fwx
uci show firewall | grep -E 'flow_offloading|fullcone'
cat /proc/net/nf_conntrack | wc -l
```

以及 CI 的 `build-logs-*` 或本地 `out/*/build.log`。
