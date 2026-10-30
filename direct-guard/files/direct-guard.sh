#!/bin/sh
# SPDX-License-Identifier: MIT
# shellcheck disable=SC3043

NAME=direct-guard
UCI=${DG_UCI:-uci}
STATE_DIR=${DG_STATE_DIR:-/etc/direct-guard}
LOCK_FILE=${DG_LOCK_FILE:-/var/lock/direct-guard.lock}
DNSMASQ_BIN=${DG_DNSMASQ_BIN:-dnsmasq}
DNSMASQ_INIT=${DG_DNSMASQ_INIT:-/etc/init.d/dnsmasq}
FW3=${DG_FW3:-/sbin/fw3}
FW4=${DG_FW4:-/sbin/fw4}

NFT_TABLE=direct_guard
IPT_CHAIN=DIRECT_GUARD
SET_PREFIX=dg_
BEGIN_MARK='# BEGIN direct-guard (managed block, do not edit)'
END_MARK='# END direct-guard'
LOG_PREFIX='direct-guard: '

msg() {
	printf '%s: %s\n' "$NAME" "$*" >&2
}

warn() {
	msg "$*"
	if command -v logger >/dev/null 2>&1; then
		logger -t "$NAME" -p daemon.warn -- "$*"
	fi
	return 0
}

is_true() {
	case "$1" in
	1 | yes | on | true | enabled) return 0 ;;
	*) return 1 ;;
	esac
}

cfg() {
	"$UCI" -q get "$NAME.$1" 2>/dev/null
}

add_word() {
	case " $1 " in
	*" $2 "*) printf '%s' "$1" ;;
	*) printf '%s' "${1:+$1 }$2" ;;
	esac
}

count_words() {
	# shellcheck disable=SC2086
	set -- $1
	echo $#
}

lower() {
	printf '%s' "$1" | tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz
}

valid_domain() {
	case "$1" in
	'' | .* | *. | *..* | *[!a-z0-9._-]*) return 1 ;;
	esac
	[ "${#1}" -le 253 ]
}

valid_ipv4() {
	local addr="${1%/*}" prefix octet a b c d rest

	if [ "$addr" != "$1" ]; then
		prefix="${1#*/}"
		case "$prefix" in
		'' | *[!0-9]* | 0?*) return 1 ;;
		esac
		[ "$prefix" -le 32 ] || return 1
	fi
	case "$addr" in
	*[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac
	IFS=. read -r a b c d rest <<EOF
$addr
EOF
	[ -n "$d" ] && [ -z "$rest" ] || return 1
	for octet in "$a" "$b" "$c" "$d"; do
		case "$octet" in
		'' | *[!0-9]* | 0?*) return 1 ;;
		esac
		[ "$octet" -le 255 ] || return 1
	done
}

valid_ipv6() {
	local addr="${1%/*}" prefix

	if [ "$addr" != "$1" ]; then
		prefix="${1#*/}"
		case "$prefix" in
		'' | *[!0-9]* | 0?*) return 1 ;;
		esac
		[ "$prefix" -le 128 ] || return 1
	fi
	case "$addr" in
	*:*) ;;
	*) return 1 ;;
	esac
	case "$addr" in
	*[!0-9a-fA-F:.]* | *:::*) return 1 ;;
	esac
	[ "${#addr}" -le 45 ]
}

valid_dev() {
	local base="${1%\*}"

	case "$base" in
	'' | *[!A-Za-z0-9_.@:-]*) return 1 ;;
	esac
	[ "${#1}" -le 15 ]
}

