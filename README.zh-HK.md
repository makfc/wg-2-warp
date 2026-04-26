# wg-2-warp

**將 WireGuard VPN traffic 經 Cloudflare WARP 出街，避開一般 datacenter IP 被封鎖嘅問題**

**其他語言:** [English](README.md) | [正體中文](README.zh-TW.md)

## 簡介

wg-2-warp 會喺 VPS 入面用 Docker 跑一個 WireGuard server，同另一個 Cloudflare WARP container。電話或者電腦連入 WireGuard 之後，traffic 會經 WARP container 出去 Internet，所以網站見到嘅會係 Cloudflare WARP IP，而唔係你部 VPS 嘅 datacenter IP。

呢個 setup 用 Cloudflare WARP free tier，會自動建立 WARP registration，唔需要你提供個人資料。

## 點樣運作

- WireGuard server 喺 Docker container 入面跑
- Cloudflare WARP client 喺另一個 Docker container 入面跑
- WireGuard client 嘅 IPv4 同 IPv6 traffic 都會由 policy routing 送去 WARP container
- 出街 IP 會變成 Cloudflare WARP IP，通常係 `104.x.x.x`
- Fail-secure firewall rule 會阻止 client traffic 直接由 VPS public interface 出街
- TCPMSS clamping 會減少 MTU 問題同 connection hang

## 架構

```text
[WireGuard Clients]
        -> UDP 51822，IPv4 endpoint 都可以承載 IPv4/IPv6 tunnel traffic
[WireGuard Container] -> [Private Docker Network] -> [WARP Container] -> Internet
```

## 系統需求

- x86_64 或 ARM64 Linux
- 已安裝 Docker 同 Docker Compose
- root 或 sudo 權限
- 一個可用嘅 UDP port，預設係 `51822`

## 平台備註

- Oracle Cloud Infrastructure ARM64 instances，包括 Ampere A1 shapes，可以 native build WARP container。
- WARP image 用 Ubuntu 24.04 (`noble`) package source，apt 會自動揀 host architecture 對應嘅 Cloudflare WARP package。
- ARM64 host 唔需要 amd64 emulation，亦唔需要特別設定 multi-architecture Docker。

## Firewall

如果有 firewall，要開 UDP `51822`。

Docker host 有時亦要加一條 `DOCKER-USER` rule：

```bash
sudo iptables -I DOCKER-USER -p udp -m udp --dport 51822 -j ACCEPT
```

呢個 project 預設用 `wg1` 同 port `51822`。如果你本身有另一個 WireGuard server 用 `wg0` 或 port `51820`，通常唔會直接撞。

## 安裝

### 1. Clone repo

```bash
git clone https://github.com/eric0e/wg-2-warp.git
cd wg-2-warp
```

### 2. 設定 WireGuard

```bash
cp wireguard/wg1.conf.example wireguard/wg1.conf
```

打開 `wireguard/wg1.conf`，填入 server private key 同 client public key：

```ini
[Interface]
Address = 10.13.13.1/24,fd42:42:42::1/64
SaveConfig = false
ListenPort = 51822
PrivateKey = YOUR_SERVER_PRIVATE_KEY

[Peer]
PublicKey = YOUR_CLIENT_PUBLIC_KEY
AllowedIPs = 10.13.13.2/32,fd42:42:42::2/128
PersistentKeepalive = 0
```

如有需要，可以咁樣 generate keys：

```bash
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key
```

唔好 commit 真實 private key。`wireguard/wg1.conf` 已經應該放喺 `.gitignore`。

### 3. Build images

```bash
docker compose build --no-cache
```

### 4. Start containers

```bash
docker compose up -d
```

### 5. 檢查狀態

```bash
docker compose ps
docker compose logs
```

你應該見到 WARP 連線成功，WireGuard container route traffic through WARP。

## Client 設定

喺電話或者電腦嘅 WireGuard app 建立 profile：

