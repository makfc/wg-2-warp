# wg-2-warp

**Route WireGuard VPN traffic through Cloudflare WARP for a clean IP address**

**Translations:** [香港廣東話](README.zh-HK.md) | [正體中文](README.zh-TW.md)

## Overview

wg-2-warp combines a WireGuard VPN server with Cloudflare WARP so that your VPN traffic exits through a Cloudflare WARP IP address rather than a typical datacenter IP. This helps you avoid the blocks and restrictions many websites apply to VPN traffic originating from datacenters. It uses the free tier of Cloudflare WARP and automatically retrieves the required registration file, so you don’t need to provide any personal information to activate the WARP client. The only information it learns is your VPN's IP address..

**How it works:**

- A WireGuard server runs on your VPS inside a Docker container
- A separate Docker container runs the Cloudflare WARP client
- All traffic from connected WireGuard clients is routed through the WARP container
- Your traffic exits to the internet with a Cloudflare WARP IP address (commonly in the 104.x.x.x range)
- WARP IPs are typically geographically close to your VPS location
- A fail‑secure design ensures traffic cannot bypass WARP, preventing accidental leak

**Use cases:**

- Remote access with a "clean" IP address
- Accessing streaming services while traveling
- Bypassing VPN/datacenter IP blocks
- Digital nomads needing reliable connectivity

## Architecture

This project uses two Docker containers connected via a private network:

```
[WireGuard Clients] 
        ↓ (UDP 51822, IPv4 endpoint with IPv4/IPv6 tunnel traffic)
[WireGuard Container] → [Private Network] → [WARP Container] → Internet (WARP IP)
```

**Key features:**

- **Two-container design:** WireGuard and WARP in separate containers
- **Dual-stack routing:** Routes both IPv4 and IPv6 WireGuard client traffic through WARP
- **Policy-based routing:** Uses Linux routing tables to direct traffic through WARP
- **Fail-secure:** Blocks direct internet access if WARP is down
- **TCPMSS clamping:** Prevents MTU issues and connection hangs
- **Persistent storage:** WARP registration persists across restarts

## Prerequisites

**System requirements:**

- x86_64 or ARM64 Linux system (tested on Ubuntu 22.04/24.04 and Oracle Cloud Infrastructure ARM64)
- Docker and Docker Compose installed
- Root or sudo access
- Free UDP port 51822 for WireGuard

**Platform notes:**

- Oracle Cloud Infrastructure ARM64 instances, including Ampere A1 shapes, can build the WARP container natively.
- The WARP image uses Ubuntu 24.04 (`noble`) packages so Cloudflare's native package for the host architecture is selected automatically.
- No amd64 emulation or multi-architecture Docker setup is required for ARM64 hosts.

**Network requirements:**

- If using a firewall, open UDP port 51822

- For Docker hosts, you may need to add an iptables rule:
  
  ```bash
  sudo iptables -I DOCKER-USER -p udp -m udp --dport 51822 -j ACCEPT
  ```

**Important:** This setup uses wg1 on port 51822. If you are already running another WireGuard server on wg0/port 51820, this configuration will not conflict with it.

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/eric0e/wg-2-warp.git
cd wg-2-warp
```

### 2. Configure WireGuard

Create your WireGuard configuration file:

```bash
cp wireguard/wg1.conf.example wireguard/wg1.conf
```

Edit `wireguard/wg1.conf` with your server and peer details:

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

**Generate keys if needed:**

```bash
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key
```

### 3. Build the Docker images

```bash
docker compose build --no-cache
```

### 4. Start the containers

```bash
docker compose up -d
```

### 5. Verify operation

Check that both containers are running:

```bash
docker compose ps
```

View the logs:

```bash
docker compose logs
```

You should see:

- WARP container connecting successfully
- WireGuard container routing through WARP
- External IP showing as 104.x.x.x (WARP address)

## Client Configuration

Configure your WireGuard client to connect to your VPS:

```ini
[Interface]
PrivateKey = YOUR_CLIENT_PRIVATE_KEY
Address = 10.13.13.2/32,fd42:42:42::2/128
DNS = 1.1.1.1,2606:4700:4700::1111
MTU = 1280  # Conservative setting to avoid fragmentation issues

