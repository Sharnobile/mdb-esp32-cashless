# Account Deletion Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user delete their account from inside the iOS app — Apple Guideline 5.1.1(v) — and make that deletion actually erase what it promises.

**Architecture:** Three layers, bottom-up. A migration rewires 17 foreign keys that block deletion today and adds one `SECURITY DEFINER` RPC that erases a company atomically. An edge function verifies the caller, picks the ordinary or cascading path, and orchestrates. The iOS app gets the affordance in **two** places, because the one that matters is not the obvious one.

**Tech Stack:** Postgres 15 / Supabase, Deno edge functions, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-07-15-ios-app-store-release-design.md` §4

**Phase 2 of 6.** Phase 1 (upload blockers) is done except its ATS task, which is deferred pending the user's LAN test and is independent of this work.

---

## Why this is the risky phase

Every other phase touches build settings or docs. **This one deletes production data.** Two properties matter more than speed:

1. **`deleteUser` fails for every real user today.** `sales.owner_id` references
   `auth.users` with no `ON DELETE` clause, so Postgres blocks the delete with a
   raw `23503`. This is not hypothetical — it is the current state, and it means
   the deletion path has never worked.
2. **A `companies` cascade does not erase sales.** `sales` and `paxcounter` have
   no company column and reach one only via `embedded_id`/`machine_id`, both of
   which are deliberately `ON DELETE SET NULL` so history survives a device swap.
   A naive cascade leaves them alive with both FKs NULL — unreachable, invisible,
   undeletable, still holding revenue history. `stock_decrement_log` is worse: it
   has **no foreign keys at all**.

Read spec §4.2 and §4.3 before starting. The `Done when` checks at the bottom are
the contract.

## Ground rules

1. **Migrations are immutable.** Never edit `20260101000000_initial_schema.sql`,
   `20260228000000_multitenancy.sql`, `20260407000000_cash_book.sql`, or any other
   committed migration. New file only. `.githooks/pre-commit` enforces this.
   (Memory `feedback_migration_immutability`.)
2. **NEVER run `supabase db reset`.** The local dev DB is prod-synced and holds
   live test data. Use `supabase migration up`.
3. **The local stack is currently down.** `supabase start` from `Docker/supabase`
   first. If it aborts on an env parse error, use `--workdir Docker`
   (memory `project_supabase_cli_workdir_env_parse`).
4. Another session may commit to `main` concurrently. Use
   `git add <path> && git commit -m … -- <path>`; never amend/reset/rebase a
   commit you did not create.
5. `ios/VMflow/Resources/Info.plist` and `ios/NotificationService/Info.plist` are
   dirty in the working tree (prebuild script rewrites `CFBundleVersion`). Never
   `git add -A`.
6. **New Swift files must be registered in `project.pbxproj` by hand** (4 places:
   PBXBuildFile, PBXFileReference, group children, Sources phase). Never run
   `xcodegen`. (Memory `project_ios_xcode_file_registration`.)

---

## Chunk 1: Database

### Task 1: FK migration + cascade RPC

**Files:**
- Create: `Docker/supabase/migrations/20260716000000_account_deletion.sql`

- [ ] **Step 1: Start the stack and confirm the failing state**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase
supabase start   # or: supabase --workdir ../. start   (see ground rule 3)
```

Then prove the bug exists, so the fix has a baseline:

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT c.conrelid::regclass AS tbl,
       a.attname            AS col,
       c.confrelid::regclass AS refs,
       c.confdeltype        AS del
FROM pg_constraint c
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
WHERE c.contype = 'f'
  AND c.confrelid IN ('auth.users'::regclass, 'public.companies'::regclass)
  AND c.confdeltype = 'a'          -- 'a' = NO ACTION = blocks
