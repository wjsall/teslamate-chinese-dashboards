-- ============================================================================
-- TeslaMate 中文仪表盘：分时电价（TOU）原生支持 — PoC v0.1
--
-- 架构（v1.4.2 GCJ-02 同款思路）：
--   tou_rates 表          → 用户配置的峰平谷时段 + 单价（按 geofence + 季节）
--   charging_processes_tou_cost 表 → 旁路 cost，不动 TeslaMate 原表
--   compute_tou_cost()    → 核心算法，按 charges 表每秒级 sample 切片求和
--   lookup_tou_rate()     → 给定时间+地点+AC/DC，查命中的 rate
--
-- 使用：
--   1) 跑本文件灌函数+表
--   2) INSERT INTO tou_rates 配置你城市的峰平谷时段
--   3) SELECT compute_tou_cost(cp_id) 算单笔
--   4) v1 会加触发器 + 视图实现「全自动 + 全局生效」
--
-- 当前状态：PoC（仅函数 + 表，无触发器无视图，需要手动调用 compute_tou_cost）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 配置表：tou_rates
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tou_rates (
  id SERIAL PRIMARY KEY,
  geofence_id INT REFERENCES geofences(id) ON DELETE CASCADE,
  -- NULL = 全局默认；具体 geofence_id = 仅这个地理围栏
  hour_start INT NOT NULL CHECK (hour_start BETWEEN 0 AND 23),
  hour_end INT NOT NULL CHECK (hour_end BETWEEN 1 AND 24),
  -- hour_end 可以是 24 表示包含到 23:59:59
  -- hour_start > hour_end 表示跨午夜（如 22-6 = 22:00 → 次日 06:00）
  rate NUMERIC(10,4) NOT NULL,
  weekday_mask SMALLINT DEFAULT 127 CHECK (weekday_mask BETWEEN 1 AND 127),
  -- 7 bits, bit0=Mon, bit1=Tue, ..., bit6=Sun
  -- 默认 127 = 全周
  -- 31 = Mon-Fri (bit 0-4)
  -- 96 = Sat-Sun (bit 5-6)
  valid_from DATE,
  -- NULL = 全年生效
  valid_to DATE,
  apply_to_dc BOOLEAN DEFAULT FALSE,
  -- 是否对 DC 快充生效（默认仅 AC 慢充）
  label TEXT,
  -- 显示用："峰" / "平" / "谷" / "夏尖" 等
  timezone TEXT DEFAULT 'Asia/Shanghai',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS tou_rates_geofence_idx ON tou_rates(geofence_id);

-- 防重复：同一 geofence × 时段 × 季节 × AC/DC 组合只能存在一条
-- 用 EXPRESSION 处理 NULL 等价（默认 NULL ≠ NULL，UNIQUE 不阻止重复 NULL）
CREATE UNIQUE INDEX IF NOT EXISTS tou_rates_unique_idx ON tou_rates (
  COALESCE(geofence_id, -1),
  hour_start,
  hour_end,
  COALESCE(valid_from, '0001-01-01'::DATE),
  COALESCE(valid_to,   '9999-12-31'::DATE),
  apply_to_dc
);

COMMENT ON TABLE tou_rates IS 'TeslaMate 中文版独家：分时电价配置表';

-- ----------------------------------------------------------------------------
-- 2. 旁路 cost 表：charging_processes_tou_cost
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS charging_processes_tou_cost (
  charging_process_id INT PRIMARY KEY REFERENCES charging_processes(id) ON DELETE CASCADE,
  cost_tou NUMERIC(10,4),
  energy_by_period JSONB,  -- {"峰": 5.2, "谷": 12.3} 用于可视化
  computed_at TIMESTAMPTZ DEFAULT NOW(),
  rates_signature TEXT     -- tou_rates 当时的 hash，用来检测 stale
);

COMMENT ON TABLE charging_processes_tou_cost IS '旁路存储 TOU 计算后的 cost，不动 TeslaMate 原表';

-- ----------------------------------------------------------------------------
-- 2c. 费用覆盖表：charging_process_cost_overrides
--
-- 为什么要有这张表：在它出现之前，「默认电价」和「单笔手工电价」是**直接 UPDATE
-- charging_processes.cost**的。那意味着一旦写下去，就再也分不清一笔费用到底是
-- TeslaMate 自己算的、用户手填的、还是我们按默认电价生成的——于是：
--   · 改了默认电价，历史记录不会跟着变（那些行的 cost 已经不是 NULL 了）
--   · 卸载分时电价功能，写进去的值留在原表里，恢复不了
--   · 一部分仪表盘读 effective_cost、一部分读原表 cost，同一笔充电两个数
-- 现在一律写这张旁路表，charging_processes 保持 TeslaMate 自己的原貌。
--
-- 一笔充电最多一行（主键即 charging_process_id）；source 记清楚来源，
-- 取值优先级由 effective_cost() 定义：手工 > 分时电价 > 默认电价 > TeslaMate 原值。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS charging_process_cost_overrides (
  charging_process_id INT PRIMARY KEY REFERENCES charging_processes(id) ON DELETE CASCADE,
  cost NUMERIC(10,4) NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('manual', 'default')),
  rate NUMERIC(10,4),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- 「这一笔在 TeslaMate 记录里原本是多少钱」。只有 adopt_legacy_default_costs() 会填：
  -- 它把早期版本写进 charging_processes.cost 的值搬到这张表、原位置清成空，那个值从此
  -- 只剩这一个落脚点，卸载时必须原样搬回去（详见 uninstall_tou()）。
  --
  -- 为什么单开一列而不是给行打个「我是搬来的」标记：cost 那一列是会被改的——改默认电价
  -- 会重算它、手工指定单价会覆盖它。标记只能告诉你「这行搬过」，改一次价原值就没了。
  -- 单独存一列，cost 随便改，要还给 TeslaMate 的那个数一直在。
  -- 默认电价 / 手工单价生成的行这一列是空的：那些值从来不属于 TeslaMate 的记录，
  -- 卸载时应当随表一起消失，而不是被写进 TeslaMate 原表。
  original_cost NUMERIC(10,4)
);

-- 老版本装过这张表的，补上后加的列
ALTER TABLE charging_process_cost_overrides
  ADD COLUMN IF NOT EXISTS original_cost NUMERIC(10,4);

COMMENT ON TABLE charging_process_cost_overrides IS
'费用覆盖（手工单价 / 默认电价），带来源标记；不写 TeslaMate 原表';

-- ----------------------------------------------------------------------------
-- 2b. 季节判断：忽略年份只看 MM-DD，处理跨年环绕（如 12/01 ~ 02/28 冬季）
--     任一边为 NULL 视为不限那一边；两边都 NULL = 全年生效
-- ----------------------------------------------------------------------------
-- 删除指定 geofence 在指定季节范围内的 AC 时段（IS NOT DISTINCT FROM 处理 NULL=NULL）
-- apply_tou_pattern / set_tou_batch 重新写入前调用，避免重复
CREATE OR REPLACE FUNCTION _tou_delete_season(
  p_geofence_id INT,
  v_from DATE,
  v_to DATE
) RETURNS VOID AS $$
  DELETE FROM tou_rates
  WHERE geofence_id IS NOT DISTINCT FROM p_geofence_id
    AND apply_to_dc = FALSE
    AND valid_from IS NOT DISTINCT FROM v_from
    AND valid_to   IS NOT DISTINCT FROM v_to;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION _tou_in_season(
  sample_date DATE,
  v_from DATE,
  v_to DATE
) RETURNS BOOLEAN AS $$
  SELECT CASE
    WHEN v_from IS NULL AND v_to IS NULL THEN TRUE
    WHEN v_from IS NULL THEN
      to_char(sample_date, 'MMDD') <= to_char(v_to, 'MMDD')
    WHEN v_to IS NULL THEN
      to_char(sample_date, 'MMDD') >= to_char(v_from, 'MMDD')
    -- 不跨年（如 07-01 ~ 09-30）
    WHEN to_char(v_from, 'MMDD') <= to_char(v_to, 'MMDD') THEN
      to_char(sample_date, 'MMDD') BETWEEN to_char(v_from, 'MMDD') AND to_char(v_to, 'MMDD')
    -- 跨年环绕（如 12-01 ~ 02-28）
    ELSE
      to_char(sample_date, 'MMDD') >= to_char(v_from, 'MMDD')
      OR to_char(sample_date, 'MMDD') <= to_char(v_to, 'MMDD')
  END
$$ LANGUAGE sql IMMUTABLE;

-- ----------------------------------------------------------------------------
-- 3. 辅助：lookup_tou_rate(sample_ts, geofence_id, is_dc)
--    给定 UTC 时间戳 + 地理围栏 + AC/DC，返回最匹配的 rate（或 NULL 表无匹配）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lookup_tou_rate(
  sample_ts TIMESTAMP,    -- UTC naive (TeslaMate 存储格式)
  cp_geofence_id INT,
  is_dc BOOLEAN
) RETURNS NUMERIC AS $$
DECLARE
  local_ts TIMESTAMP;
  sample_hour INT;
  sample_dow INT;
  sample_date DATE;
  bit_pos INT;
  rate_val NUMERIC;
  tz TEXT := 'Asia/Shanghai';  -- TODO: 从 tou_rates 第一条读 timezone，PoC 阶段写死
