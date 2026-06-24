#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="nft-forward-manager"
CONFIG_DIR="${NFWD_CONFIG_DIR:-/etc/nft-forward-manager}"
CONFIG_FILE="${NFWD_CONFIG_FILE:-$CONFIG_DIR/rules.conf}"
SYSCTL_FILE="${NFWD_SYSCTL_FILE:-/etc/sysctl.d/99-nft-forward-manager.conf}"
NFT_BIN="${NFWD_NFT_BIN:-/usr/sbin/nft}"
NFT_TABLE="${NFWD_NFT_TABLE:-nfwd_nat}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

pause() {
  printf '\n按回车返回上一级...'
  read -r _
}

die() {
  red "错误：$*"
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 运行，例如：sudo bash $0"
  fi
}

require_nftables() {
  if [[ ! -x "$NFT_BIN" ]]; then
    die "未找到 $NFT_BIN。Debian/Ubuntu 可先执行：apt update && apt install -y nftables"
  fi
}

init_config() {
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat >"$CONFIG_FILE" <<'EOF'
# nft-forward-manager 本地配置
# 格式：
# protocol|local_port|remote_addr|remote_port|snat|comment
#
# 字段说明：
# protocol    : tcp / udp / all，菜单新增默认 all
# local_port  : 客户端访问中转机 A 的对外端口，支持单端口或端口段，例如 2222 或 20000-20100
# remote_addr : 后端 B 服务器 IPv4 地址或可解析域名
# remote_port : 后端 B 服务器实际服务端口，支持单端口或端口段
# snat        : on / off；默认 off，off 表示保留客户端源 IP，需要 B 的回程路由经过 A
# comment     : 可选备注
#
# 示例：
# all|20000-20100|203.0.113.10|20000-20100|off|game udp/tcp range
# tcp|2222|203.0.113.10|22|off|ssh
EOF
  fi
}

enable_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  cat >"$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
EOF
}