ORDER BY 1, 2;
SQL
```

Expected: **17 rows.** `confdeltype = 'a'` is what "blocks the parent delete"
looks like in the catalog. Note the count — Step 5 asserts it becomes 0.

If you get a different count, stop and report it: the migration's VALUES list
below is derived from exactly these 17 and must match reality.

- [ ] **Step 2: Write the migration**

Create `Docker/supabase/migrations/20260716000000_account_deletion.sql`:

```sql
-- Account deletion (Apple Guideline 5.1.1(v)) — two problems, one migration.
--
-- 1. 17 FKs to auth.users / companies have no ON DELETE clause. A missing clause
--    is NO ACTION, which blocks the parent delete REGARDLESS of nullability —
--    nullability only decides whether SET NULL is a legal fix. sales.owner_id and
--    embeddeds.owner_id mean auth.admin.deleteUser() fails with 23503 for
--    essentially every real user today.
-- 2. sales / paxcounter / stock_decrement_log cannot be reached by a companies
--    cascade at all (no company column; their embedded_id/machine_id FKs are
--    deliberately SET NULL so device-swap history survives). They must be deleted
--    explicitly, first, in the same transaction — hence delete_company_and_data().
--
-- Constraints are located via pg_constraint rather than by guessed name:
-- `DROP CONSTRAINT IF EXISTS <table>_<col>_fkey` would miss SILENTLY on any DB
-- whose names differ, leaving the blocking FK in place while reporting success.

-- ---------------------------------------------------------------------------
-- A. Relax NOT NULL where the fix is SET NULL
-- ---------------------------------------------------------------------------
-- Audited 2026-07-16: created_by is read only by after_insert_cash_book()
-- (20260407000000_cash_book.sql:217-224), which copies NEW.created_by from
-- cash_books into cash_book_entries at INSERT time. It does not assume NOT NULL
-- and a NULL propagates harmlessly. No RLS policy reads created_by.
ALTER TABLE public.api_keys          ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.cash_books        ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.cash_book_entries ALTER COLUMN created_by DROP NOT NULL;

-- ---------------------------------------------------------------------------
-- B. Rewire every blocking FK
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r         record;
  v_conname text;
  v_attnum  int2;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- Blocking auth-user deletion → SET NULL (person goes, record stays)
      ('public.sales',                'owner_id',    'auth.users',       'SET NULL'),
      ('public.embeddeds',            'owner_id',    'auth.users',       'SET NULL'),
      ('public.paxcounter',           'owner_id',    'auth.users',       'SET NULL'),
      ('public.organization_members', 'invited_by',  'auth.users',       'SET NULL'),
      ('public.invitations',          'invited_by',  'auth.users',       'SET NULL'),
      ('public.device_provisioning',  'created_by',  'auth.users',       'SET NULL'),
      ('public.firmware_versions',    'uploaded_by', 'auth.users',       'SET NULL'),
      ('public.ota_updates',          'triggered_by','auth.users',       'SET NULL'),
      ('public.api_keys',             'created_by',  'auth.users',       'SET NULL'),
      ('public.cash_books',           'created_by',  'auth.users',       'SET NULL'),
      ('public.cash_book_entries',    'created_by',  'auth.users',       'SET NULL'),
      -- Blocking company deletion → CASCADE (company-owned data)
      ('public.embeddeds',            'company',     'public.companies', 'CASCADE'),
      ('public."vendingMachine"',     'company',     'public.companies', 'CASCADE'),
      ('public.product_category',     'company',     'public.companies', 'CASCADE'),
      ('public.products',             'company',     'public.companies', 'CASCADE'),
      ('public.cash_book_entries',    'company_id',  'public.companies', 'CASCADE'),
      -- …except this one. public.users is the PROFILE table, not company data.
      -- CASCADE here would delete the profile row of every OTHER member of a
      -- deleted company while their auth.users row survives — and
      -- on_auth_user_created only fires at signup, so it is never recreated:
      -- a live account with no profile.
      ('public.users',                'company',     'public.companies', 'SET NULL')
    ) AS t(tbl, col, reftbl, action)
  LOOP
    SELECT a.attnum INTO v_attnum
    FROM pg_attribute a
    WHERE a.attrelid = r.tbl::regclass
      AND a.attname  = r.col
      AND NOT a.attisdropped;

    IF v_attnum IS NULL THEN
      RAISE EXCEPTION 'column %.% not found', r.tbl, r.col;
    END IF;

    SELECT c.conname INTO v_conname
    FROM pg_constraint c
    WHERE c.conrelid  = r.tbl::regclass
      AND c.contype   = 'f'
      AND c.confrelid = r.reftbl::regclass
      AND c.conkey    = ARRAY[v_attnum];

    IF v_conname IS NULL THEN
      RAISE EXCEPTION 'FK on %.% -> % not found', r.tbl, r.col, r.reftbl;
    END IF;

    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, v_conname);
    EXECUTE format(
      'ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s(id) ON DELETE %s',
      r.tbl, v_conname, r.col, r.reftbl, r.action
    );
    RAISE NOTICE 'rewired % on %.% -> % (%)', v_conname, r.tbl, r.col, r.reftbl, r.action;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- C. Atomic company erasure
