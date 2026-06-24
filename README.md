# nftables-reply

Debian 11+ nftables 端口转发交互管理脚本。

## 快速启动

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/SadNoo/nftables-reply/main/nft-forward-manager.sh)
```

## 功能

- 增加规则
- 删减规则
- 查看当前 nftables 规则
- 查看当前本地配置
- 编辑本地配置
- 重新应用本地配置
- 默认 `snat=off`，保留客户端源 IP
- 检测 Docker/iptables-nft 的 `FORWARD policy drop` 并添加 NAT 转发兼容规则

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
