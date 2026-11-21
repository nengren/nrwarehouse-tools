-- =====================================================================
-- 设置第一个管理员（只需运行一次）
-- 先在 Supabase → Authentication → Users → Add user → Create new user 建好账号：
--     Email:    ken@nrwh.local     （@ 前面就是登录用户名，可以换成别的）
--     Password: 你自己定（至少 6 位）
--     勾选 Auto Confirm User
-- 再把下面两处 'ken' 改成你用的用户名，运行。
-- =====================================================================
insert into public.wh_accounts(user_id, username, role, active)
select id, 'ken', 'admin', true from auth.users where email = 'ken@nrwh.local'
on conflict (user_id) do update set role = 'admin', active = true;

-- 运行后下面这条应该返回 1 行；返回 0 行说明上面的邮箱没建对
select username, role, active from public.wh_accounts where role = 'admin';
