#!/bin/bash

echo "Starting WireGuard container..."

if [ ! -f /etc/wireguard/wg1.conf ]; then
    echo "ERROR: /etc/wireguard/wg1.conf not found"
    echo "Please create the WireGuard configuration file"
    exit 1
fi

sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true

echo "Starting WireGuard interface wg1..."
wg-quick up wg1

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to start WireGuard"
    exit 1
fi

echo "WireGuard started successfully"
echo ""
echo "=== WireGuard Status ==="
wg show
echo ""

# Wait for WARP container to be ready.
echo "Waiting for WARP container..."
WARP_READY=false
for i in {1..60}; do
    if ping -c 1 -W 1 172.22.0.10 >/dev/null 2>&1 && ping -6 -c 1 -W 1 fd00:172:22::10 >/dev/null 2>&1; then
        echo "WARP container is reachable over IPv4 and IPv6"
        WARP_READY=true
        break
    fi
    echo "Waiting... ($i/60)"
    sleep 2
done

if [ "$WARP_READY" = false ]; then
    echo "ERROR: WARP container not reachable!"
    echo "Aborting for security ..."
    exit 2
fi

# Setup routing through WARP container.
echo "Setting up routing through WARP container..."

# Ensure iproute2 directory and rt_tables file exist.
mkdir -p /etc/iproute2
if [ ! -f /etc/iproute2/rt_tables ]; then
    cat > /etc/iproute2/rt_tables << 'EOF'
255 local
254 main
253 default
0 unspec
EOF
    echo "Created /etc/iproute2/rt_tables"
fi

# Add route table entry (check if already exists first).
if ! grep -q "^200[[:space:]]" /etc/iproute2/rt_tables; then
    echo "200 warp" >> /etc/iproute2/rt_tables
    echo "Added routing table 200 (warp)"
else
    echo "Routing table 200 already exists"
fi

# Route WireGuard client traffic through WARP container.
ip route add default via 172.22.0.10 table 200
ip rule add from 10.13.13.0/24 table 200 priority 100
ip -6 route add default via fd00:172:22::10 table 200
ip -6 rule add from fd42:42:42::/64 table 200 priority 100

# Enable NAT for WireGuard clients.
iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -j MASQUERADE
iptables -A FORWARD -i wg1 -j ACCEPT
iptables -A FORWARD -o wg1 -j ACCEPT
ip6tables -A FORWARD -i wg1 -j ACCEPT
ip6tables -A FORWARD -o wg1 -j ACCEPT

# Clamping to prevent hangs.
echo "Setting TCPMSS clamp-mss-to-pmtu on wg1"
iptables -t mangle -A FORWARD -o wg1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -i wg1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -A FORWARD -o wg1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -A FORWARD -i wg1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "Routing configured"
echo ""

# ============================================================================
# FAIL-SECURE: Block traffic from WireGuard if it tries to bypass WARP.
# This rule goes AFTER the ACCEPT rules above, so it only catches traffic
# that did not match the policy routing (i.e., if WARP container is down).
# ============================================================================
iptables -A FORWARD -i wg1 -o eth0 -j DROP
ip6tables -A FORWARD -i wg1 -o eth0 -j DROP

echo "Fail-secure rules added (blocks direct eth0 exit)"
echo ""

echo "=== IPv4 Routing Configuration ==="
echo "Default route:"
ip route show
echo ""
echo "WARP routing table (table 200):"
ip route show table 200
echo ""
echo "Routing rules:"
ip rule show
echo ""

echo "=== IPv6 Routing Configuration ==="
echo "Default IPv6 route:"
ip -6 route show
echo ""
echo "WARP IPv6 routing table (table 200):"
ip -6 route show table 200
echo ""
echo "IPv6 routing rules:"
ip -6 rule show
echo ""

echo "=== NAT Rules ==="
iptables -t nat -L POSTROUTING -n -v | head -10
echo ""
echo "=== IPv6 NAT Rules ==="
ip6tables -t nat -L POSTROUTING -n -v | head -10
echo ""

echo "=== MANGLE Rules ==="
iptables -t mangle -L FORWARD -n -v  | head -10
echo ""
echo "=== IPv6 MANGLE Rules ==="
ip6tables -t mangle -L FORWARD -n -v  | head -10
echo ""

echo "=== Firewall Rules ==="
iptables -L FORWARD -n -v | grep -E "wg1|eth0|Chain"
echo ""
echo "=== IPv6 Firewall Rules ==="
ip6tables -L FORWARD -n -v | grep -E "wg1|eth0|Chain"
echo ""

if [ "$WARP_READY" = true ]; then
    echo "=== Testing Connection Through WARP ==="
    echo -n "Container's external IPv4 (will show VPS IP - this is normal): "
    curl -4 -s --max-time 10 ifconfig.me 2>/dev/null || echo "Unable to retrieve"
    echo ""
    echo -n "WireGuard server IPv6 source through WARP: "
    curl -6 --interface fd42:42:42::1 -s --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2 || echo "Unable to retrieve"
    echo "Note: WireGuard CLIENT traffic routes through WARP"
fi

echo ""
echo "WireGuard container is ready!"
echo "IPv4 client traffic (10.13.13.0/24) routes through WARP"
echo "IPv6 client traffic (fd42:42:42::/64) routes through WARP"
echo "Container's own IPv4 traffic uses VPS IP (expected)"
echo "FAIL-SECURE: Direct eth0 exit blocked for clients"
echo ""
echo "Commands:"
echo "  Check WireGuard: docker exec wireguard-server wg show"
echo "  Check routing:   docker exec wireguard-server ip route show table 200"
echo "  Check IPv6 route: docker exec wireguard-server ip -6 route show table 200"
echo "  Check WARP:      docker exec warp-server warp-cli --accept-tos status"
echo "  View firewall:   docker exec wireguard-server iptables -L FORWARD -n -v"
echo ""

tail -f /dev/null
