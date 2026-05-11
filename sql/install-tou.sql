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
  WHERE geofence_id = p_geofence_id
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
-- 4. 核心：compute_tou_cost(cp_id) — 单笔 TOU 实际费用
--    返回 NULL 表示无 tou_rates 配置（用户未启用 TOU），调用方应回退到原 cost
--
-- 算法：「按比例分配」防止 sum(power×dt) ≠ charge_energy_added 的积分误差
--   weighted_rate = SUM(raw_kwh × rate) / SUM(raw_kwh)
--   tou_cost = charge_energy_added × weighted_rate
--   即先在各时段算占比，再乘以 TeslaMate 报告的真实总 kWh，总数严格守恒
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
  SELECT geofence_id, charge_energy_added INTO cp_geofence_id, actual_kwh
  FROM charging_processes WHERE id = cp_id;

  IF actual_kwh IS NULL OR actual_kwh = 0 THEN RETURN 0; END IF;

  -- 检测 AC/DC：charges.charger_phases NULL 表 DC，非 NULL 表 AC
  SELECT NOT bool_or(charger_phases IS NOT NULL) INTO is_dc
  FROM charges WHERE charging_process_id = cp_id;

  -- 配置完整性检查：是否有任一 rate 能匹配此次充电
  SELECT EXISTS (
    SELECT 1 FROM tou_rates
    WHERE (geofence_id = cp_geofence_id OR geofence_id IS NULL)
      AND (CASE WHEN is_dc THEN apply_to_dc ELSE NOT apply_to_dc END)
  ) INTO has_any_rate;

  IF NOT has_any_rate THEN RETURN NULL; END IF;  -- 用户没配 → 回退原 cost

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
  SELECT
    CASE WHEN SUM(raw_kwh) = 0 THEN NULL
         ELSE SUM(raw_kwh * COALESCE(rate, 0)) / SUM(raw_kwh)
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
  DELETE FROM tou_rates WHERE geofence_id = target_geofence_id AND apply_to_dc = FALSE;

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
    -- compute 返回 NULL = 用户未配 TOU，不写入旁路（视图就 fallback 原 cost）
    IF computed IS NOT NULL THEN
      INSERT INTO charging_processes_tou_cost (charging_process_id, cost_tou, computed_at)
      VALUES (NEW.id, computed, NOW())
      ON CONFLICT (charging_process_id) DO UPDATE
      SET cost_tou = EXCLUDED.cost_tou,
          computed_at = NOW();
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
CREATE OR REPLACE VIEW charging_processes_v AS
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
LEFT JOIN charging_processes_tou_cost t ON t.charging_process_id = cp.id;

COMMENT ON VIEW charging_processes_v IS 'TeslaMate 中文版独家：暴露 cost_effective 让所有仪表盘自动按 TOU 显示真实费用';

-- ----------------------------------------------------------------------------
-- 7e. effective_cost(cp_id, fallback) — 让 dashboards 透明拿到 TOU 计算后的 cost
--     旁路表里有 → 返回 cost_tou；没有 → 回退原 cost
--     函数调用不破坏 PK 函数依赖，所以 GROUP BY cp.id 的 SQL 也能用
--     回滚：TRUNCATE charging_processes_tou_cost → 函数自动 fallback 原 cost
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION effective_cost(cp_id INT, fallback NUMERIC) RETURNS NUMERIC AS $$
  SELECT COALESCE(
    (SELECT cost_tou FROM charging_processes_tou_cost WHERE charging_process_id = cp_id),
    fallback
  )
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION effective_cost IS
'透明 TOU cost：旁路表有则返回 TOU 值，否则回退原 cost。dashboards 用 effective_cost(cp.id, cp.cost) 替代 cp.cost 即可';

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
WITH expanded AS (
  -- 把每条 tou_rates 展开成 (hour, season_key)
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
  FROM tou_rates r
  CROSS JOIN generate_series(0, 23) h(hr)
  WHERE r.geofence_id = p_geofence_id
    AND r.apply_to_dc = FALSE
    AND (
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
      SELECT 1 FROM tou_rates r
      WHERE r.geofence_id = p_geofence_id
        AND r.apply_to_dc = FALSE
        AND _tou_in_season(make_date(2024, m.mo, 15), r.valid_from, r.valid_to)
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
SELECT
  '⚠ 月份空缺'::TEXT,
  '-'::TEXT,
  '没配置：' || string_agg(mo || '月', ', ' ORDER BY mo)
FROM month_check
WHERE NOT has_rate
GROUP BY ()  -- 空 GROUP BY = 单个聚合行；当无空缺月时返回 0 行
HAVING COUNT(*) > 0;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION audit_tou_config(INT) IS
'返回 TOU 配置审计：时段空缺、时段重叠、月份空缺。0 行=配置完整';

-- ----------------------------------------------------------------------------
-- 8. 一键回填：用户改了 tou_rates 后跑 SELECT backfill_all_tou()
--    历史所有完成的充电会用新 rate 重算
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backfill_all_tou()
RETURNS TABLE(processed INT, updated INT, skipped INT) AS $$
DECLARE
  total INT := 0;
  done INT := 0;
  skip INT := 0;
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
        skip := skip + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      skip := skip + 1;
    END;
  END LOOP;
  processed := total;
  updated := done;
  skipped := skip;
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
BEGIN
  -- 1. 触发器
  DROP TRIGGER IF EXISTS tou_recalc ON charging_processes;

  -- 2. 视图
  DROP VIEW IF EXISTS charging_processes_v CASCADE;

  -- 3. 旁路表 + 配置表（CASCADE 会一并删依赖的所有视图/约束/外键）
  DROP TABLE IF EXISTS charging_processes_tou_cost CASCADE;
  DROP TABLE IF EXISTS tou_rates CASCADE;

  -- 4. 全部 tou_* / _tou_* / *_tou_* 函数（除 uninstall_tou 自己）
  FOR r IN
    SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (p.proname LIKE 'tou\_%'
        OR p.proname LIKE '\_tou\_%'
        OR p.proname IN ('compute_tou_cost', 'effective_cost', 'lookup_tou_rate',
                         'apply_city_template', 'audit_tou_config', 'dedup_tou_rates',
                         'backfill_all_tou', 'trigger_compute_tou'))
      AND p.proname <> 'uninstall_tou'
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE',
                   r.nspname, r.proname, r.args);
    cnt := cnt + 1;
  END LOOP;

  RETURN format('已卸载 %s 个函数 + tou_rates / charging_processes_tou_cost 表 + 视图 + 触发器。', cnt);
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
    ('jiangsu',   '江苏/南京（含夏冬尖峰）')
  ) AS t(city_id, display_name);
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION list_city_templates IS
'分时电价城市模板列表，跟 apply_city_template() 的 CASE 分支同步';

