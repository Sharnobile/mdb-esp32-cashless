-- =========================================================
-- suppressed_sales: audit of auto-dropped brownout duplicate sales
--
-- mqtt-webhook drops a sale (instead of inserting into `sales`) when it is
-- time_uncertain AND near-duplicates a recent sale on the same device/slot/
-- price/channel (brownout re-report). The dropped row is recorded here so the
-- action is transparent and reversible. Read-only in the clients.
-- Idempotent / additive.
-- =========================================================
create table if not exists public.suppressed_sales (
  id                uuid primary key default gen_random_uuid(),
  embedded_id       uuid not null references public.embeddeds(id) on delete cascade,
  item_number       integer,
  item_price        double precision,
  channel           text,
  sale_seq          bigint,
  device_created_at timestamptz,
  received_at       timestamptz not null default now(),
  matched_sale_id   uuid references public.sales(id) on delete set null,
  reason            text not null default 'time_uncertain_duplicate'
);

create index if not exists suppressed_sales_embedded_received_idx
  on public.suppressed_sales (embedded_id, received_at desc);

alter table public.suppressed_sales enable row level security;

grant select on public.suppressed_sales to authenticated;
grant select, insert, update, delete on public.suppressed_sales to service_role;

drop policy if exists suppressed_sales_select_own on public.suppressed_sales;
create policy suppressed_sales_select_own on public.suppressed_sales
  for select to authenticated
  using (
    exists (
      select 1 from public.embeddeds e
      where e.id = suppressed_sales.embedded_id
        and e.company = public.my_company_id()
    )
  );

comment on table public.suppressed_sales is
  'Audit of sales auto-dropped by mqtt-webhook as suspected brownout re-reports (time_uncertain + near-duplicate). Read-only transparency; reversible by re-inserting from this row.';
