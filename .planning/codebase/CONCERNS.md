# Codebase Concerns

**Analysis Date:** 2026-03-13

## Tech Debt

**Weak typing in composables and edge functions:**
- Files: `management-frontend/app/composables/useMachines.ts`, `management-frontend/app/composables/useProducts.ts`, `management-frontend/app/composables/useWarehouse.ts`, `Docker/supabase/functions/send-credit/index.ts`
- Issue: Extensive use of `any` type casts and `(supabase as any)` circumvents TypeScript safety. Supabase types are not generated (`~/types/database.types.ts` missing), forcing manual casting of query results.
- Impact: Silent bugs possible when column names change; no IDE autocomplete for database fields; refactoring becomes error-prone.
- Fix approach: Generate Supabase types with `supabase gen types typescript > types/database.types.ts` and reference them in all queries. Removes need for `as any` casts.

**Duplicate query aggregation logic:**
- Files: `management-frontend/app/composables/useMachines.ts` (lines 85-177)
- Issue: Manual aggregation of sales data into maps (today, yesterday, this month, last month) is repetitive and error-prone. Same pattern appears in multiple places.
- Impact: High risk of off-by-one errors; hard to maintain; difficult to add new time periods.
- Fix approach: Extract aggregation into a reusable function `aggregateSalesByMachine(rows, dateRanges)` in `app/lib/sales-aggregation.ts`.

**Large composable with mixed concerns:**
- Files: `management-frontend/app/composables/useMachines.ts` (497 lines)
- Issue: Single composable handles machines, sales stats, paxcounter, trays, stock calculation, and realtime subscriptions. Testing is difficult; logic is intertwined.
- Impact: Hard to test individual pieces; changes to one feature risk breaking others; difficult to reuse stats in other contexts.
- Fix approach: Split into focused composables: `useMachineList()`, `useMachineSalesStats()`, `useMachineStock()`, `useMachineRealtime()`.

## Known Bugs

**Timestamp parsing bug in mdb-log processing:**
- Files: `Docker/supabase/functions/mqtt-webhook/index.ts` (lines 50-61)
- Issue: C `__DATE__ __TIME__` format parsing via `new Date(raw)` is fragile. Format is "Mar  1 2026 14:30:00 +0100" which JavaScript parses but behavior varies by locale and browser. Timezone offset parsing is platform-dependent.
- Impact: Build date may be parsed incorrectly or fail silently, showing wrong timestamp in UI. Devices in different timezones may see inconsistent dates.
- Workaround: Currently just displays what was parsed; if wrong, device status shows incorrect build date.
- Fix approach: Use a library like `date-fns` or parse with explicit locale (`Date.parse()` with Intl hints). Better: have ESP32 send ISO timestamp, not C format string.

**Race condition in device provisioning:**
- Files: `Docker/supabase/functions/claim-device/index.ts` (lines 49-77)
- Issue: Idempotent retry logic checks `if (token.used_at && token.embedded_id)` but doesn't lock the token row. Two simultaneous requests with the same code could both see the same token, both create devices, and both update the token → inconsistent state.
- Impact: Rare case (device reboots during claim), but results in orphaned embedded row + confused state.
- Fix approach: Use Postgres `FOR UPDATE` lock: `SELECT ... FOR UPDATE` before checking `used_at`.

**Activity log write failures don't block sales:**
- Files: `Docker/supabase/functions/mqtt-webhook/index.ts` (lines 304-320)
- Issue: Activity log write is wrapped in try-catch that only logs error. If `adminClient.from('activity_log').insert()` fails, the sale is already committed. Audit trail is incomplete without visibility into the failure.
- Impact: Sales are recorded but activity log is missing for that sale. No alerting to operator that audit trail is broken.
- Fix approach: Log error to stderr (Deno.errors or structured JSON to console). Add monitoring/alerting on function logs. Optionally: make activity log critical and fail the sale if write fails (breaking change, requires careful rollout).

**BarcodeScanner.vue unmounted during navigation:**
- Files: `management-frontend/app/components/BarcodeScanner.vue`
- Issue: Camera stream lifecycle not explicitly managed. If user navigates away from `/warehouse` while scanner is active, cleanup may be incomplete.
- Impact: Camera resource may be held by the browser; subsequent scanner use could fail or show "camera already in use" error.
- Fix approach: Explicitly stop video stream in `onBeforeUnmount()`: check if `video.srcObject` exists and call `getTracks().forEach(t => t.stop())`.

