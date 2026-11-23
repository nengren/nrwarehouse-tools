-- =====================================================================
-- 按包裹（快递单号）记录订单 + 称重"已核查"记录
-- 在 Supabase → SQL Editor 运行一次，可重复运行
--
-- 为什么：大单拆成几个包裹发时，平台交易号相同、快递单号不同、每包各称一次重。
--   以前按平台交易号合并成一单 → 理论重量是几包之和、实称只有一包 → 误报异常，产量也记错人。
--   现在每个包裹（快递单号）单独一行；没有快递单号的才用平台交易号。
--
-- 旧数据：已有记录自动把主键换成快递单号（不拆单的订单完全不受影响）。
--   上线以来被合并错的拆单，请把 11/21 起每天的马帮表重新导入一次即可修正。
-- =====================================================================

-- ---------- 1. 订单表加平台交易号、核查字段 ----------
alter table public.wh_orders add column if not exists platform_no text;
alter table public.wh_orders add column if not exists checked_at timestamptz;
alter table public.wh_orders add column if not exists checked_by text;
update public.wh_orders set platform_no = order_no where platform_no is null;
create index if not exists wh_orders_platform_idx on public.wh_orders(platform_no);

-- ---------- 2. 明细外键改为跟随主键更新 ----------
do $$
declare c text;
begin
  select conname into c from pg_constraint
  where conrelid = 'public.wh_order_items'::regclass and contype = 'f'
    and confrelid = 'public.wh_orders'::regclass;
  if c is not null then execute format('alter table public.wh_order_items drop constraint %I', c); end if;
  alter table public.wh_order_items add constraint wh_order_items_order_no_fkey
    foreign key (order_no) references public.wh_orders(order_no) on update cascade on delete cascade;
end $$;

-- ---------- 3. 旧数据：主键换成快递单号 ----------
update public.wh_orders o set order_no = o.track_no
where coalesce(o.track_no, '') <> '' and o.order_no <> o.track_no
  and not exists (select 1 from public.wh_orders x where x.order_no = o.track_no)
  and (select count(*) from public.wh_orders y where y.track_no = o.track_no) = 1;

-- ---------- 4. 核查记录（只追加，不能改删） ----------
create table if not exists public.wh_check_log (
  id          bigserial primary key,
  order_no    text not null,        -- 包裹键（快递单号）
  platform_no text,
  action      text not null check (action in ('check','uncheck')),
  note        text,
  actual_weight integer,
  theory_weight integer,
  username    text not null,
  user_id     uuid default auth.uid(),
  at          timestamptz not null default now()
);
create index if not exists wh_check_log_order_idx on public.wh_check_log(order_no);
create index if not exists wh_check_log_at_idx on public.wh_check_log(at);

alter table public.wh_check_log enable row level security;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='wh_check_log' loop
    execute format('drop policy %I on public.wh_check_log', p.policyname);
  end loop;
end $$;
create policy wh_check_log_r on public.wh_check_log for select to authenticated using (wh_is_member());
revoke all on public.wh_check_log from anon, authenticated;
grant select on public.wh_check_log to authenticated;

-- ---------- 5. 导入：按包裹键 ----------
-- p = [{order_no(包裹键), platform_no, track_no, ship_time, packer_raw, employee_id, actual_weight, items:[...]}]
create or replace function public.wh_import_orders(p jsonb) returns integer
language plpgsql set search_path = public as $$
declare
  nos text[];