BEGIN
  IF sample_ts IS NULL THEN RETURN NULL; END IF;

  -- TeslaMate 存的是 naive UTC，先标记为 UTC 再转本地时区
  local_ts := (sample_ts AT TIME ZONE 'UTC') AT TIME ZONE tz;
  sample_hour := EXTRACT(HOUR FROM local_ts)::INT;
  sample_date := local_ts::DATE;
  sample_dow := EXTRACT(DOW FROM local_ts)::INT;
  -- PG: Sun=0,Mon=1,...Sat=6 → 我们的 bit_pos: Mon=0,Tue=1,...Sun=6
  bit_pos := CASE WHEN sample_dow = 0 THEN 6 ELSE sample_dow - 1 END;

  SELECT rate INTO rate_val
  FROM tou_rates
  WHERE
    -- 地理围栏匹配：精确匹配或全局默认
    (geofence_id = cp_geofence_id OR geofence_id IS NULL)
    -- AC/DC：DC 充电只匹配 apply_to_dc=TRUE 的；AC 充电匹配 apply_to_dc=FALSE 的（默认）
    AND (CASE WHEN is_dc THEN apply_to_dc ELSE NOT apply_to_dc END)
    -- 时段匹配（含跨午夜）
    AND (
      (hour_start < hour_end AND sample_hour >= hour_start AND sample_hour < hour_end)
      OR (hour_start > hour_end AND (sample_hour >= hour_start OR sample_hour < hour_end))
      OR (hour_start = 0 AND hour_end = 24)  -- 全天覆盖
    )
    -- 工作日/周末
    AND ((weekday_mask >> bit_pos) & 1) = 1
    -- 季节（按月日比较，忽略年份；含跨年环绕，如 12/01 ~ 02/28）
    AND _tou_in_season(sample_date, valid_from, valid_to)
  ORDER BY
    geofence_id NULLS LAST,    -- 优先 exact geofence，其次全局
    valid_from NULLS LAST,     -- 优先有日期范围的（特殊政策），其次全年
    id
  LIMIT 1;

  RETURN rate_val;
END;
$$ LANGUAGE plpgsql STABLE;

-- ----------------------------------------------------------------------------
-- 3b. _tou_has_matching_rate(cp_id) — 这笔充电有没有**任何**一条分时电价规则可能适用
--
-- 「一条都没有」和「有规则但漏了几个小时」是两种完全不同的状态，给用户看的说法也不同：
-- 前者是「你没配分时时段」，后者是「你配了，但这次充电有时段没覆盖到」。compute_tou_cost
-- 两种情况都返回 NULL（都不能给出可信的金额），所以判断放在这个共用函数里，
-- 让回算统计能分开报数，而不是把两件事混成一个「跳过」。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _tou_has_matching_rate(cp_id INT) RETURNS BOOLEAN AS $$
DECLARE
  cp_geofence_id INT;
  is_dc BOOLEAN;
BEGIN
  SELECT geofence_id INTO cp_geofence_id FROM charging_processes WHERE id = cp_id;

  -- 检测 AC/DC：charges.charger_phases NULL 表 DC，非 NULL 表 AC
  SELECT NOT bool_or(charger_phases IS NOT NULL) INTO is_dc
  FROM charges WHERE charging_process_id = cp_id;

  RETURN EXISTS (
    SELECT 1 FROM tou_rates
    WHERE (geofence_id = cp_geofence_id OR geofence_id IS NULL)
      AND (CASE WHEN is_dc THEN apply_to_dc ELSE NOT apply_to_dc END)
  );
END;
$$ LANGUAGE plpgsql STABLE;

-- ----------------------------------------------------------------------------
-- 4. 核心：compute_tou_cost(cp_id) — 单笔 TOU 实际费用
--    返回 NULL 表示无 tou_rates 配置（用户未启用 TOU），调用方应回退到原 cost
--
-- 算法：「按比例分配」防止 sum(power×dt) ≠ 真实总 kWh 的积分误差
--   weighted_rate = SUM(raw_kwh × rate) / SUM(raw_kwh)
--   tou_cost = GREATEST(charge_energy_added, charge_energy_used) × weighted_rate
--   即先在各时段算占比，再乘以 TeslaMate 报告的电网侧总 kWh，总数严格守恒
--
-- v1.7.5: 总 kWh 从 charge_energy_added（电池实收）改为
--   GREATEST(charge_energy_added, charge_energy_used)（电网侧 / 桩输出，含损耗），
--   与 set_default_charging_rate / charges 仪表盘「电价」列算法一致；
--   原来用 added 会让 TOU 费用比充电桩账单偏低 ~5-15%。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION compute_tou_cost(cp_id INT)
RETURNS NUMERIC AS $$
DECLARE
  cp_geofence_id INT;
  is_dc BOOLEAN;
  weighted_rate NUMERIC;
  actual_kwh NUMERIC;
  has_any_rate BOOLEAN;
BEGIN
  SELECT geofence_id, GREATEST(charge_energy_added, charge_energy_used)
  INTO cp_geofence_id, actual_kwh
  FROM charging_processes WHERE id = cp_id;

  -- 配置完整性检查放在最前面：是否有任一 rate 能匹配此次充电。
  -- 顺序要紧——这一段以前排在「电量为 0 就返回 0」后面，于是没配任何分时电价的用户，
  -- 每一笔 0 度的充电都会被算出 0 元写进旁路表，而旁路表优先级高于默认电价和
  -- TeslaMate 原值，等于凭空把那笔费用抹成 0。没配就是没配，一律 NULL 交给上层回退。
  has_any_rate := _tou_has_matching_rate(cp_id);
  IF NOT has_any_rate THEN RETURN NULL; END IF;  -- 用户没配 → 回退原 cost

  IF actual_kwh IS NULL OR actual_kwh = 0 THEN RETURN 0; END IF;

  -- 检测 AC/DC：charges.charger_phases NULL 表 DC，非 NULL 表 AC
  SELECT NOT bool_or(charger_phases IS NOT NULL) INTO is_dc
  FROM charges WHERE charging_process_id = cp_id;

  -- 各时段占比加权 → 加权 rate
  WITH samples AS (
    SELECT
      date,
      charger_power,
      LEAD(date) OVER (ORDER BY date) AS next_date
    FROM charges
    WHERE charging_process_id = cp_id
  ),
  sample_kwh AS (
    SELECT
      COALESCE(charger_power, 0) * EXTRACT(EPOCH FROM (next_date - date)) / 3600.0 AS raw_kwh,
      lookup_tou_rate(date, cp_geofence_id, is_dc) AS rate
    FROM samples
    WHERE next_date IS NOT NULL
      AND EXTRACT(EPOCH FROM (next_date - date)) < 600  -- 跳过 > 10 分钟的异常 gap
  )
  --【电价覆盖必须完整，缺口不能当免费电】
  -- 这里曾经写的是 SUM(raw_kwh * COALESCE(rate, 0)) / SUM(raw_kwh)：没匹配到电价的采样点
  -- rate 是 NULL，COALESCE 把它当 0 元，但那段电量仍留在分母里——结果是「配了一半电价」的
  -- 用户，未覆盖时段被按免费电算进去，总费用被静默低估，而且界面上看不出任何异常。
  -- 上面的 has_any_rate 只保证「至少有一条规则」，挡不住「有规则但没覆盖到这次充电的某些
  -- 小时」。所以这里改成：只要有**实际产生电量**的采样点没匹配到电价，整笔就返回 NULL，
  -- 回退 TeslaMate 原 cost，而不是给一个偏低的数。
  -- 注意区分两件事：rate = 0（用户明确配了 0 元，比如免费充电桩）是有效电价，照常计算；
  -- rate IS NULL（压根没配到这个时段）才是缺口。
  SELECT
    CASE
      WHEN SUM(raw_kwh) = 0 THEN NULL
      WHEN SUM(CASE WHEN raw_kwh > 0 AND rate IS NULL THEN raw_kwh ELSE 0 END) > 0 THEN NULL
      ELSE SUM(raw_kwh * rate) / SUM(raw_kwh)
    END
  INTO weighted_rate
  FROM sample_kwh;

  IF weighted_rate IS NULL THEN RETURN NULL; END IF;

  -- TeslaMate 真实总 kWh × 加权 rate = 总数对账的 TOU 费用
  RETURN ROUND((actual_kwh * weighted_rate)::NUMERIC, 4);
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 5. 城市模板一键应用：apply_city_template(city, geofence_id)
--    给 Grafana 配置仪表盘和命令行 setup-tou.sh 共用
--    返回应用了几条 rate，0 表示城市未知
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_city_template(
  city_name TEXT,
  target_geofence_id INT
) RETURNS INT AS $$
DECLARE
  inserted INT := 0;
BEGIN
  -- 先清掉这个 geofence 的 AC TOU 配置（保留 DC，避免误删）
  DELETE FROM tou_rates WHERE geofence_id IS NOT DISTINCT FROM target_geofence_id AND apply_to_dc = FALSE;

  CASE LOWER(TRIM(city_name))
  WHEN 'beijing', '北京' THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES
      (target_geofence_id, 8, 22, 0.4883, '峰'),
      (target_geofence_id, 22, 8, 0.30, '谷');
    inserted := 2;
  WHEN 'shanghai', '上海' THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES
      (target_geofence_id, 6, 22, 0.617, '峰'),
      (target_geofence_id, 22, 6, 0.307, '谷');
    inserted := 2;
  WHEN 'shenzhen', '深圳' THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES
      (target_geofence_id, 14, 17, 0.7378, '峰'),
      (target_geofence_id, 19, 22, 0.7378, '峰'),
      (target_geofence_id, 8, 14, 0.5942, '平'),
      (target_geofence_id, 17, 19, 0.5942, '平'),
      (target_geofence_id, 22, 8, 0.3010, '谷');
    inserted := 5;
  WHEN 'guangzhou', '广州' THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES
      (target_geofence_id, 14, 17, 0.6649, '峰'),
      (target_geofence_id, 19, 22, 0.6649, '峰'),
      (target_geofence_id, 8, 14, 0.6049, '平'),
      (target_geofence_id, 17, 19, 0.6049, '平'),
      (target_geofence_id, 22, 8, 0.3070, '谷');
    inserted := 5;
  WHEN 'zhejiang', 'hangzhou', '浙江', '杭州' THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES
      (target_geofence_id, 8, 22, 0.568, '峰'),
      (target_geofence_id, 22, 8, 0.288, '谷');
    inserted := 2;
  WHEN 'jiangsu', 'nanjing', '江苏', '南京' THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, valid_from, valid_to) VALUES
      (target_geofence_id, 8, 21, 0.5683, '峰', NULL, NULL),
      (target_geofence_id, 21, 8, 0.3203, '谷', NULL, NULL),
      (target_geofence_id, 13, 15, 0.6683, '夏尖', '2026-07-01', '2026-08-31'),
      (target_geofence_id, 18, 21, 0.6683, '冬尖', '2026-12-01', '2027-02-28');
    inserted := 4;
  WHEN 'wuhan', '武汉' THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES
      (target_geofence_id, 23, 7,  0.43, '谷'),
      (target_geofence_id, 7,  17, 0.58, '平'),
      (target_geofence_id, 17, 20, 0.68, '峰'),
      (target_geofence_id, 20, 22, 0.78, '尖'),
      (target_geofence_id, 22, 23, 0.68, '峰');
    inserted := 5;
  ELSE
    inserted := 0;
  END CASE;

  RETURN inserted;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 5b. 批量配置时段：set_tou_batch — 一次性配 1-6 个时段
