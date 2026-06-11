#!/bin/bash
set -euo pipefail

COUNTRY="${COUNTRY:-}"
PROXY_PORT="${PROXY_PORT:-1080}"
MAX_NODES="${MAX_NODES:-100}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
IP_TYPE="${IP_TYPE:-}"

[ -n "$COUNTRY" ] && COUNTRY="${COUNTRY^^}"
[ -n "$IP_TYPE" ] && IP_TYPE="${IP_TYPE,,}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
start_microsocks() {
    if [ -n "${MICROSOCKS_PID:-}" ] && kill -0 "$MICROSOCKS_PID" 2>/dev/null; then
        return
    fi
    microsocks -i 0.0.0.0 -p "$PROXY_PORT" &
    MICROSOCKS_PID=$!
    sleep 0.3
    if ! kill -0 "$MICROSOCKS_PID" 2>/dev/null; then
        log "microsocks failed to start"
        MICROSOCKS_PID=""
    fi
}
cleanup() {
    trap - EXIT TERM INT
    kill "${OPENVPN_PID:-}" 2>/dev/null || true
    wait "${OPENVPN_PID:-}" 2>/dev/null || true
    kill "${MICROSOCKS_PID:-}" 2>/dev/null || true
    wait "${MICROSOCKS_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 0' TERM INT

printf "vpn\nvpn\n" > /tmp/auth.txt

filter_by_ip_type() {
    local ip_type="$1"
    local nodes_file="$2"

    {
        echo -n '['
        first=true
        while IFS='|' read -r ip rest; do
            $first || echo -n ','
            first=false
            echo -n "\"$ip\""
        done < "$nodes_file"
        echo ']'
    } > /tmp/ip_payload.json

    curl -sf --max-time 15 \
        -X POST -H "Content-Type: application/json" \
        -d @/tmp/ip_payload.json \
        "http://ip-api.com/batch?fields=status,query,proxy,hosting,mobile" > /tmp/ip_result.json 2>/dev/null || {
        log "IP type query failed, skipping"; return
    }

    sed 's/},{/}\n{/g; s/^\[//; s/\]$//' /tmp/ip_result.json > /tmp/ip_records.txt

    awk -v type="$ip_type" '
{
    if (substr($0, 1, 1) == "{") $0 = substr($0, 2)
    if (substr($0, length($0), 1) == "}") $0 = substr($0, 1, length($0) - 1)
    if ($0 !~ /"success"/) next
    if (match($0, /"query":"[^"]*"/))
        ip = substr($0, RSTART + 9, RLENGTH - 10)
    else next
    mobile = ($0 ~ /"mobile":true/)
    proxy  = ($0 ~ /"proxy":true/)
    hosting = ($0 ~ /"hosting":true/)
    if (mobile) t = "mobile"
    else if (proxy) t = "proxy"
    else if (hosting) t = "hosting"
    else t = "residential"
    if (t == type) print ip
}' /tmp/ip_records.txt > /tmp/match_ips.txt

    if [ -s /tmp/match_ips.txt ]; then
        awk -F'|' 'NR==FNR{ips[$1]=1;next} $1 in ips' /tmp/match_ips.txt "$nodes_file" > /tmp/match_nodes.txt
        awk -F'|' 'NR==FNR{ips[$1]=1;next} !($1 in ips)' /tmp/match_ips.txt "$nodes_file" > /tmp/nomatch_nodes.txt
        if [ -s /tmp/match_nodes.txt ]; then
            cat /tmp/match_nodes.txt /tmp/nomatch_nodes.txt > "$nodes_file"
            log "Prioritized $(wc -l < /tmp/match_nodes.txt) ${ip_type} nodes"
        fi
    fi
}

outer_loop() {
local country_retries=0
while true; do
    log "=== Fetching nodes ==="
    curl -sf --max-time 15 "https://www.vpngate.net/api/iphone/" > /tmp/api.txt || {
        log "Fetch failed, retry in 30s"; sleep 30; continue
    }

    awk -F',' -v max="$MAX_NODES" '
    !/^[#*]/ && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && length($NF) > 100 {
        if (++count > max) exit
        print $2 "|" $7 "|" ($4+0) "|" $NF
    }' /tmp/api.txt > /tmp/nodes.txt

    total=$(wc -l < /tmp/nodes.txt)
    [ "$total" -eq 0 ] && { log "No valid nodes, retry in 30s"; sleep 30; continue; }
    log "Got $total nodes"

    if [ -n "$COUNTRY" ]; then
        grep -i "^[^|]*|${COUNTRY}|" /tmp/nodes.txt > /tmp/filtered.txt 2>/dev/null || true
        if [ ! -s /tmp/filtered.txt ]; then
            country_retries=$((country_retries + 1))
            if [ "$country_retries" -ge 3 ]; then
                log "No ${COUNTRY} nodes after ${country_retries} attempts, dropping country filter"
                country_retries=0
                COUNTRY=""
            else
                log "No ${COUNTRY} nodes, retry in 30s (${country_retries}/3)..."
                sleep 30; continue
            fi
        else
            country_retries=0
            mv /tmp/filtered.txt /tmp/nodes.txt
            log "Filtered: $(wc -l < /tmp/nodes.txt) ${COUNTRY} nodes"
        fi
    fi

    sort -t'|' -k3 -n /tmp/nodes.txt > /tmp/sorted.txt

    if [ -n "$IP_TYPE" ]; then
        filter_by_ip_type "$IP_TYPE" /tmp/sorted.txt
    fi

    head -20 /tmp/sorted.txt > /tmp/top20.txt

    log "Pinging top 20..."
    awk -F'|' '{print $1}' /tmp/top20.txt | fping -C1 -t2000 > /tmp/fping_out.txt 2>&1 || true
    best_line=""; best_latency=99999
    while IFS='|' read -r ip rest; do
        t=$(awk -v ip="$ip" '$1 == ip && $2 == ":" && $3+0 > 0 { print $3 }' /tmp/fping_out.txt)
        [ -z "$t" ] && continue
        t=${t%.*}
        [ "$t" -gt 0 ] && [ "$t" -lt "$best_latency" ] && {
            best_latency=$t; best_line="$ip|$rest"
        }
    done < /tmp/top20.txt

    if [ -z "$best_line" ]; then
        log "No ping responses, using lowest-ping node..."
        best_line=$(head -1 /tmp/sorted.txt)
        best_latency="?"
    fi

    best_ip="${best_line%%|*}"
    log "Best: $best_ip (${best_latency}ms)"

    { echo "$best_line"; awk -F'|' -v ip="$best_ip" '$1 != ip' /tmp/sorted.txt; } > /tmp/tryorder.txt

    start_microsocks

    try_nodes
    log "All nodes exhausted, re-fetching in 30s..."
    sleep 30
done
}

try_nodes() {
while IFS='|' read -r ip country ping config; do
    log "Connecting $ip..."

    echo "$config" | base64 -d > /tmp/config.ovpn 2>/dev/null || continue
    : > /tmp/openvpn.log
    cat >> /tmp/config.ovpn <<'PATCH'
auth-user-pass /tmp/auth.txt
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
PATCH

    openvpn --config /tmp/config.ovpn \
        --auth-user-pass /tmp/auth.txt \
        --connect-retry-max 1 --connect-timeout 10 --verb 1 \
        --log /tmp/openvpn.log 2>/dev/null &
    OPENVPN_PID=$!

    connected=false
    for _ in $(seq 1 30); do
        sleep 1
        if grep -q "Initialization Sequence Completed" /tmp/openvpn.log 2>/dev/null; then
            connected=true; break
        fi
        kill -0 "$OPENVPN_PID" 2>/dev/null || break
    done

    if [ "$connected" = true ]; then
        log "Connected to $ip ✓"

        for _ in 1 2 3; do
            sleep 3
            geo=$(curl -sf --max-time 5 --proxy "socks5://127.0.0.1:$PROXY_PORT" \
                "http://ip-api.com/json" 2>/dev/null || true)
            egress_ip=$(echo "$geo" | grep -o '"query":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            egress_cc=$(echo "$geo" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            [ -n "$egress_cc" ] && break
        done
        [ -z "$egress_cc" ] && egress_cc="?"
        [ -z "$egress_ip" ] && egress_ip="checking..."

        echo ""
        echo "============================================"
        echo "  vpngate2socks ready"
        echo "  SOCKS5 :$PROXY_PORT"
        echo "  Node   : $ip ($country)"
        echo "  Egress : $egress_ip ($egress_cc)"
        echo "============================================"
        echo ""

        # Health check: monitor VPN + egress country + microsocks
        health_fails=0
        while true; do
            sleep "$CHECK_INTERVAL"
            : > /tmp/openvpn.log

            if ! kill -0 "$MICROSOCKS_PID" 2>/dev/null; then
                log "microsocks died, restarting..."
                start_microsocks
            fi

            kill -0 "$OPENVPN_PID" 2>/dev/null || {
                log "VPN disconnected, switching..."
                break
            }

            geo=$(curl -sf --max-time 5 --proxy "socks5://127.0.0.1:$PROXY_PORT" \
                "http://ip-api.com/json" 2>/dev/null || true)
            egress_cc=$(echo "$geo" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")

            if [ -z "$egress_cc" ]; then
                health_fails=$((health_fails + 1))
                log "Health check failed ($health_fails/3)"
                if [ "$health_fails" -ge 3 ]; then
                    log "Health check failed 3 times, switching..."
                    break
                fi
                continue
            fi
            health_fails=0

            if [ -n "$COUNTRY" ] && [ "$egress_cc" != "$COUNTRY" ]; then
                log "Egress mismatch: $egress_cc != $COUNTRY, switching..."
                break
            fi
        done

        kill "$OPENVPN_PID" 2>/dev/null || true
        wait "$OPENVPN_PID" 2>/dev/null || true
        OPENVPN_PID=""
    else
        log "Failed $ip"
        kill "$OPENVPN_PID" 2>/dev/null || true
        wait "$OPENVPN_PID" 2>/dev/null || true
        OPENVPN_PID=""
    fi
done < /tmp/tryorder.txt
}

outer_loop