begin
  if not wh_is_member() then raise exception '没有权限 not allowed'; end if;

  select array_agg(o->>'order_no') into nos from jsonb_array_elements(p) o;

  -- 以前没有快递单号、按平台交易号存的旧记录，现在有了包裹键 → 删掉旧的，避免重复
  delete from wh_orders w
  where w.order_no in (select o->>'platform_no' from jsonb_array_elements(p) o where coalesce(o->>'platform_no','') <> '')
    and not (w.order_no = any(nos));

  insert into wh_orders(order_no, platform_no, track_no, ship_time, ship_date, packer_raw, employee_id,
                        actual_weight, imported_at, imported_by)
  select o->>'order_no',
         nullif(o->>'platform_no',''),
         nullif(o->>'track_no',''),
         (o->>'ship_time')::timestamp,
         ((o->>'ship_time')::timestamp)::date,
         o->>'packer_raw',
         nullif(o->>'employee_id','')::uuid,
         coalesce(round((o->>'actual_weight')::numeric),0)::int,
         now(), auth.uid()
  from jsonb_array_elements(p) o
  on conflict (order_no) do update set
    platform_no   = excluded.platform_no,
    track_no      = excluded.track_no,
    ship_time     = excluded.ship_time,
    ship_date     = excluded.ship_date,
    packer_raw    = excluded.packer_raw,
    employee_id   = excluded.employee_id,
    actual_weight = excluded.actual_weight,
    imported_at   = excluded.imported_at,
    imported_by   = excluded.imported_by;   -- 核查状态保留，不被重新导入清掉

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

-- ---------- 6. 称重校验数据：带平台单号、拆单序号、核查人 ----------
create or replace function public.wh_weight_orders(p_from date, p_to date, p_emp uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'no', o.order_no, 'pn', coalesce(o.platform_no, o.order_no), 'tr', o.track_no,
           't', o.ship_time, 'e', o.employee_id, 'pr', o.packer_raw,
           'aw', o.actual_weight, 'tw', o.theory_weight, 'q', o.total_qty, 'm', o.has_missing_unit,
           'ck', o.checked_by, 'ca', o.checked_at,
           'ps', (select count(*) from wh_orders x where x.platform_no = o.platform_no),
           'pi', (select count(*) from wh_orders x where x.platform_no = o.platform_no
                    and (x.ship_time, x.order_no) <= (o.ship_time, o.order_no)),
           'it', (select jsonb_agg(jsonb_build_array(i.sku, i.qty, i.unit_weight) order by i.id)
                  from wh_order_items i where i.order_no = o.order_no)
         ) order by o.ship_time desc), '[]'::jsonb)
  from wh_orders o
  where o.ship_date between p_from and p_to and (p_emp is null or o.employee_id = p_emp);
$$;

-- ---------- 7. 已核查 / 取消核查（同时写记录） ----------
create or replace function public.wh_set_checked(p_order text, p_checked boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u text; o record;
begin
  select username into u from wh_accounts where user_id = auth.uid() and active;
  if u is null then raise exception '没有权限 not allowed'; end if;
  select * into o from wh_orders where order_no = p_order;
  if not found then raise exception '找不到这个包裹 order not found'; end if;
  update wh_orders set checked_at = case when p_checked then now() end,
                       checked_by = case when p_checked then u end
  where order_no = p_order;
  insert into wh_check_log(order_no, platform_no, action, note, actual_weight, theory_weight, username, user_id)
  values (p_order, o.platform_no, case when p_checked then 'check' else 'uncheck' end,
          nullif(btrim(coalesce(p_note,'')),''), o.actual_weight, o.theory_weight, u, auth.uid());
  return jsonb_build_object('ck', case when p_checked then u end, 'ca', case when p_checked then now() end);
end $$;

-- 核查记录：按包裹发货日期范围
create or replace function public.wh_check_log_list(p_from date, p_to date)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', l.at, 'u', l.username, 'a', l.action, 'no', l.order_no, 'pn', l.platform_no,
           'aw', l.actual_weight, 'tw', l.theory_weight, 'note', l.note) order by l.at desc), '[]'::jsonb)
  from wh_check_log l
  where wh_is_member()
    and (exists (select 1 from wh_orders o where o.order_no = l.order_no and o.ship_date between p_from and p_to)
         or l.at::date between p_from and p_to);
$$;

do $$
declare f text;
begin
  foreach f in array array['wh_import_orders(jsonb)','wh_weight_orders(date,date,uuid)',
                           'wh_set_checked(text,boolean,text)','wh_check_log_list(date,date)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
