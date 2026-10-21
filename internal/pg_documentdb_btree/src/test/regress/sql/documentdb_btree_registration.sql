SET documentdb.next_collection_id TO 91000200;
SET documentdb.next_collection_index_id TO 91000200;
SET documentdb_core.bsonUseEJson TO on;

CREATE TABLE btree_registration_test (value int4);
CREATE INDEX ON btree_registration_test USING btree (value);
INSERT INTO btree_registration_test VALUES (3), (1), (2);
SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT value FROM btree_registration_test WHERE value >= 2 ORDER BY value;
SELECT value FROM btree_registration_test WHERE value >= 2 ORDER BY value;

CREATE TABLE btree_bson_test (document documentdb_core.bson);
CREATE INDEX ON btree_bson_test USING btree (
    document documentdb_btree_catalog.bson_btree_single_path_ops);
INSERT INTO btree_bson_test VALUES ('{"a":3}'), ('{"a":1}'), ('{"a":2}');
COPY (
    SELECT document::text FROM btree_bson_test
    WHERE document OPERATOR(documentdb_core.>=) '{"a":2}'::documentdb_core.bson
    ORDER BY btree_bson_test.document USING OPERATOR(documentdb_core.<)
) TO STDOUT;

-- Registrations without the flag retain prefixed index and constraint names.
SET client_min_messages = warning;
DO $$
BEGIN
    PERFORM documentdb_api_internal.create_indexes_non_concurrently(
        'btree_registration_db',
        '{"createIndexes":"default_am","indexes":[{"key":{"a":1},"name":"a_1"},{"key":{"b":1},"name":"b_1","unique":true}]}');
END;
$$;

-- The operator-family check must preserve ordinary single-path index queries.
SELECT documentdb_api.insert_one(
    'btree_registration_db', 'default_am', '{"_id":1,"a":2}') AS insert_result;
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db', '{"find":"default_am","filter":{"a":2}}');

-- The extractor is defined and must not short-circuit on a NULL collation.
SET documentdb.alternate_index_handler_name = 'btree';
\set VERBOSITY terse
SELECT documentdb_btree_catalog.bson_btree_extract_path(
    '{"a":1}'::documentdb_core.bson, 'a', NULL) AS extracted;
SELECT documentdb_btree_catalog.bson_btree_extract_path(document, path, NULL) AS extracted
FROM (VALUES
    ('{"nested":{"value":2}}'::documentdb_core.bson, 'nested.value'),
    ('{"a":[1,2]}'::documentdb_core.bson, 'a'),
    ('{}'::documentdb_core.bson, 'a')
) AS inputs(document, path);
SELECT documentdb_btree_catalog.bson_btree_extract_path(
    '{"a":[{"b":1}]}'::documentdb_core.bson, 'a.b', NULL);

SET documentdb_core.enableCollation = on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes = on;
DO $$
BEGIN
    PERFORM documentdb_api_internal.create_indexes_non_concurrently(
        'btree_registration_db',
        $cmd${"createIndexes":"extraction","indexes":[
            {"key":{"a":1,"nested.value":1},"name":"a_nested"},
            {"key":{"label":1},"name":"collated","collation":{"locale":"en","strength":1}}
        ]}$cmd$);
END;
$$;

SELECT 'documentdb_data.documents_' || collection_id AS table_name
FROM documentdb_api_catalog.collections
WHERE database_name = 'btree_registration_db' AND collection_name = 'extraction'
\gset
\d :table_name

SELECT documentdb_api.insert_one(
    'btree_registration_db', 'extraction',
    '{"_id":1,"a":1,"nested":{"value":10},"label":"alpha"}') AS insert_result;
SELECT documentdb_api.insert_one(
    'btree_registration_db', 'extraction',
    '{"_id":2,"a":2,"nested":{"value":20},"label":"beta"}') AS insert_result;

EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM :table_name
WHERE documentdb_btree_catalog.bson_btree_extract_path(document, 'a', NULL)
      OPERATOR(documentdb_core.=) '{"$":2}'::documentdb_core.bson;