valid_port_token() {
  local token="$1" start end
  if [[ "$token" =~ ^[0-9]+$ ]]; then
    (( 10#$token >= 1 && 10#$token <= 65535 ))
    return
  fi
  if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
    (( 10#$start >= 1 && 10#$start <= 65535 && 10#$end >= 1 && 10#$end <= 65535 && 10#$start <= 10#$end ))
    return
  fi
  return 1
}

validate_protocol() {
  case "$1" in
    tcp|udp|all) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_ipv4() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS=. octets
    read -r -a octets <<<"$host"
    for octet in "${octets[@]}"; do
      [[ "$octet" =~ ^[0-9]+$ ]] && (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
    printf '%s\n' "$host"
    return 0
  fi

  getent ahostsv4 "$host" | awk 'NR == 1 { print $1 }'
}

escape_comment() {
  printf '%s' "$1" | tr '"\\' '__'
}

protocols_for_rule() {
  case "$1" in
    tcp) printf 'tcp\n' ;;
    udp) printf 'udp\n' ;;
    all) printf 'tcp\nudp\n' ;;
  esac
}

generate_nft_script() {
  local table_name="${1:-$NFT_TABLE}"
  local line proto local_port remote_addr remote_port snat comment target_ip p safe_comment

  cat <<EOF
#!/usr/sbin/nft -f

add table ip $table_name
add chain ip $table_name prerouting { type nat hook prerouting priority dstnat; policy accept; }
add chain ip $table_name postrouting { type nat hook postrouting priority srcnat; policy accept; }

EOF

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue

    IFS='|' read -r proto local_port remote_addr remote_port snat comment <<<"$line"
    proto="${proto:-all}"
    snat="${snat:-off}"
    comment="${comment:-}"

    if ! validate_protocol "$proto"; then
      yellow "跳过无效协议配置：$line" >&2
      continue
    fi
    if ! valid_port_token "$local_port" || ! valid_port_token "$remote_port"; then
      yellow "跳过无效端口配置：$line" >&2
      continue
    fi

    target_ip="$(resolve_ipv4 "$remote_addr" || true)"
    if [[ -z "$target_ip" ]]; then
      yellow "跳过无法解析的远程地址：$remote_addr" >&2
      continue
    fi

    safe_comment="$(escape_comment "${comment:-$local_port->$remote_addr:$remote_port}")"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      printf 'add rule ip %s prerouting %s dport %s counter dnat to %s:%s comment "nfwd:%s"\n' \
        "$table_name" "$p" "$local_port" "$target_ip" "$remote_port" "$safe_comment"
      if [[ "$snat" == "on" || "$snat" == "true" || "$snat" == "yes" || "$snat" == "1" ]]; then
        printf 'add rule ip %s postrouting ip daddr %s %s dport %s counter masquerade comment "nfwd:%s"\n' \
          "$table_name" "$target_ip" "$p" "$remote_port" "$safe_comment"
      fi
    done < <(protocols_for_rule "$proto")
    printf '\n'
  done <"$CONFIG_FILE"
}

apply_config() {
  local tmp check_tmp check_table
  tmp="$(mktemp)"
  check_tmp="$(mktemp)"
  check_table="${NFT_TABLE}_check_$$"
  generate_nft_script "$check_table" >"$check_tmp"

  if ! "$NFT_BIN" -c -f "$check_tmp"; then
    rm -f "$tmp" "$check_tmp"
    return 1
  fi
  rm -f "$check_tmp"

  generate_nft_script "$NFT_TABLE" >"$tmp"
  if "$NFT_BIN" list table ip "$NFT_TABLE" >/dev/null 2>&1; then
    "$NFT_BIN" delete table ip "$NFT_TABLE"
  fi

  "$NFT_BIN" -f "$tmp"
  rm -f "$tmp"
}

port_contains() {
  local rule_port="$1" wanted="$2" start end
  [[ "$rule_port" == "$wanted" ]] && return 0
  [[ "$wanted" =~ ^[0-9]+$ ]] || return 1
  if [[ "$rule_port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
    (( 10#$wanted >= 10#$start && 10#$wanted <= 10#$end ))
    return
  fi
  return 1
}

local_port_exists() {
  local wanted="$1" line proto local_port rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r proto local_port rest <<<"$line"
    if port_contains "$local_port" "$wanted"; then
      return 0
    fi
  done <"$CONFIG_FILE"
  return 1
}

delete_by_port() {
  local wanted="$1" mode="${2:-local}" tmp line proto local_port remote_addr remote_port removed=0 match_port
  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$line" >>"$tmp"
      continue
    fi

    IFS='|' read -r proto local_port remote_addr remote_port _ <<<"$line"
    if [[ "$mode" == "remote" ]]; then
      match_port="$remote_port"
    else
      match_port="$local_port"
    fi

    if port_contains "$match_port" "$wanted"; then
      removed=$((removed + 1))
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$CONFIG_FILE"

  if (( removed == 0 )); then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$CONFIG_FILE"
  return 0
}

add_rule() {
  local local_port remote_port remote_addr comment line

  clear || true
  info "增加规则"
  info "本地端口：客户端访问中转机 A 的对外端口，例如 2222 或 20000-20100"
  info "远程端口：后端 B 服务器实际服务端口，例如 22 或 20000-20100"
  info "远程地址：后端 B 服务器 IPv4 地址或域名"
  info "默认不做 SNAT，后端 B 会看到真实客户端源 IP；这要求 B 的回程路由经过 A。"
  printf '\n'

  read -rp "请输入本地端口: " local_port
  valid_port_token "$local_port" || { red "端口格式无效"; pause; return; }

  read -rp "请输入远程端口: " remote_port
  valid_port_token "$remote_port" || { red "端口格式无效"; pause; return; }

  read -rp "请输入远程地址: " remote_addr
  [[ -n "$(resolve_ipv4 "$remote_addr" || true)" ]] || { red "远程地址无法解析为 IPv4"; pause; return; }

  read -rp "请输入备注（可留空）: " comment

  if local_port_exists "$local_port"; then
    yellow "本地端口 $local_port 已存在，将覆盖旧配置。"
    delete_by_port "$local_port" local || true
  fi

  line="all|$local_port|$remote_addr|$remote_port|off|$comment"
  printf '%s\n' "$line" >>"$CONFIG_FILE"

  if apply_config; then
    green "添加成功，已应用 nftables 规则。"
  else
    red "配置已写入，但应用 nftables 失败，请检查配置。"
  fi
  pause
}

remove_rule() {
  local port
  clear || true
  info "删减规则"
  info "请输入要删除的本地端口，也就是客户端访问中转机 A 的对外端口。"
  info "如果没有匹配本地端口，脚本会再按远程端口兜底尝试删除。"
  printf '\n'

  read -rp "请输入端口: " port
  valid_port_token "$port" || { red "端口格式无效"; pause; return; }

  if delete_by_port "$port" local; then
    if apply_config; then
      green "删除成功，本地端口 $port 的规则已移除并重新应用。"
    else
      red "本地配置已删除，但重新应用 nftables 失败，请手动检查。"
    fi
  elif delete_by_port "$port" remote; then
    if apply_config; then
      green "删除成功，远程端口 $port 的规则已移除并重新应用。"
    else
      red "本地配置已删除，但重新应用 nftables 失败，请手动检查。"
    fi
  else
    yellow "未找到端口 $port 对应的本地配置。"
  fi
  pause
}

show_active_rules() {
  clear || true
  info "当前iptables配置"
  printf '\n'
  if ! "$NFT_BIN" list table ip "$NFT_TABLE"; then
    yellow "当前没有 $NFT_TABLE 表，可能尚未应用配置。"
  fi
  pause
}

show_local_config() {
  clear || true
  info "所有转发规则"
  printf '\n'
  nl -ba "$CONFIG_FILE"
  pause
}

edit_local_config() {
  local editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    if command -v nano >/dev/null 2>&1; then
      editor="nano"
    else
      editor="vi"
    fi
  fi

  "$editor" "$CONFIG_FILE"
  if apply_config; then
    green "配置已重新应用。"
  else
    red "配置应用失败，请检查 $CONFIG_FILE。"
  fi
  pause
}

chain_has_comment() {
  local family="$1" text="$2"
  "$NFT_BIN" list chain "$family" filter FORWARD 2>/dev/null | grep -Fq "$text"
}

forward_policy_is_drop() {
  local family="$1" chain
  chain="$("$NFT_BIN" list chain "$family" filter FORWARD 2>/dev/null || true)"
  [[ "$chain" == *"hook forward"* && "$chain" == *"policy drop"* ]]
}

apply_docker_compat_for_family() {
  local family="$1" tmp
  forward_policy_is_drop "$family" || return 0

  yellow "检测到 $family filter FORWARD 为 policy drop，正在添加 Docker/nftables NAT 兼容放行规则。"
  tmp="$(mktemp)"
  printf '#!/usr/sbin/nft -f\n' >"$tmp"

  if ! chain_has_comment "$family" "nfwd docker compat established"; then
    printf 'insert rule %s filter FORWARD ct state established,related counter accept comment "nfwd docker compat established"\n' "$family" >>"$tmp"
  fi

  if ! chain_has_comment "$family" "nfwd docker compat dnat"; then
    printf 'insert rule %s filter FORWARD ct status dnat counter accept comment "nfwd docker compat dnat"\n' "$family" >>"$tmp"
  fi

  "$NFT_BIN" -f "$tmp" || true
  rm -f "$tmp"
}

apply_docker_compat() {
  apply_docker_compat_for_family ip
  apply_docker_compat_for_family ip6
}

menu() {
  while true; do
    clear || true
    info "你要做什么呢（请输入数字）？Ctrl+C 退出本脚本"
    info "1）增加转发规则              3）列出所有转发规则"
    info "2）删除转发规则              4）查看当前iptables配置"
    read -rp "#? " choice

    case "$choice" in
      1) add_rule ;;
      2) remove_rule ;;
      3) show_local_config ;;
      4) show_active_rules ;;
      *) yellow "无效选择"; pause ;;
    esac
  done
}

main() {
  require_root
  require_nftables
  init_config
  enable_forwarding
  apply_docker_compat

  if ! apply_config; then
    yellow "本地配置加载失败，请进入菜单检查配置。"
    pause
  fi
  menu
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  main "$@"
fi
