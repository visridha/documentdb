# DocumentDB B-tree extension

**For testing and development only. Not for production use.**

During shared preload, this extension registers PostgreSQL's existing `btree`
access method as `btree` in DocumentDB's alternate-index registry, following
`pg_documentdb_extended_rum`. It does not create a custom access method.
The SQL file creates `documentdb_btree_catalog.bson_btree_single_path_ops` using
the core BSON comparison operators and comparator. It is not a default opclass,
so it does not replace `documentdb_core.bson_btree_ops`. It currently compares
whole BSON documents. The registration's `pathExtractionFuncName` is
`bson_btree_extract_path`, qualified using the opclass catalog schema as
`documentdb_btree_catalog.bson_btree_extract_path(document, path, collation)`.
This SQL/C entry point uses `TraverseBson` to extract the leaf at the requested
path and returns a BSON document of the form `{"$": <value>}`. Missing paths
produce `{"$": null}`. Leaf objects and arrays are preserved as values, but
traversal through intermediate arrays is not supported. SQL NULL documents or
paths return SQL NULL; a NULL collation does not suppress extraction. The
collation argument is not applied yet.
Index expressions pass a quoted path and either the
collation string or SQL `NULL`; no opclass options are added in this mode.
The extension requires `documentdb` (the `pg_documentdb` extension).

The build follows `pg_documentdb_extended_rum`, and the backend regression-test
layout follows `pg_documentdb_core`. The extension is opt-in and is not included
in the repository's default build or installation.

From the repository root, using the development container:

```bash
make -C internal/pg_documentdb_btree
sudo make -C internal/pg_documentdb_btree install
make -C internal/pg_documentdb_btree check
```

Use the same `PG_CONFIG` for building, installing, and testing when selecting a
PostgreSQL version. The test harness starts a temporary PostgreSQL instance on
port **58050**, preloads the modules, and creates the `documentdb_btree` extension
after its dependencies.

For a running server, preload the modules in dependency order:

```conf
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_btree'
```

The registry name is `btree` for `documentdb.alternate_index_handler_name`.
Its `am_name_is_exact` registration flag makes index creation emit `USING btree`
without the extension prefix. Documents can be inserted into the resulting
expression indexes and queried using the same path-extraction expression.
Index creation uses single-path opclasses for B-tree, including compound indexes;
the B-tree registration does not provide a composite-path operator family.
For indexes whose columns are all expressions, its `injectIndexOptInfo` planner
callback adds a shallow copy with a separate `indexkeys` array mapping every
column to the document attribute. Each injected column also gets serialized
`BsonGinSinglePathOptions`, using the path and optional collation from its
`bson_btree_extract_path` expression. Only this extension's single-path opclass
and extraction expressions over the document column are eligible.
The original index entry, expressions, and operator families remain unchanged.
Injected entries do not advertise index-only scans, since the extracted keys
cannot supply complete documents.
The injected entry overrides its cost estimator. During cost estimation, it
replaces the path's index metadata with a copy whose keys identify expressions,
leaving the pseudo document-column keys available for matching other paths.
It also adds the opposite type bound for range conditions: `$gt`/`$gte` get
the type's upper bound, and `$lt`/`$lte` get its lower bound, respecting each
bound's inclusivity. Numeric BSON types share one bracket. NaN comparisons
are confined to NaN; MinKey and MaxKey comparisons are not type-bracketed.
It then delegates to `documentdb_btcostestimate`. The clause builder wraps the
document operand in `bson_btree_extract_path(document, path, collation)`, so both
cost estimation and execution planning see the actual extraction expression.
This fixup is localized to the B-tree extension; no late path traversal is needed.