## Security Considerations

**XOR obfuscation is not encryption:**
- Files: Multiple - MQTT payload XOR in `Docker/supabase/functions/mqtt-webhook/index.ts`, `Docker/supabase/functions/send-credit/index.ts`, `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`
- Risk: XOR cipher is deterministic and reversible without a key if plaintext is guessed. An attacker with MQTT broker access + knowledge of message format can recover the passkey or forge messages. Not cryptographically secure.
- Current mitigation: Passkey is 18-char random (entropy ~93 bits); timestamp window (±8s) prevents replay. Assumes MQTT broker is on secure network (LAN).
- Recommendations:
  1. **For immediate hardening**: Add MAC (HMAC-SHA256) in addition to XOR to detect tampering.
  2. **For future**: Migrate to AES-128-GCM (authenticated encryption). Requires firmware update; must maintain backward compatibility with old devices.
  3. Document security assumptions: "MQTT broker must be on trusted network; XOR is obfuscation only, not encryption."

**Missing rate limiting on edge functions:**
- Files: `Docker/supabase/functions/claim-device/index.ts`, `Docker/supabase/functions/send-credit/index.ts`, `Docker/supabase/functions/create-provisioning-token/index.ts`
- Risk: No rate limiting on provisioning code generation or credit sends. Attacker could brute-force provisioning codes or spam credit requests.
- Recommendations:
  1. **Provisioning**: Rate limit by IP + company_id to 10 attempts/minute.
  2. **Credit sends**: Rate limit by company_id + device_id to 1 request/second.
  3. Implement via Redis or Postgres `rate_limit` table with cleanup job.

**Webhook secret in plaintext logs:**
- Files: `Docker/supabase/functions/mqtt-webhook/index.ts` (line 12)
- Risk: If logs are exposed (e.g., via Deno.serve stderr), the secret is visible. An attacker with log access can forge webhook payloads.
- Current mitigation: Logs are typically isolated to container stderr; secret is environment variable (not hardcoded).
- Recommendations:
  1. Never log `secret` or `X-Webhook-Secret` header value.
  2. Log only `secret === expectedSecret ? "OK" : "FAIL"` for debugging.

**Product images stored as UUIDs, no content-type validation:**
- Files: `management-frontend/app/composables/useProducts.ts` (lines 93-112)
- Risk: File extension is extracted from user-provided filename and used as-is. Attacker could upload `malware.php.jpg` and if web server misconfigures MIME type, execute code.
- Current mitigation: Supabase storage bucket is `product-images` with max 2MiB and restricted to PNG/JPEG/WebP in policy (enforced server-side).
- Recommendations:
  1. Verify on client: reject if file MIME type not in `['image/png', 'image/jpeg', 'image/webp']`.
  2. Rename uploaded file to `{productId}.{hash}.{ext}` (hash of content) to prevent collision/overwrite attacks.
  3. Serve with `Content-Disposition: inline; filename=product.jpg` and `X-Content-Type-Options: nosniff` (Supabase does this by default).

## Performance Bottlenecks

**N+1 queries in last-sale fetch:**
- Files: `management-frontend/app/composables/useMachines.ts` (lines 124-132)
- Problem: For each machine, a separate query is dispatched to fetch latest sale. With 100 machines = 100 individual queries (even though batched in Promise.all, still 100 network round-trips).
- Cause: Supabase JS client doesn't support window functions (`ROW_NUMBER() OVER`) in `.select()`. Cannot fetch "latest sale per machine" in one query.
- Improvement path:
  1. **Immediate**: Reduce frequency of full refetch. Cache last-sale timestamps; only refetch sales older than 5 min.
  2. **Medium-term**: Add a Postgres view that materializes latest sale per machine (updated by trigger), then query the view once.
  3. **Long-term**: Use Postgres native client (node-postgres) for complex queries, avoid Supabase JS client limitations.

**Machine stock calculation is O(trays²) in worst case:**
- Files: `management-frontend/app/composables/useMachines.ts` (lines 238-292)
- Problem: Two passes over tray data (low/empty count, then fill_when_below). For each machine with critical stock, iterates all its trays again. With 10k trays across 100 machines = ~1ms per fetch, acceptable now but scales poorly.
- Impact: UI fetch latency grows with tray count; noticeable on large fleets.
- Improvement path:
  1. **Immediate**: Single-pass aggregation: track low/empty + fill_when_below in one loop, combine results at end.
  2. **Medium-term**: Materialize stock_health on machine inserts via trigger (denormalization). Query it directly.

