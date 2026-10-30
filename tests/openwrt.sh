#!/bin/sh
# Runs inside an openwrt/rootfs container with CAP_NET_ADMIN. Installs the
# package files by hand and exercises them with the real uci, BusyBox ash,
# firewall4 and nftables of that release.
# Usage: tests/openwrt.sh [source directory]

set -u

SRC=${1:-/src}
FILES="$SRC/direct-guard/files"
failures=0

pass() { printf 'ok - %s\n' "$*"; }
fail() {
	printf 'not ok - %s\n' "$*"
	failures=$((failures + 1))
}
check() {
	desc=$1
	shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
check_not() {
	desc=$1
	shift
	if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}
has_table() { nft list table inet direct_guard; }

grep -m1 DISTRIB_DESCRIPTION /etc/openwrt_release
mkdir -p /usr/share/direct-guard /var/lock
if [ "${DG_TEST_DNSMASQ_FULL:-0}" = 1 ]; then
	if command -v apk >/dev/null 2>&1; then
		apk update >/dev/null 2>&1 && apk del dnsmasq >/dev/null 2>&1
		apk add dnsmasq-full >/dev/null 2>&1
	else
		opkg update >/dev/null 2>&1 && opkg remove dnsmasq >/dev/null 2>&1
		opkg install dnsmasq-full >/dev/null 2>&1
	fi
	check "dnsmasq-full is installed" sh -c 'dnsmasq --version | grep -m1 "Compile time options:" | grep -qE "[ :]nftset( |$)"'
fi
cp "$FILES/direct-guard.sh" /usr/sbin/direct-guard
cp "$FILES/direct-guard.init" /etc/init.d/direct-guard
cp "$FILES/firewall.include" /usr/share/direct-guard/firewall.include
cp "$FILES/direct-guard.config" /etc/config/direct-guard
chmod 755 /usr/sbin/direct-guard /etc/init.d/direct-guard /usr/share/direct-guard/firewall.include

check "the init script parses" sh -n /etc/init.d/direct-guard
sh "$FILES/direct-guard.uci-defaults"
check "uci-defaults registers the firewall include" \
	[ "$(uci -q get firewall.direct_guard.path)" = /usr/share/direct-guard/firewall.include ]
sh "$FILES/direct-guard.uci-defaults"
check "uci-defaults is idempotent" [ "$(uci show firewall | grep -c '^firewall.direct_guard=')" = 1 ]
if [ -x /sbin/fw4 ]; then
	check_not "the fw3-only reload option is not set with fw4" uci -q get firewall.direct_guard.reload
fi

check "apply succeeds while disabled" direct-guard apply
check_not "nothing is created while disabled" has_table

uci set direct-guard.main.enabled=1
uci set direct-guard.example.enabled=1
uci add_list direct-guard.example.cidr=198.51.100.0/24
uci add_list direct-guard.example.cidr=2001:DB8:1::/48
uci add_list direct-guard.example.domain=Example.ORG
uci commit direct-guard
check "apply succeeds" direct-guard apply
check "the nftables table exists" has_table
check "auto selects nftables" sh -c 'direct-guard status | grep -q "active (nft)"'
check "static IPv4 ranges are loaded" nft get element inet direct_guard static4 '{ 192.0.2.1 }'
check "list options are read with the real uci" nft get element inet direct_guard static4 '{ 198.51.100.9 }'
check "static IPv6 ranges are loaded" nft get element inet direct_guard static6 '{ 2001:db8::1 }'
check "br-lan is allowed" sh -c 'nft list chain inet direct_guard forward | grep -q "oifname \"br-lan\" return"'

check "IPv6 ranges are lowercased" nft get element inet direct_guard static6 '{ 2001:db8:1::1 }'

if dnsmasq --version 2>/dev/null | grep -m1 'Compile time options:' | grep -qE '[ :]nftset( |$)'; then
	check "the dnsmasq block is written" grep -qxF \
		'nftset=/example.com/4#inet#direct_guard#learn4,6#inet#direct_guard#learn6' /etc/dnsmasq.conf
	check "domains are lowercased" grep -q '^nftset=/example.org/' /etc/dnsmasq.conf
	check "dnsmasq accepts the generated configuration" dnsmasq --test -C /etc/dnsmasq.conf
else
	check_not "no dnsmasq block without nftset support" grep -q 'BEGIN direct-guard' /etc/dnsmasq.conf
fi

check "the firewall include re-applies" sh /usr/share/direct-guard/firewall.include
check "the table survives re-applying" has_table
nft add element inet direct_guard learn4 '{ 203.0.113.7 }'
nft add element inet direct_guard learn4 '{ 203.0.113.8 }'
check "snapshot succeeds" direct-guard snapshot
check "snapshot saves each learned address" grep -qxF 203.0.113.8 /etc/direct-guard/learn4
check "snapshot writes one address per line" [ "$(wc -l </etc/direct-guard/learn4)" -eq 2 ]
check "status succeeds" sh -c 'direct-guard status | grep -q "learned:        2 IPv4"'

check "uninstall succeeds" direct-guard uninstall
check_not "uninstall removes the table" has_table
check_not "uninstall removes the firewall include" uci -q get firewall.direct_guard
check_not "uninstall leaves no dnsmasq block" grep -q 'BEGIN direct-guard' /etc/dnsmasq.conf

if [ "$failures" -gt 0 ]; then
	printf '%s OpenWrt test(s) failed\n' "$failures"
	exit 1
fi
printf 'all OpenWrt tests passed\n'
