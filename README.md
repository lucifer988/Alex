# Alex

Alex 是面向 Linux OpenPPP2 的双端自动调优工具。它从 OpenPPP2 客户端节点运行，通过 SSH 同时控制对应服务端，测试真实 PPP 隧道，选择综合表现最好的参数并永久保存。

默认接入上限固定为：

- 下载：`1000 Mbps`
- 上传：`60 Mbps`

评分不会因为本地网卡显示 2.5G/10G 而提高目标上限。

## 做什么

- 通过 SSH 同时备份客户端和服务端配置；
- 扫描 `concurrent`、MUX 模式、MUX turbo、发送队列、重排窗口和 TUN 队列；
- 每个方向至少测试三次并取中位数；
- 同时考察吞吐、重传、CPU 和本次测试新增的 TUN 丢包；
- 每个候选失败时恢复两端原配置；
- 最优解写回两端 `appsettings.json`；
- 使用 systemd drop-in 永久保存 TUN `txqueuelen`；
- 提交后重启两端并再次复验；
- 成功或已验证回退后清理候选、远端 helper 和事务材料；
- SSH 中断时，两端 45 分钟 watchdog 自动恢复原配置。

Alex 不修改 OpenPPP2 密钥、服务器地址、代理、路由、DNS、SNAT 或其他未知 JSON 字段。

## 前置条件

客户端和服务端需要：

- Linux + systemd；
- OpenPPP2 由 systemd 单实例管理；
- `appsettings.json` 是有效 JSON；
- TUN 隧道内服务端地址可达，默认 `10.0.0.1`；
- SSH 密钥登录和可用的 `sudo`；
- 管理 SSH 路径不能依赖即将重启的 PPP 隧道。

本机安装脚本会安装 `jq`、`iperf3`、OpenSSH client、`util-linux` 和 `iproute2` 等缺失依赖。远端必须已有 `jq`、`iperf3`、`iproute2`、systemd 和 coreutils。

## 安装

```bash
git clone --depth=1 https://github.com/lucifer988/Alex.git
cd Alex
sudo bash install.sh
```

## 准备 SSH 主机指纹

Alex 强制 `StrictHostKeyChecking=yes`，不会自动信任未知或发生变化的主机密钥。

先查看服务端指纹：

```bash
ssh-keyscan -p 22 SERVER_IP > /tmp/alex-known-hosts
ssh-keygen -lf /tmp/alex-known-hosts
```

通过服务商控制台或其他独立渠道核对指纹后安装：

```bash
sudo install -m 0644 /tmp/alex-known-hosts /etc/alex/known_hosts
rm -f /tmp/alex-known-hosts
```

## 一键调优

从 OpenPPP2 **客户端节点**执行：

```bash
sudo alex optimize \
  --ssh-host SERVER_IP \
  --ssh-user root \
  --ssh-key /root/.ssh/id_ed25519 \
  --yes
```

默认使用：

```text
客户端配置   /opt/openppp2/appsettings.json
服务端配置   /opt/openppp2/appsettings.json
客户端服务   openppp2-client.service
服务端服务   openppp2-server.service
客户端 TUN   ppp0
服务端 TUN   ppp0
隧道服务端   10.0.0.1
测速端口     5201
测试时长     每方向 15 秒 x 3 次
```

实际名称不同可以覆盖：

```bash
sudo alex optimize \
  --ssh-host SERVER_IP \
  --ssh-key /root/.ssh/id_ed25519 \
  --local-config /etc/openppp2/client.json \
  --remote-config /etc/openppp2/server.json \
  --local-service ppp-client.service \
  --remote-service ppp-server.service \
  --tun-server 10.0.0.1 \
  --yes
```

## 只检测

只做双端备份、基准测试和验证，完成后恢复并清理：

```bash
sudo alex detect \
  --ssh-host SERVER_IP \
  --ssh-key /root/.ssh/id_ed25519
```

查看将扫描的候选，不修改配置：

```bash
sudo alex optimize \
  --ssh-host SERVER_IP \
  --ssh-key /root/.ssh/id_ed25519 \
  --dry-run
```

## 回退说明

未提交事务会由 watchdog 自动回退。成功事务在最终复验后会清理过程资料，因此正常完成后不保留长期回退副本。需要长期人工回退时，应在运行 Alex 前使用现有备份系统保存两端 OpenPPP2 配置和 systemd 状态。

## 选择最优解

下载占评分 70%，上传占 30%，分别封顶于 `1000/60 Mbps`。以下情况会淘汰候选：

- 服务没有稳定恢复；
- TUN 在该次测试期间新增丢包；
- 任一方向测速失败；
- SSH 或远端状态无法确认；
- 最终持久化重启后复验失败。

重传和 CPU 超过 85% 会扣分。工具不会为了很小的峰值增益保存明显更不稳定的组合。

## 安全边界

- 仅接受固定子命令，不通过 SSH 执行用户提供的任意 shell；
- 不支持 `sshpass -p` 或命令行密码；
- 不使用 `StrictHostKeyChecking=no`；
- 每端使用 `/run/lock/alex-openppp2.lock` 防止并发事务；
- 配置通过 `jq` 结构化修改和同目录原子替换；
- 远端 helper 上传后校验 SHA-256；
- 过程文件权限为 `0600/0700`；
- 配置或路径异常时默认失败并回退。

## 开发验证

```bash
bash tests/test_alex.sh
bash tests/test_node_transaction.sh
bash -n alex alex-node install.sh lib/alex-core.sh tests/test_alex.sh tests/test_node_transaction.sh
shellcheck -x -e SC1091,SC2029,SC2034 alex alex-node install.sh lib/alex-core.sh tests/test_alex.sh tests/test_node_transaction.sh
```

## License

MIT