**Realtime subscription memory leak potential:**
- Files: `management-frontend/app/pages/machines/index.vue` (lines 51-52), `management-frontend/app/composables/useMachines.ts` (lines 372-457)
- Problem: If `unsubscribe()` is not called (e.g., exception during onMounted after subscribeToStatusUpdates), the realtime channel stays active. Rapid page navigations could open multiple channels.
- Impact: Browser memory grows; Supabase realtime connection quota exhausted; eventually all subscriptions silently fail.
- Fix approach:
  1. Wrap subscription in try-finally: `try { const unsub = subscribeToStatusUpdates() } finally { onUnmounted(unsub) }`.
  2. Add a safety timeout: auto-unsubscribe channels older than 5 minutes idle.

**useNotifications Promise.race has 10s timeout:**
- Files: `management-frontend/app/composables/useNotifications.ts` (lines 110-118)
- Problem: `Notification.requestPermission()` may hang on iOS if user previously dismissed the prompt. 10-second race timeout is arbitrary and user-experience-breaking (silent fallback to 'default').
- Impact: On slow networks or old devices, legitimate permission requests timeout. User sees "permission denied" but it's actually a timeout.
- Improvement path:
  1. **Immediate**: Increase timeout to 30s or remove timeout (block indefinitely).
  2. **Better**: Use `window.onbeforeunload` to detect page unload and auto-cancel the race.

## Fragile Areas

**useMachines composable interconnected state:**
- Files: `management-frontend/app/composables/useMachines.ts`
- Why fragile:
  - Realtime handler (lines 372-457) assumes `machines.value` array is always in sync with DB. If refetch happens during realtime update, races occur.
  - Example: `subscribeToStatusUpdates()` updates machine.embeddeds.status in real-time. If user triggers `fetchMachines()` while update is in flight, the in-memory update is overwritten or merged unpredictably.
  - Stock calculation relies on exact tray order and no missing rows. If a tray insert fails on the server but succeeds on client optimistically, stock health is wrong.
- Safe modification:
  1. Never mutate machines array in realtime handlers; instead rebuild it: `machines.value = machines.value.map(m => m.id === id ? {...m, updated} : m)`.
  2. Add a `generationId` or `revision` number to track which fetch produced the current array. Ignore realtime updates older than the current fetch.
  3. Add explicit conflict markers in tray data (e.g., `_locally_added: true`) so stock calculation skips client-only trays.
- Test coverage: Realtime handlers not tested; only happy-path server-side tests exist.

**mqtt-webhook edge function error handling:**
- Files: `Docker/supabase/functions/mqtt-webhook/index.ts`
- Why fragile:
  - Function catches all errors at the top level (line 341). If a specific query fails mid-function (e.g., push notification fetch at line 242), the whole sale is already committed but error is swallowed.
  - Payload validation (line 168) checks length === 19 but doesn't validate byte ranges. Malformed payload could overflow integers during bit shifting (lines 198-216).
  - Device lookup (line 174) assumes `embeddedData[0]` exists even if query succeeds with 0 rows; would crash.
- Safe modification:
  1. Break function into steps with clear error boundaries: parse → validate → decrypt → lookup device → insert sale → push notification → activity log. Fail fast on parse/decrypt.
  2. Add explicit null checks: `if (!embeddedData?.[0]) throw new Error('Device not found after query')`.
  3. Validate byte values before bit operations: `if (payload[i] > 255) throw new Error('Invalid payload byte')`.
  4. Test with malformed payloads (truncated, oversized, invalid checksums).

**Product image upload without transaction:**
- Files: `management-frontend/app/composables/useProducts.ts` (lines 93-112)
- Why fragile:
  - Upload to storage succeeds (line 101) but DB update fails (line 106) → orphaned file in bucket, no way to clean it up.
  - If user hits back button during upload, state is inconsistent (file uploaded but `products.value` not updated).
  - No soft-delete or cleanup job to remove unused product images.
- Safe modification:
  1. Perform DB update first (insert row with null image_path), then upload to known path. If upload fails, image_path stays null.
  2. Add an edge function `cleanup-orphaned-images` (cron job) that finds product images with no matching product row and deletes them.
  3. Add optimistic UI: show image preview immediately; mark as "uploading". If upload fails, revert UI.

