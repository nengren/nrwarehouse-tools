-- =====================================================================
-- 仓库工具 v2 初始化（上线当天运行一次）
-- 在 Supabase → SQL Editor 里整段粘贴运行。可重复运行，不会删任何旧数据。
--
-- 做了什么：
--   1. 新建：账号表、设置、发货员别名、SKU归类、订单、订单明细
--   2. 给所有 wh_ 表开权限规则：只有"已登录且在账号名单里"的人能读写
--      ⚠ 运行后旧版仓库工具立刻无法使用（旧版不登录直接读写）
--   3. 旧表 wh_employees / wh_product_lines / wh_skus / wh_records 一律保留
--      wh_records（旧产量）改为只读
--   4. 切换日 = 运行这段 SQL 的当天（菲律宾时间），之后可在管理页修改
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 新表 ----------
create table if not exists public.wh_accounts (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  username   text not null unique,
  role       text not null default 'staff' check (role in ('admin','staff')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.wh_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- 马帮里的发货员写法（小写）→ 员工
create table if not exists public.wh_packer_alias (
  alias       text primary key,
  employee_id uuid not null references public.wh_employees(id) on delete cascade,
  created_at  timestamptz not null default now()
);

-- SKU 手动归类（覆盖默认规则）
create table if not exists public.wh_sku_class (
  sku        text primary key,          -- 大写
  category   text not null check (category in ('dumbbell','other')),
  updated_at timestamptz not null default now()
);

create table if not exists public.wh_orders (
  order_no         text primary key,    -- 平台交易号
  track_no         text,
  ship_time        timestamp,           -- 马帮发货时间（本地时间）
  ship_date        date not null,
  packer_raw       text,                -- 马帮原始发货员名字
  employee_id      uuid references public.wh_employees(id) on delete set null,
  actual_weight    integer not null default 0,   -- 实称(g)
  theory_weight    integer not null default 0,   -- Σ 数量×单重
  total_qty        integer not null default 0,
  dumbbell_qty     integer not null default 0,
  other_qty        integer not null default 0,
  has_missing_unit boolean not null default false, -- 有 SKU 单重 ≤1g
  imported_at      timestamptz not null default now(),
  imported_by      uuid default auth.uid()
);
create index if not exists wh_orders_date_idx on public.wh_orders(ship_date);
create index if not exists wh_orders_emp_date_idx on public.wh_orders(employee_id, ship_date);
create index if not exists wh_orders_packer_idx on public.wh_orders(lower(btrim(packer_raw)));

create table if not exists public.wh_order_items (
  id          bigserial primary key,
  order_no    text not null references public.wh_orders(order_no) on delete cascade,
  sku         text not null,
  qty         integer not null,
  unit_weight integer not null default 0,
  is_dumbbell boolean not null default false
);
create index if not exists wh_order_items_order_idx on public.wh_order_items(order_no);
create index if not exists wh_order_items_sku_idx on public.wh_order_items(upper(sku));

-- ---------- 默认设置 ----------
insert into public.wh_settings(key, value) values
  ('cutover_date', to_jsonb(to_char((now() at time zone 'Asia/Manila')::date, 'YYYY-MM-DD'))),
  ('tol_pct', '10'::jsonb),
  ('tol_g',   '50'::jsonb)
on conflict (key) do nothing;

-- ---------- 身份判断 ----------
create or replace function public.wh_is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from wh_accounts where user_id = auth.uid() and active);
$$;

create or replace function public.wh_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from wh_accounts where user_id = auth.uid() and active and role = 'admin');
$$;

-- ---------- 哑铃规则：FS-/HL- 开头 且 单重 ≥2000g；手动归类优先 ----------
create or replace function public.wh_rule_dumbbell(p_sku text, p_unit integer) returns boolean
language sql immutable as $$
  select (upper(btrim(p_sku)) like 'FS-%' or upper(btrim(p_sku)) like 'HL-%') and coalesce(p_unit,0) >= 2000;
$$;

create or replace function public.wh_classify(p_sku text, p_unit integer) returns boolean
language sql stable set search_path = public as $$
  select coalesce(
    (select category = 'dumbbell' from wh_sku_class where sku = upper(btrim(p_sku))),
    wh_rule_dumbbell(p_sku, p_unit));
$$;

