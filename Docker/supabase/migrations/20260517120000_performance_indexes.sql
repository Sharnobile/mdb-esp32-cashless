-- =========================================================
-- Performance indexes for hot read paths
--
-- Adds indexes that close real query gaps identified by auditing every
-- Supabase query in management-frontend against the existing index set.
-- Idempotent (IF NOT EXISTS) so this migration is safe to re-run and is
-- a no-op on fresh installs once applied.
-- =========================================================

-- ---------------------------------------------------------
-- P0: indexes that are completely missing for hot queries
-- ---------------------------------------------------------

-- Dashboard fires ~7 unfiltered date-range aggregations (today, yesterday,
-- this week, last week, this month, last month, last 30 days) plus a
-- "10 most recent sales" ORDER BY. None of them carry a machine_id
-- predicate, so idx_sales_machine_id does not apply and they degrade to
-- a sequential scan as the sales table grows.
CREATE INDEX IF NOT EXISTS idx_sales_created_at
  ON public.sales (created_at DESC);

-- Per-machine date-range aggregations from useMachines.fetchMachines
-- (today/yesterday/this month/last month revenue and counts) and the
-- 30-day history on /machines/[id]. The existing idx_sales_machine_id
-- can locate the machine's rows but still has to filter by created_at
-- in memory; the composite turns it into a single range scan.
CREATE INDEX IF NOT EXISTS idx_sales_machine_created
  ON public.sales (machine_id, created_at DESC);

-- activity_log has no index at all today. The dashboard pulls the 8 most
-- recent rows on every load (RLS adds WHERE company_id = my_company_id()),
-- and /history paginates by created_at. company_id leads the composite so
-- it covers the RLS predicate as well as the ORDER BY.
CREATE INDEX IF NOT EXISTS idx_activity_log_company_created
  ON public.activity_log (company_id, created_at DESC);

-- useMachines fetches the latest paxcounter row per machine via
-- `.in('machine_id', ids).order('created_at', desc)`. paxcounter is a
-- high-write table, so the single-column idx_paxcounter_machine_id forces
-- a sort over every machine's history. Composite turns it into an index
-- range read.
CREATE INDEX IF NOT EXISTS idx_paxcounter_machine_created
  ON public.paxcounter (machine_id, created_at DESC);

-- ---------------------------------------------------------
-- P1: composites that supersede less-efficient single-column indexes
-- ---------------------------------------------------------

-- Product detail page (useProductDetail) fetches the product's recent
-- sales history and 30-day velocity series; both filter on product_id
-- and order by created_at. idx_sales_product_id covers the filter only.
CREATE INDEX IF NOT EXISTS idx_sales_product_created
  ON public.sales (product_id, created_at DESC);

-- useStockHistory and useActivityLog filter activity_log by entity_type
-- (e.g. 'stock') and sort by created_at. RLS also adds company_id, so
-- the planner can intersect with idx_activity_log_company_created when
-- both predicates are selective.
CREATE INDEX IF NOT EXISTS idx_activity_log_type_created
  ON public.activity_log (entity_type, created_at DESC);