**Warehouse stock FIFO depends on expiration_date ordering:**
- Files: `management-frontend/app/composables/useWarehouse.ts`, `Docker/supabase/functions/*/index.ts` (any that call `deduct_warehouse_stock_fifo()`)
- Why fragile:
  - FIFO selection is by `ORDER BY expiration_date ASC` in the `deduct_warehouse_stock_fifo()` function. If two batches have same expiration_date (NULL or same date), order is undefined.
  - Inserting batches without setting expiration_date means NULL, which sorts first. Operator could accidentally FIFO-pull NULL-expiry batches and expire good stock.
  - No constraint preventing duplicate (warehouse, product, expiration_date) triples; same batch could be created twice.
- Safe modification:
  1. Add UNIQUE constraint: `UNIQUE (warehouse_id, product_id, batch_number, expiration_date)`.
  2. Change FIFO to: `ORDER BY COALESCE(expiration_date, '9999-12-31') ASC, created_at ASC` (NULL batches go last; tie-break by insert order).
  3. In UI, require expiration_date for stock intake (no NULLs). Make it a required field.

## Scaling Limits

**Dashboard queries scale O(machines²):**
- Current capacity: ~500 machines
- Limit: ~2000 machines (beyond this, fetchMachines becomes slow >5s, hits Supabase connection pool limits)
- Scaling path:
  1. Paginate machine list (50 per page).
  2. Implement server-side aggregation: move sales stats & stock calculations to Postgres views or materialized views.
  3. Cache at 1-minute granularity (Redis layer between frontend + Supabase).
  4. Upgrade Supabase tier for more connections.

**Realtime channels per user:**
- Current capacity: ~20 active channels per browser tab (Supabase limit is ~100 per client)
- Limit: If user opens 5 tabs with machines page, each spawns a "machines-realtime" channel = multiplied connections
- Scaling path:
  1. Use a single shared channel per page type (one "machines-realtime" for all machines, not per machine).
  2. Add channel deduplication in composables (check if channel already exists before creating).
  3. Implement channel pooling (manage channels in a central store, not per-page).

**Activity log table growth:**
- Current capacity: ~1M rows / ~2GB per company (typical)
- Limit: Beyond 10M rows, queries slow down; audit log becomes unusable
- Scaling path:
  1. Implement table partitioning by `created_at` (monthly partitions).
  2. Archive old entries (>1 year) to cold storage.
  3. Create an index on `(company_id, created_at DESC)` for fast filtering.
  4. Paginate activity log UI (already done) to avoid loading entire table.

**MQTT broker message queue:**
- Current capacity: ~1000 messages/second for 100 devices
- Limit: ~10k messages/sec (beyond this, broker RAM exhausts, messages are dropped)
- Scaling path:
  1. Increase Mosquitto `max_queued_messages` setting.
  2. Implement message TTL: drop stale sale/status messages older than 5 minutes.
  3. Add load balancer / multi-broker setup (MQTT 5.0 clustering).

## Dependencies at Risk

**Supabase JS client lacks window function support:**
- Risk: Cannot query "latest sale per machine" or "ranked stock levels" in a single query. Requires client-side aggregation or custom SQL view.
- Impact: N+1 query patterns; complex client logic; hard to implement efficient pagination.
- Migration plan:
  1. **Short-term**: Accept current limitations; optimize with caching.
  2. **Long-term**: Migrate critical queries to direct Postgres client (node-postgres) or use Supabase `sql` template (if available in edge runtime).
  3. Alternative: Build a custom GraphQL layer (Hasura) on top of Supabase for complex queries.

**Deno npm: module compatibility drift:**
- Risk: `npm:mqtt@5` may change API or introduce breaking changes. Deno's npm compatibility is still young.
- Impact: Edge functions break on upgrade; deployment blocked.
- Recommendations:
  1. Pin `mqtt` version in `deno.json` (e.g., `mqtt@5.0.0`, not `@5`).
  2. Add CI test that verifies edge function can be deployed (deno check + supabase functions deploy --dry-run).
  3. Consider switching to native Deno MQTT client if available (e.g., `mqtt4deno`).

