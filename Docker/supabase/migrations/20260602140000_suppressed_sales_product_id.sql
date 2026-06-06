-- =========================================================
-- suppressed_sales.product_id: immutable product snapshot
--
-- The product that was in the slot at suppression time, copied from the
-- matched sale's own immutable product_id snapshot. Independent of later
-- tray reassignment. Additive/idempotent.
-- =========================================================
alter table public.suppressed_sales
  add column if not exists product_id uuid references public.products(id) on delete set null;

create index if not exists suppressed_sales_product_id_idx
  on public.suppressed_sales (product_id);

-- Backfill existing rows from their matched sale's product snapshot.
update public.suppressed_sales s
set product_id = sa.product_id
from public.sales sa
where sa.id = s.matched_sale_id
  and s.product_id is null
  and sa.product_id is not null;

comment on column public.suppressed_sales.product_id is
  'Immutable snapshot of the product sold, copied from the matched sale at suppression time. Independent of later tray reassignment.';