-- ---------------------------------------------------------------------------
-- Deletes what a cascade structurally cannot reach, then the company row.
-- One transaction: a half-erased company is worse than none.
--
-- NOT self-guarding, unlike get_platform_overview(): it is called only by the
-- delete-account edge function with the service role, after that function has
-- verified the caller. Hence the REVOKE below.
CREATE OR REPLACE FUNCTION public.delete_company_and_data(p_company_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_devices  uuid[];
  v_machines uuid[];
BEGIN
  IF p_company_id IS NULL THEN
    RAISE EXCEPTION 'p_company_id is required';
  END IF;

  SELECT coalesce(array_agg(id), '{}') INTO v_devices
  FROM public.embeddeds WHERE company = p_company_id;

  SELECT coalesce(array_agg(id), '{}') INTO v_machines
  FROM public."vendingMachine" WHERE company = p_company_id;

  -- sales / paxcounter / stock_decrement_log have no company column and their
  -- device/machine FKs are SET NULL (device-swap history). Cascade cannot reach
  -- them; without this they survive with both FKs NULL, forever unreachable.
  DELETE FROM public.sales
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);

  DELETE FROM public.paxcounter
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);

  -- No FKs at all — bare uuid columns.
  DELETE FROM public.stock_decrement_log
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);

  DELETE FROM public.companies WHERE id = p_company_id;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_company_and_data(uuid) FROM public;
REVOKE ALL ON FUNCTION public.delete_company_and_data(uuid) FROM anon, authenticated;

COMMENT ON FUNCTION public.delete_company_and_data(uuid) IS
  'Erases a company and the rows a companies-cascade cannot reach (sales, '
  'paxcounter, stock_decrement_log). Service-role only; the delete-account edge '
  'function verifies the caller. See spec 2026-07-15-ios-app-store-release §4.3.';
```

- [ ] **Step 3: Apply it**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase
supabase migration up
```

Expected: applies cleanly, with `NOTICE: rewired …` for each of the 17.
**Do not run `supabase db reset`.**

- [ ] **Step 4: Re-run it to prove idempotency**

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 \
  -f migrations/20260716000000_account_deletion.sql
```

Expected: succeeds again (the lookup finds the now-correct FK, drops and re-adds
it). `update.sh` applies each migration once, but a migration that cannot be
re-run is a trap for anyone recovering a botched deploy.

- [ ] **Step 5: Verify — the catalog, not a spot-check**

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n
  FROM pg_constraint c
  WHERE c.contype = 'f'
    AND c.confrelid IN ('auth.users'::regclass, 'public.companies'::regclass)
    AND c.confdeltype = 'a';
  ASSERT n = 0, format('%s blocking FKs remain', n);
  RAISE NOTICE 'OK: no blocking FKs to auth.users/companies';
END $$;
SQL
```

Expected: `OK`. This is a query over every FK, not a list of the ones we thought
of — a missed FK cannot hide from it. (It is blind to `stock_decrement_log`,
which has no FK; Task 2 covers that with row counts.)

- [ ] **Step 6: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/migrations/20260716000000_account_deletion.sql
git commit -m "feat(db): unblock account deletion — 17 FKs + delete_company_and_data

auth.admin.deleteUser() fails with 23503 for essentially every real user today:
sales.owner_id and embeddeds.owner_id reference auth.users with no ON DELETE
clause, which is NO ACTION and blocks regardless of nullability. 17 FKs are
rewired (SET NULL for people, CASCADE for company-owned data, SET NULL for
users.company since public.users is the profile table).

A companies cascade also cannot erase sales/paxcounter/stock_decrement_log: they
have no company column and their device FKs are deliberately SET NULL for
device-swap history. delete_company_and_data() deletes them explicitly and
atomically before the company row.