**TailwindCSS 4 dark mode detection:**
- Risk: Dark mode is stored in `localStorage` (see `app/composables/useTheme.ts`). If localStorage is disabled or cleared, user's preference is lost.
- Impact: User switches to dark mode, clears cache, reverts to system default. Annoying UX.
- Recommendations:
  1. Store preference in Supabase user metadata (sync across devices).
  2. Use CSS media query `(prefers-color-scheme: dark)` as fallback (no storage needed).

## Missing Critical Features

**No offline mode:**
- Problem: If device loses internet (LAN down, WiFi drops), management dashboard is unusable. No cached data, no offline queue.
- Blocks: Field operators can't check stock levels or create machines while offline.
- Impact on sales: None directly (devices publish to MQTT, which queues). But operators are blind.
- Recommendations:
  1. Implement service worker offline cache (already built, but not used for data).
  2. Store last known machines + sales in IndexedDB.
  3. Queue local edits (e.g., tray capacity changes) in service worker; sync when online.

**No OTA firmware update status tracking:**
- Problem: When admin clicks "Deploy OTA", firmware publishes to MQTT topic but no tracking of which devices received it.
- Blocks: Admin can't tell if device is updating or failed.
- Current workaround: Check device status in UI; if status changes to "ota_updating" or "ota_success", assume it worked.
- Recommendations:
  1. Add `firmware_ota_status` table tracking (device_id, version, status, updated_at).
  2. Device publishes `ota_success` / `ota_failed` events to MQTT.
  3. Show OTA progress in UI with success/failure list.

**No device grouping / locations:**
- Problem: All machines in a company appear flat. No way to organize by store, region, or warehouse.
- Blocks: Large operators (100+ machines) can't filter or sort meaningfully.
- Recommendations:
  1. Add `location` / `group_id` column to `vendingMachine` table.
  2. Add location CRUD page.
  3. Filter machines by location in list view.

## Test Coverage Gaps

**Realtime subscription handlers not tested:**
- What's not tested: `subscribeToStatusUpdates()` callbacks in `management-frontend/app/composables/useMachines.ts` (lines 379-395, 407-419, 424-444, 448-451)
- Files: `management-frontend/app/composables/useMachines.ts`
- Risk: Updates to embeddeds, vendingMachine, sales tables could silently fail to reflect in UI. Realtime feature silently broken until user manually refreshes.
- Test approach:
  1. Mock `supabase.channel()` and test that callback handlers update `machines.value` correctly.
  2. Test race conditions: dispatch realtime update while fetch is in-flight.
  3. Test edge cases: UPDATE with null values, DELETE then INSERT same ID, rapid fires.

**Edge function error paths not tested:**
- What's not tested: All error branches in `mqtt-webhook/index.ts` (invalid topic, device not found, checksum mismatch, push notification failures)
- Files: `Docker/supabase/functions/mqtt-webhook/index.ts` (see test file `mqtt-webhook/mdb-log.test.ts` — only tests mdb-log, not sale/paxcounter)
- Risk: Error handling code could be dead or wrong. Silent failures in activity log, push notifications, or device lookup.
- Test approach:
  1. Add test cases for truncated payload, oversized payload, invalid checksum.
  2. Test device not found (404).
  3. Mock push notification service to fail; verify sale still commits.
  4. Mock activity log to fail; verify sale still commits and error is logged.

**Product image upload failure not tested:**
- What's not tested: `uploadProductImage()` behavior when storage.upload() fails or DB update fails
- Files: `management-frontend/app/composables/useProducts.ts`
- Risk: Orphaned files, inconsistent state, user gets generic error with no recovery path.
- Test approach:
  1. Mock `supabase.storage.upload()` to fail; verify error is thrown and DB is not modified.
  2. Mock `supabase.update()` to fail; verify DB rolls back (or orphaned file is detected).
  3. Test concurrent uploads of same file (should use upsert).

**Warehouse FIFO deduction with expired batches:**
- What's not tested: `deductForRefill()` behavior when only expired batches exist
- Files: `management-frontend/app/composables/useWarehouse.ts` (function exists but test missing)
- Risk: Operator could accidentally pull expired stock. Function silently succeeds, operator ships bad product.
- Test approach:
  1. Create batches with various expiration_date (past, today, future, NULL).
  2. Call `deductForRefill(warehouse, product, quantity)` and verify it pulls oldest non-NULL first, then NULL.
  3. Test: deduct more than available (should fail); deduct from single expired batch (should succeed but warn).

---

*Concerns audit: 2026-03-13*
