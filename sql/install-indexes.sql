-- ============================================================================
-- TeslaMate 中文仪表盘：性能优化索引
--
-- 给 TeslaMate 核心表 positions 加 (car_id, date) btree 索引。
-- TeslaMate 自带的索引不覆盖「按车按时间倒序取最新一行」这种查询：
--   SELECT ... FROM positions WHERE car_id = ? ORDER BY date DESC LIMIT 1
-- 没有这个索引会走 Parallel Seq Scan，positions 表越大越慢。
--
-- 受益面板（典型）：
--   - 电池健康（State of Health）
--   - 行程列表（latest position per car）
--   - 充电费用统计 / 省钱分析（按时间窗聚合）
--   - 天气-能耗关联（v1.6.0）
--   - 分时电价回填（v1.5.0 backfill_all_tou）
--
-- 单车 80 万行实测：受影响查询从 200ms 降到 < 5ms。
--
-- 用 CONCURRENTLY 创建：不阻塞 INSERT/UPDATE，TeslaMate 后台 logger 在
-- 升级期间不会丢点（普通 CREATE INDEX 拿 SHARE lock 会阻写 5-30 秒）。
--
-- 注意：CONCURRENTLY 不能在事务块/DO 块里运行；本文件依赖 psql autocommit
-- （docker exec -i ... psql 默认就是 autocommit），不要把这个文件包在
-- BEGIN/COMMIT 里执行。
--
-- 来源：上游 issue #5306（adriankumpf/teslamate）。
-- 上游若将来正式合 migration，本文件的 IF NOT EXISTS 让它幂等共存。
--
-- 安装：
--   docker exec -i teslamate-database-1 psql -U teslamate teslamate \
--     < sql/install-indexes.sql
--
-- 失败重试：CONCURRENTLY 中途失败会留下 INVALID 索引，重跑前先清理：
--   DROP INDEX IF EXISTS idx_positions_car_id_date_btree;
--
-- 卸载：
--   DROP INDEX IF EXISTS idx_positions_car_id_date_btree;
-- ============================================================================

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_positions_car_id_date_btree
    ON positions (car_id, date);

COMMENT ON INDEX idx_positions_car_id_date_btree IS
'中文版性能优化（v1.6.1+）：覆盖「按车按时间倒序取最新」类查询。来源：上游 issue #5306。';

-- 让规划器立刻拿到新索引的选择性统计，否则可能继续走 seq scan
ANALYZE positions;