Constraints are located via pg_constraint, not by guessed name: DROP CONSTRAINT
IF EXISTS misses silently and would leave the blocking FK in place while the
migration reports success.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" \
  -- Docker/supabase/migrations/20260716000000_account_deletion.sql
```

---

### Task 2: SQL test

**Files:**
- Create: `Docker/supabase/tests/account_deletion.test.sql`

Follow the house pattern exactly: `BEGIN;` … plain `ASSERT`s … `ROLLBACK;`, fake
JWT via `set_config('request.jwt.claims', …)`. Read
`Docker/supabase/tests/platform_admin.test.sql` first — it is the closest model.

- [ ] **Step 1: Write the test**

It must cover the four things that would otherwise pass while broken:

1. **Realistic user delete** — a user owning **sales, paxcounter, a device, an
   API key and a cash-book entry**, *with a second admin present* (the second
   admin is what routes this to the ordinary path; without it the user is the sole
   admin and the cascade fires instead). `DELETE FROM auth.users WHERE id = …`
   must succeed. The weaker "API key + cash-book entry" case would pass while
   `sales.owner_id` still blocks everyone.
2. **Cascade completeness** — **snapshot the company's `embeddeds.id` and
   `vendingMachine.id` into arrays *before* calling `delete_company_and_data`**
   (afterwards there is nothing left to join on — that is the whole premise), then
   assert zero `sales`, `paxcounter` and `stock_decrement_log` rows reference the
   captured ids.
3. **Profile survival** — delete a company that has a second (viewer) member;
   assert the viewer's `public.users` row still exists with `company IS NULL` and
   their `auth.users` row is intact.
4. **Device-swap regression** — delete a *single device* (not a company); assert
   its sales rows survive with `machine_id` still set and `embedded_id` NULL. The
   FK migration must not break the behaviour `20260301400000_device_delete_fks.sql`
   deliberately introduced.

Create `Docker/supabase/tests/account_deletion.test.sql`:

```sql
-- Account deletion: FK rewiring + delete_company_and_data.
-- Rolled back. Plain ASSERTs. See spec 2026-07-15-ios-app-store-release §4.
BEGIN;
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_company2  uuid := gen_random_uuid();
  v_admin     uuid := gen_random_uuid();
  v_admin2    uuid := gen_random_uuid();
  v_viewer    uuid := gen_random_uuid();
  v_dev       uuid := gen_random_uuid();
  v_dev2      uuid := gen_random_uuid();
  v_machine   uuid;
  v_machine2  uuid;
  v_book      uuid := gen_random_uuid();
  v_devices   uuid[];
  v_machines  uuid[];
  n           int;
