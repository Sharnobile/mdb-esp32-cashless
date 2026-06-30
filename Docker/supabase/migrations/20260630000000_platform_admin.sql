-- ============================================================================
-- Internal platform-admin dashboard.
-- Adds a cross-company operator allow-list + self-guarding SECURITY DEFINER
-- aggregation RPCs. Fully additive: no existing table/policy/RPC is modified.
-- ============================================================================

-- 1. Allow-list table -------------------------------------------------------
create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.platform_admins enable row level security;
-- No policies on purpose: the table is only ever read via is_platform_admin()
-- (SECURITY DEFINER, runs as owner and bypasses RLS). Normal authenticated
-- users cannot select it. service_role keeps full access for admin scripts.
grant select, insert, delete on public.platform_admins to service_role;

-- 2. Membership helper ------------------------------------------------------
create or replace function public.is_platform_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.platform_admins where user_id = auth.uid()
  );
$$;

grant execute on function public.is_platform_admin() to authenticated, service_role;

-- 3. Cross-company overview -------------------------------------------------
-- p_days drives the configurable "window" bucket (default 30); today and 7d
-- buckets are fixed.
create or replace function public.get_platform_overview(p_days int default 30)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result json;
  v_window_start timestamptz := now() - (p_days || ' days')::interval;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  with member_agg as (
    select company_id,
           count(*)                                  as user_count,
           count(*) filter (where role = 'admin')    as admin_count,
           count(*) filter (where role = 'viewer')   as viewer_count
    from public.organization_members
    group by company_id
  ),
  device_agg as (
    select company as company_id,
           count(*)                                                              as device_count,
           count(*) filter (where status is not null and status <> 'offline')    as devices_online,
           max(status_at)                                                        as last_device_seen_at
    from public.embeddeds
    where company is not null
    group by company
  ),
  machine_agg as (
    select company as company_id, count(*) as machine_count
    from public."vendingMachine"
    where company is not null
    group by company
  ),
  sales_agg as (
    select e.company as company_id,
           count(*) filter (where s.created_at >= date_trunc('day', now()))                      as sales_today_count,
           coalesce(sum(s.item_price) filter (where s.created_at >= date_trunc('day', now())), 0) as sales_today_revenue,
           count(*) filter (where s.created_at >= now() - interval '7 days')                      as sales_7d_count,
           coalesce(sum(s.item_price) filter (where s.created_at >= now() - interval '7 days'), 0) as sales_7d_revenue,
           count(*) filter (where s.created_at >= v_window_start)                                 as sales_window_count,
           coalesce(sum(s.item_price) filter (where s.created_at >= v_window_start), 0)           as sales_window_revenue,
           max(s.created_at)                                                                       as last_sale_at
    from public.sales s
    join public.embeddeds e on e.id = s.embedded_id
    where e.company is not null
    group by e.company
  ),
  companies_json as (
    select json_agg(row_to_json(c_row) order by lower(c_row.name)) as arr
    from (
      select
        c.id                                  as company_id,
        c.name,
        coalesce(m.user_count, 0)             as user_count,
        coalesce(m.admin_count, 0)            as admin_count,
        coalesce(m.viewer_count, 0)           as viewer_count,
        coalesce(mc.machine_count, 0)         as machine_count,
        coalesce(d.device_count, 0)           as device_count,
        coalesce(d.devices_online, 0)         as devices_online,
        coalesce(sa.sales_today_count, 0)     as sales_today_count,
        coalesce(sa.sales_today_revenue, 0)   as sales_today_revenue,
        coalesce(sa.sales_7d_count, 0)        as sales_7d_count,
        coalesce(sa.sales_7d_revenue, 0)      as sales_7d_revenue,
        coalesce(sa.sales_window_count, 0)    as sales_window_count,
        coalesce(sa.sales_window_revenue, 0)  as sales_window_revenue,
        sa.last_sale_at,
        d.last_device_seen_at
      from public.companies c
      left join member_agg  m  on m.company_id  = c.id
      left join device_agg  d  on d.company_id  = c.id
      left join machine_agg mc on mc.company_id = c.id
      left join sales_agg   sa on sa.company_id = c.id
    ) c_row
  )
  select json_build_object(
    'window_days', p_days,
    'totals', json_build_object(
      'company_count',  (select count(*) from public.companies),
      'user_count',     (select count(distinct user_id) from public.organization_members),
      'machine_count',  (select count(*) from public."vendingMachine"),
      'device_count',   (select count(*) from public.embeddeds),
      'devices_online', (select count(*) from public.embeddeds
                          where status is not null and status <> 'offline')
    ),
    'companies', coalesce((select arr from companies_json), '[]'::json)
  ) into v_result;

  return v_result;
end;
$$;

grant execute on function public.get_platform_overview(int) to authenticated, service_role;

-- 4. Per-company drill-down -------------------------------------------------
create or replace function public.get_platform_company_detail(p_company_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result json;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select json_build_object(
    'company', (
      select json_build_object('id', c.id, 'name', c.name, 'created_at', c.created_at)
      from public.companies c where c.id = p_company_id
    ),
    'members', coalesce((
      select json_agg(json_build_object(
        'user_id',  om.user_id,
        'email',    coalesce(pu.email, au.email),
        'role',     om.role,
        'joined_at', om.created_at
      ) order by om.created_at)
      from public.organization_members om
      left join public.users pu on pu.id = om.user_id
      left join auth.users  au on au.id = om.user_id
      where om.company_id = p_company_id
    ), '[]'::json),
    'devices', coalesce((
      select json_agg(json_build_object(
        'embedded_id',      e.id,
        'subdomain',        e.subdomain,
        'mac_address',      e.mac_address,
        'status',           e.status,
        'status_at',        e.status_at,
        'online_since',     e.online_since,
        'firmware_version', e.firmware_version,
        'machine_name',     vm.name
      ) order by e.subdomain)
      from public.embeddeds e
      left join public."vendingMachine" vm on vm.embedded = e.id
      where e.company = p_company_id
    ), '[]'::json),
    'recent_sales', coalesce((
      select json_agg(rs)
      from (
        select s.created_at, s.item_price, s.item_number, s.channel, vm.name as machine_name
        from public.sales s
        join public.embeddeds e on e.id = s.embedded_id
        left join public."vendingMachine" vm on vm.id = s.machine_id
        where e.company = p_company_id
        order by s.created_at desc
        limit 50
      ) rs
    ), '[]'::json)
  ) into v_result;

  return v_result;
end;
$$;

grant execute on function public.get_platform_company_detail(uuid) to authenticated, service_role;

-- 5. Bootstrap seed (idempotent; no-op where the email doesn't exist) --------
insert into public.platform_admins (user_id)
select id from auth.users
where email = 'lucien@kerl-handel.de'
on conflict (user_id) do nothing;
