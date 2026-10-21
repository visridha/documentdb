SET documentdb.next_collection_id TO 91000400;
SET documentdb.next_collection_index_id TO 91000400;
SET documentdb_core.bsonUseEJson TO on;
SET documentdb.alternate_index_handler_name = 'btree';
SET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters = on;
SET documentdb.enableExplainScanIndexCosts = off;
SET client_min_messages = warning;
\set VERBOSITY terse

DO $$
BEGIN
    PERFORM documentdb_api_internal.create_indexes_non_concurrently(
        'btree_find_sort_db',
        $cmd${"createIndexes":"ordered","indexes":[
            {"key":{"a":1},"name":"a_1"},
            {"key":{"b":1},"name":"b_1"},
            {"key":{"a":1,"b":1},"name":"a_b"}
        ]}$cmd$);
    PERFORM documentdb_api.insert_one(
        'btree_find_sort_db', 'ordered',
        format('{"_id":%s,"a":%s,"b":%s}', i, i % 4, 25 - i)::documentdb_core.bson)
    FROM generate_series(1, 24) AS inputs(i);
END;
$$;

SELECT 'documentdb_data.documents_' || collection_id AS table_name
FROM documentdb_api_catalog.collections
WHERE database_name = 'btree_find_sort_db' AND collection_name = 'ordered'
\gset
\d :table_name
ANALYZE :table_name;

SET enable_seqscan = off;
SET enable_bitmapscan = off;

-- Exact path matches eliminate Sort, using forward or backward index scans.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","sort":{"a":1}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","sort":{"a":-1}}');

-- Bitmap scans do not preserve index order, so their Sort must remain.
SET enable_bitmapscan = on;
SET enable_indexscan = off;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","sort":{"a":1}}');
RESET enable_indexscan;
SET enable_bitmapscan = off;

-- A sort on an unrelated path must not use the available expression indexes.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","sort":{"unindexed":1}}');

-- Range filters and matching sorts both reach the index.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":{"$gte":2}},"sort":{"a":1}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":{"$gte":2}},"sort":{"a":-1}}');

-- An equality prefix permits sorting on the next compound-index column.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":1},"sort":{"b":1},"hint":"a_b"}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":1},"sort":{"b":-1},"hint":"a_b"}');

-- Matching all compound columns also eliminates the Sort.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":{"$gte":2}},"sort":{"a":1,"b":1},"hint":"a_b"}');

-- Reversing every compound sort direction uses a backward scan.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","sort":{"a":-1,"b":-1},"limit":3,"hint":"a_b"}');

-- Mixed directions cannot be satisfied by reversing the entire index.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":{"$gte":2}},"sort":{"a":1,"b":-1},"limit":3,"hint":"a_b"}');

-- A range on the leading column does not pin the prefix for a suffix sort.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":{"$gte":1}},"sort":{"b":1},"limit":3,"hint":"a_b"}');

-- A limited find can now stop its ordered index scan after three matches.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":1},"sort":{"b":-1},"limit":3,"hint":"a_b"}');

-- Check result order as well as plans, using unique sort keys to avoid ties.
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","sort":{"a":1,"b":1},"limit":6,"projection":{"_id":1}}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":1},"sort":{"b":1},"hint":"a_b","projection":{"_id":1}}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":1},"sort":{"b":-1},"limit":3,"hint":"a_b","projection":{"_id":1}}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","sort":{"a":-1,"b":-1},"limit":3,"hint":"a_b","projection":{"_id":1}}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":{"$gte":2}},"sort":{"a":1,"b":-1},"limit":3,"hint":"a_b","projection":{"_id":1}}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"ordered","filter":{"a":{"$gte":1}},"sort":{"b":1},"limit":3,"hint":"a_b","projection":{"_id":1}}');

-- A full index scan must retain missing/null paths and both BSON type extrema.
DO $$
BEGIN
    PERFORM documentdb_api_internal.create_indexes_non_concurrently(
        'btree_find_sort_db',
        '{"createIndexes":"full_scan_values","indexes":[{"key":{"a":1},"name":"a_1"}]}');
    PERFORM documentdb_api.insert_one(
        'btree_find_sort_db', 'full_scan_values', value::documentdb_core.bson)
    FROM (VALUES
        ('{"_id":1,"a":{"$minKey":1}}'),
        ('{"_id":2,"a":null}'),
        ('{"_id":3}'),
        ('{"_id":4,"a":-5}'),
        ('{"_id":5,"a":"z"}'),
        ('{"_id":6,"a":{"$maxKey":1}}')
    ) AS inputs(value);
END;
$$;

EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"full_scan_values","sort":{"a":1,"_id":1},"hint":"a_1"}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_find_sort_db', '{"find":"full_scan_values","sort":{"a":1,"_id":1},"hint":"a_1","projection":{"_id":1}}');

RESET enable_bitmapscan;
RESET enable_seqscan;
RESET client_min_messages;
RESET documentdb.enableExplainScanIndexCosts;
RESET documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters;
RESET documentdb.alternate_index_handler_name;
RESET documentdb_core.bsonUseEJson;