load_config() {
	local dev section d c target_enabled

	enabled=$(cfg main.enabled)
	backend=$(cfg main.backend)
	learn=$(cfg main.learn)
	dnsmasq_conf=$(cfg main.dnsmasq_conf)
	dnsmasq_restart=$(cfg main.dnsmasq_restart)
	interval=$(cfg main.snapshot_interval)
	log_on=0
	is_true "$(cfg main.log)" && log_on=1

	: "${enabled:=0}" "${backend:=auto}" "${learn:=1}" "${dnsmasq_restart:=1}"
	: "${dnsmasq_conf:=/etc/dnsmasq.conf}" "${interval:=60}"
	case "$interval" in
	'' | *[!0-9]*) interval=60 ;;
	esac
	[ "$interval" -ge 10 ] || interval=10

	devs=lo
	for dev in $(cfg main.allow_dev); do
		if valid_dev "$dev"; then
			devs=$(add_word "$devs" "$dev")
		else
			warn "ignoring invalid allow_dev '$dev'"
		fi
	done

	domains=
	static4=
	static6=
	for section in $("$UCI" -q show "$NAME" 2>/dev/null | sed -n "s/^$NAME\\.\\([^.=]*\\)=target\$/\\1/p"); do
		target_enabled=$(cfg "$section.enabled") || target_enabled=1
		is_true "$target_enabled" || continue
		for d in $(cfg "$section.domain"); do
			d=$(lower "$d")
			d=${d#\*.}
			d=${d#.}
			if valid_domain "$d"; then
				domains=$(add_word "$domains" "$d")
			else
				warn "ignoring invalid domain '$d' in target '$section'"
			fi
		done
		for c in $(cfg "$section.cidr"); do
			if valid_ipv4 "$c"; then
				static4=$(add_word "$static4" "$c")
			elif valid_ipv6 "$c"; then
				static6=$(add_word "$static6" "$(lower "$c")")
			else
				warn "ignoring invalid cidr '$c' in target '$section'"
			fi
		done
	done
	return 0
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 && return 0
	warn "the $backend backend needs '$1', which is not installed"
	return 1
}

select_backend() {
	if [ "$backend" = auto ]; then
		if [ -x "$FW4" ]; then
			backend=nft
		elif [ -x "$FW3" ]; then
			backend=iptables
		elif command -v nft >/dev/null 2>&1; then
			backend=nft
		else
			backend=iptables
		fi
	fi
	case "$backend" in
	nft) need_cmd nft ;;
	iptables) need_cmd iptables && need_cmd ipset ;;
	*)
		warn "unknown backend '$backend' (use auto, nft or iptables)"
		return 1
		;;
	esac
}

read_learned() {
	local file="$STATE_DIR/learn$1" addr

	[ -f "$file" ] || return 0
	while IFS= read -r addr || [ -n "$addr" ]; do
		[ "${addr%/*}" = "$addr" ] || continue
		if [ "$1" = 4 ]; then
			valid_ipv4 "$addr" || continue
		else
			valid_ipv6 "$addr" || continue
			addr=$(lower "$addr")
		fi
		printf '%s\n' "$addr"
	done <"$file"
}

write_file() {
	local tmp="$2.$NAME.tmp"

	if [ -f "$2" ]; then
		cp -p "$2" "$tmp" || return 1
	else
		: >"$tmp" || return 1
		chmod 644 "$tmp"
	fi
	if cat "$1" >"$tmp" && mv -f "$tmp" "$2"; then
		return 0
	fi
	rm -f "$tmp"
	return 1
}

nft_present() {
	command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1
}

nft_render() {
	local table="inet $NFT_TABLE" chain dev addr

	cat <<EOF
table $table {
	set static4 { type ipv4_addr; flags interval; auto-merge; }
	set static6 { type ipv6_addr; flags interval; auto-merge; }
	set learn4 { type ipv4_addr; }
	set learn6 { type ipv6_addr; }
	chain forward { type filter hook forward priority filter - 10; policy accept; }
	chain output { type filter hook output priority filter - 10; policy accept; }
	chain block { }
}
flush chain $table forward
flush chain $table output
flush chain $table block
flush set $table static4
flush set $table static6
EOF
	for chain in forward output; do
		for dev in $devs; do
			printf 'add rule %s %s oifname "%s" return\n' "$table" "$chain" "$dev"
		done
		printf 'add rule %s %s ip daddr @static4 goto block\n' "$table" "$chain"
		printf 'add rule %s %s ip daddr @learn4 goto block\n' "$table" "$chain"
		printf 'add rule %s %s ip6 daddr @static6 goto block\n' "$table" "$chain"
		printf 'add rule %s %s ip6 daddr @learn6 goto block\n' "$table" "$chain"
	done
	if [ "$1" = 1 ]; then
		printf 'add rule %s block limit rate 10/minute log prefix "%s"\n' "$table" "$LOG_PREFIX"
	fi
	printf 'add rule %s block counter reject\n' "$table"
	[ "$2" = 1 ] || return 0
	for addr in $static4; do
		printf 'add element %s static4 { %s }\n' "$table" "$addr"
	done
	for addr in $static6; do
		printf 'add element %s static6 { %s }\n' "$table" "$addr"
	done
	read_learned 4 | while IFS= read -r addr; do
		printf 'add element %s learn4 { %s }\n' "$table" "$addr"
	done
	read_learned 6 | while IFS= read -r addr; do
		printf 'add element %s learn6 { %s }\n' "$table" "$addr"
	done
}

