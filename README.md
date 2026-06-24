# nftables-reply

Debian 11+ nftables 端口转发交互管理脚本。

## 快速启动

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/nft-forward-manager.sh)
```

首次运行时，如果 Debian/Ubuntu 没有安装 `nftables`，脚本会自动执行：

```bash
apt-get update
apt-get install -y nftables
systemctl enable --now nftables
```

## 卸载

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/uninstall.sh)
```

卸载脚本会删除：

- nftables 表：`ip nfwd_nat`
- 本地配置目录：`/etc/nft-forward-manager`
- sysctl 配置：`/etc/sysctl.d/99-nft-forward-manager.conf`

卸载时会询问是否把 `ip/ip6 filter FORWARD policy` 改回 `drop`。如果你的服务器还在使用 Docker 或其它转发服务，不确定时建议选择 `n`。

## 功能

- 增加规则
- 删减规则
- 列出所有转发规则
- 查看当前 nftables 配置
- 编辑本地配置并导入
- 默认 `snat=off`，保留客户端源 IP
- 检测 Docker/iptables-nft 的 `FORWARD policy drop` 并改为 `policy accept` 以兼容 NAT 转发

## 菜单

```text
你要做什么呢（请输入数字）？Ctrl+C 退出本脚本
1）增加转发规则              3）列出所有转发规则
2）删除转发规则              4）查看当前nftables配置
5）编辑本地配置
#?
```

第 4 项输出的是可复制的本地配置内容。复制后可以进入第 5 项直接粘贴导入，最后单独输入一行：

```text
EOF
```

脚本会立即应用新配置。

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
- `remote_addr`：后端 B 服务器 IPv4 地址或域名
- `remote_port`：后端 B 服务器实际服务端口
- `snat`：`off` 保留真实客户端 IP，`on` 让 B 看到来源为 A

示例：

```text
all|20000-20100|203.0.113.10|20000-20100|off|game range
tcp|2222|203.0.113.10|22|off|ssh
```
