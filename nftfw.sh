#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${NFWD_CONFIG_DIR:-/etc/nft-forward-manager}"
CONFIG_FILE="${NFWD_CONFIG_FILE:-$CONFIG_DIR/rules.conf}"
SYSCTL_FILE="${NFWD_SYSCTL_FILE:-/etc/sysctl.d/99-nft-forward-manager.conf}"
NFT_BIN="${NFWD_NFT_BIN:-$(command -v nft 2>/dev/null || printf '/usr/sbin/nft')}"
NFT_TABLE="${NFWD_NFT_TABLE:-nfwd_nat}"
MANAGER_BIN="${NFWD_MANAGER_BIN:-/usr/local/sbin/nftfw}"
SERVICE_NAME="${NFWD_SERVICE_NAME:-nftfw-restore.service}"
SERVICE_FILE="${NFWD_SERVICE_FILE:-/etc/systemd/system/$SERVICE_NAME}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

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
    install_nftables
  fi

  if [[ ! -x "$NFT_BIN" ]]; then
    die "未找到 $NFT_BIN，且自动安装失败。请手动执行：apt update && apt install -y nftables"
  fi
}

install_nftables() {
  if [[ -f /etc/debian_version ]] && command -v apt-get >/dev/null 2>&1; then
    yellow "未检测到 nftables，正在自动安装依赖环境..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now nftables >/dev/null 2>&1 || true
    fi
    return
  fi

  die "未检测到 nftables，当前系统不支持自动安装。Debian/Ubuntu 可执行：apt update && apt install -y nftables"
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
# remote_addr : 后端 B 服务器 IPv4/IPv6 地址或可解析域名
# remote_port : 后端 B 服务器实际服务端口，支持单端口或端口段
# snat        : on / off；默认 on，on 表示 B 看到来源为 A；off 需要 B 的回程路由经过 A
# comment     : 可选备注
#
# 示例：
# all|20000-20100|203.0.113.10|20000-20100|on|game udp/tcp range
# all|20000-20100|2001:db8::10|20000-20100|on|game ipv6
# all|20000-20100|example.com|20000-20100|on|game domain
# tcp|2222|203.0.113.10|22|on|ssh
EOF
  fi
}

install_persistence() {
  local source_path="${BASH_SOURCE[0]:-}"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now nft-forward-manager-restore.service >/dev/null 2>&1 || true
  fi
  rm -f /etc/systemd/system/nft-forward-manager-restore.service
  rm -f /usr/local/sbin/nft-forward-manager

  if [[ -n "$source_path" && -r "$source_path" && "$source_path" != "$MANAGER_BIN" ]]; then
    mkdir -p "$(dirname "$MANAGER_BIN")"
    cp "$source_path" "$MANAGER_BIN"
    chmod 0755 "$MANAGER_BIN"
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ -x "$MANAGER_BIN" ]]; then
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=nftfw restore
After=network-online.target nftables.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MANAGER_BIN --apply-only
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}

enable_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
  cat >"$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
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

validate_snat() {
  case "$1" in
    on|off|true|false|yes|no|1|0|"") return 0 ;;
    *) return 1 ;;
  esac
}

strip_ipv6_brackets() {
  local host="$1"
  host="${host#[}"
  host="${host%]}"
  printf '%s\n' "$host"
}

is_ipv4_literal() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS=. octets
    read -r -a octets <<<"$host"
    for octet in "${octets[@]}"; do
      [[ "$octet" =~ ^[0-9]+$ ]] && (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
    return 0
  fi
  return 1
}

is_ipv6_literal() {
  local host
  host="$(strip_ipv6_brackets "$1")"
  [[ "$host" == *:* && "$host" =~ ^[0-9A-Fa-f:.]+$ ]]
}

resolve_ipv4() {
  local host
  host="$(strip_ipv6_brackets "$1")"

  if is_ipv4_literal "$host"; then
    printf '%s\n' "$host"
    return 0
  fi

  command -v getent >/dev/null 2>&1 || return 0
  getent ahostsv4 "$host" | awk '$1 ~ /^[0-9.]+$/ { print $1; exit }'
}

