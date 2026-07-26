-- Bulk-generates :count fake sales spread over the last :days days, picked
-- from existing machine_trays that have a product assigned (optionally
-- restricted to one company/machine), for local test/demo purposes only.
--
-- Called by scripts/generate-fake-sales.sh — not meant to be run by hand.
-- Expected psql vars: count (int), days (int), company_filter (uuid or ''),
-- machine_filter (uuid or ''), adjust_stock ('true'/'false').
--
-- Reuses the same stock-skip GUC as insert_manual_sale(p_adjust_stock) so
-- backdated fake sales don't touch current_stock unless explicitly asked to
-- (see Docker/supabase/migrations/20260602120000_manual_sale_skip_stock.sql).

\set ON_ERROR_STOP on

-- Silence everything until right before the final id-returning SELECT: with
-- -tA, psql still echoes a command tag (BEGIN, the set_config result row,
-- COMMIT, ...) for every statement, which would otherwise land in the ids
-- file alongside the actual uuids.
\o /dev/null
BEGIN;

\if :adjust_stock
\else
  SELECT set_config('vmflow.skip_stock_decrement', 'on', true);
\endif

-- Guard done as plain SQL + \gset (NOT a DO $$ block): psql variable
-- interpolation is skipped inside dollar-quoted string bodies, so
-- :'company_filter' would reach the server as a literal, unparseable ":".
SELECT EXISTS (
    SELECT 1
    FROM machine_trays mt
    JOIN products p ON p.id = mt.product_id
    JOIN "vendingMachine" vm ON vm.id = mt.machine_id
    WHERE mt.product_id IS NOT NULL
      AND (:'company_filter' = '' OR vm.company = NULLIF(:'company_filter', '')::uuid)
      AND (:'machine_filter' = '' OR vm.id = NULLIF(:'machine_filter', '')::uuid)
  ) AS has_candidates
\gset

\if :has_candidates
\else
  \o
  \echo 'ERROR: no machine_trays with an assigned product match the given --company/--machine filter'
  \quit 1
\endif

\o
-- Note on the random-pick pattern below: an earlier version used
-- `CROSS JOIN LATERAL (SELECT * FROM candidate_trays ORDER BY random() LIMIT 1)`.
-- Because that subquery has no correlation to the outer generate_series row,
-- Postgres is free to (and in testing, did) evaluate it once and reuse the
-- same single row for every generated sale. Instead, `rolls` computes one
-- independent random target row-number per output row as a plain per-row
-- SELECT expression (reliably evaluated once per row, same as
-- `SELECT random() FROM generate_series(1,5)` giving 5 different values),
-- then joins to that specific row by equality — no volatile function inside
-- the join condition itself.
WITH candidate_trays AS (
  SELECT
    row_number() OVER () AS rn,
    mt.machine_id,
    mt.item_number,
    p.sellprice
  FROM machine_trays mt
  JOIN products p ON p.id = mt.product_id
  JOIN "vendingMachine" vm ON vm.id = mt.machine_id
  WHERE mt.product_id IS NOT NULL
    AND (:'company_filter' = '' OR vm.company = NULLIF(:'company_filter', '')::uuid)
    AND (:'machine_filter' = '' OR vm.id = NULLIF(:'machine_filter', '')::uuid)
),
n_candidates AS (
  SELECT count(*) AS n FROM candidate_trays
),
rolls AS (
  SELECT (1 + floor(random() * nc.n))::int AS pick_rn
  FROM generate_series(1, :count)
  CROSS JOIN n_candidates nc
),
picked AS (
  SELECT
    c.machine_id,
    c.item_number,
    -- +/-10% price jitter so repeat sales of the same product aren't identical
    ROUND((c.sellprice * (0.9 + random() * 0.2))::numeric, 2)::float8 AS item_price,
    (ARRAY['cash', 'card', 'cashless'])[1 + floor(random() * 3)::int] AS channel,
    now() - make_interval(secs => random() * :days * 86400) AS created_at
  FROM rolls r
  JOIN candidate_trays c ON c.rn = r.pick_rn
),
inserted AS (
  INSERT INTO sales (machine_id, item_number, item_price, channel, created_at)
  SELECT machine_id, item_number, item_price, channel, created_at FROM picked
  RETURNING id
)
SELECT id FROM inserted;
\o /dev/null

COMMIT;