The AM's `getOpExprClauseFromIndexOperator` callback supports `$eq`, `$lt`,
`$lte`, `$gt`, and `$gte`, using the corresponding B-tree family operators and
rewriting constant operands to `{"$": <value>}`. Other operators, nonconstant
operands, and collated indexes are declined. Both `bson` and API-generated
`bsonquery` constants are accepted; generated B-tree operands use `bson`.
AMs without this callback retain the existing expression builder; a callback
returning NULL declines the clause without falling back.
Direct MongoDB comparison operators can use these conditions, with the MongoDB
predicate retained as a heap recheck. Find/aggregate predicates can also use
these conditions, though cost-based planning may prefer the shard-key index.
MongoDB matching against leaf arrays is not implemented by these scalar index
bounds.
Native BSON whole-document comparisons can still match the injected entries
and return incorrect results, since those entries describe extracted keys as
document columns rather than whole documents.
Do not use this planner-injection prototype for correctness-sensitive queries.
The regression suite retains a vacuous placeholder and checks preload
registration and continued operation of PostgreSQL's B-tree handler.

The planner regression uses 1,000 documents with competing `a_1`, `b_1`, `c_1`,
and compound `a_b` indexes. It checks unhinted index selection, ordinary and
bitmap scans, bitmap intersections/unions, and sequential-scan controls.
`documentdb.enableAddShardKeyOnlyOnPrimaryKeyFilters` removes the redundant
shard-key predicate for these queries; it does not enable selectivity statistics.
PostgreSQL's `enable_seqscan = off` discourages sequential scans without changing
selectivity estimates.

Regular BSON index creation currently sets expression-column statistics targets
to zero, including for this prototype. Consequently, `ANALYZE` alone does not
collect expression statistics, and enabling
`documentdb_core.enableBsonSelectivityFromBtreeStats` alone still gives fallback
estimates. The planner regression explicitly restores each index expression's
statistics target with `ALTER INDEX ... ALTER COLUMN ... SET STATISTICS -1`,
then runs `ANALYZE` with that selectivity flag enabled. The resulting index
estimates distinguish the common `a = 3` value (100 of 1,000 rows) from the rare
`b = 493` value (one row), and an unrestricted broad predicate prefers a
sequential scan. Heap-filter/result estimates still use the MongoDB predicate's
fallback selectivity rather than these expression statistics.

`documentdb.forceDisableSeqScan` has a separate known limitation: the shared
planner treats any native B-tree path with a single index clause as a
shard-key-only primary-key scan and removes it. Valid single-clause paths can
therefore produce `Could not find any valid index to push down for query`.
Compound queries can also fail when their surviving candidate is a
single-clause path. The regression records these errors and a bitmap
intersection that survives this exclusion; this prototype does not change that
shared-planner assumption.

The separate `documentdb_btree_find_sort` regression covers Find with ascending
and descending sorts, range filters, equality-prefix compound indexes,
compound sorts, and limits. Matching sorts use forward or backward B-tree scans
without an explicit `Sort`.
Ordered results are checked separately with projections and unique sort keys.
The AM's `getFullScanExpr` callback lowers matching full-scan markers to
`bson_btree_extract_path(document, path, NULL) >= {"$": MinKey}`. This makes
sort-only queries eligible for ordinary or bitmap index scans. The bound includes
every extracted BSON type, including MinKey, MaxKey, and missing paths mapped to null.
Unindexed paths and unsupported collations are declined. Other access methods
retain the existing composite-index full-scan handling.

During cost estimation, the extension maps `GetSortDetails` paths to exact index
columns and passes their directions and equality prefixes to
`ProcessOrderByStatements` without changing its order-by processing. The
extension then preserves the validated pathkeys, translates the generated
order-by operator into a forward or backward scan, and clears the AM order-by
expressions and column list for native B-tree ordering, as for `_id`.
Leading columns omitted from the sort must be pinned by
index equalities, and all sorted columns must agree on the physical scan
direction. Only a valid sort prefix is advertised when later keys do not match.
Bitmap scans still require sorting. Collations and MongoDB array-minimum/maximum
sort semantics are not supported; sort pushdown is for scalar leaf values.
