#!/usr/bin/env bash
# Re-apply the local esp_modem patch needed for ESP-IDF v5.5.1.
#
# Why: managed_components/ is gitignored and gets re-fetched whenever
#      idf.py reconfigure pulls a fresh dependency tree. ESP-IDF v5.5.1
#      trips a `find_desc_for_source intr_alloc.c:199 (svd != NULL)`
#      assert when esp_modem's UartTerminal calls uart_driver_install
#      with intr_alloc_flags=0 — there's a latent corrupted-shared-vector
#      bug in IDF's intr_alloc that this project's hardware reliably
#      triggers. Forcing ESP_INTR_FLAG_LEVEL1 takes the non-shared path
#      and avoids the iteration that asserts.
#
# Run this script after `idf.py reconfigure` (or any time the
# managed_components tree was re-pulled) and before `idf.py build`.
#
# Usage: ./scripts/patch-esp-modem.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$REPO_ROOT/mdb-slave-esp32s3/managed_components/espressif__esp_modem/src/esp_modem_term_uart.cpp"

if [ ! -f "$TARGET" ]; then
    echo "esp_modem not yet fetched (missing: $TARGET)"
    echo "Run 'idf.py reconfigure' from mdb-slave-esp32s3/ first, then re-run this script."
    exit 1
fi

if grep -q "ESP_INTR_FLAG_LEVEL1 /\* intr_alloc workaround" "$TARGET" 2>/dev/null; then
    echo "Patch already applied to $TARGET — nothing to do."
    exit 0
fi

python3 - "$TARGET" <<'PY'
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text()

# Match the multi-line uart_driver_install call ending in ", 0);"
needle = re.compile(
    r"(res = uart_driver_install\(config->port_num,\s*\n"
    r"\s*config->rx_buffer_size, config->tx_buffer_size,\s*\n"
    r"\s*config->event_queue_size, config->event_queue_size \?\s*event_queue : nullptr,\s*\n"
    r"\s*)0(\);)",
    re.MULTILINE,
)

m = needle.search(src)
if not m:
    print("FAIL: could not find the uart_driver_install call to patch.")
    print("Either esp_modem was upgraded and the call shape changed, or the patch already landed.")
    sys.exit(2)

replacement = m.group(1) + "ESP_INTR_FLAG_LEVEL1 /* intr_alloc workaround for IDF v5.5.1 */" + m.group(2)
patched = src[:m.start()] + replacement + src[m.end():]
path.write_text(patched)
print("Patched", path)
PY

echo "esp_modem patch applied — proceed with 'idf.py build'."