BEGIN
  -- ── Fixtures: company 1, two admins, a device, a machine, real data ──
  INSERT INTO public.companies (id, name) VALUES (v_company, 'Acme');
  INSERT INTO auth.users (id, instance_id, email, created_at) VALUES
    (v_admin,  '00000000-0000-0000-0000-000000000000', 'admin@test.local',  now()),
    (v_admin2, '00000000-0000-0000-0000-000000000000', 'admin2@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES
    (v_admin,  v_company, 'admin@test.local'),
    (v_admin2, v_company, 'admin2@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES
    (v_company, v_admin,  'admin'),
    (v_company, v_admin2, 'admin');

  INSERT INTO public.embeddeds (id, company, owner_id, status, status_at)
    VALUES (v_dev, v_company, v_admin, 'online', now());
  INSERT INTO public."vendingMachine" (name, company, embedded)
    VALUES ('M1', v_company, v_dev) RETURNING id INTO v_machine;

  INSERT INTO public.sales (embedded_id, machine_id, owner_id, item_price, item_number, channel, created_at)
    VALUES (v_dev, v_machine, v_admin, 2.50, 11, 'mdb', now());
  INSERT INTO public.paxcounter (embedded_id, machine_id, owner_id, count)
    VALUES (v_dev, v_machine, v_admin, 7);
  INSERT INTO public.stock_decrement_log (embedded_id, machine_id, item_number, item_price, reason)
    VALUES (v_dev, v_machine, 11, 2.50, 'test');
  INSERT INTO public.api_keys (company_id, key_hash, key_prefix, name, created_by)
    VALUES (v_company, 'hash', 'pfx', 'k', v_admin);
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'Kasse', 0, v_admin);

  -- ── Test 1: a realistic admin can be deleted (second admin present) ──
  -- Before the FK migration this raised 23503 via sales.owner_id.
  DELETE FROM auth.users WHERE id = v_admin;
  ASSERT NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_admin),
    'realistic admin must be deletable';
  ASSERT EXISTS (SELECT 1 FROM public.sales WHERE embedded_id = v_dev AND owner_id IS NULL),
    'sales must survive the owner with owner_id nulled';
  ASSERT EXISTS (SELECT 1 FROM public.api_keys WHERE company_id = v_company AND created_by IS NULL),
    'api key must survive its creator';
  ASSERT EXISTS (SELECT 1 FROM public.cash_book_entries WHERE company_id = v_company),
    'cash-book entries must survive their creator';
  RAISE NOTICE 'Test 1 passed: realistic user delete';

  -- ── Test 2: device delete keeps sales (device-swap regression) ──
  INSERT INTO public.embeddeds (id, company, status, status_at)
    VALUES (v_dev2, v_company, 'online', now());
  INSERT INTO public."vendingMachine" (name, company, embedded)
    VALUES ('M2', v_company, v_dev2) RETURNING id INTO v_machine2;
  INSERT INTO public.sales (embedded_id, machine_id, item_price, item_number, channel, created_at)
    VALUES (v_dev2, v_machine2, 1.50, 12, 'mdb', now());

  DELETE FROM public.embeddeds WHERE id = v_dev2;
  ASSERT EXISTS (
    SELECT 1 FROM public.sales
     WHERE machine_id = v_machine2 AND embedded_id IS NULL AND item_number = 12
  ), 'device delete must keep sales with machine_id set (20260301400000 behaviour)';
  RAISE NOTICE 'Test 2 passed: device-swap history preserved';

  -- ── Test 3: cascade completeness ──
  -- Snapshot ids BEFORE deleting; afterwards nothing remains to join on.
  SELECT coalesce(array_agg(id), '{}') INTO v_devices
    FROM public.embeddeds WHERE company = v_company;
  SELECT coalesce(array_agg(id), '{}') INTO v_machines
    FROM public."vendingMachine" WHERE company = v_company;

  PERFORM public.delete_company_and_data(v_company);

  ASSERT NOT EXISTS (SELECT 1 FROM public.companies WHERE id = v_company),
    'company row must be gone';

  SELECT count(*) INTO n FROM public.sales
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);
  ASSERT n = 0, format('%s orphaned sales rows remain', n);

  SELECT count(*) INTO n FROM public.paxcounter
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);
  ASSERT n = 0, format('%s orphaned paxcounter rows remain', n);

  SELECT count(*) INTO n FROM public.stock_decrement_log
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);
  ASSERT n = 0, format('%s orphaned stock_decrement_log rows remain', n);

  ASSERT NOT EXISTS (SELECT 1 FROM public.embeddeds WHERE id = ANY(v_devices)),
    'devices must cascade';
  ASSERT NOT EXISTS (SELECT 1 FROM public.cash_book_entries WHERE company_id = v_company),
    'cash-book entries must cascade';
  RAISE NOTICE 'Test 3 passed: cascade completeness';

  -- ── Test 4: profile survival ──
  INSERT INTO public.companies (id, name) VALUES (v_company2, 'Beta');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_viewer, '00000000-0000-0000-0000-000000000000', 'viewer@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES (v_viewer, v_company2, 'viewer@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company2, v_viewer, 'viewer');

  PERFORM public.delete_company_and_data(v_company2);

  ASSERT EXISTS (SELECT 1 FROM auth.users WHERE id = v_viewer),
    'a viewer of a deleted company must keep their auth account';
  ASSERT EXISTS (SELECT 1 FROM public.users WHERE id = v_viewer AND company IS NULL),
    'a viewer of a deleted company must keep their profile, with company nulled';
  RAISE NOTICE 'Test 4 passed: profile survival';

  RAISE NOTICE 'All account-deletion tests passed';
END $$;

