-- Company imprint fields (legal "Betreiberinformationen" / Impressum) +
-- machine_feedback table (customer-submitted problem reports & feedback).
--
-- Imprint data is read-only on the public storefront but editable by admins
-- in Settings. All columns are nullable — existing companies stay valid.
-- (German operators will usually need these fields populated to satisfy
-- §5 TMG Impressumspflicht.)

-- ─── 1. Company imprint columns ──────────────────────────────────────────────

alter table public.companies
  add column if not exists legal_name            text,
  add column if not exists contact_email         text,
  add column if not exists contact_phone         text,
  add column if not exists website               text,
  add column if not exists address_street        text,
  add column if not exists address_house_number  text,
  add column if not exists address_postal_code   text,
  add column if not exists address_city          text;

comment on column public.companies.legal_name           is 'Full legal entity name (e.g. "Acme GmbH") shown on Impressum';
comment on column public.companies.contact_email        is 'Customer-facing support email shown on Impressum and customer feedback';
comment on column public.companies.contact_phone        is 'Customer-facing phone number shown on Impressum';
comment on column public.companies.website              is 'Company website URL';
comment on column public.companies.address_street       is 'Imprint street name';
comment on column public.companies.address_house_number is 'Imprint street house number';
comment on column public.companies.address_postal_code  is 'Imprint postal code';
comment on column public.companies.address_city         is 'Imprint city';


-- ─── 2. machine_feedback (customer problem reports + general feedback) ──────

create table if not exists public.machine_feedback (
  id          uuid not null default gen_random_uuid() primary key,
  created_at  timestamptz not null default now(),
  machine_id  uuid not null references public."vendingMachine"(id) on delete cascade,
  company_id  uuid not null references public.companies(id) on delete cascade,
  type        text not null check (type in ('problem', 'feedback')),
  message     text not null,
  email       text,
  status      text not null default 'new' check (status in ('new', 'reviewed', 'dismissed'))
);

create index if not exists idx_machine_feedback_company
  on public.machine_feedback (company_id, status, created_at desc);

create index if not exists idx_machine_feedback_machine
  on public.machine_feedback (machine_id, created_at desc);

alter table public.machine_feedback enable row level security;

-- Operators can view their company's feedback
create policy "machine_feedback_select" on public.machine_feedback
  for select to authenticated
  using (company_id = public.my_company_id());

-- Admins can update status (review / dismiss)
create policy "machine_feedback_update" on public.machine_feedback
  for update to authenticated
  using (company_id = public.my_company_id() and public.i_am_admin())
  with check (company_id = public.my_company_id() and public.i_am_admin());

-- Admins can delete
create policy "machine_feedback_delete" on public.machine_feedback
  for delete to authenticated
  using (company_id = public.my_company_id() and public.i_am_admin());

-- Inserts come from the public submit-machine-feedback edge function using the
-- service role key (bypasses RLS). No INSERT policy needed for anon/auth.

grant select, update, delete on public.machine_feedback to authenticated;
grant select, insert, update, delete on public.machine_feedback to service_role;
