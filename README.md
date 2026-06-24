# nftables-reply

Debian 11+ nftables 端口转发管理脚本，适合把中转机 A 的本地端口转发到后端 B 的指定端口。

## 快速启动

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/nftfw.sh)
```

如果当前不是 root，请使用：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/nftfw.sh)
```

首次运行时，脚本会自动补齐 Debian/Ubuntu 上的 nftables 环境：

```bash
apt-get update
apt-get install -y nftables
systemctl enable --now nftables
```

## 特性

- 支持 TCP、UDP 和 TCP+UDP
- 支持单端口和端口段
- 支持 IPv4、IPv6 和域名 A/AAAA 解析
- 默认 `snat=on`，优先保证转发直接可用
- 支持开机自动恢复转发规则
- 支持导入本地配置，导入前会先校验
- 使用 nftables 内核转发，不启动用户态监听进程

## 菜单

```text
你要做什么呢（请输入数字）？Ctrl+C 退出本脚本
1）增加转发规则              3）列出所有转发规则
2）删除转发规则              4）查看本地规则配置
5）编辑本地配置              6）转发诊断
#?
```

第 3 项会用表格简洁显示当前转发规则。第 4 项会直接输出原始本地配置，可复制后粘贴到第 5 项导入。第 5 项导入时，粘贴配置后单独输入一行：

```text
EOF
```

新增规则只会询问：

- 本地端口：客户端访问中转机 A 的端口
- 远程端口：后端 B 实际服务端口
- 远程地址：后端 B 的 IPv4、IPv6 或域名

新增规则默认：

```text
protocol=all
snat=on
comment=
```

## 配置格式

配置文件位置：

```text
/etc/nft-forward-manager/rules.conf
```

格式：

```text
protocol|local_port|remote_addr|remote_port|snat|comment
```

字段说明：

- `protocol`：`tcp`、`udp` 或 `all`
- `local_port`：中转机 A 对外端口，支持单端口或端口段
- `remote_addr`：后端 B 的 IPv4、IPv6 或域名
- `remote_port`：后端 B 实际服务端口，支持单端口或端口段
- `snat`：`on` 让 B 看到来源为 A，通常直接可用；`off` 保留真实客户端 IP，但要求 B 的回程路由经过 A
- `comment`：备注，可留空

示例：

```text
all|20000-20100|203.0.113.10|20000-20100|on|game ipv4
all|20000-20100|2001:db8::10|20000-20100|on|game ipv6
all|20000-20100|example.com|20000-20100|on|game domain
tcp|2222|203.0.113.10|22|on|ssh
```

域名会解析 A 和 AAAA 记录：A 记录生成 IPv4 转发，AAAA 记录生成 IPv6 转发。

## 工作方式

脚本使用 nftables 的内核 DNAT/SNAT 转发，不启动用户态监听进程，所以：

```bash
lsof -i:端口
```

没有结果是正常的，不能用它判断转发是否生效。

正确检查方式：

```bash
nft list table ip nfwd_nat
nft list table ip6 nfwd_nat
```

从外部客户端访问中转机 A 的本地端口后，看对应规则的 `counter` 是否增加。

更新规则时，脚本不会删除整张 nftables 表；它会确保 `ip/ip6 nfwd_nat` 表和链存在，然后 `flush` 本脚本自己的链并重新写入规则。这样比删除整表再重建更稳。

## 持久化

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
bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/uninstall.sh)
```

如果当前不是 root，请使用：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/uninstall.sh)
```

卸载脚本会删除：

- systemd 服务：`/etc/systemd/system/nftfw-restore.service`
- 旧 systemd 服务：`/etc/systemd/system/nft-forward-manager-restore.service`
- 本地脚本：`/usr/local/sbin/nftfw`
- 旧本地脚本：`/usr/local/sbin/nft-forward-manager`
- nftables 表：`ip nfwd_nat`
- nftables 表：`ip6 nfwd_nat`
- 本地配置目录：`/etc/nft-forward-manager`
- sysctl 配置：`/etc/sysctl.d/99-nft-forward-manager.conf`

卸载时会询问是否把常见 forward 链的 `policy` 改回 `drop`。如果服务器还在使用 Docker 或其它转发服务，不确定时建议选择 `n`。
