#!/bin/bash
# Phase-1 spike: prove the controller-only AP lookup end to end.
#
# Works against BOTH controller flavours, auto-detected:
#   UniFi OS console   -> POST /api/auth/login , GET /proxy/network/api/s/<site>/...
#   Self-hosted (HAOS) -> POST /api/login      , GET /api/s/<site>/...
#
# Host:   $UNIFI_HOST (e.g. 192.168.0.50:8443)
# Auth:   $UNIFI_PASS, or keychain -s unifi-apmenubar -a $UNIFI_USER
set -uo pipefail

HOST="${UNIFI_HOST:?set UNIFI_HOST, e.g. UNIFI_HOST=10.0.0.2:8443}"
USER_NAME="${UNIFI_USER:?set UNIFI_USER, e.g. UNIFI_USER=viewer}"
JAR="$(mktemp -t unifi-cookies)"
trap 'rm -f "$JAR"' EXIT

MAC=$(ifconfig en0 | awk '/ether/{print tolower($2)}')
HOSTNAME_ONLY="${HOST%%:*}"; PORT="${HOST##*:}"; [ "$PORT" = "$HOST" ] && PORT=443

echo "=== target ==="
echo "  https://$HOST"
echo "=== TLS leaf fingerprint (pin this in the app) ==="
echo | openssl s_client -connect "$HOSTNAME_ONLY:$PORT" -servername "$HOSTNAME_ONLY" 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^/  /'
echo "=== this Mac's on-air Wi-Fi MAC ==="
echo "  $MAC"

PASS="${UNIFI_PASS:-$(security find-generic-password -a "$USER_NAME" -s unifi-apmenubar -w 2>/dev/null)}"
[ -z "$PASS" ] && { echo "!! no password. security add-generic-password -a $USER_NAME -s unifi-apmenubar -w"; exit 1; }

BODY=$(jq -nc --arg u "$USER_NAME" --arg p "$PASS" '{username:$u,password:$p,rememberMe:true}')
try_login() {
  curl -sk -m 10 -c "$JAR" -o /tmp/unifi-login.json -w '%{http_code}' \
    -H 'Content-Type: application/json' -d "$BODY" "https://$HOST$1"
}

echo "=== login as $USER_NAME ==="
OK=false
for EP in /api/login /api/auth/login; do
  CODE=$(try_login "$EP")
  echo "  $EP -> $CODE"
  if [ "$CODE" = "200" ]; then OK=true; break; fi
done
if [ "$OK" != true ]; then
  echo "  body: $(head -c 300 /tmp/unifi-login.json)"
  case "$CODE" in
    400|401) echo "  -> bad credentials, or the admin is not local to THIS controller";;
    423)     echo "  -> account locked; reset it in Settings > Admins & Users";;
    000)     echo "  -> no response: wrong host/port, or TLS refused";;
  esac
  exit 1
fi

# Both endpoints can answer on 9.x, so detect the API prefix by probing rather
# than inferring it from which login succeeded.
PREFIX=""
for P in "" "/proxy/network"; do
  if curl -sk -m 10 -b "$JAR" -H "Accept: application/json" "https://$HOST$P/api/self/sites" \
     | jq -e '.data' >/dev/null 2>&1; then PREFIX="$P"; break; fi
done
echo "  api prefix: '${PREFIX:-<none>}'"

api() { curl -sk -m 10 -b "$JAR" -H "Accept: application/json" "https://$HOST$PREFIX$1"; }

echo "=== sites (display name vs internal id) ==="
SITES=$(api /api/self/sites)
echo "$SITES" | jq -r '.data[]? | "  id=\(.name)  desc=\(.desc)  role=\(.role // "-")"'
SITE="${UNIFI_SITE:-$(echo "$SITES" | jq -r '.data[0].name // "default"')}"
echo "  using site id: $SITE"

STA=$(api "/api/s/$SITE/stat/sta")
if ! echo "$STA" | jq -e '.data' >/dev/null 2>&1; then
  echo "!! stat/sta denied or malformed: $(echo "$STA" | head -c 200)"; exit 1
fi
echo "=== my client record ==="
echo "$STA" | jq -r --arg m "$MAC" '.data[]? | select((.mac // ""|ascii_downcase) == $m)
    | "  ap_mac=\(.ap_mac // "-")  essid=\(.essid // "-")  signal=\(.signal // "-")  wired=\(.is_wired)"'
AP_MAC=$(echo "$STA" | jq -r --arg m "$MAC" 'first(.data[]? | select((.mac // ""|ascii_downcase) == $m) | .ap_mac) // empty')

DEV=$(api "/api/s/$SITE/stat/device")
if ! echo "$DEV" | jq -e '.data' >/dev/null 2>&1; then
  echo "!! stat/device denied (Viewer role may be too low): $(echo "$DEV" | head -c 200)"
else
  echo "=== access points ==="
  echo "$DEV" | jq -r '.data[]? | select(.type=="uap") | "  \(.mac)  \(.name // .model)"'
fi

echo
if [ -n "$AP_MAC" ]; then
  NAME=$(echo "$DEV" | jq -r --arg a "$AP_MAC" 'first(.data[]? | select((.mac // ""|ascii_downcase) == ($a|ascii_downcase)) | .name) // empty')
  echo ">>> CONNECTED TO: ${NAME:-<unnamed $AP_MAC>}"
else
  echo ">>> client $MAC not found on site $SITE (private MAC rotated, on ethernet, or wrong site)"
fi
