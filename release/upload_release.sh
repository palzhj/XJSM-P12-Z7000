#!/usr/bin/env bash
# Create a GitHub Release and upload assets. Requires GITHUB_TOKEN with repo scope.
set -euo pipefail

REPO="palzhj/XJSM-P12-Z7000"
TAG="v16"
NAME="v16 — Broadcast + 12-Engine XVC Remote JTAG (K7 programming verified)"
DIR="$(cd "$(dirname "$0")" && pwd)"

: "${GITHUB_TOKEN:?please export GITHUB_TOKEN=ghp_xxx}"
API="https://api.github.com/repos/$REPO"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")

echo "==> Creating release $TAG"
BODY=$(python3 -c 'import json,sys;print(json.dumps({"tag_name":"'$TAG'","name":"'"$NAME"'","body":open("'$DIR'/RELEASE_NOTES_v16.md").read(),"draft":false,"prerelease":false}))')
RESP=$(curl -sS "${AUTH[@]}" -X POST "$API/releases" -d "$BODY")
UP=$(echo "$RESP" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("upload_url",""))')
if [ -z "$UP" ]; then echo "Create failed:"; echo "$RESP" | head -20; exit 1; fi
UP="${UP%%\{*}"

for f in "$DIR"/v16/*; do
  n=$(basename "$f")
  echo "==> Uploading $n"
  curl -sS "${AUTH[@]}" -H "Content-Type: application/octet-stream" \
       --data-binary @"$f" "$UP?name=$n" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("   ",d.get("state",d.get("message")))'
done

echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