SELECT document
FROM :table_name
WHERE documentdb_btree_catalog.bson_btree_extract_path(document, 'a', NULL)
      OPERATOR(documentdb_core.=) '{"$":2}'::documentdb_core.bson;

-- MongoDB comparison operators use the injected document-column index keys.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM :table_name
WHERE document OPERATOR(documentdb_api_catalog.@=) '{"a":2}'::documentdb_core.bson;

-- API predicates use bsonquery operands, unlike the direct comparison above.
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM :table_name
WHERE documentdb_api_catalog.bson_dollar_eq(
    document, '{"a":2}'::documentdb_core.bsonquery);

-- The API planner may still prefer the cheaper shard-key index.
-- Log both expression-index copies; the plain-column primary key is not copied.
SET client_min_messages = log;
SET documentdb.logRelationIndexesOrder = on;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db', '{"find":"extraction","filter":{"a":2}}');
SET documentdb.logRelationIndexesOrder = off;
SET client_min_messages = warning;

EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_pipeline(
    'btree_registration_db',
    '{"aggregate":"extraction","pipeline":[{"$match":{"a":2}}],"cursor":{}}');

EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_pipeline(
    'btree_registration_db',
    '{"aggregate":"extraction","pipeline":[{"$match":{"a":2}}],"hint":"a_nested","cursor":{}}');

EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db', '{"find":"extraction","filter":{"a":{"$gt":1}}}');

SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":2,"nested.value":{"$gt":10}}}');
RESET enable_bitmapscan;

SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":{"$lt":2}},"projection":{"_id":1}}');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":{"$lte":1}},"projection":{"_id":1}}');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":{"$gt":1}},"projection":{"_id":1}}');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":{"$gte":2}},"projection":{"_id":1}}');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"nested.value":20},"projection":{"_id":1}}');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":{"$exists":true}},"projection":{"_id":1}}');

-- Range bounds must exclude other BSON types without filtering them on the heap.
DO $$
BEGIN
    PERFORM documentdb_api.insert_one(
        'btree_registration_db', 'extraction', document::documentdb_core.bson)
    FROM (VALUES
        ('{"_id":10,"a":{"$numberLong":"3"}}'),
        ('{"_id":11,"a":{"$numberDouble":"4.5"}}'),
        ('{"_id":12,"a":{"$numberDecimal":"5.5"}}'),
        ('{"_id":13,"a":{"$numberDouble":"Infinity"}}'),
        ('{"_id":14,"a":{"$numberDouble":"-Infinity"}}'),
        ('{"_id":15,"a":{"$numberDouble":"NaN"}}'),
        ('{"_id":16,"a":"alpha"}'),
        ('{"_id":17,"a":"zeta"}'),
        ('{"_id":18,"a":null}'),
        ('{"_id":19,"a":true}'),
        ('{"_id":20,"a":{"value":1}}'),
        ('{"_id":21,"a":{"$minKey":1}}'),
        ('{"_id":22,"a":{"$maxKey":1}}')
    ) AS inputs(document);
END;
$$;

SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db', '{"find":"extraction","filter":{"a":{"$gt":1}}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db', '{"find":"extraction","filter":{"a":{"$lt":2}}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db', '{"find":"extraction","filter":{"a":{"$gt":"alpha"}}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db', '{"find":"extraction","filter":{"a":{"$lte":"zeta"}}}');
EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":{"$gte":{"$numberDouble":"NaN"}}}}');
RESET enable_bitmapscan;

-- Sentinel comparisons must continue to span multiple BSON types.
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":{"$gt":{"$minKey":1}}},"projection":{"_id":1}}');
SELECT document
FROM documentdb_api_catalog.bson_aggregation_find(
    'btree_registration_db',
    '{"find":"extraction","filter":{"a":{"$lt":{"$maxKey":1}}},"projection":{"_id":1}}');

RESET enable_seqscan;
RESET client_min_messages;
RESET documentdb.alternate_index_handler_name;
RESET documentdb_core.enableCollation;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.bsonUseEJson;