--     用于 Grafana「批量配置时段」面板
--     单价 rate=0 或 hour_start=hour_end 表示跳过该时段
--
--     所有时段参数都是 TEXT 接收，函数内部转 INT/NUMERIC：
--     - Volkov Form Panel 把 showIf=false 的字段从 payload 里删掉，
--       SQL 模板替换会变成字面量 'undefined' → 直接传 INT 会报错
--     - 接 TEXT + NULLIF 处理 'undefined' / 空串 / 'null' → 全当 0
--     - valid_from/valid_to 同时支持 YYYY-MM-DD 和 YYYYMMDD 格式
-- ----------------------------------------------------------------------------
-- 升级时清掉所有旧 overload，避免歧义
DROP FUNCTION IF EXISTS set_tou_batch(
  integer, integer, integer, numeric, text,
  integer, integer, numeric, text,
  integer, integer, numeric, text,
  integer, integer, numeric, text,
  integer, integer, numeric, text,
  integer, integer, numeric, text
);
DROP FUNCTION IF EXISTS set_tou_batch(
  integer, integer, integer, numeric, text,
  integer, integer, numeric, text,
  integer, integer, numeric, text,
  integer, integer, numeric, text,
  integer, integer, numeric, text,
  integer, integer, numeric, text,
  text, text
);

-- 内部辅助：把 'undefined' / 'null' / '' 都转 NULL，再转目标类型
CREATE OR REPLACE FUNCTION _tou_clean_int(s TEXT) RETURNS INT AS $$
  SELECT COALESCE(NULLIF(NULLIF(NULLIF(s, ''), 'undefined'), 'null')::NUMERIC::INT, 0)
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION _tou_clean_numeric(s TEXT) RETURNS NUMERIC AS $$
  SELECT COALESCE(NULLIF(NULLIF(NULLIF(s, ''), 'undefined'), 'null')::NUMERIC, 0)
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION _tou_clean_label(s TEXT) RETURNS TEXT AS $$
  SELECT NULLIF(NULLIF(NULLIF(NULLIF(s, ''), 'undefined'), 'null'), 'NULL')
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION _tou_clean_date(s TEXT) RETURNS DATE AS $$
  SELECT CASE
    WHEN s IS NULL OR s IN ('', 'undefined', 'null') THEN NULL
    WHEN s ~ '^\d{4}-\d{1,2}-\d{1,2}$' THEN to_date(s, 'YYYY-MM-DD')
    WHEN s ~ '^\d{8}$'                  THEN to_date(s, 'YYYYMMDD')
    WHEN s ~ '^\d{4}/\d{1,2}/\d{1,2}$' THEN to_date(s, 'YYYY/MM/DD')
    ELSE NULL
  END
$$ LANGUAGE sql IMMUTABLE;

-- 把表单的 month + day 字符串拼成 DATE（用 2024 闰年作 sentinel，年份不重要）
-- m/d 任一为空 / 'undefined' / 'null' / '0' → 返回 NULL（表示「全年生效」）
-- 自动把无效日（如 6/31, 2/30）clamp 到该月最后一天，避免用户选错日就报错
CREATE OR REPLACE FUNCTION _tou_md_to_date(m TEXT, d TEXT) RETURNS DATE AS $$
DECLARE
  mi INT;
  di INT;
  last_day INT;
BEGIN
  IF m IS NULL OR m IN ('', 'undefined', 'null', '0') THEN RETURN NULL; END IF;
  IF d IS NULL OR d IN ('', 'undefined', 'null', '0') THEN RETURN NULL; END IF;
  mi := m::INT;
  di := d::INT;
  IF mi < 1 OR mi > 12 THEN RETURN NULL; END IF;
  -- 用 2024 闰年算各月最大天数（含 2/29）
  last_day := EXTRACT(DAY FROM (make_date(2024, mi, 1) + interval '1 month - 1 day'))::INT;
  IF di < 1 THEN di := 1; END IF;
  IF di > last_day THEN di := last_day; END IF;
  RETURN make_date(2024, mi, di);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION set_tou_batch(
  p_geofence_id INT,
  s1_start TEXT, s1_end TEXT, s1_rate TEXT, s1_label TEXT,
  s2_start TEXT DEFAULT '0', s2_end TEXT DEFAULT '0', s2_rate TEXT DEFAULT '0', s2_label TEXT DEFAULT '',
  s3_start TEXT DEFAULT '0', s3_end TEXT DEFAULT '0', s3_rate TEXT DEFAULT '0', s3_label TEXT DEFAULT '',
  s4_start TEXT DEFAULT '0', s4_end TEXT DEFAULT '0', s4_rate TEXT DEFAULT '0', s4_label TEXT DEFAULT '',
  s5_start TEXT DEFAULT '0', s5_end TEXT DEFAULT '0', s5_rate TEXT DEFAULT '0', s5_label TEXT DEFAULT '',
  s6_start TEXT DEFAULT '0', s6_end TEXT DEFAULT '0', s6_rate TEXT DEFAULT '0', s6_label TEXT DEFAULT '',
  p_valid_from TEXT DEFAULT NULL,
  p_valid_to TEXT DEFAULT NULL
) RETURNS INT AS $$
DECLARE
  inserted INT := 0;
  v_from DATE := _tou_clean_date(p_valid_from);
  v_to   DATE := _tou_clean_date(p_valid_to);
  i_s1_start INT     := _tou_clean_int(s1_start);
  i_s1_end   INT     := _tou_clean_int(s1_end);
  n_s1_rate  NUMERIC := _tou_clean_numeric(s1_rate);
  l_s1       TEXT    := _tou_clean_label(s1_label);
  i_s2_start INT     := _tou_clean_int(s2_start);
  i_s2_end   INT     := _tou_clean_int(s2_end);
  n_s2_rate  NUMERIC := _tou_clean_numeric(s2_rate);
  l_s2       TEXT    := _tou_clean_label(s2_label);
  i_s3_start INT     := _tou_clean_int(s3_start);
  i_s3_end   INT     := _tou_clean_int(s3_end);
  n_s3_rate  NUMERIC := _tou_clean_numeric(s3_rate);
  l_s3       TEXT    := _tou_clean_label(s3_label);
  i_s4_start INT     := _tou_clean_int(s4_start);
  i_s4_end   INT     := _tou_clean_int(s4_end);
  n_s4_rate  NUMERIC := _tou_clean_numeric(s4_rate);
  l_s4       TEXT    := _tou_clean_label(s4_label);
  i_s5_start INT     := _tou_clean_int(s5_start);
  i_s5_end   INT     := _tou_clean_int(s5_end);
  n_s5_rate  NUMERIC := _tou_clean_numeric(s5_rate);
  l_s5       TEXT    := _tou_clean_label(s5_label);
  i_s6_start INT     := _tou_clean_int(s6_start);
  i_s6_end   INT     := _tou_clean_int(s6_end);
  n_s6_rate  NUMERIC := _tou_clean_numeric(s6_rate);
  l_s6       TEXT    := _tou_clean_label(s6_label);
BEGIN
  -- 替换该 geofence 该季节范围内的 AC 时段（IS NOT DISTINCT FROM 处理 NULL=NULL，统一逻辑）
  PERFORM _tou_delete_season(p_geofence_id, v_from, v_to);

  IF n_s1_rate > 0 AND i_s1_start <> i_s1_end THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, valid_from, valid_to)
    VALUES (p_geofence_id, i_s1_start, i_s1_end, n_s1_rate, l_s1, v_from, v_to);
    inserted := inserted + 1;
  END IF;
  IF n_s2_rate > 0 AND i_s2_start <> i_s2_end THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, valid_from, valid_to)
    VALUES (p_geofence_id, i_s2_start, i_s2_end, n_s2_rate, l_s2, v_from, v_to);
    inserted := inserted + 1;
  END IF;
  IF n_s3_rate > 0 AND i_s3_start <> i_s3_end THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, valid_from, valid_to)
    VALUES (p_geofence_id, i_s3_start, i_s3_end, n_s3_rate, l_s3, v_from, v_to);
    inserted := inserted + 1;
  END IF;
  IF n_s4_rate > 0 AND i_s4_start <> i_s4_end THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, valid_from, valid_to)
    VALUES (p_geofence_id, i_s4_start, i_s4_end, n_s4_rate, l_s4, v_from, v_to);
    inserted := inserted + 1;
  END IF;
  IF n_s5_rate > 0 AND i_s5_start <> i_s5_end THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, valid_from, valid_to)
    VALUES (p_geofence_id, i_s5_start, i_s5_end, n_s5_rate, l_s5, v_from, v_to);
    inserted := inserted + 1;
  END IF;
  IF n_s6_rate > 0 AND i_s6_start <> i_s6_end THEN
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, valid_from, valid_to)
    VALUES (p_geofence_id, i_s6_start, i_s6_end, n_s6_rate, l_s6, v_from, v_to);
    inserted := inserted + 1;
  END IF;

  RETURN inserted;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 6. 触发器函数：充电完成自动算 cost_tou 写入旁路表