[Peer]
PublicKey = YOUR_SERVER_PUBLIC_KEY
Endpoint = YOUR_VPS_IP:51822
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

Replace:

- `YOUR_CLIENT_PRIVATE_KEY` with your client's private key
- `YOUR_SERVER_PUBLIC_KEY` with your server's public key  
- `YOUR_VPS_IP` with your VPS IP address

The WireGuard endpoint can be an IPv4 address while still carrying IPv6 traffic inside the tunnel. Use `AllowedIPs = 0.0.0.0/0, ::/0` when you want both IPv4 and IPv6 client traffic to route through WARP.

## Testing

After connecting your WireGuard client, verify the setup:

**Check your IP address:**

```bash
curl https://icanhazip.com
curl -6 https://icanhazip.com
```

The IPv4 result should be in the 104.x.x.x range (Cloudflare WARP), and the IPv6 result should be a Cloudflare/WARP IPv6 address when IPv6 is enabled in your client profile.

**Check detailed connection info:**

```bash
curl https://cloudflare.com/cdn-cgi/trace
```

Look for `warp=on` in the output.

## Management

### Common Docker commands

```bash
# View container status
docker compose ps

# View logs
docker compose logs 

# View logs for specific container
docker compose logs warp
docker compose logs wireguard

# Restart containers
docker compose restart

# Stop containers
docker compose down

# Rebuild after changes
docker compose build --no-cache
docker compose up -d

# Execute commands inside containers
docker exec -it warp-server bash
docker exec -it wireguard-server bash
```

### Inside the containers

**Check WireGuard status:**

```bash
docker exec wireguard-server wg show
```

**Check WARP status:**

```bash
docker exec warp-server warp-cli --accept-tos status
```

**Check routing configuration:**

```bash
docker exec wireguard-server ip route show table 200
docker exec wireguard-server ip -6 route show table 200
docker exec wireguard-server ip rule show
docker exec wireguard-server ip -6 rule show
```

**Check firewall rules:**

```bash
docker exec wireguard-server iptables -L FORWARD -n -v
```

## Configuration Options

### Network Subnet

The default private network uses `172.22.0.0/16` for IPv4 and `fd00:172:22::/64` for IPv6. To change:

Edit `docker-compose.yml`:

```yaml
networks:
  warp-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.25.0.0/16  # Your custom subnet
        - subnet: fd00:172:25::/64  # Your custom IPv6 subnet
```

Update IP addresses in:

- `docker-compose.yml` (both services)
- `entrypoint-wireguard.sh` (routing rules)

### WireGuard Network

The default WireGuard networks are `10.13.13.0/24` for IPv4 and `fd42:42:42::/64` for IPv6. To change:

Edit `wireguard/wg1.conf` and update routing rules in `entrypoint-wireguard.sh`:

```bash
ip rule add from YOUR_NETWORK/24 table 200 priority 100
ip -6 rule add from YOUR_IPV6_NETWORK/64 table 200 priority 100
iptables -t nat -A POSTROUTING -s YOUR_NETWORK/24 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s YOUR_IPV6_NETWORK/64 -j MASQUERADE
```

### Adding More Peers

Add additional peer blocks to `wireguard/wg1.conf`:

```ini
[Peer]
PublicKey = ANOTHER_CLIENT_PUBLIC_KEY
AllowedIPs = 10.13.13.3/32,fd42:42:42::3/128
PersistentKeepalive = 0
```

Restart the WireGuard container:

```bash
docker compose restart wireguard
```

## Troubleshooting

### Container fails to start

**Check logs:**

```bash
docker compose logs warp
docker compose logs wireguard
```

**Common issues:**

- WARP fails to register: Delete `warp-data/` directory and restart
- Port already in use: Change port mapping in `docker-compose.yml`
- Permission denied: Ensure Docker has proper privileges

### WARP shows "warp=off"

```bash
docker exec warp-server warp-cli --accept-tos status
docker exec warp-server warp-cli --accept-tos connect
```

If connection fails, delete registration and restart:

