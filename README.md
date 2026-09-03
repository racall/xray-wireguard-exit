# Xray VLESS + REALITY + WireGuard 多出口

本目录包含两个面向 Ubuntu/Debian 的交互式脚本：

- `inbounds.sh`：运行在入口机，提供 VLESS + REALITY + TCP，并允许每个 VLESS 用户选择直连或指定的 WireGuard 出口。
- `outbounds.sh`：运行在出口机，接收入口机经 WireGuard 发来的流量，然后通过出口机公网 NAT 上网。

适合 Shadowrocket 的分享链接格式：

```text
vless://UUID@入口地址:端口?encryption=none&fp=chrome&pbk=REALITY公钥&security=reality&sid=短ID&sni=伪装域名&spx=%2F路径&type=tcp#节点名称
```

本脚本没有启用 XTLS Vision，所以链接中不需要 `flow` 参数。

## 一、先理解机器角色

```text
Shadowrocket
     │ VLESS + REALITY + TCP
     ▼
入口机 inbounds.sh
     │ 每个出口一条独立 WireGuard 隧道
     ├──────────────► 出口机 A outbounds.sh ──► Internet
     └──────────────► 出口机 B outbounds.sh ──► Internet
```

入口机负责接收客户端连接；出口机只负责 WireGuard、转发和 NAT。一台入口机可以配置多个出口，一台出口机也可以登记多台入口机。

## 二、安装与启动

在对应服务器上传脚本，然后执行：

```bash
chmod +x inbounds.sh outbounds.sh
sudo ./inbounds.sh
```

出口服务器运行：

```bash
sudo ./outbounds.sh
```

脚本仅支持 Ubuntu 和 Debian，必须使用 root 或 `sudo` 运行。

## 三、入口机初始化

在入口机运行 `sudo ./inbounds.sh`，选择：

```text
1) 初始化入口机
```

依次填写：

- 入口机公网域名或 IPv4：客户端实际访问的地址，不要带 `http://`。
- VLESS 客户端端口：例如 `443`、`17708`。
- REALITY 伪装域名：例如 `www.microsoft.com` 或已确认支持 TLS 1.3 的正常网站。

脚本会自动生成 REALITY 密钥、Short ID 和 SpiderX 路径，并创建 `/usr/local/etc/xray/config.json`；添加 VLESS 用户时再为该用户自动生成 UUID。

如果以前运行的是本脚本的 XHTTP 版本，也必须重新选择一次“初始化入口机”，让服务端真正切换为 TCP。只复制新的 `type=tcp` 链接不会改变服务端协议。

入口机云安全组和防火墙需要放行：

```text
VLESS端口/TCP
每个WireGuard端口/UDP
```

## 四、添加一个新出口：完整步骤

下面以第二个出口 `vircs-att` 为例：

```text
入口隧道地址：10.66.67.1/24
入口监听端口：51821/UDP
出口隧道地址：10.66.67.254/24
隧道网段：    10.66.67.0/24
```

### 第 1 步：入口机创建出口

入口机菜单选择：

```text
2) 添加 WireGuard 出口
```

示例输入：

```text
新出口名称：vircs-att
本入口在该隧道的地址：10.66.67.1/24
本入口监听的 UDP 端口：51821
出口机 WireGuard 公钥：第一次尚未获得，直接回车
```

脚本会输出：

```text
入口 WireGuard endpoint : 入口域名或IP:51821
入口 WireGuard 公钥     : 一串Base64公钥
入口隧道 IP             : 10.66.67.1/32
```

保存这三项，并在入口机云安全组放行 `51821/UDP`。

### 第 2 步：初始化对应出口机

在新的出口服务器运行：

```bash
sudo ./outbounds.sh
```

选择：

```text
1) 初始化或重新配置出口机
```

对于上面的 `vircs-att`，填写：

```text
WireGuard 接口名称：wg-exit
出口机隧道地址：10.66.67.254/24
所有入口共用的隧道网段：10.66.67.0/24
出口机公网网卡：通常使用自动检测结果，直接回车
```

关键规则：入口机是 `10.66.67.1/24`，出口机就必须位于相同的 `10.66.67.0/24` 网段，通常使用 `.254/24`。不能直接接受不匹配的默认值 `10.66.66.254/24`。

### 第 3 步：出口机登记入口机

初始化完成后选择添加第一台入口机，或在菜单选择：

```text
2) 添加入口机
```

填写入口机在第 1 步输出的信息：

```text
新入口名称：dmit-la
入口机 WireGuard 地址：入口域名或IP:51821
入口机 WireGuard 公钥：粘贴入口机 vircs-att 对应的公钥
入口机唯一隧道 IP：10.66.67.1/32
```

完成后出口机显示：

```text
Outbounds shared public key: 出口机公钥
```

复制这个出口机公钥。

### 第 4 步：入口机填写出口机公钥