--    AFTER trigger 不阻塞 TeslaMate 事务，异常吞掉避免污染主流程
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trigger_compute_tou()
RETURNS TRIGGER AS $$
DECLARE
  computed NUMERIC;
BEGIN
  BEGIN
    computed := compute_tou_cost(NEW.id);
    -- compute 返回 NULL = 这笔算不出可信的分时电价费用（没配时段，或配了但有时段没覆盖到）。
    --
    -- 算不出来时**必须把旁路表里的旧值删掉**，不能只是「不写」。旧实现只写不删，结果是：
    -- 电价配全时算出一个数存进旁路表 → 用户把配置改成只覆盖一半 → 这里返回 NULL →
    -- 旧值原封不动留在表里 → 界面继续显示那个已知算错的数字，而且怎么重算都不会变。
    -- 「电价缺口按 0 元算」那个 bug 的受害者正是这批人：修好算法之后，他们库里那些
    -- 低估值一个都不会自己消失。删掉之后费用按优先级回退（默认电价 → TeslaMate 原值），
    -- 显示一个来源明确的数，好过显示一个来源不明的错数。
    IF computed IS NOT NULL THEN
      INSERT INTO charging_processes_tou_cost (charging_process_id, cost_tou, computed_at)
      VALUES (NEW.id, computed, NOW())
      ON CONFLICT (charging_process_id) DO UPDATE
      SET cost_tou = EXCLUDED.cost_tou,
          computed_at = NOW();
    ELSE
      DELETE FROM charging_processes_tou_cost WHERE charging_process_id = NEW.id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- 任何错误吞掉，不影响 TeslaMate 写充电完成事务
    RAISE WARNING 'TOU 计算失败 cp_id=%, 跳过: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 装到 charging_processes 表 AFTER UPDATE/INSERT
-- 仅在 end_date 从 NULL 变为有值（充电完成）时触发
DROP TRIGGER IF EXISTS tou_recalc ON charging_processes;
CREATE TRIGGER tou_recalc
AFTER INSERT OR UPDATE OF end_date, cost ON charging_processes
FOR EACH ROW
WHEN (NEW.end_date IS NOT NULL)
EXECUTE FUNCTION trigger_compute_tou();

-- ----------------------------------------------------------------------------
-- 7. 视图 charging_processes_v：透明覆盖，所有 cost 类仪表盘改用此
--    cost_effective = COALESCE(cost_tou, cost) — 没装 TOU 用户透明回退到原 cost
-- ----------------------------------------------------------------------------
-- 注：本视图不能直接替换 dashboards 的 FROM charging_processes，
-- PG 视图不传递底层表 PK 函数依赖到下游 GROUP BY，会破坏所有 GROUP BY cp.id 的聚合 SQL。
-- 视图作为只读展示/对账查询用 OK；批量替换底表请用 trigger 或逐面板 JOIN旁路表。
-- 这个视图的重建必须放在一个带异常处理的 DO 块里，三个理由缺一不可：
--
-- 1) 不能只用 CREATE OR REPLACE VIEW：视图选了 cp.*，建视图时 * 会被展开成当时的列并
--    固化。等 TeslaMate 将来给 charging_processes 加列（历史上 cost、charge_energy_used
--    都是后加的），新列排在 cost_effective 之前，而 CREATE OR REPLACE VIEW 只允许在
--    列表末尾追加列，直接报 cannot change name of view column，重装中断。
-- 2) 也不能无脑 DROP 再建：用户可能在这个视图上建了自己的视图/物化视图，那时 DROP 会报
--    dependent objects still exist，整份 SQL 同样中断——只是把失败条件从"上游加列"换成
--    "用户建过东西"，一样不可自愈。加 CASCADE 更糟，会连用户自己的对象一起删掉。
-- 3) DROP 和 CREATE 分成两条语句时，psql 默认 autocommit，中间存在视图不存在的窗口，
--    此刻刷新仪表盘会报 relation does not exist；更糟的是 DROP 成功而 CREATE 因故失败
--    （连接断、进程被杀）会让视图永久消失。DO 块是单条语句、单个事务，没有这个窗口。
--
-- 所以：在 DO 块里试着 DROP，撞到依赖就保留旧视图并 RAISE NOTICE 告诉用户怎么处理，
-- 然后正常继续装后面的对象（本视图只用于对账查询，没有任何仪表盘引用它，旧一点没关系）；
-- 能 DROP 掉就重建成最新定义。无论哪条路径，本文件后面的 effective_cost 等对象都照装。
DO $view$
BEGIN
    BEGIN
        DROP VIEW IF EXISTS charging_processes_v;
    -- 两种都要捕获：dependent_objects_still_exist = 有对象依赖它；
    -- wrong_object_type = 同名对象存在但不是普通视图（例如用户把它换成了物化视图），
    -- 这时 DROP VIEW 报 "is not a view"，不捕获同样会中断整份文件。
    EXCEPTION WHEN dependent_objects_still_exist OR wrong_object_type THEN
        RAISE NOTICE '跳过重建视图 charging_processes_v：有其他对象依赖它，或它已被换成别的对象类型。';
        RAISE NOTICE '  其余分时电价对象会照常安装，不受影响。';
        RAISE NOTICE '  想让这个视图也更新到最新定义：先删掉依赖它的对象，再重跑本文件。';
        RETURN;
    END;

    -- ⚠ cost_effective 只看「分时电价 → TeslaMate 原值」两档，**不认识费用覆盖表**
    --   （手工单价 / 默认电价）。同一笔充电，这个视图给的数可能和仪表盘上显示的不一样。
    --   要拿「用户实际看到的费用」，一律用 effective_cost(cp.id, cp.cost)。
    --   这里保持现状是因为没有任何仪表盘读它，改成四档要重定义视图列、代价大于收益；
    --   但下一个人别把它当权威——它不是。
    EXECUTE $v$
        CREATE VIEW charging_processes_v AS
        SELECT
          cp.*,
          COALESCE(t.cost_tou, cp.cost) AS cost_effective,
          t.cost_tou,
          t.energy_by_period,
          CASE
            WHEN t.cost_tou IS NOT NULL THEN 'TOU'
            WHEN cp.cost IS NOT NULL THEN 'flat'
            ELSE 'unknown'
          END AS cost_mode
        FROM charging_processes cp
        LEFT JOIN charging_processes_tou_cost t ON t.charging_process_id = cp.id
    $v$;

    EXECUTE $c$COMMENT ON VIEW charging_processes_v IS '临时对账查询用：cost_effective 只含分时电价与 TeslaMate 原值，不含手工单价/默认电价，可能与仪表盘显示不一致；取用户实际看到的费用请用 effective_cost(cp.id, cp.cost)'$c$;
END
$view$;

-- ----------------------------------------------------------------------------
-- 7e. effective_cost(cp_id, fallback) — 让 dashboards 透明拿到 TOU 计算后的 cost
--     旁路表里有 → 返回 cost_tou；没有 → 回退原 cost
--     函数调用不破坏 PK 函数依赖，所以 GROUP BY cp.id 的 SQL 也能用
--     回滚：TRUNCATE charging_processes_tou_cost → 函数自动 fallback 原 cost
-- ----------------------------------------------------------------------------
-- 取值优先级（越靠前越优先）：
--   1. 手工单价——用户对这一笔明确指定的价格，最强意图，压过一切
--   2. 分时电价——按时段算出来的结果，比一口价精确
--   3. 默认电价——用户设的"没有更好信息时按这个算"
--   4. TeslaMate 原值——上面都没有时用它（fallback 参数，调用方传 cp.cost）
CREATE OR REPLACE FUNCTION effective_cost(cp_id INT, fallback NUMERIC) RETURNS NUMERIC AS $$
  SELECT COALESCE(
    (SELECT cost FROM charging_process_cost_overrides
      WHERE charging_process_id = cp_id AND source = 'manual'),
    (SELECT cost_tou FROM charging_processes_tou_cost WHERE charging_process_id = cp_id),
    (SELECT cost FROM charging_process_cost_overrides
      WHERE charging_process_id = cp_id AND source = 'default'),
    fallback
  )
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION effective_cost IS
'透明 TOU cost：旁路表有则返回 TOU 值，否则回退原 cost。dashboards 用 effective_cost(cp.id, cp.cost) 替代 cp.cost 即可';

-- ----------------------------------------------------------------------------
-- 7f. cost_before_tou(cp_id, fallback) — 「如果不按分时电价算，这笔会显示多少钱」
--
-- 就是把 effective_cost 的优先级里「分时电价」那一档拿掉：手工单价 > 默认电价 >
-- TeslaMate 原值。分时电价对账面板拿它当基准。
--
-- 为什么不能直接用 charging_processes.cost 当基准：手工单价和默认电价都写在覆盖表里、
-- 不写 TeslaMate 原表，所以家充这类 TeslaMate 本来就没有金额的记录，cp.cost 是空的，
-- 「差额」一栏会整列为空——而那批充电恰恰是这个面板唯一要对账的对象。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cost_before_tou(cp_id INT, fallback NUMERIC) RETURNS NUMERIC AS $$
  SELECT COALESCE(
    (SELECT cost FROM charging_process_cost_overrides
      WHERE charging_process_id = cp_id AND source = 'manual'),
    (SELECT cost FROM charging_process_cost_overrides
      WHERE charging_process_id = cp_id AND source = 'default'),
    fallback
  )
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION cost_before_tou IS
'不含分时电价的费用：手工单价 > 默认电价 > TeslaMate 原值。给分时电价对账面板当基准';