nft_add_each() {
	local addr

	while IFS= read -r addr; do
		[ -n "$addr" ] || continue
		nft add element inet "$NFT_TABLE" "$1" "{ $addr }" 2>/dev/null ||
			warn "cannot add $addr to the $1 set"
	done
}

nft_apply() {
	local file="$tmpdir/ruleset.nft" err="$tmpdir/nft.err" addr

	if ipt_present; then
		cmd_snapshot
		ipt_remove
	fi
	nft_render "$log_on" 1 >"$file"
	nft -f "$file" 2>"$err" && return 0
	if [ "$log_on" = 1 ]; then
		nft_render 0 1 >"$file"
		if nft -f "$file" 2>>"$err"; then
			warn "logging is unavailable (missing nftables log support?); applied without it"
			return 0
		fi
		log_on=0
	fi
	nft_render 0 0 >"$file"
	if ! nft -f "$file" 2>>"$err"; then
		cmd_snapshot
		nft_remove
		if ! nft -f "$file" 2>>"$err"; then
			warn "failed to apply the nftables rules: $(head -n 3 "$err" | tr '\n' ' ')"
			return 1
		fi
	fi
	for addr in $static4; do echo "$addr"; done | nft_add_each static4
	for addr in $static6; do echo "$addr"; done | nft_add_each static6
	read_learned 4 | nft_add_each learn4
	read_learned 6 | nft_add_each learn6
	return 0
}

nft_remove() {
	nft_present || return 0
	nft delete table inet "$NFT_TABLE"
}

nft_elements() {
	nft list set inet "$NFT_TABLE" "$1" >/dev/null 2>&1 || return 1
	{
		nft list set inet "$NFT_TABLE" "$1" | tr -d ' \t\n'
		echo
	} | sed -n 's/.*elements={\([^}]*\)}.*/\1/p' | tr ',' '\n' | sed '/^$/d'
}

nft_counters() {
	nft list chain inet "$NFT_TABLE" block 2>/dev/null |
		sed -n 's/.*counter packets \([0-9]*\) bytes \([0-9]*\).*/\1 \2/p'
}

ipt_cmd() {
	if [ "$1" = 4 ]; then echo iptables; else echo ip6tables; fi
}

ipt_dev() {
	case "$1" in
	*\*) printf '%s+' "${1%\*}" ;;
	*) printf '%s' "$1" ;;
	esac
}

ipt_present() {
	command -v iptables >/dev/null 2>&1 && iptables -w 5 -n -L "$IPT_CHAIN" >/dev/null 2>&1
}

ipt_drop_chain() {
	local chain

	"$1" -w 5 -n -L "$2" >/dev/null 2>&1 || return 0
	for chain in FORWARD OUTPUT; do
		while "$1" -w 5 -C "$chain" -j "$2" 2>/dev/null; do
			"$1" -w 5 -D "$chain" -j "$2" || break
		done
	done
	"$1" -w 5 -F "$2" 2>/dev/null
	"$1" -w 5 -X "$2" 2>/dev/null
}

ipset_sync() {
	local fam="$1" family=inet static="${SET_PREFIX}static$1" learn="${SET_PREFIX}learn$1"
	local tmp="${SET_PREFIX}static${1}_new" list="$static4" addr

	if [ "$fam" = 6 ]; then
		family=inet6
		list=$static6
	fi
	ipset -exist create "$static" hash:net family "$family" maxelem 65536 &&
		ipset -exist create "$learn" hash:ip family "$family" maxelem 65536 &&
		ipset -exist create "$tmp" hash:net family "$family" maxelem 65536 &&
		ipset flush "$tmp" || return 1
	if ! for addr in $list; do echo "add $tmp $addr"; done | ipset -exist restore 2>/dev/null; then
		ipset flush "$tmp"
		for addr in $list; do
			ipset -exist add "$tmp" "$addr" 2>/dev/null || warn "cannot add $addr to the $static set"
		done
	fi
	ipset swap "$tmp" "$static" && ipset destroy "$tmp" || return 1
	if ! read_learned "$fam" | sed "s/^/add $learn /" | ipset -exist restore 2>/dev/null; then
		read_learned "$fam" | while IFS= read -r addr; do
			ipset -exist add "$learn" "$addr" 2>/dev/null || warn "cannot add $addr to the $learn set"
		done
	fi
	return 0
}