回到入口机，选择：

```text
3) 更新 WireGuard 出口
```

脚本会列出已有出口。选择 `vircs-att`，地址和端口直接回车保留，在“出口机 WireGuard 公钥”处粘贴第 3 步取得的出口机公钥。

不要再次选择“添加 WireGuard 出口”，也不要创建同名出口；已有出口必须通过“更新”完成配对。

### 第 5 步：让 VLESS 用户使用新出口

新用户选择：

```text
4) 添加 VLESS 用户并选择出口
```

已有用户选择：

```text
5) 更新 VLESS 用户
```

脚本会列出已有用户。选择用户后，将“该用户使用的出口”填写为：

```text
vircs-att
```

使用 `direct` 表示不走 WireGuard，直接从入口机公网出站。

## 五、为什么有时填 `/24`，有时填 `/32`

`/24` 用于 WireGuard 接口地址，表示接口所在网段；`/32` 用于出口机 Peer 的 `AllowedIPs`，只代表某一台入口机。

```ini
# 入口机接口
Address = 10.66.67.1/24

# 出口机接口
Address = 10.66.67.254/24

# 出口机上的入口 Peer
AllowedIPs = 10.66.67.1/32
```

因此各输入框应填写：

| 位置 | 填写内容 |
|---|---|
| 入口机“本入口在该隧道的地址” | `10.66.67.1/24` |
| 出口机“出口机隧道地址” | `10.66.67.254/24` |
| 出口机“所有入口共用的隧道网段” | `10.66.67.0/24` |
| 出口机“入口机唯一隧道 IP” | `10.66.67.1/32` |

如果每个 Peer 都使用 `/24`，多台入口机的 `AllowedIPs` 会重叠，WireGuard 无法准确判断返回流量应该发给哪台入口机。

## 六、多入口、多出口地址规划

### 一台入口机连接多个独立出口机

每条隧道使用不同网段和 UDP 端口：

| 出口 | 入口地址 | 出口地址 | 网段 | 入口UDP端口 |
|---|---|---|---|---|
| exit1 | `10.66.66.1/24` | `10.66.66.254/24` | `10.66.66.0/24` | `51820` |
| exit2 | `10.66.67.1/24` | `10.66.67.254/24` | `10.66.67.0/24` | `51821` |
| exit3 | `10.66.68.1/24` | `10.66.68.254/24` | `10.66.68.0/24` | `51822` |

入口脚本默认按此规则分配，但初始化出口机时仍需确认出口机地址与入口网段一致。

### 一台出口机接入多台入口机

该出口机只有一个 WireGuard 接口和一个网段，所有入口必须使用同一网段内不同的 IP：

```text
出口机：10.66.66.254/24
入口机 A：10.66.66.1/24，登记为 10.66.66.1/32
入口机 B：10.66.66.2/24，登记为 10.66.66.2/32
入口机 C：10.66.66.3/24，登记为 10.66.66.3/32
```

不要为了添加第二台入口而重新初始化并更换出口机网段，否则原有入口会断开。直接选择“添加入口机”即可。

## 七、菜单说明

### 入口机 `inbounds.sh`

```text
1) 初始化入口机
2) 添加 WireGuard 出口
3) 更新 WireGuard 出口
4) 添加 VLESS 用户并选择出口
5) 更新 VLESS 用户
6) 删除 VLESS 用户
7) 删除 WireGuard 出口
8) 查看 WireGuard 出口和 VLESS 连接
9) 仅显示 VLESS 连接
0) 退出
```

“添加”只允许新名称；名称已经存在时必须选择“更新”。“更新”会先显示已有项目，选择后再修改，并保留未修改字段的原值。

也可以直接运行子命令：

```bash
sudo ./inbounds.sh init
sudo ./inbounds.sh add-exit
sudo ./inbounds.sh update-exit
sudo ./inbounds.sh add-user
sudo ./inbounds.sh update-user
sudo ./inbounds.sh del-user
sudo ./inbounds.sh del-exit
sudo ./inbounds.sh list
sudo ./inbounds.sh show-links
```

### 出口机 `outbounds.sh`

```text
1) 初始化或重新配置出口机
2) 添加入口机
3) 更新入口机
4) 移除入口机
5) 列出入口并查看状态
0) 退出
```

子命令：

```bash
sudo ./outbounds.sh init
sudo ./outbounds.sh add
sudo ./outbounds.sh update
sudo ./outbounds.sh remove
sudo ./outbounds.sh status
```

## 八、查看 VLESS 链接并导入 Shadowrocket

入口机选择：

```text
9) 仅显示 VLESS 连接
```

复制终端输出的完整单行 `vless://` 链接并导入 Shadowrocket。不要复制聊天软件自动转换后的 Markdown 超链接；如果出现反斜杠、`[www.example.com]()` 等内容，链接已经被聊天软件破坏。

本脚本生成的是：

