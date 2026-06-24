#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${NFWD_CONFIG_DIR:-/etc/nft-forward-manager}"
SYSCTL_FILE="${NFWD_SYSCTL_FILE:-/etc/sysctl.d/99-nft-forward-manager.conf}"
NFT_BIN="${NFWD_NFT_BIN:-/usr/sbin/nft}"
NFT_TABLE="${NFWD_NFT_TABLE:-nfwd_nat}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

die() {
  red "错误：$*"
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 运行，例如：sudo bash uninstall.sh"
  fi
}

delete_nft_table() {
  if [[ -x "$NFT_BIN" ]] && "$NFT_BIN" list table ip "$NFT_TABLE" >/dev/null 2>&1; then
    "$NFT_BIN" delete table ip "$NFT_TABLE"
    green "已删除 nftables 表：ip $NFT_TABLE"
  else
    yellow "未发现 nftables 表：ip $NFT_TABLE"
  fi
}

remove_config() {
  if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    green "已删除配置目录：$CONFIG_DIR"
  else
    yellow "未发现配置目录：$CONFIG_DIR"
  fi
}

remove_sysctl_file() {
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    green "已删除 sysctl 配置：$SYSCTL_FILE"
  else
    yellow "未发现 sysctl 配置：$SYSCTL_FILE"
  fi
}

forward_policy_is_accept() {
  local family="$1" chain
  [[ -x "$NFT_BIN" ]] || return 1
  chain="$("$NFT_BIN" list chain "$family" filter FORWARD 2>/dev/null || true)"
  [[ "$chain" == *"hook forward"* && "$chain" == *"policy accept"* ]]
}

restore_forward_drop_for_family() {
  local family="$1" tmp
  forward_policy_is_accept "$family" || return 0
  tmp="$(mktemp)"
  {
    printf '#!/usr/sbin/nft -f\n'
    printf 'chain %s filter FORWARD { policy drop ; }\n' "$family"
  } >"$tmp"
  "$NFT_BIN" -f "$tmp" || true
  rm -f "$tmp"
  green "已将 $family filter FORWARD policy 改回 drop"
}

maybe_restore_forward_policy() {
  printf '\n'
  yellow "提示：安装脚本可能曾为 Docker/nftables NAT 兼容把 FORWARD policy 改为 accept。"
  yellow "如果你不确定，建议选择 n，避免影响 Docker 或其它转发流量。"
  read -rp "是否尝试将 ip/ip6 filter FORWARD policy 改回 drop？[y/N]: " answer
  case "${answer,,}" in
    y|yes)
      restore_forward_drop_for_family ip
      restore_forward_drop_for_family ip6
      ;;
    *)
      yellow "已跳过 FORWARD policy 恢复。"
      ;;
  esac
}

main() {
  require_root
  delete_nft_table
  remove_config
  remove_sysctl_file
  maybe_restore_forward_policy
  green "卸载完成。"
}

main "$@"
