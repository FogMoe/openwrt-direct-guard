#!/usr/bin/env bash
# Exercises direct-guard against real netfilter inside network namespaces:
#   client (10.99.1.2) -- lan0 [router] wan0 -- upstream (10.99.2.x)
# Usage (as root): tests/integration.sh nft|iptables
# Set DG_TEST_SHELL to run the script with another shell, e.g. "busybox sh".

set -Eeuo pipefail

BACKEND=${1:-}
case "$BACKEND" in
nft | iptables) ;;
*)
	printf 'usage: %s nft|iptables\n' "$0" >&2
	exit 2
	;;
esac
if [ "$(id -u)" != 0 ]; then
	printf 'integration tests must run as root\n' >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/direct-guard/files/direct-guard.sh"
read -r -a SH <<<"${DG_TEST_SHELL:-sh}"
WORK=$(mktemp -d)
NS_C="dgc$$"
NS_R="dgr$$"
NS_W="dgw$$"
failures=0

cleanup() {
	set +e
	local pid
	for pid in "$WORK"/*.pid; do
		[ -f "$pid" ] && kill "$(cat "$pid")" 2>/dev/null
	done
	ip netns del "$NS_C" 2>/dev/null
	ip netns del "$NS_R" 2>/dev/null
	ip netns del "$NS_W" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$*"; }
fail() {
	printf 'not ok - %s\n' "$*"
	failures=$((failures + 1))
}
expect() {
	local desc=$1
	shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
expect_not() {
	local desc=$1
	shift
	if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

in_ns() {
	local ns=$1
	shift
	ip netns exec "$ns" "$@"
}
reach() { in_ns "$1" ping -c 2 -i 0.2 -W 1 "$2"; }
settle() {
	local _
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		reach "$1" "$2" && return 0
		sleep 0.5
	done
	return 1
}
lookup() { in_ns "$NS_R" busybox nslookup -type=a "$1" 127.0.0.1; }

dg() {
	in_ns "$NS_R" env \
		DG_UCI="$ROOT/tests/bin/uci" DG_TEST_UCI_FILE="$WORK/uci" \
		DG_STATE_DIR="$WORK/state" DG_LOCK_FILE="$WORK/lock" \
		DG_DNSMASQ_INIT=/nonexistent DG_FW3=/nonexistent DG_FW4=/nonexistent \
		"${SH[@]}" "$SCRIPT" "$@"
}

write_config() {
	cat >"$WORK/uci" <<EOF
direct-guard.main=global
direct-guard.main.enabled='$1'
direct-guard.main.backend='$2'
direct-guard.main.allow_dev='lan0'
direct-guard.main.dnsmasq_conf='$WORK/dnsmasq.conf'
direct-guard.main.log='1'
direct-guard.guarded=target
direct-guard.guarded.domain='guard.test'
direct-guard.guarded.cidr='10.99.2.3' 'fd99:2::3' '10.99.1.2'
EOF
}

guard_active() {
	if [ "$1" = nft ]; then
		in_ns "$NS_R" nft list table inet direct_guard
	else
		in_ns "$NS_R" iptables -n -L DIRECT_GUARD
	fi
}

learned_has() {
	if [ "$BACKEND" = nft ]; then
		in_ns "$NS_R" nft get element inet direct_guard learn4 "{ $1 }"
	else
		in_ns "$NS_R" ipset test dg_learn4 "$1"
	fi
}

ip netns add "$NS_C"
ip netns add "$NS_R"
ip netns add "$NS_W"
ip link add c0 netns "$NS_C" type veth peer name lan0 netns "$NS_R"
ip link add wan0 netns "$NS_R" type veth peer name w0 netns "$NS_W"
for ns in "$NS_C" "$NS_R" "$NS_W"; do
	in_ns "$ns" ip link set lo up
done
in_ns "$NS_C" ip addr add 10.99.1.2/24 dev c0
in_ns "$NS_C" ip -6 addr add fd99:1::2/64 dev c0 nodad
in_ns "$NS_C" ip link set c0 up
in_ns "$NS_C" ip route add default via 10.99.1.1
in_ns "$NS_C" ip -6 route add default via fd99:1::1
in_ns "$NS_R" ip addr add 10.99.1.1/24 dev lan0
in_ns "$NS_R" ip -6 addr add fd99:1::1/64 dev lan0 nodad
in_ns "$NS_R" ip addr add 10.99.2.1/24 dev wan0
in_ns "$NS_R" ip -6 addr add fd99:2::1/64 dev wan0 nodad
in_ns "$NS_R" ip link set lan0 up
in_ns "$NS_R" ip link set wan0 up
in_ns "$NS_R" sysctl -q -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
in_ns "$NS_W" ip addr add 10.99.2.2/24 dev w0
for host in 3 4 5 6 7; do
	in_ns "$NS_W" ip addr add "10.99.2.$host/32" dev w0
done
in_ns "$NS_W" ip -6 addr add fd99:2::2/64 dev w0 nodad
in_ns "$NS_W" ip -6 addr add fd99:2::3/128 dev w0 nodad
in_ns "$NS_W" ip -6 addr add fd99:2::4/128 dev w0 nodad
in_ns "$NS_W" ip link set w0 up
in_ns "$NS_W" ip route add default via 10.99.2.1
in_ns "$NS_W" ip -6 route add default via fd99:2::1

expect "baseline: client reaches 10.99.2.3" settle "$NS_C" 10.99.2.3
expect "baseline: router reaches 10.99.2.3" settle "$NS_R" 10.99.2.3
expect "baseline: client reaches fd99:2::3" settle "$NS_C" fd99:2::3
expect "baseline: client reaches fd99:2::4" settle "$NS_C" fd99:2::4

dnsmasq_feature=nftset
[ "$BACKEND" = iptables ] && dnsmasq_feature=ipset
have_dnsmasq=0
if command -v dnsmasq >/dev/null 2>&1 &&
	dnsmasq --version | grep -m1 'Compile time options:' | grep -qE "[ :]$dnsmasq_feature( |\$)"; then
	have_dnsmasq=1
fi
cat >"$WORK/dnsmasq.conf" <<EOF
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-hosts
server=10.99.2.2
EOF

mkdir -p "$WORK/state"
printf '10.99.2.5\n' >"$WORK/state/learn4"
write_config 1 "$BACKEND"
expect "apply succeeds" dg apply
expect "firewall objects exist" guard_active "$BACKEND"
expect "client reaches an unguarded address" reach "$NS_C" 10.99.2.4
expect_not "client is rejected for a guarded range (forward)" reach "$NS_C" 10.99.2.3
expect_not "client is rejected for a restored learned address" reach "$NS_C" 10.99.2.5
expect_not "router is rejected for a guarded range (output)" reach "$NS_R" 10.99.2.3
expect "router reaches a guarded address through an allowed device" reach "$NS_R" 10.99.1.2
expect "client reaches an unguarded IPv6 address" reach "$NS_C" fd99:2::4
expect_not "client is rejected for a guarded IPv6 address" reach "$NS_C" fd99:2::3

status=$(dg status)
expect "status reports the active backend" grep -q "firewall:       active ($BACKEND)" <<<"$status"
expect_not "status counts rejected packets" grep -q "rejected:       0 packet" <<<"$status"

if [ "$BACKEND" = nft ]; then
	before=$(in_ns "$NS_R" nft list table inet direct_guard | wc -l)
	dg apply
	after=$(in_ns "$NS_R" nft list table inet direct_guard | wc -l)
else
	before=$(in_ns "$NS_R" iptables -S | wc -l)
	dg apply
	after=$(in_ns "$NS_R" iptables -S | wc -l)
	expect "a single jump sits first in FORWARD" test "$(in_ns "$NS_R" iptables -S FORWARD | sed -n 2p)" = "-A FORWARD -j DIRECT_GUARD"
fi
expect "re-applying is idempotent" test "$before" = "$after"
expect_not "client stays rejected after re-applying" reach "$NS_C" 10.99.2.3

if [ "$BACKEND" = nft ]; then
	in_ns "$NS_R" nft add element inet direct_guard learn4 "{ 10.99.2.7 }"
else
	in_ns "$NS_R" ipset add dg_learn4 10.99.2.7
fi
dg snapshot
expect "snapshot saves new learned addresses" grep -qxF 10.99.2.7 "$WORK/state/learn4"
expect "snapshot keeps restored learned addresses" grep -qxF 10.99.2.5 "$WORK/state/learn4"

if [ "$have_dnsmasq" = 1 ]; then
	expect "the dnsmasq block is written" grep -q "^$dnsmasq_feature=/guard.test/" "$WORK/dnsmasq.conf"
	in_ns "$NS_W" dnsmasq --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces \
		--listen-address=10.99.2.2 --address=/guard.test/10.99.2.6 --address=/other.test/10.99.2.4 \
		--pid-file="$WORK/upstream.pid"
	in_ns "$NS_R" dnsmasq -C "$WORK/dnsmasq.conf" --pid-file="$WORK/router.pid"
	sleep 1
	expect "a guarded name resolves" lookup guard.test
	expect "dnsmasq adds resolved addresses to the learned set" learned_has 10.99.2.6
	expect_not "client is rejected for a learned address" reach "$NS_C" 10.99.2.6
	expect "an unguarded name resolves" lookup other.test
	expect_not "other names are not learned" learned_has 10.99.2.4
else
	printf 'skip - dnsmasq with %s support is not installed\n' "$dnsmasq_feature"
fi

dg forget
expect_not "forget clears the saved addresses" test -e "$WORK/state/learn4"
expect "forget clears the learned set" reach "$NS_C" 10.99.2.5

if [ "$BACKEND" = nft ] && command -v iptables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1; then
	in_ns "$NS_R" nft add element inet direct_guard learn4 "{ 10.99.2.5 }"
	write_config 1 iptables
	expect "switching to the iptables backend succeeds" dg apply
	expect_not "the nftables table is removed after switching" guard_active nft
	expect "the iptables chain exists after switching" guard_active iptables
	expect_not "learned addresses survive switching" reach "$NS_C" 10.99.2.5
	write_config 1 nft
	expect "switching back to nftables succeeds" dg apply
	expect_not "the iptables chain is removed after switching back" guard_active iptables
	expect_not "learned addresses survive switching back" reach "$NS_C" 10.99.2.5
fi

write_config 0 "$BACKEND"
expect "applying a disabled configuration succeeds" dg apply
expect_not "disabling removes the firewall objects" guard_active "$BACKEND"
expect "disabling restores access" reach "$NS_C" 10.99.2.3
expect_not "disabling removes the dnsmasq block" grep -q 'BEGIN direct-guard' "$WORK/dnsmasq.conf"
expect "disabling keeps the rest of the dnsmasq configuration" grep -qxF 'server=10.99.2.2' "$WORK/dnsmasq.conf"

write_config 1 "$BACKEND"
dg apply
expect "remove succeeds" dg remove
expect_not "remove deletes the firewall objects" guard_active "$BACKEND"
expect "remove restores access" reach "$NS_C" 10.99.2.3

if [ "$failures" -gt 0 ]; then
	printf '%s %s integration test(s) failed\n' "$failures" "$BACKEND"
	exit 1
fi
printf 'all %s integration tests passed\n' "$BACKEND"