ROLLBACK;
```

- [ ] **Step 2: Run it to verify it passes**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase/tests
./run-sql-tests.sh
```

Expected: `account_deletion.test.sql` passes along with the existing suite.

If a fixture INSERT fails on a column that does not exist, fix the **fixture** to
match the real schema — do not weaken an assertion to make the test pass.

- [ ] **Step 3: Prove the test would have caught the bug**

This is the step that makes the test worth having. Temporarily re-break one FK
and confirm Test 1 fails:

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres <<'SQL'
BEGIN;
ALTER TABLE public.sales DROP CONSTRAINT sales_owner_id_fkey;
ALTER TABLE public.sales ADD CONSTRAINT sales_owner_id_fkey
  FOREIGN KEY (owner_id) REFERENCES auth.users(id);
-- now run the test body's Test 1 — it must raise 23503
ROLLBACK;
SQL
```

Expected: `23503`. Then confirm the suite still passes afterwards (the `ROLLBACK`
undoes the sabotage). If Test 1 passes with the FK re-broken, the test is not
testing what it claims.

- [ ] **Step 4: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/tests/account_deletion.test.sql
git commit -m "test(db): account deletion — realistic user, cascade completeness, profile survival

Covers the four cases that would otherwise pass while broken: a realistic admin
(owning sales/paxcounter/device/api key/cash-book entry, with a second admin so
the ordinary path is exercised); cascade completeness against ids snapshotted
before the delete; a viewer's profile surviving their company; and the
device-swap SET NULL behaviour the FK migration must not break.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" \
  -- Docker/supabase/tests/account_deletion.test.sql
```

---

## Chunk 2: Edge function

### Task 3: `delete-account`

**Files:**
- Create: `Docker/supabase/functions/delete-account/index.ts`
- Create: `Docker/supabase/functions/delete-account/deno.json`
- Modify: `Docker/supabase/config.toml`

Follow `Docker/supabase/functions/invite-member/index.ts` — same auth pattern
(`verify_jwt = false` in config, identity verified in-function via
`adminClient.auth.getUser(token)`), same error shape, same `deno.json`
(`{"imports": {}}`).

- [ ] **Step 1: Write the function**

Contract (spec §4.4):

```
POST /functions/v1/delete-account
Authorization: Bearer <user JWT>
Body: {"confirm_company_name": "<string>"}   // required only when cascading
→ 200 {"deleted": true, "company_deleted": bool}
→ 400 {"error": "company_name_mismatch"}
→ 401 {"error": "unauthorized"}
```

Order — **and the order is the design, not an implementation detail**:

1. Resolve caller via `adminClient.auth.getUser(token)`; 401 if absent.
2. Read `organization_members` → `company_id`, `role`. No row → skip to 5.
3. If `role = 'admin'` **and** no *other* admin exists for that company → cascading:
   a. Require `confirm_company_name` to equal `companies.name` exactly, else 400.
   b. **Collect** the company's `products.image_path` values — they become
      unreadable once the cascade runs.
   c. Call `delete_company_and_data(company_id)`.
   d. **Only after it returns successfully**, remove those objects from the
      `product-images` bucket. Best-effort: log a removal failure, do not abort.
4. Otherwise no company-side work — the caller's `organization_members` row is
   removed by step 5's cascade (`organization_members.user_id → auth.users ON
   DELETE CASCADE`, `20260228000000_multitenancy.sql:12`).
5. `adminClient.auth.admin.deleteUser(user.id)`.

Two properties to preserve exactly:

- **Storage last.** Removing images before the RPC means a failing RPC leaves a
  live, in-use company that has silently lost every product image — damage with no
  deletion. Read paths first, delete objects last.
- **`deleteUser` last.** It goes through the GoTrue admin API and cannot join the
  Postgres transaction. Failing between 3 and 5 leaves an orphan admin with no
  company, who can simply delete again (a user with no company row is always
  deletable) — recoverable. Reversing them strands the company undeletable.

- [ ] **Step 2: Wire both environments**

`Docker/supabase/functions/delete-account/deno.json`:

```json
{
  "imports": {}
}
```

In `Docker/supabase/config.toml`, add next to the other function entries:

```toml
[functions.delete-account]
import_map = "./functions/delete-account/deno.json"
```

The function needs only `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`, which
already exist in both prod (docker-compose `environment:`) and dev
(`[edge_runtime.secrets]`). **No new env var** — so `.env.example`, `setup.sh`,
`update.sh`, `docker-compose.yml` and the Dockerfile are all untouched. (Memory
`project_supabase_cli_workdir_env_parse`: prod and dev are two separate systems;
a function missing from `config.toml` fails *only in production*.)

- [ ] **Step 3: Test the ordinary path**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase
supabase functions serve delete-account --no-verify-jwt &
```

