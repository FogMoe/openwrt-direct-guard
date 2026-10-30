#!/bin/sh
# Unit tests for the pure parts of direct-guard. Runs as any user and under
# any POSIX shell: sh tests/unit.sh, busybox sh tests/unit.sh, ...

set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/direct-guard/files/direct-guard.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
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
same() {
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi
}

DG_UCI="$ROOT/tests/bin/uci"
DG_TEST_UCI_FILE="$WORK/uci"
DG_STATE_DIR="$WORK/state"
DG_DNSMASQ_BIN="$ROOT/tests/bin/dnsmasq-fake"
export DG_UCI DG_TEST_UCI_FILE DG_STATE_DIR DG_DNSMASQ_BIN

DG_LIB=1
# shellcheck source=direct-guard/files/direct-guard.sh
. "$SCRIPT"
set -f
tmpdir="$WORK/tmp"
mkdir -p "$tmpdir"

for v in example.com a.b-c.example x_y.example localhost; do
	check "valid domain $v" valid_domain "$v"
done
for v in '' .example.com example.com. a..b 'exa mple.com' a/b 'a#b' EXAMPLE.com; do
	check_not "invalid domain '$v'" valid_domain "$v"
done

for v in 1.2.3.4 0.0.0.0/0 192.0.2.0/24 255.255.255.255/32 10.0.0.0/8; do
	check "valid IPv4 $v" valid_ipv4 "$v"
done
for v in 256.1.1.1 1.2.3 1.2.3.4.5 1.2.3.4/33 01.2.3.4 1.2.3.4/ 1.2.3.4/024 a.b.c.d ' 1.2.3.4' 1..2.3; do
	check_not "invalid IPv4 '$v'" valid_ipv4 "$v"
done

for v in 2001:db8::1 2001:db8::/32 ::1 ::ffff:192.0.2.1 fe80::1/128; do
	check "valid IPv6 $v" valid_ipv6 "$v"
done
for v in 2001:db8::/129 1.2.3.4 gggg::1 :::1 2001:db8::/ 2001:db8::/01; do
	check_not "invalid IPv6 '$v'" valid_ipv6 "$v"
done

for v in br-lan lo 'tun*' wg0 eth0.2 pppoe-wan; do
	check "valid device $v" valid_dev "$v"
done
for v in '' '*' 'a b' 'tun*x' averyveryverylongname0 'br/lan'; do
	check_not "invalid device '$v'" valid_dev "$v"
done

cat >"$WORK/uci" <<'EOF'
direct-guard.main=global
direct-guard.main.enabled='1'
direct-guard.main.backend='nft'
direct-guard.main.allow_dev='br-lan' 'tun*' 'bad/dev' 'br-lan'
direct-guard.main.snapshot_interval='5'
direct-guard.svc=target
direct-guard.svc.domain='Example.COM' '*.example.net' 'bad..domain' 'example.com'
direct-guard.svc.cidr='192.0.2.0/24' '2001:DB8::/32' '300.1.1.1' '192.0.2.0/24'
direct-guard.off=target
direct-guard.off.enabled='0'
direct-guard.off.domain='disabled.example'
direct-guard.@target[0]=target
direct-guard.@target[0].cidr='198.51.100.7'
EOF
load_config 2>"$WORK/warnings"
same "allowed devices keep lo first and drop invalid ones" "$devs" "lo br-lan tun*"
same "domains are lowercased, deduplicated and stripped of wildcards" "$domains" "example.com example.net"
same "IPv4 ranges include anonymous targets" "$static4" "192.0.2.0/24 198.51.100.7"
same "IPv6 ranges are lowercased" "$static6" "2001:db8::/32"
same "snapshot interval has a lower bound" "$interval" 10
same "defaults apply to unset options" "$learn $dnsmasq_restart $dnsmasq_conf $log_on" "1 1 /etc/dnsmasq.conf 0"
check "invalid domains are reported" grep -q "bad..domain" "$WORK/warnings"
check "invalid ranges are reported" grep -q "300.1.1.1" "$WORK/warnings"
check "invalid devices are reported" grep -q "bad/dev" "$WORK/warnings"
check_not "disabled targets are skipped" grep -q disabled "$WORK/warnings"

mkdir -p "$DG_STATE_DIR"
printf '203.0.113.5\nnot-an-ip\n203.0.113.0/24\n203.0.113.6' >"$DG_STATE_DIR/learn4"
printf '2001:DB8::5\n' >"$DG_STATE_DIR/learn6"
same "learned IPv4 addresses are validated" "$(read_learned 4 | tr '\n' ' ')" "203.0.113.5 203.0.113.6 "
same "learned IPv6 addresses are lowercased" "$(read_learned 6)" "2001:db8::5"