```ini
[Interface]
PrivateKey = YOUR_CLIENT_PRIVATE_KEY
Address = 10.13.13.2/32,fd42:42:42::2/128
DNS = 1.1.1.1,2606:4700:4700::1111
MTU = 1280

[Peer]
PublicKey = YOUR_SERVER_PUBLIC_KEY
Endpoint = YOUR_VPS_IP:51822
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

`AllowedIPs = 0.0.0.0/0, ::/0` 代表 client 會將所有 IPv4/IPv6 traffic 都送入 VPN。

WireGuard endpoint 可以係 IPv4，例如 `YOUR_VPS_IP:51822`，但 tunnel 入面仍然可以行 IPv6，出站就由 WARP IPv6 出去。

## 測試

連入 WireGuard 之後，睇吓出街 IP：

```bash
curl https://icanhazip.com
curl -6 https://icanhazip.com
```

詳細 WARP 狀態可以睇：

```bash
curl https://cloudflare.com/cdn-cgi/trace
```

如果見到 `warp=on`，即係 traffic 正經 WARP 出去。

## 常用管理指令

```bash
docker compose ps
docker compose logs
docker compose logs warp
docker compose logs wireguard
docker compose restart
docker compose down
docker compose build --no-cache
docker compose up -d
```

Container 入面檢查：

```bash
docker exec wireguard-server wg show
docker exec warp-server warp-cli --accept-tos status
docker exec wireguard-server ip route show table 200
docker exec wireguard-server ip -6 route show table 200
docker exec wireguard-server ip rule show
docker exec wireguard-server ip -6 rule show
```

## 改設定

### Docker private network

預設 Docker private network 係 IPv4 `172.22.0.0/16` 同 IPv6 `fd00:172:22::/64`。如果要改，更新 `docker-compose.yml` 入面嘅 subnet 同 container IP，然後同步更新 `entrypoint-wireguard.sh`。

### WireGuard network

預設 WireGuard network 係 IPv4 `10.13.13.0/24` 同 IPv6 `fd42:42:42::/64`。如果要改，要同步改：

- `wireguard/wg1.conf`
- `entrypoint-wireguard.sh` 入面嘅 `ip rule` 同 NAT rule

### 加多個 peer

喺 `wireguard/wg1.conf` 加：

```ini
[Peer]
PublicKey = ANOTHER_CLIENT_PUBLIC_KEY
AllowedIPs = 10.13.13.3/32,fd42:42:42::3/128
PersistentKeepalive = 0
```

之後 restart WireGuard container：

```bash
docker compose restart wireguard
```

## Troubleshooting

### Container 起唔到

```bash
docker compose logs warp
docker compose logs wireguard
```

常見原因：

- WARP registration 失敗：刪走 `warp-data/` 再重開
- Port 已經有人用：改 `docker-compose.yml` port mapping
- 權限問題：確認 Docker 有需要嘅 privilege/capability

### WARP 顯示 `warp=off`

```bash
docker exec warp-server warp-cli --accept-tos status
docker exec warp-server warp-cli --accept-tos connect
```

如果都唔得，可以重新 registration：

```bash
docker compose down
rm -rf warp-data/
docker compose up -d
```

### Client 連唔到

確認 firewall：

```bash
sudo iptables -L DOCKER-USER -n -v
sudo iptables -I DOCKER-USER -p udp -m udp --dport 51822 -j ACCEPT
```

確認 WireGuard interface：

```bash
docker exec wireguard-server wg show
```

### Traffic 冇經 WARP

```bash
docker exec wireguard-server ip route show table 200
docker exec wireguard-server ip -6 route show table 200
docker exec wireguard-server ip rule show
docker exec wireguard-server ip -6 rule show
```

應該會見到 default route 經 `172.22.0.10` / `fd00:172:22::10`，同埋 `from 10.13.13.0/24 lookup 200` / `from fd42:42:42::/64 lookup 200`。

## 限制

- 已測試 x86_64 Ubuntu 22.04/24.04 同 Oracle Cloud Infrastructure ARM64
- 已測試用 IPv4 WireGuard endpoint，經 WARP 做 IPv6 出站
- 其他 distro 或 VPS provider 可能得，但未必測過
- 部分 provider 可能會限制 WARP traffic
- WireGuard 加 WARP 會有額外 latency
- WARP free tier 可能有 bandwidth 或服務限制

## 貢獻

歡迎開 issue 或 pull request。特別有用嘅方向包括：

- 測試更多 Linux distro
- 測試更多 VPS provider
- 測試更多 ARM64/ARM host
- 改善 IPv6 support
- 改善文件