```bash
docker compose down
rm -rf warp-data/
docker compose up -d
```

### Client cannot connect

**Verify firewall:**

```bash
sudo iptables -L DOCKER-USER -n -v
```

**Add rule if missing:**

```bash
sudo iptables -I DOCKER-USER -p udp -m udp --dport 51822 -j ACCEPT
```

**Check WireGuard is listening:**

```bash
docker exec wireguard-server wg show
```

### Traffic not routing through WARP

**Verify routing table:**

```bash
docker exec wireguard-server ip route show table 200
docker exec wireguard-server ip -6 route show table 200
```

Should show: `default via 172.22.0.10` and `default via fd00:172:22::10`

**Verify policy routing:**

```bash
docker exec wireguard-server ip rule show
docker exec wireguard-server ip -6 rule show
```

Should show: `from 10.13.13.0/24 lookup 200` and `from fd42:42:42::/64 lookup 200`

**Test WARP connectivity from WireGuard container:**

```bash
docker exec wireguard-server ping -c 3 172.22.0.10
```

### Connection hangs or slow

The TCPMSS clamping rules should prevent this, but if issues persist:

**Check MTU settings:**

```bash
docker exec warp-server ip link show CloudflareWARP
docker exec wireguard-server ip link show wg1
```

## How It Works

### Routing Flow

1. Client connects to WireGuard server (10.13.13.1) on port 51822
2. The client may use an IPv4 endpoint while carrying IPv4 and IPv6 tunnel traffic
3. WireGuard container receives traffic on wg1 interface
4. Policy routing rules match source `10.13.13.0/24` and `fd42:42:42::/64`
5. Traffic is sent to routing table 200
6. Table 200 routes via `172.22.0.10` or `fd00:172:22::10` (WARP container)
7. WARP container NATs traffic through CloudflareWARP interface
8. Traffic exits with WARP IPv4 or IPv6 address

### Security Features

**Fail-secure design:**

```bash
iptables -A FORWARD -i wg1 -o eth0 -j DROP
```

This rule blocks WireGuard traffic from directly accessing eth0 (the internet). Traffic MUST go through the WARP container (172.22.0.10) or it is dropped.

**Health checks:**
Both containers have health checks that verify:

- WARP: Connected to Cloudflare and responding with 104.x.x.x IP
- WireGuard: Interface up, WARP reachable, routing table configured

## Limitations

**Platform support:**

- Tested on x86_64 Ubuntu 22.04/24.04 and Oracle Cloud Infrastructure ARM64
- ARM64 builds use Ubuntu 24.04 (`noble`) packages for Cloudflare WARP
- IPv6 routing has been tested with an IPv4 WireGuard endpoint and IPv6 WARP egress
- Other distributions and VPS providers may work but are untested

**Network restrictions:**

- May not work on some VPS providers with restricted networking
- Some providers block or throttle WARP traffic

**Performance:**

- Additional latency from double-encapsulation (WireGuard + WARP)
- WARP free tier may have bandwidth limitations

## Related Projects

This project was inspired by [warp-docker](https://github.com/cmj2002/warp-docker) by cmj2002. While wg-2-warp implements a different architecture specifically for routing WireGuard traffic through WARP, the initial concept came from exploring that project.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

**Areas where contributions would be helpful:**

- Testing on different Linux distributions
- Testing on different VPS providers
- Testing on additional ARM64/ARM hosts
- IPv6 support improvements and provider compatibility reports
- Documentation improvements

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- Cloudflare for providing the WARP client and service
- WireGuard for the excellent VPN protocol
- [cmj2002/warp-docker](https://github.com/cmj2002/warp-docker) for inspiration

### Development Notes

Documentation, project structure, and open source best practices were developed with assistance from Claude (Anthropic AI). All code was written, tested, and validated by the project maintainer.

## Support

For issues and questions:

1. Check the [Troubleshooting](#troubleshooting) section
2. Search existing [GitHub Issues](https://github.com/eric0e/wg-2-warp/issues)
3. Open a new issue with:
   - Your OS and Docker version
   - Complete error logs
   - Steps to reproduce

**Note:** This is a community project. Response times may vary.
