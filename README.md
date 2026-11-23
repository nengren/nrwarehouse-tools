# NR 仓库工具 Warehouse Tools

网址（开启 GitHub Pages 后）：https://nengren.github.io/nrwarehouse-tools/

合并了原「仓库工具」和「PackGuard 称重校验」：

| 页面 | 作用 |
|---|---|
| 📥 导入 | 上传马帮出库表 → 产量 + 称重校验一次出结果。同一平台交易号重复导入只会覆盖，不会重复计数 |
| 📊 产量总览 | 今日/昨日/本周/上周/本月/上月/自定义；哑铃、其他分开比，按日均排序 |
| ⚖️ 称重校验 | 按包裹（快递单号）校验：异常 / 秤未捕获 / 单重缺失 / 正常；拆单标注；已核查记录；发货员异常率；单重校准建议 |
| 👤 个人 | 某个发货员的月度产量、每日明细、称重异常 |
| ⚙️ 管理（仅管理员） | 账号、发货员与马帮别名、SKU 归类、切换日与阈值 |

## 规则

- **产量** = SKU 数量之和（一单 2 种 SKU 共 5 件 → 5）。按发货员算。
- **哑铃** = SKU 以 `FS-` 或 `HL-` 开头 **且** 单重 ≥ 2000g；其余算「其他」。管理页可逐个 SKU 手动改，改了会同步更新历史订单。
- **称重异常** = 偏差超过 ±10% **且** 差值超过 50g（管理员可改默认值）。有 SKU 单重 ≤1g 的订单归「单重缺失」，不算异常。
- **一周** = 周一到周日。
- **包裹** = 一个快递单号。大单拆成几个包裹时，平台交易号相同、每包各算一次称重和产量；没有快递单号的才按平台交易号。
- **已核查**：每次核查/撤销都记在 `wh_check_log`（谁、什么时候、当时的理论/实称重量），只能新增不能改。重新导入不会清掉核查状态。
- **切换日**：之前的产量读旧表 `wh_records`（手工录入，旧数据只有哑铃），从切换日起读导入的马帮数据。旧表全部保留、只读。

## 马帮导出模板需要的列

`平台交易号`、`发货时间`、`发货员`、`库存SKU`、`数量`、`单位重量`、`订单重量`；`快递单号` 可选。

## 上线步骤（按顺序）

1. **合并 PR**，然后 GitHub 仓库 → Settings → Pages → Source 选 `Deploy from a branch`，Branch 选 `main` / `(root)`，保存。几分钟后网址可用。
2. **Supabase → Authentication → Sign In / Providers → Email**：
   - 关掉 **Confirm email**（不然新建的账号登录不了）
   - **Allow new users to sign up** 保持打开（管理页新建账号要用；外人就算注册了也看不到任何数据）
3. **Supabase → Authentication → Users → Add user → Create new user**：
   Email 填 `ken@nrwh.local`（@ 前面就是登录用户名），密码自己定，勾选 **Auto Confirm User**。
4. **Supabase → SQL Editor**：粘贴运行 `sql/2026-11-21_wh_v2_init.sql`。
   ⚠ 运行后**旧版仓库工具立刻不能用**，所有电脑同一天换新网址。切换日自动设为运行当天。
5. **SQL Editor**：运行 `sql/2026-11-21_wh_v2_admin.sql`（用户名不是 ken 的话先改里面两处）。最后一条查询应返回 1 行。
6. 打开网址，用 `ken` + 密码登录。在「管理 → 账号」里给其他人建账号。

## 以后改代码

每次改动走 PR；涉及数据库的改动会附带一个带日期的 `sql/*.sql`，在 SQL Editor 里运行即可（都可重复运行）。

## 其他

- 面单改重量功能代码保留，目前隐藏：`index.html` 里 `SHOW_LABEL_EDITOR = true` 可打开。
- 忘记密码：管理员在「管理 → 账号」里重设别人的密码；管理员自己忘了，在 Supabase → SQL Editor 运行：
  `update auth.users set encrypted_password = extensions.crypt('新密码', extensions.gen_salt('bf')) where email = 'ken@nrwh.local';`
