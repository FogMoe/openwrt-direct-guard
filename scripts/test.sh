#!/usr/bin/env bash
# Lints the shell code and runs the unit tests under every available shell.
# Integration tests need root: sudo tests/integration.sh nft|iptables

set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

posix_files=(
	direct-guard/files/direct-guard.sh
	direct-guard/files/direct-guard.init
	direct-guard/files/direct-guard.uci-defaults
	direct-guard/files/firewall.include
	tests/bin/uci
	tests/bin/dnsmasq-fake
	tests/unit.sh
	tests/openwrt.sh
)

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -x -s sh -e SC3043 "${posix_files[@]}"
	shellcheck scripts/test.sh tests/integration.sh
	printf 'shellcheck passed\n'
else
	printf 'skip - shellcheck is not installed\n'
fi

if command -v shfmt >/dev/null 2>&1; then
	shfmt -d -sr -s direct-guard/files/direct-guard.init
	shfmt -d -s -ln posix "${posix_files[@]}"
	printf 'shfmt passed\n'
else
	printf 'skip - shfmt is not installed\n'
fi

shells=(sh dash bash "busybox sh")
for shell in "${shells[@]}"; do
	read -r -a cmd <<<"$shell"
	if ! command -v "${cmd[0]}" >/dev/null 2>&1; then
		printf 'skip - %s is not installed\n' "$shell"
		continue
	fi
	printf '== unit tests with %s\n' "$shell"
	"${cmd[@]}" tests/unit.sh
done