```text
security=reality&type=tcp
```

不是 XHTTP。Shadowrocket 能导入链接但无法连接时，先确认客户端节点的传输方式确实是 TCP、TLS/安全类型是 REALITY，并检查地址、端口、Public Key、Short ID 和 SNI。

UUID 是访问凭据。不要公开分享；如果已经发到公开场所，请删除旧用户后创建新用户，以生成新 UUID。

## 九、验证是否成功

### 入口机

选择：

```text
8) 查看 WireGuard 出口和 VLESS 连接
```

也可以执行：

```bash
sudo wg show
sudo systemctl status xray --no-pager
sudo systemctl status wg-quick@wgx1 --no-pager
```

第二条出口通常是 `wgx2`。`latest handshake` 有近期时间，说明 WireGuard 两端已经完成握手。

### 出口机

选择：

```text
5) 列出入口并查看状态
```

也可以执行：

```bash
sudo wg show
sudo systemctl status wg-quick@wg-exit --no-pager
sysctl net.ipv4.ip_forward
```

`net.ipv4.ip_forward` 应为 `1`。客户端连接 VLESS 后，可访问 IP 查询网站，确认显示的是出口机公网 IP，而不是入口机公网 IP。

## 十、常见问题

### 1. 一直没有 WireGuard handshake

依次检查：

- 入口机云安全组是否放行对应的 UDP 端口，例如 `51821/UDP`。
- 出口机登记的 Endpoint 是否为入口机公网地址和正确端口。
- 两边粘贴的 WireGuard 公钥是否对应同一条出口。
- 入口、出口是否属于同一隧道网段。
- 出口机 Peer 的入口 IP 是否使用唯一 `/32`。

### 2. WireGuard 有握手，但客户端不能上网

检查出口机：

```bash
sysctl net.ipv4.ip_forward
sudo iptables -t nat -S POSTROUTING
ip -4 route show default
```

确认公网网卡填写正确，并确认 VLESS 用户选择的是目标出口而不是 `direct`。

### 3. Shadowrocket 无法连接

- 链接应包含 `type=tcp`，不能是 `type=xhttp`。
- 入口机 VLESS TCP 端口必须在安全组中放行。
- SNI、REALITY Public Key、Short ID 必须与服务端一致。
- 从入口机终端直接复制原始链接，不要复制被聊天软件格式化的版本。
- 查看日志：`sudo journalctl -u xray -n 100 --no-pager`。

### 4. 新建出口后显示了旧出口的信息

这是早期版本脚本中已修复的问题。请替换为当前版本 `inbounds.sh`，然后选择“更新 WireGuard 出口”，选中新出口并直接回车保留已有值。当前版本会重新加载正在操作的出口，再放行端口和显示对应公钥。

需要手动核对某个出口（以 `vircs-att` 为例）时运行：

```bash
sudo cat /etc/xray-wireguard-exit/inbound-exits/vircs-att.env
sudo wg pubkey < /etc/xray-wireguard-exit/inbound-exits/vircs-att.key
```

### 5. WireGuard 出口断开后会自动直连吗

不会。绑定该出口的 VLESS 用户会连接失败，不会自动改用入口机公网，避免流量意外从错误出口泄漏。

## 十一、配置文件位置

入口机：

```text
/usr/local/etc/xray/config.json                  Xray 最终配置（由脚本生成）
/etc/xray-wireguard-exit/inbounds-base.env       入口基础配置
/etc/xray-wireguard-exit/inbound-exits/          各 WireGuard 出口状态和私钥
/etc/xray-wireguard-exit/vless-users/            各 VLESS 用户
/etc/wireguard/wgxN.conf                          各出口 WireGuard 配置
```

出口机：

```text
/etc/xray-wireguard-exit/outbounds.env           出口基础配置
/etc/xray-wireguard-exit/outbounds-wg.key        出口机共享私钥
/etc/xray-wireguard-exit/outbounds-peers/         各入口机状态
/etc/wireguard/wg-exit.conf                       WireGuard 配置
```

这些文件包含私钥和访问凭据，仅允许 root 读取。不要直接修改 `/usr/local/etc/xray/config.json`，因为脚本下一次更新用户或出口时会重新生成并覆盖它。

## 十二、安全和行为说明

- 为兼容 Shadowrocket，入口脚本将 REALITY 最低客户端版本设置为 `0.0.0`。Xray 官方提示，降低该限制可能增加被识别和封锁的风险。
- WireGuard 出口不可用时不会自动回退到入口机直连。
- 域名解析由入口机上的 Xray 完成，目标 TCP/UDP 流量从用户选择的出口访问互联网。
- 脚本仅在 UFW 已启用时自动添加本机规则，不会修改云厂商安全组。
- 删除的用户和出口会移动到 `/etc/xray-wireguard-exit/` 下的备份目录，不会立即彻底擦除。
