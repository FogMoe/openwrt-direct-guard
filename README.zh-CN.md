# direct-guard

[English](README.md)

`direct-guard` 是给运行透明代理的 OpenWrt 路由器用的“出口泄露保护”。你指定一些目标（域名、地址段），只要发往它们的流量准备从未被允许的网口离开路由器，就会被直接拒绝。这样即使代理没在运行，这些目标也永远不会被直连访问到。

## 为什么需要

PassWall、OpenClash，或者自己写的 sing-box、Xray TPROXY 方案，都是在路由之前把流量转给代理。代理运行时，流量不会自己走到 WAN；但代理没在运行、或者规则正在重载时就不是这样了：定时更新规则、改设置、进程崩溃、防火墙重载。这段时间里流量按正常路由走，直接从 WAN 出去。对大部分流量来说每天几秒无所谓，但对某些服务不行。

代理自身的规则管不到这段空窗期，因为那时代理根本没在运行。`direct-guard` 工作在防火墙层，不依赖代理的进程和规则，代理重启期间照样拦截。

## 工作原理

- 要保护的目标写在 **target** 里：地址段（`cidr`）和域名（`domain`）。域名由 dnsmasq 转成地址：受保护域名及其子域名的每次解析结果，会在返回给客户端之前加入地址集合。这些学到的地址每分钟保存到 `/etc/direct-guard/`，开机时恢复。
- 在 firewall4（OpenWrt 22.03 及以后）上，`direct-guard` 建立自己的 nftables 表 `inet direct_guard`，在 `filter - 10` 优先级挂 `forward` 和 `output` 两条链。它们排在 mangle 和 route 链之后，所以被代理打标记、走策略路由的流量，到这里时出口网卡已经确定。在 fw3 上则使用 ipset，以及插在 `FORWARD` 和 `OUTPUT` 第一位的 `DIRECT_GUARD` 链。
- 发往受保护目标的包，只有出口网卡是 `lo` 或在 `allow_dev` 列表里（默认 `br-lan`）才放行，其余一律拒绝并计数。用拒绝（reject）而不是丢弃（drop），连接会立刻失败，不会一直卡着。
- 走代理的流量不会碰到这些规则：TPROXY 和 REDIRECT 把它交给路由器本机的代理程序，代理程序自己连的是代理服务器，不是受保护的目标。
- dnsmasq 规则写在 `/etc/dnsmasq.conf` 里一段由程序管理的区块中。OpenWrt 自带的 dnsmasq 会读这个文件；自己另起 dnsmasq 并带上 `conf-file=/etc/dnsmasq.conf` 的代理（例如 PassWall）也会读。
- 通过防火墙 include，每次防火墙重载后自动重新应用规则。

## 它不做什么

- 只拦截发往受保护目标的包，不隐藏 DNS 查询或其他流量。
- 域名学习只能看到经过 dnsmasq 的 DNS。自己用 DoH、DoT 或写死 DNS 服务器的设备会绕过它；要覆盖这些设备，请把服务的地址段写进 `cidr`。
- 从允许的网口出去的流量不做过滤。
- **TUN 模式**的代理会把流量路由到 tun 网卡。要把这块网卡加进 `allow_dev`，否则走代理的流量也会被拦。
- 使用 fake-IP DNS 时，dnsmasq 学到的是假地址，看不到真实地址，请改用 `cidr`。
- 学到的地址会一直保留，直到执行 `direct-guard forget`。CDN 地址可能和其他网站共用，但只有准备直连出去的流量才会被拦。
- 它是一道兜底保护，不能代替正确的代理配置。

## 运行要求

- 使用 firewall4 和 nftables 的 OpenWrt（22.03 起的默认配置），或者装有 `iptables`、`ipset`、`kmod-ipt-ipset` 的 fw3 固件。
- 要保护域名，需要 `dnsmasq-full`（firewall4 下需要 nftset 支持，fw3 下需要 ipset 支持）。没有它时只保护 `cidr` 地址段，`direct-guard` 会给出提示。

## 安装

