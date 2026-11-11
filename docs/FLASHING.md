# 刷机、备份与回厂

> 目标设备：GL.iNet GL-BE9300（Flint 3），IPQ5332，eMMC。
>
> 这台机器**没有可用的串口**，刷坏后只能靠 U-Boot/TFTP 或整盘备份恢复。请把本文从头读完再动手。

---

## 1. 刷机前必须做的事

### 1.1 记录设备信息

在原厂系统 SSH 里执行，把输出保存到电脑：

```sh
cat /etc/openwrt_release
cat /proc/version
cat /proc/partitions
ip -br link
for i in /sys/class/net/*/address; do echo "$i $(cat $i)"; done
```

MAC 地址、无线校准数据都在 eMMC 的 ART 分区里；ART 是**本机唯一**的，丢了无法从别处复制。

### 1.2 整盘备份 eMMC（强烈建议）

在原厂系统里，把 eMMC 直接流式传到电脑（不依赖 U 盘文件系统）：

```sh
# 在电脑上执行；gzip 可用 WSL/Git Bash/macOS/Linux
ssh root@192.168.1.1 'dd if=/dev/mmcblk0 bs=4M' | gzip -9 > be9300-emmc-backup.img.gz
```

或者在路由器上写到已挂载的 U 盘（文件系统需为 ext4/vfat，镜像默认带这两个驱动）：

```sh
cat /proc/partitions          # 确认 mmcblk0 和 U 盘设备名，别写错
dd if=/dev/mmcblk0 of=/mnt/usb/be9300-emmc-backup.img bs=4M status=progress
sync
```

备份大小约等于 eMMC 容量（通常 8 GB 级），压缩后 2–3 GB。**把文件放到另一台机器/云盘**，不要只留在路由器上。

### 1.3 准备恢复手段

- 下载并保存你当前版本的原厂固件（GL.iNet 下载中心：<https://dl.gl-inet.com/router/be9300/>）
- 准备一台能开 TFTP 的电脑和网线
- 读一遍 OpenWrt 设备页的 U-Boot 恢复章节：<https://openwrt.org/toh/gl.inet/gl-be9300>

---

## 2. 从原厂固件刷入

> 只使用产物里的 `*-factory.bin`。**不要**从原厂刷 `*-sysupgrade.bin`。

```sh
# 电脑上
scp openwrt-qualcommbe-ipq53xx-glinet_gl-be9300-squashfs-factory.bin \
    root@192.168.1.1:/tmp/

ssh root@192.168.1.1
df -h /tmp                     # 确认 /tmp 放得下（通常 tmpfs 一半内存）
sysupgrade -F -n /tmp/openwrt-qualcommbe-ipq53xx-glinet_gl-be9300-squashfs-factory.bin
```

说明：

- `-F` 必须加。原厂镜像校验要求 QSDK FIT，社区 factory 镜像不是 QSDK FIT。
- 提示 `u-boot` / `tz` / `sb11` 等 section 缺失是**预期**的：这些分区不会被覆盖。
- `-n` 表示不保留原厂配置（原厂和 OpenWrt 的配置格式不同，必须清）。
- 刷写后设备自动重启，等待 3–5 分钟。LAN 口默认地址 `192.168.1.1`，浏览器打开 `https://192.168.1.1`（自签证书，点继续）。
- 默认无密码，首次登录后立刻设置 root 密码。

如果 5 分钟后没有起来：

1. 网线接 LAN 口，看电脑是否拿到 `192.168.1.x` 地址
2. 断电重插，观察指示灯
3. 仍不行 → 进入第 5 节 U-Boot/TFTP 救援

---

## 3. 从已有 OpenWrt 升级

```sh
scp openwrt-qualcommbe-ipq53xx-glinet_gl-be9300-squashfs-sysupgrade.bin \
    root@192.168.1.1:/tmp/
ssh root@192.168.1.1
sysupgrade -n /tmp/openwrt-qualcommbe-ipq53xx-glinet_gl-be9300-squashfs-sysupgrade.bin
```

- 同 target 升级可去掉 `-n` 保留配置；跨大版本/首次刷入建议 `-n`
- 升级过程中不要断电