-- 重算订单汇总字段
create or replace function public.wh_recalc_orders(p_orders text[]) returns void
language sql set search_path = public as $$
  update wh_orders w set
    theory_weight    = s.tw,
    total_qty        = s.tq,
    dumbbell_qty     = s.dq,
    other_qty        = s.oq,
    has_missing_unit = s.miss
  from (
    select order_no,
           coalesce(sum(qty * unit_weight),0)::int                 as tw,
           coalesce(sum(qty),0)::int                               as tq,
           coalesce(sum(qty) filter (where is_dumbbell),0)::int    as dq,
           coalesce(sum(qty) filter (where not is_dumbbell),0)::int as oq,
           coalesce(bool_or(unit_weight <= 1), false)               as miss
    from wh_order_items where order_no = any(p_orders) group by order_no
  ) s
  where w.order_no = s.order_no;
$$;

-- ---------- 导入：同一平台交易号覆盖，不重复计数 ----------
-- p = [{order_no, track_no, ship_time:'YYYY-MM-DD HH:MM:SS', packer_raw, employee_id, actual_weight,
--       items:[{sku, qty, unit_weight}]}]
create or replace function public.wh_import_orders(p jsonb) returns integer
language plpgsql set search_path = public as $$
declare
  nos text[];
begin
  if not wh_is_member() then raise exception '没有权限 not allowed'; end if;

  insert into wh_orders(order_no, track_no, ship_time, ship_date, packer_raw, employee_id,
                        actual_weight, imported_at, imported_by)
  select o->>'order_no',
         nullif(o->>'track_no',''),
         (o->>'ship_time')::timestamp,
         ((o->>'ship_time')::timestamp)::date,
         o->>'packer_raw',
         nullif(o->>'employee_id','')::uuid,
         coalesce(round((o->>'actual_weight')::numeric),0)::int,
         now(), auth.uid()
  from jsonb_array_elements(p) o
  on conflict (order_no) do update set
    track_no      = excluded.track_no,
    ship_time     = excluded.ship_time,
    ship_date     = excluded.ship_date,
    packer_raw    = excluded.packer_raw,
    employee_id   = excluded.employee_id,
    actual_weight = excluded.actual_weight,
    imported_at   = excluded.imported_at,
    imported_by   = excluded.imported_by;

  select array_agg(o->>'order_no') into nos from jsonb_array_elements(p) o;

  delete from wh_order_items where order_no = any(nos);

  insert into wh_order_items(order_no, sku, qty, unit_weight, is_dumbbell)
  select o->>'order_no',
         btrim(i->>'sku'),
         coalesce(round((i->>'qty')::numeric),0)::int,
         coalesce(round((i->>'unit_weight')::numeric),0)::int,
         wh_classify(i->>'sku', coalesce(round((i->>'unit_weight')::numeric),0)::int)
  from jsonb_array_elements(p) o, jsonb_array_elements(o->'items') i;

  perform wh_recalc_orders(nos);
  return coalesce(array_length(nos,1),0);
end $$;

create or replace function public.wh_existing_orders(p text[]) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(order_no), '[]'::jsonb) from wh_orders where order_no = any(p);
$$;