-- ----------------------------------------------------------------------------
-- 7d. 一键去重：dedup_tou_rates()
--     按 (geofence + 时段 + 季节 + 慢/快) 去重，保留 ID 最小的那条
--     给已经手工写过重复数据的用户用，配合 UNIQUE INDEX 兜底
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dedup_tou_rates()
RETURNS TABLE(removed INT) AS $$
WITH dups AS (
  SELECT id,
    ROW_NUMBER() OVER (
      PARTITION BY geofence_id, hour_start, hour_end, valid_from, valid_to, apply_to_dc
      ORDER BY id
    ) AS rn
  FROM tou_rates
),
del AS (
  DELETE FROM tou_rates
  WHERE id IN (SELECT id FROM dups WHERE rn > 1)
  RETURNING id
)
SELECT COUNT(*)::INT FROM del;
$$ LANGUAGE sql;

COMMENT ON FUNCTION dedup_tou_rates IS '清理 tou_rates 中完全重复的记录，每组保留 ID 最小的';

-- ----------------------------------------------------------------------------
-- 7b. 配置审计：audit_tou_config(geofence_id)
--     检查 3 类问题：每个季节的小时空缺/重叠 + 全年月份空缺
--     返回每条问题一行，没问题就返回 0 行（用户看到「✓ 配置完整」）
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- 7a. 一键 24 小时配置：apply_tou_pattern
--     接收一个 24 字符的「档位地图」串，自动合并相邻同档为时段写入
--     字符: G=谷 P=平 F=峰 J=尖 D=深谷（其他字符当跳过）
--     避免「漏小时 / 重叠 / 拼错段」三大坑
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_tou_pattern(
  p_geofence_id INT,
  p_pattern TEXT,
  p_rate_g  TEXT DEFAULT '0',  -- 谷
  p_rate_p  TEXT DEFAULT '0',  -- 平
  p_rate_f  TEXT DEFAULT '0',  -- 峰
  p_rate_j  TEXT DEFAULT '0',  -- 尖
  p_rate_d  TEXT DEFAULT '0',  -- 深谷
  p_from_month TEXT DEFAULT NULL,
  p_from_day   TEXT DEFAULT NULL,
  p_to_month   TEXT DEFAULT NULL,
  p_to_day     TEXT DEFAULT NULL
) RETURNS INT AS $$
DECLARE
  v_from DATE := _tou_md_to_date(p_from_month, p_from_day);
  v_to   DATE := _tou_md_to_date(p_to_month,   p_to_day);
  rate_g NUMERIC := _tou_clean_numeric(p_rate_g);
  rate_p NUMERIC := _tou_clean_numeric(p_rate_p);
  rate_f NUMERIC := _tou_clean_numeric(p_rate_f);
  rate_j NUMERIC := _tou_clean_numeric(p_rate_j);
  rate_d NUMERIC := _tou_clean_numeric(p_rate_d);
  pat TEXT := UPPER(COALESCE(NULLIF(p_pattern, ''), ''));
  inserted INT := 0;
BEGIN
  -- pattern 必须正好 24 字符
  IF LENGTH(pat) <> 24 THEN
    RAISE EXCEPTION '档位地图必须正好 24 字符（每位一小时），实际：% 字符', LENGTH(pat);
  END IF;

  -- 替换该 geofence 同季节范围的 AC 时段（_tou_delete_season 用 IS NOT DISTINCT FROM 处理 NULL）
  PERFORM _tou_delete_season(p_geofence_id, v_from, v_to);

  -- 合并相邻同档 → segments，批量插入
  -- 注：不做跨午夜合并（如串首尾都是 G），同档分两段写入不影响 compute_tou_cost 和审计
  -- 用户想合并跨夜，可在「✏️ 修改单价」之后用「🗑️ 删除」+「➕ 添加」手动调
  WITH chars AS (
    SELECT h.h AS hr, substr(pat, h.h + 1, 1) AS c
    FROM generate_series(0, 23) h(h)
  ),
  runs AS (
    SELECT hr, c,
      hr - ROW_NUMBER() OVER (PARTITION BY c ORDER BY hr) AS grp
    FROM chars
    WHERE c IN ('G', 'P', 'F', 'J', 'D')
  ),
  segments AS (
    SELECT MIN(hr) AS hs, MAX(hr) + 1 AS he, c,
      CASE c
        WHEN 'G' THEN rate_g WHEN 'P' THEN rate_p WHEN 'F' THEN rate_f
        WHEN 'J' THEN rate_j WHEN 'D' THEN rate_d
      END AS rate,
      CASE c
        WHEN 'G' THEN '谷' WHEN 'P' THEN '平' WHEN 'F' THEN '峰'
        WHEN 'J' THEN '尖' WHEN 'D' THEN '深谷'
      END AS label
    FROM runs
    GROUP BY c, grp
  ),
  ins AS (
    INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, valid_from, valid_to)
    SELECT p_geofence_id, hs, he, rate, label, v_from, v_to
    FROM segments
    WHERE rate > 0  -- 单价为 0 跳过（用户没填该档）
    RETURNING 1
  )
  SELECT COUNT(*) INTO inserted FROM ins;

  RETURN inserted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION apply_tou_pattern IS
'24 字符档位地图（G=谷 P=平 F=峰 J=尖 D=深谷）一键覆盖一个季节，自动合并相邻同档';

-- ----------------------------------------------------------------------------
-- 7c. 终极简化版：apply_tou_simple
--     用户只填「谷时段」「峰时段」+ 3 档单价 + 季节
--     平段 = 24h 自动减去谷+峰
--     时段串支持多段：'0-7, 23-24' 或 '22-7'（跨夜）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _tou_parse_ranges(p_str TEXT)
RETURNS TABLE(hr INT) AS $$
  -- 把 '0-7, 23-24' 这种串展开成所有覆盖的小时
  -- 跨夜 '22-7' 会展开成 22,23,0,1,...,6
  WITH parts AS (
    SELECT trim(unnest(string_to_array(COALESCE(NULLIF(NULLIF(p_str, ''), 'undefined'), ''), ','))) AS part
  ),
  ranges AS (
    SELECT
      NULLIF(trim(split_part(part, '-', 1)), '')::INT AS hs,
      NULLIF(trim(split_part(part, '-', 2)), '')::INT AS he
    FROM parts
    WHERE part ~ '^\s*\d+\s*-\s*\d+\s*$'
  )
  SELECT DISTINCT h.h
  FROM ranges r
  CROSS JOIN generate_series(0, 23) h(h)
  WHERE
    (r.hs < r.he AND h.h >= r.hs AND h.h < r.he)
    OR (r.hs > r.he AND (h.h >= r.hs OR h.h < r.he))
    OR (r.hs = 0 AND r.he = 24)
$$ LANGUAGE sql IMMUTABLE;

