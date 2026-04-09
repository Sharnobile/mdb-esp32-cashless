-- Public storefront: restock subscriptions + product wishes

-- 1. Restock notification subscriptions (public visitors subscribe to out-of-stock alerts)
create table if not exists public.restock_subscriptions (
  id          uuid not null default gen_random_uuid() primary key,
  created_at  timestamptz not null default now(),
  machine_id  uuid not null references public."vendingMachine"(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete cascade,
  email       text not null,
  notified_at timestamptz,  -- NULL = pending, set when notification is sent
  company_id  uuid not null references public.companies(id) on delete cascade,
  constraint restock_subscriptions_unique unique (machine_id, product_id, email)
);

create index if not exists idx_restock_subs_lookup
  on public.restock_subscriptions (machine_id, product_id)
  where notified_at is null;

alter table public.restock_subscriptions enable row level security;

-- Operators can view their company's subscriptions
create policy "restock_subscriptions_select" on public.restock_subscriptions
  for select to authenticated
  using (company_id = public.my_company_id());

-- Admins can delete (cleanup)
create policy "restock_subscriptions_delete" on public.restock_subscriptions
  for delete to authenticated
  using (company_id = public.my_company_id() and public.i_am_admin());


-- 2. Product wishes (public visitors request products)
create table if not exists public.product_wishes (
  id          uuid not null default gen_random_uuid() primary key,
  created_at  timestamptz not null default now(),
  machine_id  uuid not null references public."vendingMachine"(id) on delete cascade,
  company_id  uuid not null references public.companies(id) on delete cascade,
  wish_text   text not null,
  email       text,
  status      text not null default 'new' check (status in ('new', 'reviewed', 'dismissed'))
);

create index if not exists idx_product_wishes_company
  on public.product_wishes (company_id, status);

alter table public.product_wishes enable row level security;

-- Operators can view their company's wishes
create policy "product_wishes_select" on public.product_wishes
  for select to authenticated
  using (company_id = public.my_company_id());

-- Admins can update status
create policy "product_wishes_update" on public.product_wishes
  for update to authenticated
  using (company_id = public.my_company_id() and public.i_am_admin())
  with check (company_id = public.my_company_id() and public.i_am_admin());

-- Admins can delete
create policy "product_wishes_delete" on public.product_wishes
  for delete to authenticated
  using (company_id = public.my_company_id() and public.i_am_admin());