-- ---------- 产量汇总（返回单个 jsonb，不受 1000 行上限影响） ----------
-- 切换日之前读旧表 wh_records（旧数据全部算哑铃），切换日起读订单
create or replace function public.wh_output(p_from date, p_to date) returns jsonb
language sql stable set search_path = public as $$
  with cut as (
    select coalesce((select (value #>> '{}')::date from wh_settings where key = 'cutover_date'),
                    '9999-12-31'::date) as d
  ),
  n as (
    select o.ship_date as day, o.employee_id as emp,
           sum(o.dumbbell_qty)::bigint as db, sum(o.other_qty)::bigint as ot, count(*)::bigint as orders
    from wh_orders o, cut
    where o.ship_date between greatest(p_from, cut.d) and p_to and o.employee_id is not null
    group by 1, 2
  ),
  old as (
    select r.record_date as day, r.employee_id as emp,
           sum(r.quantity)::bigint as db, 0::bigint as ot, null::bigint as orders
    from wh_records r, cut
    where r.record_date between p_from and least(p_to, cut.d - 1)
    group by 1, 2
  )
  select coalesce(jsonb_agg(jsonb_build_object('d', day, 'e', emp, 'db', db, 'ot', ot, 'o', orders)), '[]'::jsonb)
  from (select * from n union all select * from old) x;
$$;

-- 某人某段时间按 SKU 明细；p_cat: dumbbell / other / all
create or replace function public.wh_output_detail(p_emp uuid, p_from date, p_to date, p_cat text)
returns jsonb language sql stable set search_path = public as $$
  with cut as (
    select coalesce((select (value #>> '{}')::date from wh_settings where key = 'cutover_date'),
                    '9999-12-31'::date) as d
  ),
  n as (
    select upper(i.sku) as sku, sum(i.qty)::bigint as q
    from wh_order_items i join wh_orders o on o.order_no = i.order_no, cut
    where o.employee_id = p_emp
      and o.ship_date between greatest(p_from, cut.d) and p_to
      and (p_cat = 'all' or (p_cat = 'dumbbell') = i.is_dumbbell)
    group by 1
  ),
  old as (
    select upper(s.code) as sku, sum(r.quantity)::bigint as q
    from wh_records r join wh_skus s on s.id = r.sku_id, cut
    where r.employee_id = p_emp
      and r.record_date between p_from and least(p_to, cut.d - 1)
      and p_cat in ('all', 'dumbbell')
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_array(sku, q) order by q desc, sku), '[]'::jsonb)
  from (select sku, sum(q) as q from (select * from n union all select * from old) u group by sku) t;
$$;

-- ---------- 称重校验数据 ----------
create or replace function public.wh_weight_orders(p_from date, p_to date, p_emp uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'no', o.order_no, 'tr', o.track_no, 't', o.ship_time, 'e', o.employee_id, 'pr', o.packer_raw,
           'aw', o.actual_weight, 'tw', o.theory_weight, 'q', o.total_qty, 'm', o.has_missing_unit,
           'it', (select jsonb_agg(jsonb_build_array(i.sku, i.qty, i.unit_weight) order by i.id)
                  from wh_order_items i where i.order_no = o.order_no)
         ) order by o.ship_time desc), '[]'::jsonb)
  from wh_orders o
  where o.ship_date between p_from and p_to and (p_emp is null or o.employee_id = p_emp);
$$;

-- 单重校准建议：只看单 SKU 订单，实称÷数量 的中位数（含包材）与马帮单重差得多的
create or replace function public.wh_sku_calibration(p_from date, p_to date)
returns jsonb language sql stable set search_path = public as $$
  with single as (
    select o.order_no from wh_orders o
    join wh_order_items i on i.order_no = o.order_no
    where o.ship_date between p_from and p_to and o.actual_weight > 0
    group by o.order_no having count(*) = 1
  ),
  s as (
    select upper(i.sku) as sku, i.unit_weight, o.actual_weight::numeric / nullif(i.qty,0) as per_unit
    from single x
    join wh_orders o on o.order_no = x.order_no
    join wh_order_items i on i.order_no = x.order_no
    where not (i.unit_weight <= 1 and o.actual_weight = o.total_qty)   -- 排除秤未捕获
  ),
  g as (
    select sku, max(unit_weight) as cur, count(*) as n,
           round(percentile_cont(0.5) within group (order by per_unit))::int as med
    from s where per_unit is not null group by sku having count(*) >= 3
  )
  select coalesce(jsonb_agg(jsonb_build_object('sku', sku, 'cur', cur, 'n', n, 'med', med)
                  order by abs(med - cur) desc), '[]'::jsonb)
  from g
  where cur <= 1 or abs(med - cur) > greatest(cur * 0.10, 50);
$$;

-- ---------- SKU 归类 ----------
create or replace function public.wh_sku_list(p_days integer default 90)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('sku', t.sku, 'uw', t.uw, 'n', t.n, 'db', t.db, 'ov', c.category)
                  order by t.n desc), '[]'::jsonb)
  from (
    select upper(i.sku) as sku, max(i.unit_weight) as uw, sum(i.qty) as n, bool_or(i.is_dumbbell) as db
    from wh_order_items i join wh_orders o on o.order_no = i.order_no
    where o.ship_date >= current_date - p_days
    group by 1
  ) t left join wh_sku_class c on c.sku = t.sku;
$$;

-- p_cat = 'dumbbell' / 'other' / null(恢复默认规则)；同时更新历史订单
create or replace function public.wh_set_sku_class(p_sku text, p_cat text) returns void
language plpgsql set search_path = public as $$
declare k text := upper(btrim(p_sku)); nos text[];
begin
  if not wh_is_member() then raise exception '没有权限 not allowed'; end if;
  if p_cat is null then
    delete from wh_sku_class where sku = k;
  else
    insert into wh_sku_class(sku, category, updated_at) values (k, p_cat, now())
    on conflict (sku) do update set category = excluded.category, updated_at = now();
  end if;
  update wh_order_items set is_dumbbell = wh_classify(sku, unit_weight) where upper(sku) = k;
  select array_agg(distinct order_no) into nos from wh_order_items where upper(sku) = k;
  if nos is not null then perform wh_recalc_orders(nos); end if;
end $$;

