#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${NFWD_CONFIG_DIR:-/etc/nft-forward-manager}"
SYSCTL_FILE="${NFWD_SYSCTL_FILE:-/etc/sysctl.d/99-nft-forward-manager.conf}"
NFT_BIN="${NFWD_NFT_BIN:-$(command -v nft 2>/dev/null || printf '/usr/sbin/nft')}"
NFT_TABLE="${NFWD_NFT_TABLE:-nfwd_nat}"
MANAGER_BIN="${NFWD_MANAGER_BIN:-/usr/local/sbin/nftfw}"
SERVICE_NAME="${NFWD_SERVICE_NAME:-nftfw-restore.service}"
SERVICE_FILE="${NFWD_SERVICE_FILE:-/etc/systemd/system/$SERVICE_NAME}"

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

  if [[ -x "$NFT_BIN" ]] && "$NFT_BIN" list table ip6 "$NFT_TABLE" >/dev/null 2>&1; then
    "$NFT_BIN" delete table ip6 "$NFT_TABLE"
    green "已删除 nftables 表：ip6 $NFT_TABLE"
  else
    yellow "未发现 nftables 表：ip6 $NFT_TABLE"
  fi
}

remove_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable --now nft-forward-manager-restore.service >/dev/null 2>&1 || true
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    green "已删除 systemd 服务：$SERVICE_FILE"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  else
    yellow "未发现 systemd 服务：$SERVICE_FILE"
  fi

  if [[ -f /etc/systemd/system/nft-forward-manager-restore.service ]]; then
    rm -f /etc/systemd/system/nft-forward-manager-restore.service
    green "已删除旧 systemd 服务：/etc/systemd/system/nft-forward-manager-restore.service"
  fi
}

remove_manager_bin() {
  if [[ -f "$MANAGER_BIN" ]]; then
    rm -f "$MANAGER_BIN"
    green "已删除脚本文件：$MANAGER_BIN"
  else
    yellow "未发现脚本文件：$MANAGER_BIN"
  fi

  if [[ -f /usr/local/sbin/nft-forward-manager ]]; then
    rm -f /usr/local/sbin/nft-forward-manager
    green "已删除旧脚本文件：/usr/local/sbin/nft-forward-manager"
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
  local family="$1" table="$2" chain_name="$3" chain
  [[ -x "$NFT_BIN" ]] || return 1
  chain="$("$NFT_BIN" list chain "$family" "$table" "$chain_name" 2>/dev/null || true)"
  [[ "$chain" == *"hook forward"* && "$chain" == *"policy accept"* ]]
}

restore_forward_drop() {
  local family="$1" table="$2" chain_name="$3" tmp
  forward_policy_is_accept "$family" "$table" "$chain_name" || return 0
  tmp="$(mktemp)"
  {
    printf '#!/usr/sbin/nft -f\n'
    printf 'chain %s %s %s { policy drop ; }\n' "$family" "$table" "$chain_name"
  } >"$tmp"
  "$NFT_BIN" -f "$tmp" || true
  rm -f "$tmp"
  green "已将 $family $table $chain_name policy 改回 drop"
}

maybe_restore_forward_policy() {
  printf '\n'
  yellow "提示：安装脚本可能曾为 Docker/nftables NAT 兼容把 FORWARD policy 改为 accept。"
  yellow "如果你不确定，建议选择 n，避免影响 Docker 或其它转发流量。"
  read -rp "是否尝试将常见 forward 链 policy 改回 drop？[y/N]: " answer
  case "${answer,,}" in
    y|yes)
      restore_forward_drop ip filter FORWARD
      restore_forward_drop ip filter forward
      restore_forward_drop ip6 filter FORWARD
      restore_forward_drop ip6 filter forward
      restore_forward_drop inet filter FORWARD
      restore_forward_drop inet filter forward
      ;;
    *)
      yellow "已跳过 FORWARD policy 恢复。"
      ;;
  esac
}

main() {
  require_root
  remove_service
  remove_manager_bin
  delete_nft_table
  remove_config
  remove_sysctl_file
  maybe_restore_forward_policy
  green "卸载完成。"
}

main "$@"