---

## 4. 首次启动后

1. 设置 root 密码
2. 配置 WAN（DHCP/PPPoE/静态）
3. 配置 Wi-Fi（默认关闭）
4. 打开 LuCI → **应用过滤**，确认仪表盘有数据
5. 确认 offload 已关闭：

```sh
uci get firewall.@defaults[0].flow_offloading        # 0
uci get firewall.@defaults[0].flow_offloading_hw     # 0
uci get fwx.advanced.disable_hnat                    # 1
lsmod | grep '^oaf'
```

如果 `flow_offloading` 不是 0（例如你恢复了旧配置），执行：

```sh
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall
/etc/init.d/firewall reload
/etc/init.d/appfilter restart
```

---

## 5. 变砖救援：U-Boot + TFTP initramfs

> 具体 U-Boot 菜单/命令以 OpenWrt 设备页为准；不同 bootloader 版本按键和地址可能不同。下面只给通用流程。

1. 电脑网卡设静态 IP `192.168.1.2/24`，网关不用填
2. 电脑开 TFTP 服务，根目录放 `*-initramfs-uImage.itb`
3. 网线接路由器 LAN 口
4. 断电，按住 Reset（或按设备页说明的按键）上电，进入 U-Boot
5. 在 U-Boot 里给设备设 IP，从电脑 TFTP 拉 initramfs 并启动：

```
setenv ipaddr 192.168.1.1
setenv serverip 192.168.1.2
tftpboot <loadaddr> openwrt-qualcommbe-ipq53xx-glinet_gl-be9300-initramfs-uImage.itb
bootm <loadaddr>
```

`<loadaddr>` 以设备页/U-Boot 环境为准（不同 bootloader 版本不同），不要照抄一个未经核对的地址。

6. initramfs 起来后（地址仍是 192.168.1.1），用 `sysupgrade` 刷 factory 或 sysupgrade 镜像，或从备份恢复

如果 U-Boot 也进不去，只能用 eMMC 备份 + 硬件编程器；这就是 1.2 必须备份的原因。

---

## 6. 回原厂

### 6.1 用原厂固件

1. 从 GL.iNet 下载中心下载对应型号/版本的原厂 `.bin`（建议就是你刷机前的版本）
2. 传到路由器 `/tmp`
3. 在 OpenWrt 上执行（镜像内置 `dumpimage`，flint3 的 `glinet-upgrade.sh` 会解包原厂 FIT）：

```sh
sysupgrade -F -n /tmp/openwrt-be9300-<version>.bin
```

> 这条路径在 flint3 的 README 里标注为 working，但不同原厂版本可能有差异。操作前先看设备页 "Return to stock" 一节；如果 `sysupgrade` 拒绝，改用 U-Boot TFTP 刷原厂镜像。

### 6.2 从整盘备份恢复

只有在你确认备份完整、且 U-Boot/TFTP 可用时再做：

```sh
# 在 initramfs 环境里，确认 mmcblk0 是 eMMC 后再执行
gunzip -c be9300-emmc-backup.img.gz | dd of=/dev/mmcblk0 bs=4M
sync
reboot
```

写错设备名会覆盖别的盘，执行前务必 `cat /proc/partitions` 核对。

---

## 7. 常见刷机问题

| 现象 | 原因/处理 |
|---|---|
| `sysupgrade` 报 image check 失败 | 从原厂刷必须 `-F`，且必须用 factory 镜像 |
| 刷完 ping 不通 192.168.1.1 | 等 5 分钟；检查网线是否 LAN；尝试 DHCP 获取；仍不行走 TFTP |
| 启动后 Wi-Fi 没有 | 默认关闭，需在 LuCI 里启用；确认国家码/信道 |
| 5G/6G 起不来 | 检查 `dmesg | grep ath12k`；DFS 信道可能需要等待 |
| 回原厂后配置还在 | 原厂恢复时执行 `-n` 或恢复后恢复出厂 |
| 刷完 MAC 变了 | 若刷过非本机备份的 ART/整盘镜像，MAC 会变；用本机备份恢复 |
