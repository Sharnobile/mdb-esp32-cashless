-- =========================================================
-- Initial schema
-- Creates all base tables that predate the migration system.
-- All subsequent migrations assume these tables already exist.
-- =========================================================

-- companies
create table if not exists public.companies (
  id         uuid not null default gen_random_uuid(),
  created_at timestamp with time zone not null default now(),
  name       text not null,
  constraint companies_pkey primary key (id)
);

alter table public.companies enable row level security;

grant select, insert on public.companies to authenticated;
grant select, insert, update, delete on public.companies to service_role;

-- users (public profile; populated by on_auth_user_created trigger)
create table if not exists public.users (
  id         uuid not null references auth.users(id) on delete cascade,
  created_at timestamp with time zone not null default now(),
  company    uuid references public.companies(id),
  constraint users_pkey primary key (id)
);

alter table public.users enable row level security;

grant select, update on public.users to authenticated;
grant select, insert, update, delete on public.users to service_role;

-- embeddeds (IoT devices)
create table if not exists public.embeddeds (
  id          uuid not null default gen_random_uuid(),
  created_at  timestamp with time zone not null default now(),
  owner_id    uuid references auth.users(id),
  mac_address text,
  status      text,
  status_at   timestamp with time zone,
  passkey     text,
  company     uuid references public.companies(id),
  subdomain   bigserial not null,
  constraint embeddeds_pkey primary key (id)
);

alter table public.embeddeds enable row level security;

grant select on public.embeddeds to authenticated;
grant select, insert, update, delete on public.embeddeds to service_role;

-- sales
create table if not exists public.sales (
  id          uuid not null default gen_random_uuid(),
  created_at  timestamp with time zone not null default now(),
  owner_id    uuid references auth.users(id),
  embedded_id uuid references public.embeddeds(id) on delete cascade,
  item_price  float8,
  item_number integer,
  channel     text,
  lat         float8,
  lng         float8,
  constraint sales_pkey primary key (id)
);

alter table public.sales enable row level security;

grant select on public.sales to authenticated;
grant select, insert, update, delete on public.sales to service_role;

-- vendingMachine
create table if not exists public."vendingMachine" (
  id         uuid not null default gen_random_uuid(),
  created_at timestamp with time zone not null default now(),
  name         text,
  company      uuid references public.companies(id),
  embedded     uuid references public.embeddeds(id),
  location_lat float8,
  location_lon float8,
  constraint "vendingMachine_pkey" primary key (id)
);

alter table public."vendingMachine" enable row level security;

grant select, insert, update, delete on public."vendingMachine" to authenticated;
grant select, insert, update, delete on public."vendingMachine" to service_role;

-- product_category
create table if not exists public.product_category (
  id         uuid not null default gen_random_uuid(),
  created_at timestamp with time zone not null default now(),
  name       text,
  company    uuid references public.companies(id),
  constraint product_category_pkey primary key (id)
);

alter table public.product_category enable row level security;

grant select, insert, update, delete on public.product_category to authenticated;
grant select, insert, update, delete on public.product_category to service_role;

-- products
-- Note: the wrong FK constraint products_id_fkey (id → product_category.id) was
-- present in the original schema and is dropped in 20260228000000_multitenancy.sql.
-- We intentionally do NOT create it here; the IF EXISTS drop is a safe no-op.
create table if not exists public.products (
  id         uuid not null default gen_random_uuid(),
  created_at timestamp with time zone not null default now(),
  name        text,
  sellprice   float8,
  description text,
  company     uuid references public.companies(id),
  category    uuid,
  constraint products_pkey primary key (id)
);

alter table public.products enable row level security;

grant select, insert, update, delete on public.products to authenticated;
grant select, insert, update, delete on public.products to service_role;
