CREATE SCHEMA documentdb_btree_catalog;

CREATE FUNCTION documentdb_btree_catalog.bson_btree_extract_path(
    document documentdb_core.bson, path text, collation text)
RETURNS documentdb_core.bson
LANGUAGE C IMMUTABLE PARALLEL SAFE
AS 'MODULE_PATHNAME', 'bson_btree_extract_path';

CREATE OPERATOR CLASS documentdb_btree_catalog.bson_btree_single_path_ops
    FOR TYPE documentdb_core.bson USING btree AS
        OPERATOR 1 documentdb_core.< (documentdb_core.bson, documentdb_core.bson),
        OPERATOR 2 documentdb_core.<= (documentdb_core.bson, documentdb_core.bson),
        OPERATOR 3 documentdb_core.= (documentdb_core.bson, documentdb_core.bson),
        OPERATOR 4 documentdb_core.>= (documentdb_core.bson, documentdb_core.bson),
        OPERATOR 5 documentdb_core.> (documentdb_core.bson, documentdb_core.bson),
        FUNCTION 1 documentdb_core.bson_compare(documentdb_core.bson, documentdb_core.bson);