resolve_ipv6() {
  local host
  host="$(strip_ipv6_brackets "$1")"

  if is_ipv6_literal "$host"; then
    if command -v getent >/dev/null 2>&1; then
      getent ahostsv6 "$host" | awk '$1 ~ /:/ { print $1; exit }'
      return 0
    fi
    printf '%s\n' "$host"
    return 0
  fi

  command -v getent >/dev/null 2>&1 || return 0
  getent ahostsv6 "$host" | awk '$1 ~ /:/ { print $1; exit }'
}

resolve_targets() {
  local host="$1" ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && printf 'ip|%s\n' "$ip"
  done < <(resolve_ipv4 "$host" || true)

  while IFS= read -r ip; do
    [[ -n "$ip" ]] && printf 'ip6|%s\n' "$ip"
  done < <(resolve_ipv6 "$host" || true)
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

generate_nft_table_setup_script() {
  local table_name="${1:-$NFT_TABLE}"

  cat <<EOF
#!/usr/sbin/nft -f

add table ip $table_name
add chain ip $table_name prerouting { type nat hook prerouting priority dstnat; policy accept; }
add chain ip $table_name postrouting { type nat hook postrouting priority srcnat; policy accept; }

add table ip6 $table_name
add chain ip6 $table_name prerouting { type nat hook prerouting priority dstnat; policy accept; }
add chain ip6 $table_name postrouting { type nat hook postrouting priority srcnat; policy accept; }

EOF
}

generate_nft_rules() {
  local table_name="${1:-$NFT_TABLE}"
  local line proto local_port remote_addr remote_port snat comment family target_ip p safe_comment target targets

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue

    IFS='|' read -r proto local_port remote_addr remote_port snat comment <<<"$line"
    proto="${proto:-all}"
    snat="${snat:-on}"
    comment="${comment:-}"

    if ! validate_protocol "$proto"; then
      yellow "跳过无效协议配置：$line" >&2
      continue
    fi
    if ! valid_port_token "$local_port" || ! valid_port_token "$remote_port"; then
      yellow "跳过无效端口配置：$line" >&2
      continue
    fi

    targets="$(resolve_targets "$remote_addr" || true)"
    if [[ -z "$targets" ]]; then
      yellow "跳过无法解析的远程地址：$remote_addr" >&2
      continue
    fi

    safe_comment="$(escape_comment "${comment:-$local_port->$remote_addr:$remote_port}")"
    while IFS='|' read -r family target_ip; do
      [[ -z "$family" || -z "$target_ip" ]] && continue
      if [[ "$family" == "ip6" ]]; then
        target="[$target_ip]:$remote_port"
      else
        target="$target_ip:$remote_port"
      fi

      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        printf 'add rule %s %s prerouting %s dport %s counter dnat to %s comment "nfwd:%s"\n' \
          "$family" "$table_name" "$p" "$local_port" "$target" "$safe_comment"
        if [[ "$snat" == "on" || "$snat" == "true" || "$snat" == "yes" || "$snat" == "1" ]]; then
          printf 'add rule %s %s postrouting %s daddr %s %s dport %s counter masquerade comment "nfwd:%s"\n' \
            "$family" "$table_name" "$family" "$target_ip" "$p" "$remote_port" "$safe_comment"
        fi
      done < <(protocols_for_rule "$proto")
    done <<<"$targets"
    printf '\n'
  done <"$CONFIG_FILE"
}

generate_nft_script() {
  local table_name="${1:-$NFT_TABLE}"
  generate_nft_table_setup_script "$table_name"
  generate_nft_rules "$table_name"
}

generate_nft_apply_script() {
  local table_name="${1:-$NFT_TABLE}"

  cat <<EOF
#!/usr/sbin/nft -f

flush chain ip $table_name prerouting
flush chain ip $table_name postrouting
flush chain ip6 $table_name prerouting
flush chain ip6 $table_name postrouting

EOF

  generate_nft_rules "$table_name"
}

ensure_nft_family_table() {
  local family="$1" table_name="${2:-$NFT_TABLE}" tmp

  if ! "$NFT_BIN" list table "$family" "$table_name" >/dev/null 2>&1; then
    "$NFT_BIN" add table "$family" "$table_name" || return 1
  fi

  tmp="$(mktemp)"
  printf '#!/usr/sbin/nft -f\n' >"$tmp"
  if ! "$NFT_BIN" list chain "$family" "$table_name" prerouting >/dev/null 2>&1; then
    printf 'add chain %s %s prerouting { type nat hook prerouting priority dstnat; policy accept; }\n' "$family" "$table_name" >>"$tmp"
  fi
  if ! "$NFT_BIN" list chain "$family" "$table_name" postrouting >/dev/null 2>&1; then
    printf 'add chain %s %s postrouting { type nat hook postrouting priority srcnat; policy accept; }\n' "$family" "$table_name" >>"$tmp"
  fi

  if [[ "$(wc -l <"$tmp")" -gt 1 ]]; then
    "$NFT_BIN" -f "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  fi
  rm -f "$tmp"
}

ensure_nft_tables() {
  local table_name="${1:-$NFT_TABLE}"
  ensure_nft_family_table ip "$table_name"
  ensure_nft_family_table ip6 "$table_name"
}

apply_config() {
  local tmp check_tmp check_table

  validate_config_syntax "$CONFIG_FILE" || return 1

  tmp="$(mktemp)"
  check_tmp="$(mktemp)"
  check_table="${NFT_TABLE}_check_$$"
  generate_nft_script "$check_table" >"$check_tmp"

  if ! "$NFT_BIN" -c -f "$check_tmp"; then
    rm -f "$tmp" "$check_tmp"
    return 1
  fi
  rm -f "$check_tmp"

  ensure_nft_tables "$NFT_TABLE" || {
    rm -f "$tmp"
    return 1
  }

  generate_nft_apply_script "$NFT_TABLE" >"$tmp"

  if ! "$NFT_BIN" -c -f "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if ! "$NFT_BIN" -f "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

validate_config_file() {
  local file="$1" old_file tmp check_table
  old_file="$CONFIG_FILE"
  tmp="$(mktemp)"
  check_table="${NFT_TABLE}_check_$$"

  validate_config_syntax "$file" || {
    rm -f "$tmp"
    return 1
  }

  CONFIG_FILE="$file"
  generate_nft_script "$check_table" >"$tmp"
  CONFIG_FILE="$old_file"

  if "$NFT_BIN" -c -f "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

validate_config_syntax() {
  local file="$1" line proto local_port remote_addr remote_port snat comment lineno=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue

    IFS='|' read -r proto local_port remote_addr remote_port snat comment <<<"$line"
    proto="${proto:-all}"
    snat="${snat:-on}"

    if [[ -z "${local_port:-}" || -z "${remote_addr:-}" || -z "${remote_port:-}" ]]; then
      red "第 $lineno 行缺少字段：$line" >&2
      return 1
    fi
    if ! validate_protocol "$proto"; then
      red "第 $lineno 行协议无效，只支持 tcp/udp/all：$line" >&2
      return 1
    fi
    if ! valid_port_token "$local_port" || ! valid_port_token "$remote_port"; then
      red "第 $lineno 行端口无效：$line" >&2
      return 1
    fi
    if [[ -z "$(resolve_targets "$remote_addr" || true)" ]]; then
      red "第 $lineno 行远程地址无法解析为 IPv4/IPv6：$line" >&2
      return 1
    fi
    if ! validate_snat "$snat"; then
      red "第 $lineno 行 SNAT 字段无效，只支持 on/off：$line" >&2
      return 1
    fi
  done <"$file"
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
  local local_port remote_port remote_addr line backup

  clear || true
  info "增加规则"
  info "本地端口：客户端访问中转机 A 的对外端口，例如 2222 或 20000-20100"
  info "远程端口：后端 B 服务器实际服务端口，例如 22 或 20000-20100"
  info "远程地址：后端 B 服务器 IPv4/IPv6 地址或域名"
  info "默认开启 SNAT，后端 B 会看到来源为 A，这样通常不需要改 B 的回程路由。"
  printf '\n'

  read -rp "请输入本地端口: " local_port
  valid_port_token "$local_port" || { red "端口格式无效"; return; }

  read -rp "请输入远程端口: " remote_port
  valid_port_token "$remote_port" || { red "端口格式无效"; return; }

  read -rp "请输入远程地址: " remote_addr
  [[ -n "$(resolve_targets "$remote_addr" || true)" ]] || { red "远程地址无法解析为 IPv4/IPv6"; return; }

  backup="$(mktemp)"
  cp "$CONFIG_FILE" "$backup"

  if local_port_exists "$local_port"; then
    yellow "本地端口 $local_port 已存在，将覆盖旧配置。"
    delete_by_port "$local_port" local || true
  fi

  line="all|$local_port|$remote_addr|$remote_port|on|"
  printf '%s\n' "$line" >>"$CONFIG_FILE"

  if apply_config; then
    green "添加成功，已应用 nftables 规则。"
  else
    mv "$backup" "$CONFIG_FILE"
    apply_config >/dev/null 2>&1 || true
    red "添加失败，已恢复原配置。请检查 nftables 或目标配置。"
  fi
  rm -f "$backup"
}

remove_rule() {
  local port backup
  clear || true
  info "删减规则"
  info "请输入要删除的本地端口，也就是客户端访问中转机 A 的对外端口。"
  info "如果没有匹配本地端口，脚本会再按远程端口兜底尝试删除。"
  printf '\n'

  read -rp "请输入端口: " port
  valid_port_token "$port" || { red "端口格式无效"; return; }

  backup="$(mktemp)"
  cp "$CONFIG_FILE" "$backup"

  if delete_by_port "$port" local; then
    if apply_config; then
      green "删除成功，本地端口 $port 的规则已移除并重新应用。"
    else
      mv "$backup" "$CONFIG_FILE"
      apply_config >/dev/null 2>&1 || true
      red "删除失败，已恢复原配置。请检查 nftables 或目标配置。"
    fi
  elif delete_by_port "$port" remote; then
    if apply_config; then
      green "删除成功，远程端口 $port 的规则已移除并重新应用。"
    else
      mv "$backup" "$CONFIG_FILE"
      apply_config >/dev/null 2>&1 || true
      red "删除失败，已恢复原配置。请检查 nftables 或目标配置。"
    fi
  else
    yellow "未找到端口 $port 对应的本地配置。"
  fi
  rm -f "$backup"
}

list_forward_rules() {
  local line proto local_port remote_addr remote_port snat comment idx=0

  info "所有转发规则"
  printf '\n'
  printf '%-4s %-5s %-18s %-40s %-18s %-6s\n' "序号" "协议" "本地端口" "远程地址" "远程端口" "SNAT"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r proto local_port remote_addr remote_port snat comment <<<"$line"
    proto="${proto:-all}"
    snat="${snat:-on}"
    idx=$((idx + 1))
    printf '%-4s %-5s %-18s %-40s %-18s %-6s\n' "$idx" "$proto" "$local_port" "$remote_addr" "$remote_port" "$snat"
  done <"$CONFIG_FILE"

  if (( idx == 0 )); then
    yellow "暂无转发规则。"
  fi
}

show_current_nftables_config() {
  info "当前本地配置（可复制后粘贴到第5项导入）"
  printf '\n'
  cat "$CONFIG_FILE"
}

diagnose_forwarding() {
  info "转发诊断"
  printf '\n'
  info "说明：nftables DNAT 是内核转发，不会创建监听进程，所以 lsof -i:端口 没有结果是正常的。"
  printf '\n'

  info "IPv4 转发开关："
  sysctl net.ipv4.ip_forward 2>/dev/null || true
  printf '\n'

  info "IPv6 转发开关："
  sysctl net.ipv6.conf.all.forwarding 2>/dev/null || true
  printf '\n'

  info "本脚本 nftables NAT 表："
  if ! "$NFT_BIN" list table ip "$NFT_TABLE"; then
    yellow "当前没有 ip $NFT_TABLE 表。"
  fi
  "$NFT_BIN" list table ip6 "$NFT_TABLE" 2>/dev/null || yellow "当前没有 ip6 $NFT_TABLE 表。"
  printf '\n'

  info "常见 forward 链："
  "$NFT_BIN" list chain ip filter FORWARD 2>/dev/null || true
  "$NFT_BIN" list chain ip filter forward 2>/dev/null || true
  "$NFT_BIN" list chain ip6 filter FORWARD 2>/dev/null || true
  "$NFT_BIN" list chain ip6 filter forward 2>/dev/null || true
  "$NFT_BIN" list chain inet filter FORWARD 2>/dev/null || true
  "$NFT_BIN" list chain inet filter forward 2>/dev/null || true
  printf '\n'

  info "排查建议：从外部客户端访问 A 的本地端口后，再看上面 nfwd_nat 规则 counter 是否增加。"
}

edit_local_config() {
  local tmp backup line
  tmp="$(mktemp)"
  backup="$(mktemp)"
  cp "$CONFIG_FILE" "$backup"

  info "编辑本地配置"
  info "请直接粘贴完整配置，单独输入 EOF 结束并应用。"
  info "格式：protocol|local_port|remote_addr|remote_port|snat|comment"
  printf '\n'

  while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    printf '%s\n' "$line" >>"$tmp"
  done

  if ! validate_config_file "$tmp"; then
    red "导入配置校验失败，已保留原配置。"
    rm -f "$tmp" "$backup"
    return
  fi

  mv "$tmp" "$CONFIG_FILE"
  if apply_config; then
    green "配置已重新应用。"
  else
    mv "$backup" "$CONFIG_FILE"
    apply_config >/dev/null 2>&1 || true
    red "配置应用失败，请检查 $CONFIG_FILE。"
  fi
  rm -f "$backup"
}

forward_policy_is_drop() {
  local family="$1" table="$2" chain_name="$3" chain
  chain="$("$NFT_BIN" list chain "$family" "$table" "$chain_name" 2>/dev/null || true)"
  [[ "$chain" == *"hook forward"* && "$chain" == *"policy drop"* ]]
}

forward_chain_exists() {
  local family="$1" table="$2" chain_name="$3"
  "$NFT_BIN" list chain "$family" "$table" "$chain_name" >/dev/null 2>&1
}

forward_chain_has() {
  local family="$1" table="$2" chain_name="$3" pattern="$4"
  "$NFT_BIN" list chain "$family" "$table" "$chain_name" 2>/dev/null | grep -Fq "$pattern"
}

apply_forward_accept() {
  local family="$1" table="$2" chain_name="$3" tmp
  forward_chain_exists "$family" "$table" "$chain_name" || return 0

  yellow "正在兼容 $family $table $chain_name 的 NAT 转发放行规则。"
  tmp="$(mktemp)"
  {
    printf '#!/usr/sbin/nft -f\n'
    if ! forward_chain_has "$family" "$table" "$chain_name" "ct state established,related"; then
      printf 'insert rule %s %s %s ct state established,related counter accept\n' "$family" "$table" "$chain_name"
    fi
    if ! forward_chain_has "$family" "$table" "$chain_name" "ct status dnat"; then
      printf 'insert rule %s %s %s ct status dnat counter accept\n' "$family" "$table" "$chain_name"
    fi
    if forward_policy_is_drop "$family" "$table" "$chain_name"; then
      printf 'chain %s %s %s { policy accept ; }\n' "$family" "$table" "$chain_name"
    fi
  } >"$tmp"
  "$NFT_BIN" -f "$tmp" || true
  rm -f "$tmp"
}

apply_docker_compat() {
  apply_forward_accept ip filter FORWARD
  apply_forward_accept ip filter forward
  apply_forward_accept ip6 filter FORWARD
  apply_forward_accept ip6 filter forward
  apply_forward_accept inet filter FORWARD
  apply_forward_accept inet filter forward
}

menu() {
  while true; do
    printf '\n'
    info "你要做什么呢（请输入数字）？Ctrl+C 退出本脚本"
    info "1）增加转发规则              3）列出所有转发规则"
    info "2）删除转发规则              4）查看本地规则配置"
    info "5）编辑本地配置              6）转发诊断"
    read -rp "#? " choice

    case "$choice" in
      1) add_rule ;;
      2) remove_rule ;;
      3) list_forward_rules ;;
      4) show_current_nftables_config ;;
      5) edit_local_config ;;
      6) diagnose_forwarding ;;
      *) yellow "无效选择" ;;
    esac
  done
}

apply_only() {
  require_root
  require_nftables
  init_config
  enable_forwarding
  apply_docker_compat

  apply_config
}

main() {
  if [[ "${1:-}" == "--apply-only" ]]; then
    apply_only
    exit $?
  fi

  require_root
  require_nftables
  init_config
  install_persistence
  enable_forwarding
  apply_docker_compat

  if ! apply_config; then
    yellow "本地配置加载失败，请进入菜单检查配置。"
  fi

  menu
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  main "$@"
fi
