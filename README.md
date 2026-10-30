# direct-guard

[中文说明](README.zh-CN.md)

`direct-guard` is a fail-closed egress guard for OpenWrt routers that run a
transparent proxy. It rejects traffic to the destinations you choose whenever
that traffic is about to leave the router through an interface you have not
allowed, so those destinations are never reached directly, even while the
proxy is down.

## Why

Transparent proxies such as PassWall, OpenClash or hand-written sing-box and
Xray TPROXY setups divert traffic before it is routed. While they run, nothing
reaches the WAN on its own. That stops being true whenever the proxy is not
running or its rules are being reloaded: a scheduled rule update, a settings
change, a crash or a firewall reload. During that window, traffic is routed
normally and leaves through the WAN directly. For a few seconds a day this may
not matter for most traffic, but for some services it does.

Rules inside the proxy cannot cover this window, because the proxy is not
running. `direct-guard` lives in the firewall, does not depend on the proxy's
processes or rules, and keeps blocking while the proxy restarts.

## How it works

- Destinations come from **targets**: address ranges (`cidr`) and domains
  (`domain`). Domains are turned into addresses by dnsmasq: every answer for
  a protected domain, or any of its subdomains, is added to a set before the
  client receives it. These learned addresses are saved to `/etc/direct-guard/`
  every minute and restored at boot.
- With firewall4 (OpenWrt 22.03 and later), `direct-guard` adds its own
  nftables table, `inet direct_guard`, with `forward` and `output` chains at
  priority `filter - 10`. They run after mangle and route chains, so traffic
  that a proxy marks for policy routing already has its final output device.
  With fw3, it uses ipsets and a `DIRECT_GUARD` chain placed first in
  `FORWARD` and `OUTPUT`.
- A packet to a protected destination is allowed only if its output device is
  `lo` or listed in `allow_dev` (default `br-lan`). Anything else is rejected
  and counted. Rejecting, rather than dropping, makes connections fail at once
  instead of hanging.
- Proxied traffic never reaches these rules: TPROXY and REDIRECT deliver it to
  the proxy on the router itself, and the proxy's own connections go to the
  proxy server, not to the protected destination.
- dnsmasq rules are kept in a managed block in `/etc/dnsmasq.conf`. OpenWrt's
  dnsmasq reads that file, and so do proxies that run their own dnsmasq with
  `conf-file=/etc/dnsmasq.conf`, such as PassWall.
- A firewall include re-applies the rules after every firewall reload.

## What it does not do

- It only stops packets to protected destinations. It does not hide DNS
  queries or other traffic.
- Domain learning only sees DNS that goes through dnsmasq. Devices with their
  own DNS-over-HTTPS, DNS-over-TLS or hard-coded resolvers bypass it. Add the
  service's address ranges as `cidr` to cover them.
- Traffic that leaves through an allowed device is not filtered.
- Proxies in **TUN mode** route traffic to a tun device. Add that device to
  `allow_dev`, or the proxied traffic is blocked as well.
- With fake-IP DNS, dnsmasq learns fake addresses and never sees the real
  ones. Add `cidr` ranges instead.
- Learned addresses are kept until you run `direct-guard forget`. A CDN
  address can be shared with other sites; it is only blocked for traffic that
  would go out directly.
- It is a safety net, not a substitute for a correct proxy setup.

## Requirements

- OpenWrt with firewall4 and nftables (the default since 22.03), or a fw3
  build with `iptables`, `ipset` and `kmod-ipt-ipset`.
- `dnsmasq-full` to guard domains (nftset support with firewall4, ipset
  support with fw3). Without it, only `cidr` ranges are guarded and
  `direct-guard` says so.

## Install