nft_render 0 1 >"$WORK/full.nft"
check "nft: allowed devices return early" grep -qxF 'add rule inet direct_guard forward oifname "tun*" return' "$WORK/full.nft"
check "nft: loopback is always allowed" grep -qxF 'add rule inet direct_guard output oifname "lo" return' "$WORK/full.nft"
check "nft: learned IPv6 is guarded on output" grep -qxF 'add rule inet direct_guard output ip6 daddr @learn6 goto block' "$WORK/full.nft"
check "nft: static ranges are added" grep -qxF 'add element inet direct_guard static4 { 192.0.2.0/24 }' "$WORK/full.nft"
check "nft: learned addresses are restored" grep -qxF 'add element inet direct_guard learn4 { 203.0.113.6 }' "$WORK/full.nft"
check "nft: rejects with a counter" grep -qxF 'add rule inet direct_guard block counter reject' "$WORK/full.nft"
check_not "nft: no logging by default" grep -q ' log ' "$WORK/full.nft"
check "nft: chains run after mangle and before filter" grep -q 'hook forward priority filter - 10' "$WORK/full.nft"
nft_render 1 0 >"$WORK/rules.nft"
check "nft: logging is rate limited" grep -qxF 'add rule inet direct_guard block limit rate 10/minute log prefix "direct-guard: "' "$WORK/rules.nft"
check_not "nft: rules-only render has no elements" grep -q 'add element' "$WORK/rules.nft"

same "iptables wildcard devices" "$(ipt_dev 'tun*')" "tun+"

backend=nft
DG_TEST_DNSMASQ_FEATURES="ipset nftset"
export DG_TEST_DNSMASQ_FEATURES
dnsmasq_render >"$WORK/want.nft"
same "dnsmasq: one nftset rule per domain" "$(sed -n 1p "$WORK/want.nft")" \
	"nftset=/example.com/4#inet#direct_guard#learn4,6#inet#direct_guard#learn6"
same "dnsmasq: nftset rule count" "$(wc -l <"$WORK/want.nft" | tr -d ' ')" 2
backend=iptables
same "dnsmasq: ipset rule" "$(dnsmasq_render | sed -n 1p)" "ipset=/example.com/dg_learn4,dg_learn6"
DG_TEST_DNSMASQ_FEATURES="no-ipset no-nftset"
same "dnsmasq: nothing without set support" "$(dnsmasq_render 2>"$WORK/warnings")" ""
check "dnsmasq: missing support is reported" grep -q "dnsmasq-full" "$WORK/warnings"
learn=0
DG_TEST_DNSMASQ_FEATURES="ipset nftset"
same "dnsmasq: nothing when learning is off" "$(dnsmasq_render)" ""
learn=1
backend=nft

dnsmasq_conf="$WORK/dnsmasq.conf"
printf 'log-facility=/dev/null\nconf-dir=/tmp/dnsmasq.d\n' >"$dnsmasq_conf"
cp "$dnsmasq_conf" "$WORK/original.conf"
chmod 600 "$dnsmasq_conf"
dnsmasq_sync "$WORK/want.nft"
same "dnsmasq: block is added" "$dnsmasq_changed" 1
check "dnsmasq: other lines are kept" grep -qxF 'conf-dir=/tmp/dnsmasq.d' "$dnsmasq_conf"
same "dnsmasq: block content" "$(dnsmasq_block "$dnsmasq_conf" inside)" "$(cat "$WORK/want.nft")"
same "dnsmasq: file mode is preserved" "$(stat -c %a "$dnsmasq_conf")" 600
dnsmasq_sync "$WORK/want.nft"
same "dnsmasq: unchanged block is left alone" "$dnsmasq_changed" 0
sed -n 1p "$WORK/want.nft" >"$WORK/want.one"
dnsmasq_sync "$WORK/want.one"
same "dnsmasq: block is replaced" "$(dnsmasq_block "$dnsmasq_conf" inside)" "$(cat "$WORK/want.one")"
same "dnsmasq: only one block exists" "$(grep -cxF "$BEGIN_MARK" "$dnsmasq_conf")" 1
cp "$dnsmasq_conf" "$WORK/before-fail.conf"
DG_TEST_DNSMASQ_TEST=fail
export DG_TEST_DNSMASQ_TEST
check_not "dnsmasq: rejected configuration fails" dnsmasq_sync "$WORK/want.nft"
check "dnsmasq: rejected configuration is not written" cmp -s "$dnsmasq_conf" "$WORK/before-fail.conf"
DG_TEST_DNSMASQ_TEST=ok
: >"$WORK/empty"
dnsmasq_sync "$WORK/empty"
check "dnsmasq: block is removed cleanly" cmp -s "$dnsmasq_conf" "$WORK/original.conf"
printf '%s\nnftset=/x/4#inet#t#s\n' "$BEGIN_MARK" >>"$dnsmasq_conf"
cp "$dnsmasq_conf" "$WORK/damaged.conf"
check_not "dnsmasq: damaged markers are refused" dnsmasq_sync "$WORK/want.nft"
check "dnsmasq: damaged file is not touched" cmp -s "$dnsmasq_conf" "$WORK/damaged.conf"
dnsmasq_conf="$WORK/missing.conf"
dnsmasq_sync "$WORK/empty"
check_not "dnsmasq: no file is created for an empty block" test -e "$dnsmasq_conf"

out=$(sh "$SCRIPT" bogus 2>&1)
same "unknown commands exit with 2" "$?" 2
case "$out" in
*"Usage: direct-guard"*) pass "unknown commands print usage" ;;
*) fail "unknown commands print usage" ;;
esac
sh "$SCRIPT" help >/dev/null 2>&1
same "help exits with 0" "$?" 0

if [ "$failures" -gt 0 ]; then
	printf '%s unit test(s) failed\n' "$failures"
	exit 1
fi
printf 'all unit tests passed\n'
