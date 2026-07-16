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
-- verified the caller. Hence the REVOKEs below.
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

  -- cash_book_entries.cash_book_id is ON DELETE RESTRICT (20260407000000:61),
  -- which is non-deferrable and fires the moment the companies-cascade reaches
  -- cash_books. Cascade-trigger order is OID-string order, so relying on the
  -- entries cascade winning that race is not a guarantee — it could differ
  -- between dev and prod. Delete both explicitly, entries first — the same
  -- order delete_cash_book() uses (20260407100000). The single-statement
  -- entries delete also satisfies the corrects_entry_id self-FK (NO ACTION),
  -- which is checked at end-of-statement.
  DELETE FROM public.cash_book_entries WHERE company_id = p_company_id;
  DELETE FROM public.cash_books        WHERE company_id = p_company_id;

  DELETE FROM public.companies WHERE id = p_company_id;
END;
$$;

-- Three statements, all load-bearing — do not "simplify":
--
-- 1. REVOKE FROM public: CREATE FUNCTION grants EXECUTE to PUBLIC by default.
-- 2. REVOKE FROM anon, authenticated: Supabase images often configure
--    ALTER DEFAULT PRIVILEGES ... GRANT ALL ON FUNCTIONS TO anon, authenticated —
--    which stamps EXPLICIT per-role ACL entries at creation time that the PUBLIC
--    revoke does not reach (see 20260602120000:190-191: default privileges vary
--    per install; rely on them neither being present NOR absent). Without this
--    line, on such installs ANY authenticated user could POST
--    /rest/v1/rpc/delete_company_and_data with an arbitrary company uuid —
--    the function is deliberately not self-guarding (the edge function verifies
--    the caller), so this revoke IS the tenant boundary.
-- 3. GRANT TO service_role: service_role is NOLOGIN + BYPASSRLS, not superuser;
--    after the revokes it has no EXECUTE path left, and PostgREST's
--    SET ROLE service_role would get 42501 — killing the edge function while the
--    SQL suite (which runs as the postgres superuser) stays green.
--    House pattern: 20260712000000:77-78.
REVOKE ALL ON FUNCTION public.delete_company_and_data(uuid) FROM public;
REVOKE ALL ON FUNCTION public.delete_company_and_data(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_company_and_data(uuid) TO service_role;

COMMENT ON FUNCTION public.delete_company_and_data(uuid) IS
  'Erases a company and the rows a companies-cascade cannot reach (sales, '
  'paxcounter, stock_decrement_log, cash book). Service-role only; the '
  'delete-account edge function verifies the caller. See spec '
  '2026-07-15-ios-app-store-release §4.3.';