ipset_sync_all() {
	local fam

	for fam in $1; do
		ipset_sync "$fam" || return 1
	done
}

ipt_apply() {
	local fam ipt new="${IPT_CHAIN}_NEW" dev set chain families=4

	if nft_present; then
		cmd_snapshot
		nft_remove
	fi
	if command -v ip6tables >/dev/null 2>&1; then
		families="4 6"
	else
		warn "ip6tables is not installed; IPv6 destinations are not guarded"
	fi
	if ! ipset_sync_all "$families"; then
		cmd_snapshot
		ipt_remove
		ipset_sync_all "$families" || {
			warn "failed to prepare the ipsets"
			return 1
		}
	fi
	for fam in $families; do
		ipt=$(ipt_cmd "$fam")
		"$ipt" -w 5 -N "$new" 2>/dev/null || "$ipt" -w 5 -F "$new" || return 1
		for dev in $devs; do
			"$ipt" -w 5 -A "$new" -o "$(ipt_dev "$dev")" -j RETURN || return 1
		done
		for set in "${SET_PREFIX}static$fam" "${SET_PREFIX}learn$fam"; do
			if [ "$log_on" = 1 ] && ! "$ipt" -w 5 -A "$new" -m set --match-set "$set" dst \
				-m limit --limit 10/min -j LOG --log-prefix "$LOG_PREFIX" 2>/dev/null; then
				warn "logging is unavailable (missing LOG target?); continuing without it"
				log_on=0
			fi
			"$ipt" -w 5 -A "$new" -m set --match-set "$set" dst -j REJECT || {
				warn "failed to add the $ipt reject rule (is kmod-ipt-ipset installed?)"
				return 1
			}
		done
		for chain in FORWARD OUTPUT; do
			"$ipt" -w 5 -I "$chain" 1 -j "$new" || return 1
		done
		ipt_drop_chain "$ipt" "$IPT_CHAIN"
		"$ipt" -w 5 -E "$new" "$IPT_CHAIN" || return 1
	done
}

ipt_remove() {
	local fam ipt set

	for fam in 4 6; do
		ipt=$(ipt_cmd "$fam")
		command -v "$ipt" >/dev/null 2>&1 || continue
		ipt_drop_chain "$ipt" "${IPT_CHAIN}_NEW"
		ipt_drop_chain "$ipt" "$IPT_CHAIN"
	done
	command -v ipset >/dev/null 2>&1 || return 0
	for set in static4 learn4 static6 learn6 static4_new static6_new; do
		ipset destroy "$SET_PREFIX$set" 2>/dev/null
	done
	return 0
}

ipset_elements() {
	ipset list -n "$1" >/dev/null 2>&1 || return 1
	ipset save "$1" | awk '$1 == "add" { print $3 }'
}

ipt_counters() {
	local fam ipt

	for fam in 4 6; do
		ipt=$(ipt_cmd "$fam")
		command -v "$ipt" >/dev/null 2>&1 || continue
		"$ipt" -w 5 -n -v -x -L "$IPT_CHAIN" 2>/dev/null
	done | awk '$3 == "REJECT" { p += $1; b += $2 } END { print p + 0, b + 0 }'
}

active_backend() {
	if nft_present; then
		echo nft
	elif command -v ipset >/dev/null 2>&1 && ipset list -n "${SET_PREFIX}learn4" >/dev/null 2>&1; then
		echo iptables
	else
		return 1
	fi
}

learned_elements() {
	case "$1" in
	nft) nft_elements "learn$2" ;;
	iptables) ipset_elements "${SET_PREFIX}learn$2" ;;
	*) return 1 ;;
	esac
}

dnsmasq_feature() {
	"$DNSMASQ_BIN" --version 2>/dev/null | grep -m1 'Compile time options:' |
		grep -qE "[ :]$1( |\$)"
}

