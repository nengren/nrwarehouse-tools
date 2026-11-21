-- =====================================================================
-- 单重校准建议：SKU 按马帮原始大小写输出（方便复制回马帮批量改重量）
-- 在 Supabase → SQL Editor 运行一次即可，可重复运行
-- =====================================================================
create or replace function public.wh_sku_calibration(p_from date, p_to date)
returns jsonb language sql stable set search_path = public as $$
  with single as (
    select o.order_no from wh_orders o
    join wh_order_items i on i.order_no = o.order_no
    where o.ship_date between p_from and p_to and o.actual_weight > 0
    group by o.order_no having count(*) = 1
  ),
  s as (
    select upper(i.sku) as sku, i.sku as raw_sku, i.unit_weight,
           o.actual_weight::numeric / nullif(i.qty,0) as per_unit
    from single x
    join wh_orders o on o.order_no = x.order_no
    join wh_order_items i on i.order_no = x.order_no
    where not (i.unit_weight <= 1 and o.actual_weight = o.total_qty)   -- 排除秤未捕获
  ),
  g as (
    select sku,
           mode() within group (order by raw_sku) as raw_sku,          -- 马帮里最常见的写法
           max(unit_weight) as cur, count(*) as n,
           round(percentile_cont(0.5) within group (order by per_unit))::int as med
    from s where per_unit is not null group by sku having count(*) >= 3
  )
  select coalesce(jsonb_agg(jsonb_build_object('sku', raw_sku, 'cur', cur, 'n', n, 'med', med)
                  order by abs(med - cur) desc), '[]'::jsonb)
  from g
  where cur <= 1 or abs(med - cur) > greatest(cur * 0.10, 50);
$$;