-- 旧版 8 参数 apply_tou_simple（不含 sharp/deep）→ 升级时清掉避免 overload 冲突
DROP FUNCTION IF EXISTS apply_tou_simple(INT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION apply_tou_simple(
  p_geofence_id INT,
  p_valley_ranges TEXT,
  p_valley_rate   TEXT,
  p_peak_ranges   TEXT DEFAULT '',
  p_peak_rate     TEXT DEFAULT '0',
  p_mid_rate      TEXT DEFAULT '0',
  p_sharp_ranges  TEXT DEFAULT '',  -- 尖
  p_sharp_rate    TEXT DEFAULT '0',
  p_deep_ranges   TEXT DEFAULT '',  -- 深谷
  p_deep_rate     TEXT DEFAULT '0',
  p_from_month TEXT DEFAULT NULL,
  p_from_day   TEXT DEFAULT NULL,
  p_to_month   TEXT DEFAULT NULL,
  p_to_day     TEXT DEFAULT NULL
) RETURNS INT AS $$
DECLARE
  rate_g NUMERIC := _tou_clean_numeric(p_valley_rate);
  rate_f NUMERIC := _tou_clean_numeric(p_peak_rate);
  rate_p NUMERIC := _tou_clean_numeric(p_mid_rate);
  rate_j NUMERIC := _tou_clean_numeric(p_sharp_rate);
  rate_d NUMERIC := _tou_clean_numeric(p_deep_rate);
  pat TEXT := repeat('P', 24);  -- 默认全平
  h INT;
BEGIN
  -- 优先级从低到高：深谷 → 谷 → 峰 → 尖（后写覆盖前）
  FOR h IN SELECT hr FROM _tou_parse_ranges(p_deep_ranges) LOOP
    pat := overlay(pat PLACING 'D' FROM h + 1 FOR 1);
  END LOOP;
  FOR h IN SELECT hr FROM _tou_parse_ranges(p_valley_ranges) LOOP
    pat := overlay(pat PLACING 'G' FROM h + 1 FOR 1);
  END LOOP;
  FOR h IN SELECT hr FROM _tou_parse_ranges(p_peak_ranges) LOOP
    pat := overlay(pat PLACING 'F' FROM h + 1 FOR 1);
  END LOOP;
  FOR h IN SELECT hr FROM _tou_parse_ranges(p_sharp_ranges) LOOP
    pat := overlay(pat PLACING 'J' FROM h + 1 FOR 1);
  END LOOP;

  -- 复用 apply_tou_pattern 完成合并 + 写入
  RETURN apply_tou_pattern(
    p_geofence_id, pat,
    rate_g::TEXT, rate_p::TEXT, rate_f::TEXT, rate_j::TEXT, rate_d::TEXT,
    p_from_month, p_from_day, p_to_month, p_to_day
  );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION apply_tou_simple IS
'5 档简化版：谷/峰/尖/深谷 时段 + 5 档单价，平段自动占剩余';

CREATE OR REPLACE FUNCTION audit_tou_config(p_geofence_id INT)
RETURNS TABLE(
  severity TEXT,
  season TEXT,
  detail TEXT
) AS $$
-- cfg = 这个充电点的慢充分时时段配置。**默认电价不在这里面**：设默认电价只会写
-- charging_process_cost_overrides，不会往 tou_rates 塞一条 24 小时规则（早期版本会，
-- 那条规则会把超充等真实账单顶掉）。所以「只设了默认电价」的用户 cfg 是空的，
-- 这不是故障，下面单独给一行说明，而不是报 12 个月全部空缺。
WITH cfg AS (
  SELECT r.*
  FROM tou_rates r
  WHERE r.geofence_id IS NOT DISTINCT FROM p_geofence_id
    AND r.apply_to_dc = FALSE
),
expanded AS (
  -- 把每条时段配置展开成 (hour, season_key)
  SELECT
    r.id,
    r.label,
    r.rate,
    CASE
      WHEN r.valid_from IS NULL AND r.valid_to IS NULL THEN '全年'
      ELSE COALESCE(to_char(r.valid_from, 'MM/DD'), '?') || ' ~ ' ||
           COALESCE(to_char(r.valid_to,   'MM/DD'), '?')
    END AS season_key,
    h.hr
  FROM cfg r
  CROSS JOIN generate_series(0, 23) h(hr)
  WHERE (
      (r.hour_start < r.hour_end AND h.hr >= r.hour_start AND h.hr < r.hour_end)
      OR (r.hour_start > r.hour_end AND (h.hr >= r.hour_start OR h.hr < r.hour_end))
      OR (r.hour_start = 0 AND r.hour_end = 24)
    )
),
seasons AS (
  SELECT DISTINCT season_key FROM expanded
),
gaps AS (
  SELECT s.season_key, h.hr
  FROM seasons s
  CROSS JOIN generate_series(0, 23) h(hr)
  WHERE NOT EXISTS (
    SELECT 1 FROM expanded e WHERE e.season_key = s.season_key AND e.hr = h.hr
  )
),
overlap_rows AS (
  SELECT season_key, hr, COUNT(*) AS n,
         array_agg(id ORDER BY id) AS ids,
         array_agg(DISTINCT rate)  AS rates
  FROM expanded
  GROUP BY season_key, hr
  HAVING COUNT(*) > 1
),
month_check AS (
  -- 12 个月里，哪些月份在该 geofence 有任何 rate 匹配
  SELECT m.mo,
    EXISTS (
      SELECT 1 FROM cfg r
      WHERE _tou_in_season(make_date(2024, m.mo, 15), r.valid_from, r.valid_to)
    ) AS has_rate
  FROM generate_series(1, 12) m(mo)
)
-- 1) 时段空缺
SELECT
  '⚠ 时段空缺'::TEXT,
  season_key,
  '缺 ' || string_agg(hr || '点', ', ' ORDER BY hr) || '（共 ' || COUNT(*) || ' 小时）'
FROM gaps
GROUP BY season_key
UNION ALL
-- 2) 时段重叠（同小时多条覆盖）
SELECT
  '⚠ 时段重叠'::TEXT,
  season_key,
  hr || ' 点被 ' || n || ' 条覆盖（ID: ' || array_to_string(ids, ', ') ||
  CASE WHEN array_length(rates, 1) > 1 THEN '，单价不一致：' || array_to_string(rates, ', ') ELSE '' END || '）'
FROM overlap_rows
UNION ALL
-- 3) 月份空缺（整月没落入任何季节）
--    只在「确实配了时段」时才检查。一条都没配的时候整年当然都是空的，
--    报 12 个月空缺只会把人吓一跳，真正该说的是下面那句。
SELECT
  '⚠ 月份空缺'::TEXT,
  '-'::TEXT,
  '没配置：' || string_agg(mo || '月', ', ' ORDER BY mo)
FROM month_check
WHERE NOT has_rate
  AND EXISTS (SELECT 1 FROM cfg)
GROUP BY ()  -- 空 GROUP BY = 单个聚合行；当无空缺月时返回 0 行
HAVING COUNT(*) > 0
UNION ALL
-- 4) 压根没配分时时段：给一句人话，别让人以为功能坏了
SELECT
  'ℹ 未配分时时段'::TEXT,
  '-'::TEXT,
  '这个充电点还没有配置峰谷时段，所以上面的「24 小时电价分布」是空的。'
  || '如果你只设了一个统一的默认电价，这就是正常状态——充电费用按默认电价计算，'
  || '不需要配时段。想按峰谷分别计价，用上面的「一键填一整季节」或城市模板配一次即可。'
WHERE NOT EXISTS (SELECT 1 FROM cfg);
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION audit_tou_config(INT) IS
'返回 TOU 配置审计：时段空缺、时段重叠、月份空缺；一条时段都没配时返回一行说明。0 行=配置完整';

-- ----------------------------------------------------------------------------
-- 8. 一键回填：用户改了 tou_rates 后跑 SELECT backfill_all_tou()
--    历史所有完成的充电会用新 rate 重算
-- ----------------------------------------------------------------------------
-- 返回的五个计数各自是一件事，不要混着看：
--   processed 扫过的充电笔数
--   updated   算出了分时电价费用并写进旁路表
--   skipped   这笔没有任何分时电价规则适用（你没配分时时段，或者只配了别的充电点/别的
--             充放类型）——属于正常情况，费用按默认电价或 TeslaMate 原值显示
--   gapped    有规则、但这笔充电有时段没被覆盖到，算不出可信金额
--   cleared   上面 gapped 这批里，清掉了多少条**以前算出来的旧值**。这个数不为 0 说明
--             你库里原本存着一批算错的费用，现在它们被清掉了，界面上的数字会变
--   failed    计算时报错的笔数（正常应为 0，出现时看数据库日志里的 WARNING）
-- 老实现把 skipped / gapped / failed 全并成一个 skipped，于是「你没配」和「你配漏了」
-- 在提示里长得一模一样，后者恰恰是需要用户回去补配置的那种。
--
-- 返回的列变多了，CREATE OR REPLACE 改不了返回类型（会报 cannot change return type），
-- 升级的用户必须先把旧的那个删掉。
DROP FUNCTION IF EXISTS backfill_all_tou();

CREATE OR REPLACE FUNCTION backfill_all_tou()
RETURNS TABLE(processed INT, updated INT, skipped INT, gapped INT, cleared INT, failed INT) AS $$
DECLARE
  total INT := 0;
  done INT := 0;
  skip INT := 0;
  gap INT := 0;
  clr INT := 0;
  err INT := 0;
  removed INT;
  cp_record RECORD;
  computed NUMERIC;
BEGIN
  FOR cp_record IN
    SELECT id FROM charging_processes WHERE end_date IS NOT NULL ORDER BY id
  LOOP
    total := total + 1;
    BEGIN
      computed := compute_tou_cost(cp_record.id);
      IF computed IS NOT NULL THEN
        INSERT INTO charging_processes_tou_cost (charging_process_id, cost_tou, computed_at)
        VALUES (cp_record.id, computed, NOW())
        ON CONFLICT (charging_process_id) DO UPDATE
        SET cost_tou = EXCLUDED.cost_tou,
            computed_at = NOW();
        done := done + 1;
      ELSE
        -- 算不出来就得把旧值清掉，理由同 trigger_compute_tou()：留着等于让用户一直看
        -- 一个已知算错的数，而且「重算历史」按钮点多少次都不会变。
        DELETE FROM charging_processes_tou_cost WHERE charging_process_id = cp_record.id;
        GET DIAGNOSTICS removed = ROW_COUNT;
        clr := clr + removed;
        IF _tou_has_matching_rate(cp_record.id) THEN
          gap := gap + 1;
        ELSE
          skip := skip + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      err := err + 1;
      RAISE WARNING '分时电价回算失败 cp_id=%，已跳过：%', cp_record.id, SQLERRM;
    END;
  END LOOP;
  processed := total;
  updated := done;
  skipped := skip;
  gapped := gap;
  cleared := clr;
  failed := err;
  RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 8b. 一键卸载：uninstall_tou() — 把所有 tou_* / charging_processes_v 一次拆掉
--     用 pg_proc 自动找函数，避免手工列表跟实现漂移
--     ⚠ CASCADE 会删掉所有依赖 tou_rates / charging_processes_tou_cost 的对象
--       （包括用户自己建的视图）— 卸载前先 \d+ tou_rates 看 referenced by 列表
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION uninstall_tou() RETURNS TEXT AS $$
DECLARE
  r RECORD;
  cnt INT := 0;
  restored INT := 0;