-- ----------------------------------------------------------------------------
-- 9. set_default_charging_rate — 一键设默认电价（v1.7.3+ 新增）
--
-- 设计：tou_rates 系统设计了 TOU 旁路表 + 视图 charging_processes_v.cost_effective，
-- 但项目 dashboards 没有 join 旁路表（v1.8 待办）。在那之前，最实用的方式是
-- 当用户设默认电价时，同时**直接 UPDATE charging_processes.cost**（仅填 cost IS NULL
-- 且 geofence_id IS NULL 的充电），这样 charges 等已有仪表盘自动显示费用，
-- 不需要先大改 6 个 SQL。
--
-- 用法：
--   SELECT * FROM set_default_charging_rate(1.0);
-- 行为：
--   - tou_rates 写两行 (AC + DC，apply_to_dc=FALSE/TRUE)，rate 都用 p_rate
--   - 已有的默认行用 ON CONFLICT 覆盖（更新 rate）
--   - UPDATE charging_processes SET cost = ROUND(kWh × p_rate, 2)
--     WHERE geofence_id IS NULL AND cost IS NULL AND end_date IS NOT NULL
--   - 不覆盖 TeslaMate 已算的 / 用户手填的 cost
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_default_charging_rate(p_rate NUMERIC)
RETURNS TABLE(message TEXT) AS $$
DECLARE
  v_updated_cp INT;
BEGIN
  IF p_rate IS NULL OR p_rate <= 0 THEN
    RETURN QUERY SELECT '❌ 默认电价必须 > 0'::TEXT;
    RETURN;
  END IF;

  -- AC 默认行
  INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, apply_to_dc)
  VALUES (NULL, 0, 24, p_rate, '默认(AC)', FALSE)
  ON CONFLICT (COALESCE(geofence_id, -1), hour_start, hour_end,
               COALESCE(valid_from, '0001-01-01'::DATE),
               COALESCE(valid_to, '9999-12-31'::DATE), apply_to_dc)
  DO UPDATE SET rate = EXCLUDED.rate, label = EXCLUDED.label;

  -- DC 默认行
  INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, apply_to_dc)
  VALUES (NULL, 0, 24, p_rate, '默认(DC)', TRUE)
  ON CONFLICT (COALESCE(geofence_id, -1), hour_start, hour_end,
               COALESCE(valid_from, '0001-01-01'::DATE),
               COALESCE(valid_to, '9999-12-31'::DATE), apply_to_dc)
  DO UPDATE SET rate = EXCLUDED.rate, label = EXCLUDED.label;

  -- 把所有 cost IS NULL 且 geofence_id IS NULL 的已完成充电填上 cost
  -- 用 GREATEST(charge_energy_added, charge_energy_used) 与 charges 仪表盘「电价」
  -- 列（cost / GREATEST(added, used)）的算法一致，让用户看到的「电价」就是 p_rate
  -- charge_energy_used 是充电桩输出（含损耗），通常 > charge_energy_added（车实际收到）
  UPDATE charging_processes
  SET cost = ROUND((GREATEST(charge_energy_added, charge_energy_used) * p_rate)::NUMERIC, 2)
  WHERE geofence_id IS NULL
    AND end_date IS NOT NULL
    AND (charge_energy_added IS NOT NULL OR charge_energy_used IS NOT NULL)
    AND cost IS NULL;
  GET DIAGNOSTICS v_updated_cp = ROW_COUNT;

  RETURN QUERY SELECT format('✅ 默认电价 %s 元/度 已保存（AC+DC 两条 tou_rates）。新填 %s 个无价格充电记录的 cost', p_rate, v_updated_cp);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION set_default_charging_rate IS
'v1.7.3: tou-config 仪表盘 panel 21 调此函数。设默认电价 + 即时填充无价格充电的 cp.cost';

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
