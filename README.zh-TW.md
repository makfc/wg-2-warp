# wg-2-warp

**透過 Cloudflare WARP 路由 WireGuard VPN 流量，使用較乾淨的出口 IP**

**其他語言:** [English](README.md) | [香港廣東話](README.zh-HK.md)

## 簡介

wg-2-warp 會在 VPS 上以 Docker 執行 WireGuard 伺服器，並在另一個 Docker 容器中執行 Cloudflare WARP 用戶端。WireGuard 用戶端連線後，流量會經由 WARP 容器送出，因此外部網站看到的是 Cloudflare WARP IP，而不是一般資料中心 IP。

此設定使用 Cloudflare WARP 免費方案，並會自動建立必要的 WARP 註冊資料，不需要提供個人資料。

## 運作方式

- WireGuard 伺服器在 Docker 容器中執行
- Cloudflare WARP 用戶端在獨立 Docker 容器中執行
- 來自 WireGuard 用戶端的 IPv4 與 IPv6 流量透過 policy routing 送往 WARP 容器
- 對外 IP 會顯示為 Cloudflare WARP IP，通常是 `104.x.x.x`
- Fail-secure 防火牆規則會阻止用戶端流量直接從 VPS public interface 對外連線
- TCPMSS clamping 可減少 MTU 問題與連線卡住的情況

## 架構

```text
[WireGuard Clients]
        -> UDP 51822，IPv4 endpoint 也可以承載 IPv4/IPv6 tunnel traffic
[WireGuard Container] -> [Private Docker Network] -> [WARP Container] -> Internet
```

## 系統需求

- x86_64 或 ARM64 Linux
- 已安裝 Docker 與 Docker Compose
- root 或 sudo 權限
- 可用的 UDP port，預設為 `51822`

## 平台說明

- Oracle Cloud Infrastructure ARM64 instances，包括 Ampere A1 shapes，可以原生建置 WARP 容器。
- WARP image 使用 Ubuntu 24.04 (`noble`) 套件來源，apt 會自動選擇符合主機架構的 Cloudflare WARP 套件。
- ARM64 主機不需要 amd64 emulation，也不需要額外設定 multi-architecture Docker。

## 防火牆

若使用防火牆，請開放 UDP `51822`。

Docker host 有時也需要加入 `DOCKER-USER` 規則：

```bash
sudo iptables -I DOCKER-USER -p udp -m udp --dport 51822 -j ACCEPT
```

本專案預設使用 `wg1` 與 port `51822`。如果你已有另一個 WireGuard 伺服器使用 `wg0` 或 port `51820`，通常不會直接衝突。

## 安裝

### 1. Clone repository

```bash
git clone https://github.com/eric0e/wg-2-warp.git
cd wg-2-warp
```

### 2. 設定 WireGuard

```bash
cp wireguard/wg1.conf.example wireguard/wg1.conf
```

編輯 `wireguard/wg1.conf`，填入伺服器 private key 與用戶端 public key：

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

如需產生 keys：

```bash
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key
```

請勿 commit 真實 private key。`wireguard/wg1.conf` 應保留在 `.gitignore` 中。

### 3. Build images

```bash
docker compose build --no-cache
```

### 4. 啟動 containers

```bash
docker compose up -d
```

### 5. 驗證狀態

```bash
docker compose ps
docker compose logs
```

應可看到 WARP 成功連線，且 WireGuard container 將流量路由至 WARP。

## 用戶端設定

在手機或電腦的 WireGuard app 中建立 profile：

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

`AllowedIPs = 0.0.0.0/0, ::/0` 代表用戶端會將所有 IPv4/IPv6 流量送入 VPN。

WireGuard endpoint 可以是 IPv4，例如 `YOUR_VPS_IP:51822`，但 tunnel 內仍可承載 IPv6，並透過 WARP IPv6 對外連線。

## 測試

連上 WireGuard 後，檢查對外 IP：

```bash
curl https://icanhazip.com
curl -6 https://icanhazip.com
```

檢查詳細 WARP 狀態：

```bash
curl https://cloudflare.com/cdn-cgi/trace
```

若看到 `warp=on`，表示流量正透過 WARP 對外連線。

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

在 containers 內檢查：

```bash
docker exec wireguard-server wg show
docker exec warp-server warp-cli --accept-tos status
docker exec wireguard-server ip route show table 200
docker exec wireguard-server ip -6 route show table 200
docker exec wireguard-server ip rule show
docker exec wireguard-server ip -6 rule show
```

## 設定選項

### Docker private network

預設 Docker private network 為 IPv4 `172.22.0.0/16` 與 IPv6 `fd00:172:22::/64`。若要修改，請更新 `docker-compose.yml` 中的 subnet 與 container IP，並同步更新 `entrypoint-wireguard.sh`。

### WireGuard network

預設 WireGuard network 為 IPv4 `10.13.13.0/24` 與 IPv6 `fd42:42:42::/64`。若要修改，請同步更新：

- `wireguard/wg1.conf`
- `entrypoint-wireguard.sh` 中的 `ip rule` 與 NAT rule

### 新增 peer

在 `wireguard/wg1.conf` 新增：

```ini
[Peer]
PublicKey = ANOTHER_CLIENT_PUBLIC_KEY
AllowedIPs = 10.13.13.3/32,fd42:42:42::3/128
PersistentKeepalive = 0
```

接著重新啟動 WireGuard container：

```bash
docker compose restart wireguard
```

## 疑難排解

### Container 無法啟動

```bash
docker compose logs warp
docker compose logs wireguard
```

常見原因：

- WARP registration 失敗：刪除 `warp-data/` 後重新啟動
- Port 已被占用：修改 `docker-compose.yml` port mapping
- 權限問題：確認 Docker 具備必要 privilege/capability

### WARP 顯示 `warp=off`

```bash
docker exec warp-server warp-cli --accept-tos status
docker exec warp-server warp-cli --accept-tos connect
```

若仍無法連線，可重新建立 registration：

```bash
docker compose down
rm -rf warp-data/
docker compose up -d
```

### 用戶端無法連線

確認防火牆：

```bash
sudo iptables -L DOCKER-USER -n -v
sudo iptables -I DOCKER-USER -p udp -m udp --dport 51822 -j ACCEPT
```

確認 WireGuard interface：

```bash
docker exec wireguard-server wg show
```

### 流量沒有經過 WARP

```bash
docker exec wireguard-server ip route show table 200
docker exec wireguard-server ip -6 route show table 200
docker exec wireguard-server ip rule show
docker exec wireguard-server ip -6 rule show
```

應看到 default route 經由 `172.22.0.10` / `fd00:172:22::10`，以及 `from 10.13.13.0/24 lookup 200` / `from fd42:42:42::/64 lookup 200`。

## 限制

- 已測試 x86_64 Ubuntu 22.04/24.04 與 Oracle Cloud Infrastructure ARM64
- 已測試使用 IPv4 WireGuard endpoint，並透過 WARP 進行 IPv6 對外連線
- 其他 Linux 發行版或 VPS provider 可能可用，但尚未完整測試
- 部分 provider 可能會限制 WARP 流量
- WireGuard 加上 WARP 會帶來額外延遲
- WARP 免費方案可能有頻寬或服務限制

## 貢獻

歡迎提出 issue 或 pull request。特別有幫助的方向包括：

- 測試更多 Linux 發行版
- 測試更多 VPS provider
- 測試更多 ARM64/ARM host
- 改善 IPv6 support
- 改善文件