BEGIN
  -- 1. 触发器
  --    必须第一步就摘掉：下一步要写 charging_processes.cost，触发器还在的话会顺手
  --    往马上就要被删的旁路表里塞值，白做功还可能报错。
  DROP TRIGGER IF EXISTS tou_recalc ON charging_processes;

  -- 2. 把「搬过来的 TeslaMate 原值」还回去
  --    adopt_legacy_default_costs() 会把原表里的费用挪进覆盖表、原位置清空，
  --    覆盖表是那个值当时唯一的落脚点。直接删表 = 把 TeslaMate 自己的数据一起删了，
  --    与「卸载之后费用完全回到 TeslaMate 自己的数据」正好相反。
  --    只还 original_cost 不为空的行、而且还的是 original_cost 而不是 cost：
  --    cost 可能已经被「改默认电价」重算过、被「手工指定单价」覆盖过，还回去就成了
  --    我们算的数冒充 TeslaMate 的记录。默认电价 / 手工单价生成的行 original_cost 是空的，
  --    它们本就不属于 TeslaMate 的记录，随表消失即可。
  --    cp.cost IS NULL 的条件是防覆盖：期间用户自己填过金额就以他填的为准。
  UPDATE charging_processes cp
  SET cost = o.original_cost
  FROM charging_process_cost_overrides o
  WHERE o.charging_process_id = cp.id
    AND o.original_cost IS NOT NULL
    AND cp.cost IS NULL;
  GET DIAGNOSTICS restored = ROW_COUNT;

  -- 3. 视图
  DROP VIEW IF EXISTS charging_processes_v CASCADE;

  -- 4. 旁路表 + 配置表（CASCADE 会一并删依赖的所有视图/约束/外键）
  DROP TABLE IF EXISTS charging_processes_tou_cost CASCADE;
  -- 覆盖表也要删：卸载之后费用显示应当完全回到 TeslaMate 自己的数据。
  -- 这正是当初直接写原表做不到的事——那些值留在 charging_processes 里，卸载也带不走。
  DROP TABLE IF EXISTS charging_process_cost_overrides CASCADE;
  DROP TABLE IF EXISTS tou_rates CASCADE;

  -- 5. 全部 tou_* / _tou_* / *_tou_* 函数（除 uninstall_tou 自己）
  --    名字里没有 tou 的（effective_cost / cost_before_tou / adopt_legacy_default_costs 等）
  --    必须写进下面这份显式名单，否则卸载完还会剩函数，而它们引用的表已经没了。
  FOR r IN
    SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (p.proname LIKE 'tou\_%'
        OR p.proname LIKE '\_tou\_%'
        OR p.proname IN ('compute_tou_cost', 'effective_cost', 'cost_before_tou',
                         'lookup_tou_rate', 'apply_city_template', 'audit_tou_config',
                         'dedup_tou_rates', 'backfill_all_tou', 'trigger_compute_tou',
                         'adopt_legacy_default_costs', 'list_city_templates',
                         'set_default_charging_rate', 'set_tou_batch',
                         'apply_tou_pattern', 'apply_tou_simple'))
      AND p.proname <> 'uninstall_tou'
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE',
                   r.nspname, r.proname, r.args);
    cnt := cnt + 1;
  END LOOP;

  RETURN format('已卸载 %s 个函数 + tou_rates / charging_processes_tou_cost 表 + 视图 + 触发器；%s 笔曾被搬走的费用已写回 TeslaMate 记录。', cnt, restored);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION uninstall_tou IS
'一键卸载分时电价系统。装回去：重跑 install-tou.sql。卸载本身：DROP FUNCTION uninstall_tou()';

-- ----------------------------------------------------------------------------
-- 8c. 城市模板元数据：list_city_templates() — 给脚本/UI 动态查城市列表
--     install-tou.sql 是城市的单一数据源；setup-tou.sh / tou-wizard.sh / build-*.py 都从这里查
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION list_city_templates() RETURNS TABLE (
  city_id TEXT,
  display_name TEXT
) AS $$
  SELECT * FROM (VALUES
    ('beijing',   '北京'),
    ('shanghai',  '上海'),
    ('shenzhen',  '深圳'),
    ('guangzhou', '广州'),
    ('zhejiang',  '浙江/杭州'),
    ('jiangsu',   '江苏/南京（含夏冬尖峰）'),
    ('wuhan',     '武汉')
  ) AS t(city_id, display_name);
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION list_city_templates IS
'分时电价城市模板列表，跟 apply_city_template() 的 CASE 分支同步';

-- ----------------------------------------------------------------------------
-- 9. set_default_charging_rate — 一键设默认电价
--
-- 用法：
--   SELECT * FROM set_default_charging_rate(1.0);
-- 行为：
--   - 给「TeslaMate 没有费用、且不在任何地理围栏内」的已完成充电写一行 default 覆盖
--     （charging_process_cost_overrides），cost = ROUND(kWh × p_rate, 2)
--   - **不写 tou_rates**：默认电价不是分时电价
--   - **不动 charging_processes.cost**：TeslaMate 的原值、用户手工指定的价格都不受影响
--
-- 早期实现是直接 UPDATE 原表的，那样一旦写下去就分不清费用来源、改默认价历史不跟着变、
-- 卸载也恢复不了。改成覆盖表之后这三件事都成立了（见 charging_process_cost_overrides）。
--
-- 【为什么不再往 tou_rates 写「0-24 点全天 p_rate」的 AC/DC 两条规则】
-- 那两条规则一写下去，就等于告诉系统「所有充电、所有时段都按这个价」。触发器于是给
-- **每一笔**充电都算出一个分时电价值写进旁路表，而分时电价的优先级高于 TeslaMate 原值——
-- 结果是超充这种桩侧已经报了真实金额的充电，账单 120 元、界面显示 7 元。用户设的是
-- 「没有更好信息时按这个价估」，拿到的却是「用这个价覆盖掉所有真实账单」。
-- 现在默认电价只写覆盖表，优先级排在 TeslaMate 原值之上、分时电价之下，
-- 只对真正没有费用的记录生效；tou_rates 里有规则，就说明用户真的配过分时时段。
-- ----------------------------------------------------------------------------
-- 早期版本写进 tou_rates 的那两条「默认」全天规则的清理函数。
-- 标签是我们自己写死的，只有 set_default_charging_rate 会产生，按标签认得准；
-- 同时限定全局（geofence NULL）、0-24 点、无季节，避免误伤用户手配的规则。
--
-- 谁在调：安装/升级时跑一次（本文件 9c 节），以及**每一次**设置默认电价时都跑。
-- 不是「升级时的一次性清理」——用户可能先升级、再从老备份恢复库，或者手工把那两条
-- 规则加了回来，每次设价都查一遍才挡得住。
-- 返回删掉的条数：这是在删用户数据库里的行，调用方必须把它讲给用户听，不许静默吞掉。
CREATE OR REPLACE FUNCTION _tou_drop_legacy_default_rates() RETURNS INT AS $$
DECLARE
  n INT;
BEGIN
  DELETE FROM tou_rates
  WHERE geofence_id IS NULL
    AND hour_start = 0 AND hour_end = 24
    AND valid_from IS NULL AND valid_to IS NULL
    AND label IN ('默认(AC)', '默认(DC)');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION set_default_charging_rate(p_rate NUMERIC)
RETURNS TABLE(message TEXT) AS $$
DECLARE
  v_updated_cp INT;
  v_dropped_rules INT;
  v_note TEXT := '';
BEGIN
  IF p_rate IS NULL OR p_rate <= 0 THEN
    RETURN QUERY SELECT '❌ 默认电价必须 > 0'::TEXT;
    RETURN;
  END IF;

  -- 老版本在这里写过两条全天规则，把它们清掉（见上面的说明）。
  -- 删的是用户数据库里的行，删了就得说——把条数接进下面的返回消息，
  -- 没删到就一个字都不多讲，别给正常路径添噪音。
  v_dropped_rules := _tou_drop_legacy_default_rates();
  IF v_dropped_rules > 0 THEN
    v_note := format(
      '｜⚠ 顺带清理：发现并移除了 %s 条由旧版「默认电价」写进分时电价表的全天规则。'
      || '那些规则会让所有充电都按这个统一电价重算，把 TeslaMate 自己报的充电金额（比如超充账单）顶掉；'
      || '移除之后，统一电价只用在 TeslaMate 没有金额的充电上。'
      || '你自己配的峰谷时段不受影响。',
      v_dropped_rules);
  END IF;

  -- 写覆盖表，不碰 charging_processes.cost（见 charging_process_cost_overrides 注释）。
  -- 用 GREATEST(charge_energy_added, charge_energy_used) 与 charges 仪表盘「电价」列
  -- （cost / GREATEST(added, used)）的算法一致，让用户看到的「电价」就是 p_rate；
  -- charge_energy_used 是充电桩输出（含损耗），通常 > charge_energy_added（车实际收到）。
  --
  -- 只覆盖 TeslaMate 自己没有费用的记录（cost IS NULL）：它报了实际费用的，那是比
  -- 我们的估算更好的数据，不该被一口价盖掉。
  --
  -- ON CONFLICT DO UPDATE 是这次改动顺带修掉的一个老毛病：以前写进原表之后
  -- cost 就不再是 NULL，用户第二次改默认电价时那些历史记录不会跟着变，只有新充电才用新价。
  -- 现在改一次默认价，所有由默认价生成的记录都会重算——手工指定的那些不受影响。
  INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate, updated_at)
  SELECT cp.id,
         ROUND((GREATEST(cp.charge_energy_added, cp.charge_energy_used) * p_rate)::NUMERIC, 2),
         'default', p_rate, NOW()
  FROM charging_processes cp
  WHERE cp.geofence_id IS NULL
    AND cp.end_date IS NOT NULL
    AND (cp.charge_energy_added IS NOT NULL OR cp.charge_energy_used IS NOT NULL)
    AND cp.cost IS NULL
  ON CONFLICT (charging_process_id) DO UPDATE
    SET cost = EXCLUDED.cost, rate = EXCLUDED.rate, updated_at = NOW()
    -- 手工指定过的那笔不动：用户明确表达过意图，默认价不该覆盖它
    WHERE charging_process_cost_overrides.source = 'default';
  GET DIAGNOSTICS v_updated_cp = ROW_COUNT;

  RETURN QUERY SELECT format('✅ 默认电价 %s 元/度 已保存。按此价计费的充电记录：%s 笔（TeslaMate 已经报了金额的充电、以及你手工指定过价格的充电，都不受影响）%s', p_rate, v_updated_cp, v_note);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION set_default_charging_rate IS