Download the package from the
[latest release](https://github.com/FogMoe/openwrt-direct-guard/releases/latest).
It is architecture independent.

```sh
# OpenWrt 25.12 and later (apk)
apk add --allow-untrusted ./direct-guard-*.apk

# OpenWrt 24.10 and earlier (opkg)
opkg install ./direct-guard_*_all.ipk
```

The package is installed disabled. To guard domains, replace `dnsmasq` with
`dnsmasq-full`. Your `/etc/config/dhcp` is kept.

```sh
# apk replaces dnsmasq in place
apk update && apk add dnsmasq-full

# opkg cannot: fetch everything first, because the router resolves names
# through the dnsmasq you are about to remove
opkg update
cd /tmp && opkg download dnsmasq-full
opkg install $(opkg info dnsmasq-full | sed -n 's/^Depends: //p' | sed 's/([^)]*)//g; s/,/ /g')
opkg remove dnsmasq
opkg install /tmp/dnsmasq-full_*.ipk
```

## Configure

Describe what to protect in `/etc/config/direct-guard`, enable it, and
restart the service:

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

Options of `config global 'main'`:

| Option | Default | Meaning |
| --- | --- | --- |
| `enabled` | `0` | Turn the guard on. |
| `backend` | `auto` | `nft`, `iptables`, or `auto` (nft with firewall4, iptables with fw3). |
| `allow_dev` | `br-lan` | Output devices that may carry traffic to protected destinations. `lo` is always allowed. A trailing `*` is a wildcard, such as `tun*`. |
| `learn` | `1` | Learn the addresses of `domain` entries through dnsmasq. |
| `dnsmasq_conf` | `/etc/dnsmasq.conf` | File that receives the managed dnsmasq block. |
| `dnsmasq_restart` | `1` | Restart OpenWrt's dnsmasq when the block changes. |
| `snapshot_interval` | `60` | Seconds between saves of learned addresses (at least 10). |
| `log` | `0` | Log rejected packets to the kernel log, at most 10 per minute, with the prefix `direct-guard: `. |

Each `config target` section takes `domain` and `cidr` lists and an optional
`enabled`. A domain covers its subdomains, and a leading `*.` is ignored.

### Notes for proxies

- **PassWall** (TPROXY or REDIRECT) works as is. Its own dnsmasq picks up the
  managed block the next time PassWall restarts, for example after its daily
  rule update or `/etc/init.d/passwall restart`.
- **TUN mode** (OpenClash, mihomo, sing-box and others): add the tun device to
  `allow_dev`. Check its name with `ip link` while the proxy runs.
- **Other LAN bridges or VPNs** that should reach protected destinations,
  such as a guest network or a WireGuard tunnel, also go in `allow_dev`.

## Use

| Command | What it does |
| --- | --- |
| `direct-guard status` | Show the backend, targets, learned addresses, rejected packets and the dnsmasq block. |
| `direct-guard apply` | Apply the configuration. When `enabled` is `0`, remove everything. |
| `direct-guard remove` | Remove the rules, the sets and the dnsmasq block. |
| `direct-guard snapshot` | Save learned addresses now. |
| `direct-guard forget` | Clear learned addresses. |

`service direct-guard stop` only stops the snapshot watcher. The rules stay
in place, so stopping the service does not open the gate. To turn the guard
off, set `enabled` to `0` and restart the service, or run
`direct-guard remove`.

## Uninstall

```sh
apk del direct-guard        # or: opkg remove direct-guard
```

This removes the rules, the sets, the dnsmasq block and the firewall include.
Learned addresses stay in `/etc/direct-guard/`; delete that directory if you
no longer need them.

## Build from source

Add this repository as a feed of an OpenWrt SDK or buildroot:

```sh
echo "src-git directguard https://github.com/FogMoe/openwrt-direct-guard.git" >> feeds.conf
./scripts/feeds update directguard
./scripts/feeds install direct-guard
make package/direct-guard/compile
```

## Development

```sh
bash scripts/test.sh                       # ShellCheck, shfmt and unit tests
sudo bash tests/integration.sh nft         # real netfilter in network namespaces
sudo bash tests/integration.sh iptables
docker run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" \
  openwrt/rootfs:x86_64-25.12.6 /bin/sh /src/tests/openwrt.sh /src
```

The integration tests need `nftables`, `iptables`, `ipset`, `iproute2`,
`iputils-ping`, `busybox` and, for the dnsmasq tests, `dnsmasq` with nftset
and ipset support.

## License

[MIT](LICENSE)