从[最新发布](https://github.com/FogMoe/openwrt-direct-guard/releases/latest)下载安装包，它与 CPU 架构无关。

```sh
# OpenWrt 25.12 及以后（apk）
apk add --allow-untrusted ./direct-guard-*.apk

# OpenWrt 24.10 及以前（opkg）
opkg install ./direct-guard_*_all.ipk
```

安装后默认是关闭的。要保护域名，请把 `dnsmasq` 换成 `dnsmasq-full`，`/etc/config/dhcp` 会保留。

```sh
# apk 可以直接替换
apk update && apk add dnsmasq-full

# opkg 不能直接替换。要先把所需的包都下载好，
# 因为路由器自己就是靠即将卸载的 dnsmasq 解析域名的
opkg update
cd /tmp && opkg download dnsmasq-full
opkg install $(opkg info dnsmasq-full | sed -n 's/^Depends: //p' | sed 's/([^)]*)//g; s/,/ /g')
opkg remove dnsmasq
opkg install /tmp/dnsmasq-full_*.ipk
```

## 配置

在 `/etc/config/direct-guard` 里写明要保护的目标，启用后重启服务：

```sh
uci delete direct-guard.example
uci set direct-guard.service=target
uci add_list direct-guard.service.domain='example.com'
uci add_list direct-guard.service.cidr='192.0.2.0/24'
uci add_list direct-guard.service.cidr='2001:db8::/32'
uci set direct-guard.main.enabled='1'
uci commit direct-guard
service direct-guard restart
direct-guard status
```

`config global 'main'` 的选项：

| 选项 | 默认值 | 含义 |
| --- | --- | --- |
| `enabled` | `0` | 是否启用。 |
| `backend` | `auto` | `nft`、`iptables`，或 `auto`（firewall4 用 nft，fw3 用 iptables）。 |
| `allow_dev` | `br-lan` | 允许承载受保护目标流量的出口网卡。`lo` 始终允许。末尾的 `*` 是通配符，例如 `tun*`。 |
| `learn` | `1` | 是否通过 dnsmasq 学习 `domain` 的地址。 |
| `dnsmasq_conf` | `/etc/dnsmasq.conf` | 写入 dnsmasq 管理区块的文件。 |
| `dnsmasq_restart` | `1` | 区块变化时是否重启 OpenWrt 自带的 dnsmasq。 |
| `snapshot_interval` | `60` | 保存学到地址的间隔秒数（最少 10）。 |
| `log` | `0` | 是否把被拒绝的包记到内核日志，每分钟最多 10 条，前缀为 `direct-guard: `。 |

每个 `config target` 段包含 `domain` 和 `cidr` 两个列表，以及可选的 `enabled`。域名会同时覆盖它的子域名，开头的 `*.` 会被忽略。

### 各代理的注意事项

- **PassWall**（TPROXY 或 REDIRECT 方式）开箱即用。它自己的 dnsmasq 会在 PassWall 下次重启时读到管理区块，比如每天的规则更新之后，或执行 `/etc/init.d/passwall restart` 之后。
- **TUN 模式**（OpenClash、mihomo、sing-box 等）：把 tun 网卡加进 `allow_dev`。代理运行时可以用 `ip link` 查看网卡名。
- 需要访问受保护目标的**其他内网网桥或 VPN**，比如访客网络、WireGuard 隧道，也要加进 `allow_dev`。

## 使用

| 命令 | 作用 |
| --- | --- |
| `direct-guard status` | 显示后端、目标、学到的地址、被拒绝的包数和 dnsmasq 区块。 |
| `direct-guard apply` | 应用配置；`enabled` 为 `0` 时移除全部规则。 |
| `direct-guard remove` | 移除规则、地址集合和 dnsmasq 区块。 |
| `direct-guard snapshot` | 立即保存学到的地址。 |
| `direct-guard forget` | 清空学到的地址。 |

`service direct-guard stop` 只会停掉定时保存的后台进程，规则仍然保留，停服务不会让保护失效。要关闭保护，请把 `enabled` 设为 `0` 再重启服务，或者执行 `direct-guard remove`。

## 卸载

```sh
apk del direct-guard        # 或：opkg remove direct-guard
```

卸载会移除规则、地址集合、dnsmasq 区块和防火墙 include。学到的地址保留在 `/etc/direct-guard/`，不需要的话可以手动删除。

## 从源码构建

把本仓库作为 OpenWrt SDK 或 buildroot 的 feed：

```sh
echo "src-git directguard https://github.com/FogMoe/openwrt-direct-guard.git" >> feeds.conf
./scripts/feeds update directguard
./scripts/feeds install direct-guard
make package/direct-guard/compile
```

## 开发

```sh
bash scripts/test.sh                       # ShellCheck、shfmt 和单元测试
sudo bash tests/integration.sh nft         # 在网络命名空间里用真实的 netfilter 测试
sudo bash tests/integration.sh iptables
docker run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" \
  openwrt/rootfs:x86_64-25.12.6 /bin/sh /src/tests/openwrt.sh /src
```

集成测试需要 `nftables`、`iptables`、`ipset`、`iproute2`、`iputils-ping`、`busybox`；dnsmasq 相关测试还需要支持 nftset 和 ipset 的 `dnsmasq`。

## 许可证

[MIT](LICENSE)