dnsmasq_render() {
	local domain

	is_true "$learn" || return 0
	[ -n "$domains" ] || return 0
	case "$backend" in
	nft)
		if ! dnsmasq_feature nftset; then
			warn "dnsmasq has no nftset support (install dnsmasq-full); domains are not learned"
			return 0
		fi
		for domain in $domains; do
			printf 'nftset=/%s/4#inet#%s#learn4,6#inet#%s#learn6\n' "$domain" "$NFT_TABLE" "$NFT_TABLE"
		done
		;;
	iptables)
		if ! dnsmasq_feature ipset; then
			warn "dnsmasq has no ipset support (install dnsmasq-full); domains are not learned"
			return 0
		fi
		for domain in $domains; do
			printf 'ipset=/%s/%slearn4,%slearn6\n' "$domain" "$SET_PREFIX" "$SET_PREFIX"
		done
		;;
	esac
}

dnsmasq_block() {
	awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v keep="$2" '
		$0 == b { inside = 1; next }
		$0 == e { inside = 0; next }
		(inside && keep == "inside") || (!inside && keep == "outside")
	' "$1"
}

dnsmasq_sync() {
	local want="$1" conf="$dnsmasq_conf" cur="$tmpdir/dnsmasq.cur" new="$tmpdir/dnsmasq.new" out begins ends

	dnsmasq_changed=0
	if [ -f "$conf" ]; then
		begins=$(grep -cxF "$BEGIN_MARK" "$conf")
		ends=$(grep -cxF "$END_MARK" "$conf")
		if [ "$begins" != "$ends" ] || [ "$begins" -gt 1 ]; then
			warn "$conf has damaged direct-guard markers; fix it by hand, leaving it unchanged"
			return 1
		fi
		dnsmasq_block "$conf" inside >"$cur"
	else
		[ -s "$want" ] || return 0
		: >"$cur"
	fi
	cmp -s "$cur" "$want" && return 0
	{
		[ -f "$conf" ] && dnsmasq_block "$conf" outside
		if [ -s "$want" ]; then
			echo "$BEGIN_MARK"
			cat "$want"
			echo "$END_MARK"
		fi
	} >"$new"
	if [ -s "$want" ] && ! out=$("$DNSMASQ_BIN" --test -C "$new" 2>&1); then
		warn "dnsmasq rejected the generated configuration, leaving $conf unchanged: $out"
		return 1
	fi
	write_file "$new" "$conf" || {
		warn "cannot write $conf"
		return 1
	}
	dnsmasq_changed=1
}

dnsmasq_reload() {
	[ "$dnsmasq_changed" = 1 ] || return 0
	if [ -n "${DG_NO_DNSMASQ_RESTART:-}" ] || ! is_true "$dnsmasq_restart"; then
		msg "updated $dnsmasq_conf; restart dnsmasq to apply it"
		return 0
	fi
	[ -x "$DNSMASQ_INIT" ] || return 0
	pidof dnsmasq >/dev/null 2>&1 || return 0
	"$DNSMASQ_INIT" restart >/dev/null 2>&1 || warn "failed to restart dnsmasq"
}

cmd_snapshot() {
	local active fam out="$tmpdir/learned" file

	active=$(active_backend) || return 0
	for fam in 4 6; do
		file="$STATE_DIR/learn$fam"
		learned_elements "$active" "$fam" >"$out.live" || continue
		{
			cat "$out.live"
			echo
			[ -f "$file" ] && cat "$file"
			echo
		} | sed '/^$/d' | sort -u >"$out"
		[ -s "$out" ] || continue
		cmp -s "$out" "$file" && continue
		if ! { mkdir -p "$STATE_DIR" && write_file "$out" "$file"; }; then
			warn "cannot save learned addresses to $file"
		fi
	done
	return 0
}

teardown() {
	cmd_snapshot
	nft_remove
	ipt_remove
	: >"$tmpdir/dnsmasq.want"
	dnsmasq_sync "$tmpdir/dnsmasq.want" && dnsmasq_reload
	return 0
}

cmd_apply() {
	load_config
	if ! is_true "$enabled"; then
		teardown
		return 0
	fi
	select_backend || return 1
	if [ -z "$domains$static4$static6" ]; then
		warn "no enabled target has a domain or cidr; nothing is guarded yet"
	fi
	if [ "$backend" = nft ]; then
		nft_apply
	else
		ipt_apply
	fi || return 1
	dnsmasq_render >"$tmpdir/dnsmasq.want"
	dnsmasq_sync "$tmpdir/dnsmasq.want" && dnsmasq_reload
	return 0
}