Create a throwaway user with a company that has a second admin, get their JWT,
and:

```bash
curl -i -X POST http://127.0.0.1:54321/functions/v1/delete-account \
  -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -d '{}'
```

Expected: `200 {"deleted":true,"company_deleted":false}`, the user gone from
`auth.users`, the company and its data intact.

- [ ] **Step 4: Test the cascade path and its guard**

With a sole-admin user:

```bash
# wrong name → must refuse
curl -i -X POST http://127.0.0.1:54321/functions/v1/delete-account \
  -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
  -d '{"confirm_company_name":"wrong"}'
```
Expected: `400 {"error":"company_name_mismatch"}` and **nothing deleted** —
verify the company still exists before continuing.

```bash
# correct name → company goes
curl -i -X POST http://127.0.0.1:54321/functions/v1/delete-account \
  -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
  -d '{"confirm_company_name":"<exact name>"}'
```
Expected: `200 {"deleted":true,"company_deleted":true}`; company, devices, sales
all gone.

- [ ] **Step 5: Test unauthorized**

```bash
curl -i -X POST http://127.0.0.1:54321/functions/v1/delete-account \
  -H 'Content-Type: application/json' -d '{}'
```
Expected: `401`.

- [ ] **Step 6: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/delete-account Docker/supabase/config.toml
git commit -m "feat(api): delete-account edge function (Apple 5.1.1(v))

Ordinary path removes just the user; a sole admin may delete their company too,
guarded by an exact company-name confirmation. Order is load-bearing: paths are
read first, delete_company_and_data runs, storage objects are removed only after
it succeeds, and deleteUser goes last — GoTrue cannot join the Postgres
transaction, so failing mid-sequence must leave a recoverable orphan admin rather
than an undeletable company.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" \
  -- Docker/supabase/functions/delete-account Docker/supabase/config.toml
```

---

## Chunk 3: iOS

### Task 4: Delete affordance in both entry points

**Files:**
- Modify: `ios/VMflow/Views/Settings/SettingsView.swift`
- Modify: `ios/VMflow/VMflowApp.swift` (`NoOrganizationView`)
- Create: `ios/VMflow/Views/Settings/DeleteAccountSheet.swift`
- Modify: `ios/VMflow/Services/AuthService.swift` (add `deleteAccount`)
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`
- Modify: `ios/VMflow.xcodeproj/project.pbxproj` (register the new file)

- [ ] **Step 1: Understand why there are two entry points**

`RootView` (`ios/VMflow/VMflowApp.swift:38-56`) routes on three states, and
`organization == nil` lands on `NoOrganizationView` (`VMflowApp.swift:75-98`),
which today offers **only Sign Out and Retry** and says *"Please create or join
one using the web dashboard."* `AdaptiveRootView` — and therefore `SettingsView`
— is never rendered.

A user who registers in-app via `RegisterView` is **org-less on first launch**.
So the most natural reviewer script — register a fresh account, look for account
deletion — dead-ends on a screen with no delete affordance that points at a
website. Putting the button only in Settings re-creates the exact rejection this
phase exists to prevent. It is also the state an orphan admin lands in, which is
what makes the edge function's retry-safety real rather than theoretical.

- [ ] **Step 2: Add `deleteAccount` to `AuthService`**

Calls the edge function with the current session's JWT, and on success signs out
(so `RootView` returns to `AuthNavigationView`). It must surface
`company_name_mismatch` distinctly from a generic failure so the sheet can show
the right message.

- [ ] **Step 3: Build `DeleteAccountSheet`**

Two modes, driven by whether the caller is the sole admin:

- **Ordinary:** a confirmation dialog naming the consequence.
- **Cascading:** a screen listing what disappears (machines, sales, warehouse,
  devices) and a text field requiring the **exact company name**, with the delete
  button disabled until it matches.

The app cannot know "sole admin" without asking; the simplest honest approach is
to attempt the delete and let the function's `400 company_name_mismatch` /
`company_deleted` drive the UI, rather than duplicating the admin-count rule
client-side where it would drift from the server.

- [ ] **Step 4: Wire both entry points**

Destructive row at the bottom of `SettingsView` below Sign Out, and the same
affordance on `NoOrganizationView` next to its Sign Out button.

- [ ] **Step 5: Add en/de strings**

Insert **surgically** into `ios/VMflow/Resources/Localizable.xcstrings` — key is
the resolved `String(localized:)` literal, de entries only, du-tone. **Never
re-serialize the file with a script**: Xcode's key sort is not codepoint order and
a full rewrite produces an unreviewable diff. (Memory
`reference_ios_xcstrings_editing`.)

- [ ] **Step 6: Register the new Swift file**

`ios/VMflow.xcodeproj` has no synchronized groups. `DeleteAccountSheet.swift`
must be added to `project.pbxproj` in **4 places**: `PBXBuildFile`,
`PBXFileReference`, the group's `children`, and the **Sources** build phase
(`CF37A3A9F0065BB67F3BEE95`). Miss one and it silently does not compile in.
**Never run `xcodegen`.** (Memory `project_ios_xcode_file_registration`.)

- [ ] **Step 7: Build**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodebuild -project VMflow.xcodeproj -scheme VMflow \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`. A build that succeeds while the file is
unregistered is the failure mode — verify the symbol is actually referenced.

- [ ] **Step 8: The test that matters — a fresh org-less account**

On a simulator against the local stack:

1. Register a **brand-new** account in-app.
2. You land on `NoOrganizationView`.
3. **The delete affordance must be there**, and deleting must complete and return
   you to the login screen.

This is the reviewer's script. If it does not work, nothing else in this phase
matters.

Then the Settings path: log in as a member of a company with a second admin,
Settings → Delete account → confirm → back at login, company intact.

- [ ] **Step 9: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/Views/Settings/DeleteAccountSheet.swift \
        ios/VMflow/Views/Settings/SettingsView.swift \
        ios/VMflow/VMflowApp.swift \
        ios/VMflow/Services/AuthService.swift \
        ios/VMflow/Resources/Localizable.xcstrings \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): in-app account deletion (Apple 5.1.1(v))

Two entry points, deliberately: SettingsView and NoOrganizationView. A user who
registers in-app is org-less on first launch and never reaches Settings, so a
Settings-only button would leave the most natural reviewer script — register,
then look for deletion — dead-ending on a screen that points at the web
dashboard. It is also the state an orphan admin lands in.

Sole admins must type their company name to confirm; the sole-admin rule stays
server-side rather than being duplicated in the client where it would drift.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" \
  -- ios/VMflow/Views/Settings/DeleteAccountSheet.swift \
     ios/VMflow/Views/Settings/SettingsView.swift \
     ios/VMflow/VMflowApp.swift \
     ios/VMflow/Services/AuthService.swift \
     ios/VMflow/Resources/Localizable.xcstrings \
     ios/VMflow.xcodeproj/project.pbxproj
```

---

## Done when

- `supabase migration up` applies cleanly, and re-running the file succeeds
- **Zero** FKs to `auth.users` / `companies` have `confdeltype = 'a'`
- `./run-sql-tests.sh` green, including the four new cases
- Re-breaking `sales_owner_id_fkey` makes Test 1 fail (the test tests something)
- `delete-account` returns 200 / 400 / 401 per the contract, verified by curl
- **A freshly registered, org-less account can delete itself from
  `NoOrganizationView`** — the reviewer's script
- A member with a second admin present can delete from Settings, company intact
- Deleting one device still leaves its sales with `machine_id` set

## Open, not decided here

The GoBD/HGB §257 vs GDPR Art. 17(3)(b) question on cash-book entries (spec §4.2)
is with the user's tax advisor. It does not block this phase; if the answer is
"retain", `delete_company_and_data` changes — which is one function, by design.
