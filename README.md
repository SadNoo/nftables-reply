# nftables-reply

Debian 11+ nftables 端口转发交互管理脚本。

## 快速启动

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/nftfw.sh)
```

首次运行时，如果 Debian/Ubuntu 没有安装 `nftables`，脚本会自动执行：

```bash
apt-get update
apt-get install -y nftables
systemctl enable --now nftables
```

脚本会自动安装到：

```text
/usr/local/sbin/nftfw
```

并创建开机恢复服务：

```text
/etc/systemd/system/nftfw-restore.service
```

服务器重启后会自动执行：

```bash
/usr/local/sbin/nftfw --apply-only
```

从 `/etc/nft-forward-manager/rules.conf` 恢复转发规则。

## 卸载

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/uninstall.sh)
```

卸载脚本会删除：

- systemd 服务：`/etc/systemd/system/nft-forward-manager-restore.service`
- systemd 服务：`/etc/systemd/system/nftfw-restore.service`
- 旧本地脚本：`/usr/local/sbin/nft-forward-manager`
- 本地脚本：`/usr/local/sbin/nftfw`
- nftables 表：`ip nfwd_nat`
- nftables 表：`ip6 nfwd_nat`
- 本地配置目录：`/etc/nft-forward-manager`
- sysctl 配置：`/etc/sysctl.d/99-nft-forward-manager.conf`

卸载时会询问是否把常见 forward 链的 `policy` 改回 `drop`。如果你的服务器还在使用 Docker 或其它转发服务，不确定时建议选择 `n`。

## 功能

- 增加规则
- 删减规则
- 简洁列出所有转发规则
- 查看当前本地配置，可直接复制
- 编辑本地配置并导入
- 开机自动恢复转发规则
- 支持 IPv4、IPv6、域名 A/AAAA 记录解析
- 默认 `snat=on`，优先保证直接可用；需要保留客户端源 IP 时可改为 `off`
- 检测 Docker/iptables-nft 的 `FORWARD policy drop` 并改为 `policy accept` 以兼容 NAT 转发
- 转发诊断，查看 `ip_forward`、nftables NAT 表和 counter

## 菜单

```text
你要做什么呢（请输入数字）？Ctrl+C 退出本脚本
1）增加转发规则              3）列出所有转发规则
2）删除转发规则              4）查看本地规则配置
5）编辑本地配置              6）转发诊断
#?
```

第 3 项会以表格方式简洁展示当前规则。第 4 项会 `cat` 原始本地配置，复制后可以进入第 5 项直接粘贴导入，最后单独输入一行：

```text
EOF
```

脚本会先校验导入内容，校验通过才会覆盖原配置并立即应用；校验失败会保留原配置。

新增规则只需要输入本地端口、远程端口和远程地址。脚本默认使用：

```text
protocol=all
snat=on
comment=
```

## 重要说明

nftables 做的是内核 DNAT 转发，不会创建用户态监听进程，所以：

```bash
lsof -i:端口
```

没有结果是正常的，不能用它判断 nftables 转发是否生效。

正确检查方式：

```bash
nft list table ip nfwd_nat
nft list table ip6 nfwd_nat
```

从外部客户端访问中转机 A 的本地端口后，看对应规则的 `counter` 是否增加。

## 配置位置

```text
/etc/nft-forward-manager/rules.conf
```

配置格式：

```text
protocol|local_port|remote_addr|remote_port|snat|comment
```

字段含义：

- `local_port`：客户端访问中转机 A 的对外端口
- `remote_addr`：后端 B 服务器 IPv4/IPv6 地址或域名
- `remote_port`：后端 B 服务器实际服务端口
- `snat`：`on` 让 B 看到来源为 A，通常直接可用；`off` 保留真实客户端 IP，但要求 B 的回程路由经过 A

示例：

```text
all|20000-20100|203.0.113.10|20000-20100|on|game range
all|20000-20100|2001:db8::10|20000-20100|on|game ipv6
all|20000-20100|example.com|20000-20100|on|game domain
tcp|2222|203.0.113.10|22|on|ssh
```

域名会自动解析 A 和 AAAA 记录：A 记录生成 IPv4 转发，AAAA 记录生成 IPv6 转发。
