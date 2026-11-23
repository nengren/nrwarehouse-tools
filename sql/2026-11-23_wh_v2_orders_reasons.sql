-- =====================================================================
-- 产量加单数（按包裹）+ 核查原因 + 导入日历
-- 在 Supabase → SQL Editor 运行一次，可重复运行（需先运行过 2026-11-23_wh_v2_package_key.sql）
-- =====================================================================

-- ---------- 1. 产量汇总：加哑铃单数 do、其他单数 oo（一个包裹 = 一单） ----------
-- 旧手工数据没有单数，返回 null
create or replace function public.wh_output(p_from date, p_to date) returns jsonb
language sql stable set search_path = public as $$
  with cut as (
    select coalesce((select (value #>> '{}')::date from wh_settings where key = 'cutover_date'),
                    '9999-12-31'::date) as d
  ),
  n as (
    select o.ship_date as day, o.employee_id as emp,
           sum(o.dumbbell_qty)::bigint as db, sum(o.other_qty)::bigint as ot, count(*)::bigint as orders,
           count(*) filter (where o.dumbbell_qty > 0)::bigint as do_,
           count(*) filter (where o.other_qty > 0)::bigint as oo_
    from wh_orders o, cut
    where o.ship_date between greatest(p_from, cut.d) and p_to and o.employee_id is not null
    group by 1, 2
  ),
  old as (
    select r.record_date as day, r.employee_id as emp,
           sum(r.quantity)::bigint as db, 0::bigint as ot, null::bigint as orders,
           null::bigint as do_, null::bigint as oo_
    from wh_records r, cut
    where r.record_date between p_from and least(p_to, cut.d - 1)
    group by 1, 2
  )
  select coalesce(jsonb_agg(jsonb_build_object('d', day, 'e', emp, 'db', db, 'ot', ot,
                                               'o', orders, 'do', do_, 'oo', oo_)), '[]'::jsonb)
  from (select * from n union all select * from old) x;
$$;

-- ---------- 2. 核查原因 ----------
-- pack_error 打包错误 / unit_wrong SKU单重不对 / packaging 包材多 / scale_error 称重失误 / other 其他
alter table public.wh_orders add column if not exists check_reason text;
alter table public.wh_check_log add column if not exists reason text;

drop function if exists public.wh_set_checked(text, boolean, text);
create or replace function public.wh_set_checked(p_order text, p_checked boolean,
                                                  p_reason text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u text; o record; r text := nullif(btrim(coalesce(p_reason,'')),'');
begin
  select username into u from wh_accounts where user_id = auth.uid() and active;
  if u is null then raise exception '没有权限 not allowed'; end if;
  if p_checked and (r is null or r not in ('pack_error','unit_wrong','packaging','scale_error','other')) then
    raise exception '请选择原因 reason required';
  end if;
  select * into o from wh_orders where order_no = p_order;
  if not found then raise exception '找不到这个包裹 order not found'; end if;
  update wh_orders set checked_at   = case when p_checked then now() end,
                       checked_by   = case when p_checked then u end,
                       check_reason = case when p_checked then r end
  where order_no = p_order;
  insert into wh_check_log(order_no, platform_no, action, reason, note, actual_weight, theory_weight, username, user_id)
  values (p_order, o.platform_no, case when p_checked then 'check' else 'uncheck' end,
          case when p_checked then r end, nullif(btrim(coalesce(p_note,'')),''),
          o.actual_weight, o.theory_weight, u, auth.uid());
  return jsonb_build_object('ck', case when p_checked then u end,
                            'ca', case when p_checked then now() end,
                            'rs', case when p_checked then r end);
end $$;

-- 称重数据带核查原因
create or replace function public.wh_weight_orders(p_from date, p_to date, p_emp uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'no', o.order_no, 'pn', coalesce(o.platform_no, o.order_no), 'tr', o.track_no,
           't', o.ship_time, 'e', o.employee_id, 'pr', o.packer_raw,
           'aw', o.actual_weight, 'tw', o.theory_weight, 'q', o.total_qty, 'm', o.has_missing_unit,
           'ck', o.checked_by, 'ca', o.checked_at, 'rs', o.check_reason,
           'ps', (select count(*) from wh_orders x where x.platform_no = o.platform_no),
           'pi', (select count(*) from wh_orders x where x.platform_no = o.platform_no
                    and (x.ship_time, x.order_no) <= (o.ship_time, o.order_no)),
           'it', (select jsonb_agg(jsonb_build_array(i.sku, i.qty, i.unit_weight) order by i.id)
                  from wh_order_items i where i.order_no = o.order_no)
         ) order by o.ship_time desc), '[]'::jsonb)
  from wh_orders o
  where o.ship_date between p_from and p_to and (p_emp is null or o.employee_id = p_emp);
$$;

create or replace function public.wh_check_log_list(p_from date, p_to date)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', l.at, 'u', l.username, 'a', l.action, 'no', l.order_no, 'pn', l.platform_no,
           'aw', l.actual_weight, 'tw', l.theory_weight, 'rs', l.reason, 'note', l.note) order by l.at desc), '[]'::jsonb)
  from wh_check_log l
  where wh_is_member()
    and (exists (select 1 from wh_orders o where o.order_no = l.order_no and o.ship_date between p_from and p_to)
         or l.at::date between p_from and p_to);
$$;

-- ---------- 3. 导入日历：每天导入了多少个包裹、最后导入时间 ----------
create or replace function public.wh_import_calendar(p_from date, p_to date)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('d', ship_date, 'n', n, 'last', last) order by ship_date), '[]'::jsonb)
  from (select ship_date, count(*) as n, max(imported_at) as last
        from wh_orders where ship_date between p_from and p_to group by ship_date) t;
$$;

do $$
declare f text;
begin
  foreach f in array array['wh_output(date,date)','wh_set_checked(text,boolean,text,text)',
                           'wh_weight_orders(date,date,uuid)','wh_check_log_list(date,date)',
                           'wh_import_calendar(date,date)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
