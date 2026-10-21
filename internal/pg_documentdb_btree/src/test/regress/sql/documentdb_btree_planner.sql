SET documentdb.next_collection_id TO 91000300;
SET documentdb.next_collection_index_id TO 91000300;
SET documentdb_core.bsonUseEJson TO on;
SET documentdb.alternate_index_handler_name = 'btree';
SET client_min_messages = warning;
\set VERBOSITY terse

DO $$
BEGIN
    PERFORM documentdb_api_internal.create_indexes_non_concurrently(
        'btree_planner_db',
        $cmd${"createIndexes":"choices","indexes":[
            {"key":{"a":1},"name":"a_1"},
            {"key":{"b":1},"name":"b_1"},
            {"key":{"c":1},"name":"c_1"},
            {"key":{"a":1,"b":1},"name":"a_b"}
        ]}$cmd$);
    PERFORM documentdb_api.insert_one(
        'btree_planner_db', 'choices',
        format('{"_id":%s,"a":%s,"b":%s,"c":%s,"padding":"%s"}',
               i, i % 10, i, (i / 10) % 10, repeat('x', 300))::documentdb_core.bson)
    FROM generate_series(1, 1000) AS inputs(i);
END;
$$;

SELECT 'documentdb_data.documents_' || collection_id AS table_name
FROM documentdb_api_catalog.collections
WHERE database_name = 'btree_planner_db' AND collection_name = 'choices'
\gset
\d :table_name
ANALYZE :table_name;

SELECT index_relation.relname, stats.staattnum, stats.stadistinct
FROM pg_index AS indexes
JOIN pg_class AS index_relation ON index_relation.oid = indexes.indexrelid
JOIN pg_statistic AS stats ON stats.starelid = indexes.indexrelid
WHERE indexes.indrelid = :'table_name'::regclass
ORDER BY index_relation.relname, stats.staattnum;

-- Different predicates must match different indexes, without hints.
SET enable_seqscan = off;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"b":493}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"c":4}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3,"b":493}}');

-- Omitting the redundant shard-key filter does not enable BSON statistics.
SET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters = on;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3}}');

-- The selectivity flag alone cannot use expression statistics disabled at creation.
SET documentdb_core.enableBsonSelectivityFromBtreeStats = on;
EXPLAIN (ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3}}');
EXPLAIN (ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"b":493}}');

-- Restore expression statistics targets and compare common and rare values.
ALTER INDEX documentdb_data.documents_rum_index_91000302 ALTER COLUMN 1 SET STATISTICS -1;
ALTER INDEX documentdb_data.documents_rum_index_91000303 ALTER COLUMN 1 SET STATISTICS -1;
ALTER INDEX documentdb_data.documents_rum_index_91000304 ALTER COLUMN 1 SET STATISTICS -1;
ALTER INDEX documentdb_data.documents_rum_index_91000305 ALTER COLUMN 1 SET STATISTICS -1;
ALTER INDEX documentdb_data.documents_rum_index_91000305 ALTER COLUMN 2 SET STATISTICS -1;
ANALYZE :table_name;

SELECT index_relation.relname, stats.staattnum, stats.stadistinct
FROM pg_index AS indexes
JOIN pg_class AS index_relation ON index_relation.oid = indexes.indexrelid
JOIN pg_statistic AS stats ON stats.starelid = indexes.indexrelid
WHERE indexes.indrelid = :'table_name'::regclass
ORDER BY index_relation.relname, stats.staattnum;

EXPLAIN (ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3}}');
EXPLAIN (ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"b":493}}');

-- Recheck the compound predicate with collected expression statistics.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3,"b":493}}');

-- Compare a broad predicate with and without the sequential-scan cost penalty.
SET documentdb.enableExplainScanIndexCosts = off;
RESET enable_seqscan;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":{"$gte":0}}}');
SET enable_seqscan = off;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":{"$gte":0}}}');

-- Exercise single-index bitmaps and intersections/unions across separate paths.
SET enable_indexscan = off;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"b":493}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3,"c":4}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"$or":[{"a":3},{"c":4}]}}');
RESET enable_indexscan;

-- Known limitation: hard exclusion mistakes single-clause B-trees for shard-key scans.
SET documentdb.forceDisableSeqScan = on;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3,"b":493}}');
SET enable_indexscan = off;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_planner_db', '{"find":"choices","filter":{"a":3,"c":4}}');
RESET enable_indexscan;

RESET documentdb.forceDisableSeqScan;
RESET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters;
RESET documentdb_core.enableBsonSelectivityFromBtreeStats;
RESET documentdb.enableExplainScanIndexCosts;
RESET enable_seqscan;
RESET client_min_messages;
RESET documentdb.alternate_index_handler_name;
RESET documentdb_core.bsonUseEJson;
