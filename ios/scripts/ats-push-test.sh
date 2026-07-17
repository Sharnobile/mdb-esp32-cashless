#!/usr/bin/env bash
# ATS verification helper: sends a push whose image URL is a plain-http LAN
# address, exercising the NotificationService extension's image download —
# the exact path the ATS change affects. Run against the booted simulator with
# the Debug app already installed and the local Supabase stack up.
#
# Usage: ios/scripts/ats-push-test.sh
set -euo pipefail

HOST="${SUPABASE_LAN:-http://10.0.1.130:54321}"
BUNDLE="de.kerl-handel.app.debug"
ANON="${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY to the local anon key (supabase status)}"

echo "→ Finding a product image on $HOST ..."
IMG_PATH=$(curl -s "$HOST/rest/v1/products?select=image_path&image_path=not.is.null&limit=1" \
  -H "apikey: $ANON" | sed -n 's/.*"image_path":"\([^"]*\)".*/\1/p')
if [ -z "$IMG_PATH" ]; then
  echo "✗ No product with an image found. Is the stack up and seeded?" >&2
  exit 1
fi
IMG_URL="$HOST/storage/v1/object/public/product-images/$IMG_PATH"
echo "  image: $IMG_URL"

echo "→ Confirming the image is reachable over http ..."
curl -sf -o /dev/null "$IMG_URL" && echo "  reachable ✓" || { echo "✗ image URL 404" >&2; exit 1; }

PAYLOAD=$(mktemp /tmp/ats-push.XXXX.json)
cat > "$PAYLOAD" <<JSON
{
  "aps": { "alert": { "title": "ATS Test", "body": "Bild sollte erscheinen" }, "mutable-content": 1 },
  "image": "$IMG_URL"
}
JSON

echo "→ Pushing to booted simulator ($BUNDLE) ..."
xcrun simctl push booted "$BUNDLE" "$PAYLOAD"
rm -f "$PAYLOAD"

cat <<'DONE'

Now look at the simulator's notification (pull down from the top if needed):
  • Image visible  → NSAllowsLocalNetworking covers numeric LAN IPs. ATS pass.
  • No image       → open Console.app, filter subsystem
                     "de.kerl-handel.app.debug.NotificationService", category "push".
      - an "Image download failed … App Transport Security / NSURLErrorDomain"
        line  → it does NOT cover it. Tell Claude to restore
        NSAllowsArbitraryLoads in both plists.
      - no such line → the payload/image was the problem, not ATS. Re-run.
DONE