'tou-config 仪表盘调此函数。设默认电价 = 为无费用的充电写入 default 覆盖（不写 tou_rates、不改 TeslaMate 原表）';

-- ----------------------------------------------------------------------------
-- 9b. adopt_legacy_default_costs(p_old_rate) — 把早期写进原表的默认电价搬进覆盖表
--
-- 给谁用：在「默认电价」还会直接改 charging_processes.cost 的版本上用过这个功能的人。
-- 那些值现在还留在原表里，表现是：改默认电价时它们不跟着变，卸载也带不走。
--
-- 怎么做到安全：只认**算得出来**的行——cost 恰好等于 ROUND(kWh × 你给的旧电价, 2)，
-- 且这笔充电不在任何地理围栏内。能对上这个乘法的行才是我们当年写的；对不上的一律不碰
-- （TeslaMate 自己报的费用、你手工改过的值，都不满足这个等式）。
-- 认出来之后：把值搬进覆盖表（source='default'，同时把原值抄进 original_cost 列备份），
-- 并把原表恢复成 NULL——也就是我们写入之前的样子。
--
-- 用法（p_old_rate 填你当初设的那个默认电价）：
--   SELECT * FROM adopt_legacy_default_costs(1.0);
-- 先看会动多少行、不实际修改：
--   SELECT * FROM adopt_legacy_default_costs(1.0, TRUE);
--
-- ============================================================================
-- 这个函数曾经有三条会让数据永久消失的路径，逐条记下来免得再犯：
--
-- ① 已经有覆盖值的那笔，原值被抹掉了。
--    老写法是 INSERT ... ON CONFLICT DO NOTHING 之后，**无条件**
--    UPDATE charging_processes SET cost = NULL。你要是先给某笔手工指定过价格，
--    INSERT 会被 DO NOTHING 跳过，UPDATE 却照样把原表清空——于是 TeslaMate 的原始金额
--    哪儿都不存在了，连这个函数自己都搬不回来。现在改成一条语句里
--    INSERT ... RETURNING，只有**真正插进去的那些行**才会被清空原表。
--
-- ② 零电量的记录会被任何电价「认领」。
--    判据是 cost = ROUND(kWh × rate, 2)。电量为 0 时两边都是 0，等式恒成立，
--    于是一笔 charge_energy_added=0 / cost=0 的记录，填 999 元/度也能对上、也会被清空。
--    现在要求 kWh > 0：电量为 0 就不存在「按电价算出来的费用」这回事。
--
-- ③ 卸载会把搬过来的原值一起删掉。
--    uninstall_tou() 会 DROP 掉覆盖表。搬迁之后 TeslaMate 的原值只存在于那张表里，
--    卸载等于把它删了，与「卸载之后费用完全回到 TeslaMate 自己的数据」正好相反。
--    现在搬过来的行会把原值抄一份进 original_cost 列，uninstall_tou() 删表之前先照着
--    这一列把值写回 charging_processes.cost（详见那个函数）。
--
-- 另外两处：试算报的是候选笔数而不是真会动的笔数（已有覆盖值的那些其实动不了）；
-- 以及老写法用 CREATE TEMP TABLE ... ON COMMIT DROP，同一个事务里调第二次直接报
-- relation already exists——而文档正是教用户「先试算再执行」。现在整个函数不建临时表，
-- 一条 CTE 语句搞定，连着调多少次都行。
-- ============================================================================
CREATE OR REPLACE FUNCTION adopt_legacy_default_costs(
  p_old_rate NUMERIC,
  p_dry_run BOOLEAN DEFAULT FALSE
) RETURNS TABLE(message TEXT) AS $$
DECLARE
  v_movable INT;
  v_blocked INT;
  v_moved INT;
BEGIN
  IF p_old_rate IS NULL OR p_old_rate <= 0 THEN
    RETURN QUERY SELECT '请提供你当初设置的默认电价，例如：SELECT * FROM adopt_legacy_default_costs(1.0);'::TEXT;
    RETURN;
  END IF;

  IF p_dry_run THEN
    SELECT
      count(*) FILTER (WHERE o.charging_process_id IS NULL),
      count(*) FILTER (WHERE o.charging_process_id IS NOT NULL)
    INTO v_movable, v_blocked
    FROM charging_processes cp
    LEFT JOIN charging_process_cost_overrides o ON o.charging_process_id = cp.id
    WHERE cp.geofence_id IS NULL
      AND cp.end_date IS NOT NULL
      AND cp.cost IS NOT NULL
      AND GREATEST(cp.charge_energy_added, cp.charge_energy_used) > 0
      AND cp.cost = ROUND((GREATEST(cp.charge_energy_added, cp.charge_energy_used) * p_old_rate)::NUMERIC, 2);

    RETURN QUERY SELECT format(
      '试算：有 %s 笔充电的费用与「%s 元/度」完全吻合，会被搬进覆盖表并把原始费用恢复为空；另有 %s 笔虽然对得上、但你已经给它们指定过价格，不会被动。去掉第二个参数即可实际执行。',
      v_movable, p_old_rate, v_blocked);
    RETURN;
  END IF;

  -- 一条语句里搬完：INSERT 的 RETURNING 只吐出**确实插进去**的 id，
  -- UPDATE 只清这些 id 的原表值。已有覆盖值的行连碰都不碰，原值留在 TeslaMate 记录里。
  --
  -- 这里的 UPDATE 会触发 tou_recalc。默认电价不再往 tou_rates 写规则之后，没配分时时段
  -- 的用户不会因此被钉上任何分时电价值（compute_tou_cost 直接返回 NULL）；真的配过分时
  -- 时段、而且规则覆盖到这笔充电的用户会拿到一个分时电价值——按既定优先级它本来就该
  -- 压过默认电价，是预期行为，不是这次搬迁的副作用。
  WITH hits AS (
    SELECT cp.id, cp.cost
    FROM charging_processes cp
    WHERE cp.geofence_id IS NULL
      AND cp.end_date IS NOT NULL
      AND cp.cost IS NOT NULL
      AND GREATEST(cp.charge_energy_added, cp.charge_energy_used) > 0
      AND cp.cost = ROUND((GREATEST(cp.charge_energy_added, cp.charge_energy_used) * p_old_rate)::NUMERIC, 2)
  ),
  ins AS (
    INSERT INTO charging_process_cost_overrides
      (charging_process_id, cost, source, rate, updated_at, original_cost)
    -- cost 和 original_cost 一开始是同一个数，但用途不同：cost 是「现在显示多少钱」，
    -- 以后改默认电价会跟着重算；original_cost 是「TeslaMate 记录里原本是多少钱」，
    -- 谁都不许改，卸载时按它还原。
    SELECT h.id, h.cost, 'default', p_old_rate, NOW(), h.cost FROM hits h
    ON CONFLICT (charging_process_id) DO NOTHING
    RETURNING charging_process_id
  ),
  upd AS (
    UPDATE charging_processes cp SET cost = NULL
    FROM ins WHERE cp.id = ins.charging_process_id
    RETURNING cp.id
  )
  SELECT count(*)::INT INTO v_moved FROM upd;

  RETURN QUERY SELECT format('✅ 已把 %s 笔按「%s 元/度」生成的费用搬进覆盖表，TeslaMate 原始记录恢复为空。以后改默认电价，这些记录会跟着重算；卸载分时电价功能时，这些值会原样写回 TeslaMate 记录。', v_moved, p_old_rate);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION adopt_legacy_default_costs IS
'把早期版本写进 charging_processes.cost 的默认电价搬进覆盖表；只动能被电价算式认出来的行，卸载时可原样还原';

-- ----------------------------------------------------------------------------
-- 9c. 升级清理：把早期版本因「设默认电价」而写进 tou_rates 的两条全天规则清掉
--
-- 只装一次的用户看不到这段（没有那两条规则，什么都不会发生）。升级上来的用户会命中：
-- 那两条规则让每一笔充电都算得出「分时电价费用」，而分时电价优先级高于 TeslaMate 原值，
-- 超充这类桩侧已报真实金额的充电就会被一口价顶掉（实测：账单 120 元、界面显示 7 元）。
-- 光删规则不够——之前算出来的值还留在旁路表里，照样顶。所以删完立刻回算一遍：
-- backfill_all_tou() 现在算不出结果时会把旧值删掉，正好把这批脏值清干净。
-- ----------------------------------------------------------------------------
DO $legacy_default$
DECLARE
  n INT;
  r RECORD;
BEGIN
  n := _tou_drop_legacy_default_rates();
  IF n > 0 THEN
    RAISE NOTICE '已清理 % 条由「默认电价」写进分时电价表的全天规则。', n;
    RAISE NOTICE '  默认电价从此只作用于 TeslaMate 没有金额的充电，不再覆盖超充等真实账单。';
    SELECT * INTO r FROM backfill_all_tou();
    RAISE NOTICE '  重算历史：扫描 % 笔，按分时电价计费 % 笔，清除按旧规则算出的费用 % 笔。',
                 r.processed, r.updated, r.cleared;
  END IF;
END
$legacy_default$;

-- ----------------------------------------------------------------------------
-- 10. 自检：函数装好但需要用户配 tou_rates 才能算
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  RAISE NOTICE 'TOU 函数已装好。下一步：';
  RAISE NOTICE '  1. INSERT INTO tou_rates 配置你的峰平谷时段';
  RAISE NOTICE '  2. SELECT compute_tou_cost(<charging_process_id>) 测试';
  RAISE NOTICE '  3. 若返回 NULL → tou_rates 配置缺失或匹配不上';
END $$;
