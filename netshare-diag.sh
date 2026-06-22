#!/bin/bash
#
# Run this WHILE CONNECTED TO NETSHARE. It probes how the NetShare proxy
# behaves so we can pick the lightest reliable setup for the terminal (claude).
# Results are printed AND saved to ~/netshare-diag.txt so you can read them
# after switching back to a normal Wi-Fi (even if the session dropped).
#
P_HOST=192.168.49.1
P_PORT=8282
P=${P_HOST}:${P_PORT}
OUT="$HOME/netshare-diag.txt"

run() {
  {
    echo "==== NetShare proxy diagnostics  $(date) ===="

    echo "-- 1) proxy port reachable?"
    if nc -z -G 3 "$P_HOST" "$P_PORT" 2>/dev/null; then echo "   OPEN"; else echo "   CLOSED (are you on NetShare?)"; fi

    echo "-- 2) HTTP proxy mode (curl -x http://) "
    curl -s -m 12 -x "http://$P" -o /dev/null -w "   http_proxy -> HTTP %{http_code} (%{time_total}s)\n" https://www.google.com/generate_204 2>&1 \
      || echo "   http_proxy -> FAILED"

    echo "-- 3) SOCKS5 proxy mode (curl --socks5-hostname)"
    curl -s -m 12 --socks5-hostname "$P" -o /dev/null -w "   socks5     -> HTTP %{http_code} (%{time_total}s)\n" https://www.google.com/generate_204 2>&1 \
      || echo "   socks5     -> FAILED"

    echo "-- 4) does Claude's API host work via HTTP proxy?"
    curl -s -m 12 -x "http://$P" -o /dev/null -w "   api.anthropic.com -> HTTP %{http_code} (%{time_total}s)\n" https://api.anthropic.com 2>&1 \
      || echo "   api.anthropic.com -> FAILED"

    echo ""
    echo "INTERPRETATION:"
    echo "  * If (2) shows 204  -> use:  export HTTPS_PROXY=http://$P ; export HTTP_PROXY=http://$P ; claude --continue"
    echo "  * If only (3) works -> NetShare is SOCKS-only; tell me and we'll use the tunnel route for claude."
    echo "  * (4) 200/4xx = reachable (auth error is fine); timeout/000 = blocked."
    echo "============================================="
  } 2>&1 | tee "$OUT"
}

run
echo ""
echo "Saved to: $OUT"