cmd_forget() {
	rm -f "$STATE_DIR/learn4" "$STATE_DIR/learn6"
	case "$(active_backend)" in
	nft)
		nft flush set inet "$NFT_TABLE" learn4
		nft flush set inet "$NFT_TABLE" learn6
		;;
	iptables)
		ipset flush "${SET_PREFIX}learn4" 2>/dev/null
		ipset flush "${SET_PREFIX}learn6" 2>/dev/null
		;;
	esac
	return 0
}

cmd_status() {
	local active learned4 learned6 counters lines watcher=no

	load_config
	printf 'enabled:        %s\n' "$(is_true "$enabled" && echo yes || echo no)"
	if active=$(active_backend); then
		printf 'firewall:       active (%s)\n' "$active"
	else
		printf 'firewall:       not active\n'
	fi
	printf 'allowed egress: %s\n' "$devs"
	printf 'targets:        %s domain(s), %s IPv4 and %s IPv6 range(s)\n' \
		"$(count_words "$domains")" "$(count_words "$static4")" "$(count_words "$static6")"
	if [ -n "$active" ]; then
		learned4=$(learned_elements "$active" 4 | wc -l)
		learned6=$(learned_elements "$active" 6 | wc -l)
		printf 'learned:        %s IPv4 and %s IPv6 address(es)\n' "$learned4" "$learned6"
		if [ "$active" = nft ]; then counters=$(nft_counters); else counters=$(ipt_counters); fi
		# shellcheck disable=SC2086
		set -- ${counters:-0 0}
		printf 'rejected:       %s packet(s), %s byte(s)\n' "$1" "$2"
	fi
	lines=0
	[ -f "$dnsmasq_conf" ] && lines=$(dnsmasq_block "$dnsmasq_conf" inside | grep -cE '^(nftset|ipset)=')
	printf 'dnsmasq:        %s domain rule(s) in %s\n' "$lines" "$dnsmasq_conf"
	pgrep -f "$NAME watch" >/dev/null 2>&1 && watcher=yes
	printf 'watcher:        %s\n' "$watcher"
}

cmd_watch() {
	load_config
	while :; do
		sleep "$interval"
		(take_lock && cmd_snapshot)
	done
}

cmd_uninstall() {
	load_config
	teardown
	if "$UCI" -q get firewall.direct_guard >/dev/null 2>&1; then
		"$UCI" -q delete firewall.direct_guard && "$UCI" commit firewall
	fi
	return 0
}

take_lock() {
	local tries=60

	command -v flock >/dev/null 2>&1 || return 0
	mkdir -p "${LOCK_FILE%/*}" 2>/dev/null
	exec 9>"$LOCK_FILE" || return 0
	while ! flock -n 9; do
		tries=$((tries - 1))
		if [ "$tries" -le 0 ]; then
			warn "another $NAME command is still running"
			return 1
		fi
		sleep 1
	done
}

usage() {
	cat <<EOF
Usage: $NAME <command>

Commands:
  apply      apply /etc/config/$NAME (removes the guard when disabled)
  remove     remove the firewall rules, the sets and the dnsmasq block
  status     show the current state
  snapshot   save learned addresses to $STATE_DIR
  forget     clear learned addresses
  watch      save learned addresses periodically (used by the service)
  uninstall  remove everything, including the firewall include
EOF
}

main() {
	local cmd="${1:-help}"

	set -f
	case "$cmd" in
	help | -h | --help)
		usage
		return 0
		;;
	apply | remove | status | snapshot | forget | watch | uninstall) ;;
	*)
		usage >&2
		return 2
		;;
	esac
	if [ "$(id -u)" != 0 ]; then
		msg "must be run as root"
		return 1
	fi
	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/$NAME.XXXXXX") || return 1
	trap 'rm -rf "$tmpdir"' EXIT
	trap 'exit 1' INT TERM
	case "$cmd" in
	apply) take_lock && cmd_apply ;;
	remove) take_lock && load_config && teardown ;;
	status) cmd_status ;;
	snapshot) take_lock && cmd_snapshot ;;
	forget) take_lock && cmd_forget ;;
	watch) cmd_watch ;;
	uninstall) take_lock && cmd_uninstall ;;
	esac
}

[ -n "${DG_LIB:-}" ] || main "$@"