-- ---------- 别名：改指向时同时更新历史订单 ----------
create or replace function public.wh_set_alias(p_alias text, p_emp uuid) returns integer
language plpgsql set search_path = public as $$
declare k text := lower(btrim(p_alias)); n integer;
begin
  if not wh_is_member() then raise exception '没有权限 not allowed'; end if;
  insert into wh_packer_alias(alias, employee_id) values (k, p_emp)
  on conflict (alias) do update set employee_id = excluded.employee_id;
  update wh_orders set employee_id = p_emp where lower(btrim(packer_raw)) = k;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- 账号管理（仅管理员） ----------
create or replace function public.wh_admin_add_account(p_user uuid, p_username text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not wh_is_admin() then raise exception '仅管理员 admin only'; end if;
  insert into wh_accounts(user_id, username, role) values (p_user, lower(btrim(p_username)), coalesce(p_role,'staff'));
end $$;

create or replace function public.wh_admin_update_account(p_user uuid, p_role text, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not wh_is_admin() then raise exception '仅管理员 admin only'; end if;
  if p_user = auth.uid() and (p_role <> 'admin' or not p_active) then
    raise exception '不能停用或降级自己 cannot demote yourself';
  end if;
  update wh_accounts set role = p_role, active = p_active where user_id = p_user;
end $$;

create or replace function public.wh_admin_set_password(p_user uuid, p_pw text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not wh_is_admin() then raise exception '仅管理员 admin only'; end if;
  if length(coalesce(p_pw,'')) < 6 then raise exception '密码至少6位 min 6 chars'; end if;
  if not exists(select 1 from wh_accounts where user_id = p_user) then raise exception 'not a warehouse account'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_pw, extensions.gen_salt('bf')), updated_at = now()
  where id = p_user;
end $$;

-- ---------- 权限规则 ----------
do $$
declare t text; p record;
begin
  foreach t in array array['wh_employees','wh_product_lines','wh_skus','wh_records',
                           'wh_accounts','wh_settings','wh_packer_alias','wh_sku_class',
                           'wh_orders','wh_order_items'] loop
    execute format('alter table public.%I enable row level security', t);
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- 旧表：员工名单可读写（导入时会新增员工）；其余旧表只读
create policy wh_employees_rw on public.wh_employees for all to authenticated
  using (wh_is_member()) with check (wh_is_member());
create policy wh_product_lines_r on public.wh_product_lines for select to authenticated using (wh_is_member());
create policy wh_skus_r on public.wh_skus for select to authenticated using (wh_is_member());
create policy wh_records_r on public.wh_records for select to authenticated using (wh_is_member());

-- 新表
create policy wh_accounts_r on public.wh_accounts for select to authenticated
  using (user_id = auth.uid() or wh_is_admin());
create policy wh_settings_r on public.wh_settings for select to authenticated using (wh_is_member());
create policy wh_settings_w on public.wh_settings for all to authenticated
  using (wh_is_admin()) with check (wh_is_admin());
create policy wh_packer_alias_rw on public.wh_packer_alias for all to authenticated
  using (wh_is_member()) with check (wh_is_member());
create policy wh_sku_class_rw on public.wh_sku_class for all to authenticated
  using (wh_is_member()) with check (wh_is_member());
create policy wh_orders_rw on public.wh_orders for all to authenticated
  using (wh_is_member()) with check (wh_is_member());
create policy wh_order_items_rw on public.wh_order_items for all to authenticated
  using (wh_is_member()) with check (wh_is_member());

grant select, insert, update, delete on public.wh_employees, public.wh_settings, public.wh_packer_alias,
  public.wh_sku_class, public.wh_orders, public.wh_order_items to authenticated;
grant select on public.wh_product_lines, public.wh_skus, public.wh_records, public.wh_accounts to authenticated;
grant usage, select on sequence public.wh_order_items_id_seq to authenticated;

-- 函数只给登录用户
do $$
declare f text;
begin
  foreach f in array array[
    'wh_is_member()','wh_is_admin()','wh_rule_dumbbell(text,integer)','wh_classify(text,integer)',
    'wh_recalc_orders(text[])','wh_import_orders(jsonb)','wh_existing_orders(text[])',
    'wh_output(date,date)','wh_output_detail(uuid,date,date,text)','wh_weight_orders(date,date,uuid)',
    'wh_sku_calibration(date,date)','wh_sku_list(integer)','wh_set_sku_class(text,text)',
    'wh_set_alias(text,uuid)','wh_admin_add_account(uuid,text,text)',
    'wh_admin_update_account(uuid,text,boolean)','wh_admin_set_password(uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
