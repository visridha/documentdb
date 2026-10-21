/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/documentdb_btree.c
 *
 * Register the experimental DocumentDB B-tree index access method.
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "fmgr.h"

#include "catalog/pg_am_d.h"
#include "catalog/pg_collation_d.h"
#include "access/stratnum.h"
#include "commands/defrem.h"
#include "miscadmin.h"
#include "nodes/pathnodes.h"
#include "nodes/makefuncs.h"
#include "optimizer/restrictinfo.h"
#include "parser/parse_func.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/type_cache.h"

#include "index_am/index_am_exports.h"
#include "io/bson_core.h"
#include "io/bsonvalue_utils.h"
#include "metadata/collection.h"
#include "metadata/metadata_cache.h"
#include "opclass/bson_gin_index_mgmt.h"
#include "opclass/bson_gin_index_types_core.h"
#include "opclass/bson_index_support.h"
#include "planner/mongo_query_operator.h"
#include "utils/documentdb_pg_compatibility.h"

PG_MODULE_MAGIC;

void _PG_init(void);

typedef struct DocumentDBBtreeOidCacheData
{
	Oid BsonDocumentDBBtreeSinglePathOperatorFamilyId;
} DocumentDBBtreeOidCacheData;

static DocumentDBBtreeOidCacheData Cache = { 0 };

static void DocumentDBBtreeCostEstimate(PlannerInfo *root, IndexPath *path,
										double loopCount, Cost *indexStartupCost,
										Cost *indexTotalCost,
										Selectivity *indexSelectivity,
										double *indexCorrelation, double *indexPages);
static Oid DocumentDBBtreeIndexAmId(void);
static Oid DocumentDBBtreeExtractPathFunctionId(void);
static Oid DocumentDBBtreeSinglePathOpFamilyOid(void);
static Oid UnimplementedBtreeOpFamilyOid(void);
static const char * GetDocumentDBBtreeCatalogSchema(void);
static IndexOptInfo * DocumentDBBtreeInjectIndexOptInfo(PlannerInfo *root,
														RelOptInfo *rel,
														IndexOptInfo *index);
static bytea * CreateBtreeSinglePathOptions(Node *expression, Oid extractPathFunctionId,
											Index relid);
static OpExpr * CreateBtreeComparison(Expr *expression, const bson_value_t *value,
									  StrategyNumber strategy);
static OpExpr * CreateBtreeTypeBound(OpExpr *comparison, Oid operatorFamily);
static void AddBtreeTypeBounds(PlannerInfo *root, IndexPath *path);
static void DocumentDBBtreePushOrderBy(PlannerInfo *root, IndexPath *path);
static OpExpr * DocumentDBBtreeGetFullScanExpr(Expr *documentExpr, Expr *sortSpec,
											   bytea *indexOptions, bool *lossy);
static OpExpr * DocumentDBBtreeGetOpExprClauseFromIndexOperator(const
																MongoIndexOperatorInfo *
																operator,
																Expr *firstArgExpr,
																Expr *secondArg,
																bytea *indexOptions,
																bool *lossy);

PGDLLEXPORT void
_PG_init(void)
{
	if (!process_shared_preload_libraries_in_progress)
	{
		ereport(ERROR, (errmsg(
							"pg_documentdb_btree can only be loaded via shared_preload_libraries"),
						errdetail_log(
							"Add pg_documentdb_btree after pg_documentdb in shared_preload_libraries.")));
	}

	static BsonIndexAmEntry documentDBIndexAmEntry = {
		.is_single_path_index_supported = true,
		.am_name = "btree",
		.am_name_is_exact = true,
		.pathExtractionFuncName = "bson_btree_extract_path",
		.injectIndexOptInfo = DocumentDBBtreeInjectIndexOptInfo,
		.getOpExprClauseFromIndexOperator =
			DocumentDBBtreeGetOpExprClauseFromIndexOperator,
		.getFullScanExpr = DocumentDBBtreeGetFullScanExpr,
		.get_am_oid = DocumentDBBtreeIndexAmId,
		.get_single_path_op_family_oid = DocumentDBBtreeSinglePathOpFamilyOid,
		.get_composite_path_op_family_oid = UnimplementedBtreeOpFamilyOid,
		.get_opclass_catalog_schema = GetDocumentDBBtreeCatalogSchema,
		.get_opclass_internal_catalog_schema = GetDocumentDBBtreeCatalogSchema,
	};

	RegisterIndexAm(documentDBIndexAmEntry);
}


static Oid
DocumentDBBtreeIndexAmId(void)
{
	return BTREE_AM_OID;
}


static Oid
DocumentDBBtreeExtractPathFunctionId(void)
{
	Oid argumentTypes[] = { BsonTypeId(), TEXTOID, TEXTOID };
	return LookupFuncName(
		list_make2(makeString((char *) GetDocumentDBBtreeCatalogSchema()),
				   makeString("bson_btree_extract_path")),
		lengthof(argumentTypes), argumentTypes, false);
}


static IndexOptInfo *
DocumentDBBtreeInjectIndexOptInfo(PlannerInfo *root, RelOptInfo *rel, IndexOptInfo *index)
{
	if (index->indexprs == NIL || list_length(index->indexprs) != index->ncolumns)
	{
		return NULL;
	}

	Oid singlePathOpFamily = DocumentDBBtreeSinglePathOpFamilyOid();
	for (int column = 0; column < index->ncolumns; column++)
	{
		if (index->opfamily[column] != singlePathOpFamily)
		{
			return NULL;
		}
	}

	Oid extractPathFunctionId = DocumentDBBtreeExtractPathFunctionId();

	IndexOptInfo *injectedIndex = palloc(sizeof(IndexOptInfo));
	memcpy(injectedIndex, index, sizeof(IndexOptInfo));
	injectedIndex->amcostestimate = DocumentDBBtreeCostEstimate;
	injectedIndex->indexkeys = palloc(sizeof(int) * index->ncolumns);
	injectedIndex->opclassoptions = palloc0(sizeof(bytea *) * index->ncolumns);

	/* Extracted index values cannot satisfy requests for the complete document. */
	injectedIndex->canreturn = palloc0(sizeof(bool) * index->ncolumns);
	int column = 0;
	ListCell *cell;
	foreach(cell, index->indexprs)
	{
		bytea *options = CreateBtreeSinglePathOptions(lfirst(cell), extractPathFunctionId,
													  rel->relid);
		if (options == NULL)
		{
			return NULL;
		}

		injectedIndex->indexkeys[column] = DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER;
		injectedIndex->opclassoptions[column] = options;
		column++;
	}

	return injectedIndex;
}


static bytea *
CreateBtreeSinglePathOptions(Node *expression, Oid extractPathFunctionId, Index relid)
{
	if (!IsA(expression, FuncExpr))
	{
		return NULL;
	}

	FuncExpr *extract = castNode(FuncExpr, expression);
	if (extract->funcid != extractPathFunctionId || list_length(extract->args) != 3 ||
		!IsA(linitial(extract->args), Var) ||
		!IsA(lsecond(extract->args), Const) || !IsA(lthird(extract->args), Const))
	{
		return NULL;
	}

	Var *document = linitial_node(Var, extract->args);
	Const *path = lsecond_node(Const, extract->args);
	Const *collation = lthird_node(Const, extract->args);
	if ((Index) document->varno != relid || document->varlevelsup != 0 ||
		document->varattno != DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER ||
		path->constisnull)
	{
		return NULL;
	}

	char *pathString = TextDatumGetCString(path->constvalue);
	char *collationString = collation->constisnull ? NULL :
							TextDatumGetCString(collation->constvalue);
	Size pathSize = FillSinglePathSpec(pathString, NULL);
	Size collationSize = collationString == NULL ? 0 :
						 FillCollationSpec(collationString, NULL);
	Size optionsSize = sizeof(BsonGinSinglePathOptions) + pathSize + collationSize;
	BsonGinSinglePathOptions *options = palloc0(optionsSize);
	SET_VARSIZE(options, optionsSize);
	options->base.type = IndexOptionsType_SinglePath;
	options->base.version = IndexOptionsVersion_V0;
	options->base.indexTermTruncateLimit = -1;
	options->base.wildcardIndexTruncatedPathLimit = INT32_MAX;
	options->path = sizeof(BsonGinSinglePathOptions);
	FillSinglePathSpec(pathString, ((char *) options) + options->path);
	if (collationString != NULL)
	{
		options->base.collation = sizeof(BsonGinSinglePathOptions) + pathSize;
		FillCollationSpec(collationString, ((char *) options) + options->base.collation);
		pfree(collationString);
	}

	pfree(pathString);
	return (bytea *) options;
}


static OpExpr *
DocumentDBBtreeGetOpExprClauseFromIndexOperator(const MongoIndexOperatorInfo *operator,
												Expr *firstArgExpr, Expr *secondArg,
												bytea *indexOptions, bool *lossy)
{
	StrategyNumber strategy;
	switch (operator->indexStrategy)
	{
		case BSON_INDEX_STRATEGY_DOLLAR_LESS:
		{
			strategy = BTLessStrategyNumber;
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_LESS_EQUAL:
		{
			strategy = BTLessEqualStrategyNumber;
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_EQUAL:
		{
			strategy = BTEqualStrategyNumber;
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER_EQUAL:
		{
			strategy = BTGreaterEqualStrategyNumber;
			break;
		}

		case BSON_INDEX_STRATEGY_DOLLAR_GREATER:
		{
			strategy = BTGreaterStrategyNumber;
			break;
		}

		default:
			return NULL;
	}

	if (indexOptions == NULL || !IsA(secondArg, Const))
	{
		return NULL;
	}

	BsonGinSinglePathOptions *options = (BsonGinSinglePathOptions *) indexOptions;
	Const *operand = castNode(Const, secondArg);
	if (options->base.type != IndexOptionsType_SinglePath || options->isWildcard ||
		options->base.collation != 0 || operand->constisnull ||
		(operand->consttype != BsonTypeId() && operand->consttype != BsonQueryTypeId()))
	{
		return NULL;
	}

	pgbsonelement element;
	PgbsonToSinglePgbsonElement(DatumGetPgBson(operand->constvalue), &element);
	uint32_t indexPathLength;
	const char *indexPath;
	Get_Index_Path_Option(options, path, indexPath, indexPathLength);
	Const *path = makeConst(TEXTOID, -1, DEFAULT_COLLATION_OID, -1,
							PointerGetDatum(cstring_to_text_with_len(indexPath,
																	 indexPathLength)),
							false, false);
	FuncExpr *extraction = makeFuncExpr(DocumentDBBtreeExtractPathFunctionId(),
										BsonTypeId(),
										list_make3(copyObject(firstArgExpr), path,
												   makeNullConst(TEXTOID, -1,
																 DEFAULT_COLLATION_OID)),
										InvalidOid, DEFAULT_COLLATION_OID,
										COERCE_EXPLICIT_CALL);

	/* Retain the MongoDB predicate to recheck BSON query semantics on the heap. */
	*lossy = true;
	return CreateBtreeComparison((Expr *) extraction, &element.bsonValue, strategy);
}


static OpExpr *
DocumentDBBtreeGetFullScanExpr(Expr *documentExpr, Expr *sortSpec,
							   bytea *indexOptions, bool *lossy)
{
	if (indexOptions == NULL || !IsA(sortSpec, Const))
	{
		return NULL;
	}

	Const *sortOperand = castNode(Const, sortSpec);
	if (sortOperand->constisnull ||
		(sortOperand->consttype != BsonTypeId() &&
		 sortOperand->consttype != BsonQueryTypeId()) ||
		!ValidateIndexForQualifierValue(indexOptions, sortOperand->constvalue,
										BSON_INDEX_STRATEGY_DOLLAR_ORDERBY))
	{
		return NULL;
	}

	pgbsonelement sortElement;
	PgbsonToSinglePgbsonElementWithCollation(DatumGetPgBson(sortOperand->constvalue),
											 &sortElement);
	bson_value_t minKey = { .value_type = BSON_TYPE_MINKEY };
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendValue(&writer, sortElement.path, sortElement.pathLength, &minKey);
	Const *operand = makeConst(BsonTypeId(), -1, InvalidOid, -1,
							   PointerGetDatum(PgbsonWriterGetPgbson(&writer)),
							   false, false);
	const MongoIndexOperatorInfo *gteOperator =
		GetMongoIndexOperatorInfoByOperatorType(QUERY_OPERATOR_GTE);
	OpExpr *comparison = DocumentDBBtreeGetOpExprClauseFromIndexOperator(
		gteOperator, documentExpr, (Expr *) operand, indexOptions, lossy);
	if (comparison != NULL)
	{
		/* Every extracted value, including missing paths mapped to null, is >= MinKey. */
		*lossy = false;
	}

	return comparison;
}


static OpExpr *
CreateBtreeComparison(Expr *expression, const bson_value_t *value,
					  StrategyNumber strategy)
{
	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	PgbsonWriterAppendValue(&writer, "$", 1, value);
	Const *operand = makeConst(BsonTypeId(), -1, InvalidOid, -1,
							   PointerGetDatum(PgbsonWriterGetPgbson(&writer)), false,
							   false);
	Oid operatorId = get_opfamily_member(DocumentDBBtreeSinglePathOpFamilyOid(),
										 BsonTypeId(), BsonTypeId(), strategy);
	if (!OidIsValid(operatorId))
	{
		ereport(ERROR, (errmsg("B-tree BSON operator for strategy %d is not defined",
							   strategy)));
	}

	return castNode(OpExpr, make_opclause(operatorId, BOOLOID, false,
										  expression, (Expr *) operand,
										  InvalidOid, InvalidOid));
}


static OpExpr *
CreateBtreeTypeBound(OpExpr *comparison, Oid operatorFamily)
{
	StrategyNumber strategy = get_op_opfamily_strategy(comparison->opno, operatorFamily);
	if (strategy != BTLessStrategyNumber && strategy != BTLessEqualStrategyNumber &&
		strategy != BTGreaterStrategyNumber && strategy != BTGreaterEqualStrategyNumber)
	{
		return NULL;
	}

	Const *operand = lsecond_node(Const, comparison->args);
	pgbsonelement element;
	PgbsonToSinglePgbsonElement(DatumGetPgBson(operand->constvalue), &element);
	bson_type_t type = element.bsonValue.value_type;

	/* MinKey/MaxKey comparisons cross type brackets; array matching is not supported. */
	if (type == BSON_TYPE_MINKEY || type == BSON_TYPE_MAXKEY || type == BSON_TYPE_ARRAY)
	{
		return NULL;
	}

	bool inclusive = true;
	bson_value_t bound;
	if (IsBsonValueNaN(&element.bsonValue))
	{
		bound = element.bsonValue;
		strategy = strategy == BTLessStrategyNumber ||
				   strategy == BTLessEqualStrategyNumber ?
				   BTGreaterEqualStrategyNumber : BTLessEqualStrategyNumber;
	}
	else if (strategy == BTGreaterStrategyNumber ||
			 strategy == BTGreaterEqualStrategyNumber)
	{
		bound = GetUpperBound(type, &inclusive);
		strategy = inclusive ? BTLessEqualStrategyNumber : BTLessStrategyNumber;
	}
	else if (type == BSON_TYPE_NULL && strategy == BTLessEqualStrategyNumber)
	{
		/* Include undefined values in the null bracket, as the regular indexes do. */
		bound = GetLowerBound(BSON_TYPE_MINKEY);
		strategy = BTGreaterStrategyNumber;
	}
	else
	{
		bound = GetLowerBound(type);
		strategy = BTGreaterEqualStrategyNumber;
	}

	return CreateBtreeComparison(copyObject(linitial(comparison->args)), &bound,
								 strategy);
}


static void
AddBtreeTypeBounds(PlannerInfo *root, IndexPath *path)
{
	List *indexClauses = NIL;
	ListCell *cell;
	foreach(cell, path->indexclauses)
	{
		IndexClause *clause = lfirst_node(IndexClause, cell);
		Oid operatorFamily = path->indexinfo->opfamily[clause->indexcol];
		List *indexQuals = list_copy(clause->indexquals);
		ListCell *qualCell;
		foreach(qualCell, clause->indexquals)
		{
			RestrictInfo *qual = lfirst_node(RestrictInfo, qualCell);
			if (!IsA(qual->clause, OpExpr))
			{
				continue;
			}

			OpExpr *comparison = castNode(OpExpr, qual->clause);
			OpExpr *bound = CreateBtreeTypeBound(comparison, operatorFamily);
			if (bound != NULL)
			{
				indexQuals = lappend(indexQuals,
									 make_simple_restrictinfo(root, (Expr *) bound));
			}
		}

		IndexClause *boundedClause = palloc(sizeof(IndexClause));
		memcpy(boundedClause, clause, sizeof(IndexClause));
		boundedClause->indexquals = indexQuals;
		indexClauses = lappend(indexClauses, boundedClause);
	}

	path->indexclauses = indexClauses;
}


static void
DocumentDBBtreePushOrderBy(PlannerInfo *root, IndexPath *path)
{
	if (root->query_pathkeys == NIL)
	{
		return;
	}

	bool hasGroupby = false;
	bool isOrderById = false;
	bool hasDistinct = false;
	List *sortDetails = GetSortDetails(root, path->path.parent->relid, &hasGroupby,
									   &isOrderById, &hasDistinct);
	if (sortDetails == NIL || hasGroupby || hasDistinct)
	{
		list_free_deep(sortDetails);
		return;
	}

	/* Re-costing may have changed the qualifiers that pin the sort prefix. */
	path->path.pathkeys = NIL;
	IndexOptInfo *index = path->indexinfo;
	const char *queryOrderPaths[INDEX_MAX_KEYS] = { 0 };
	bool equalityPrefixes[INDEX_MAX_KEYS] = { 0 };
	bool nonEqualityPrefixes[INDEX_MAX_KEYS] = { 0 };
	int32_t pathSortOrders[INDEX_MAX_KEYS] = { 0 };
	int32_t minOrderByColumn = INT_MAX;
	int32_t maxOrderByColumn = -1;
	ListCell *cell;
	foreach(cell, sortDetails)
	{
		SortIndexInputDetails *sort = lfirst(cell);
		if (sort->collationConst != NULL || sort->funcOid != BsonOrderByFunctionOid())
		{
			break;
		}

		int column;
		for (column = maxOrderByColumn + 1; column < index->nkeycolumns; column++)
		{
			BsonGinSinglePathOptions *options =
				(BsonGinSinglePathOptions *) index->opclassoptions[column];
			if (options == NULL || options->base.type != IndexOptionsType_SinglePath ||
				options->isWildcard || options->base.collation != 0)
			{
				continue;
			}

			uint32_t indexPathLength;
			const char *indexPath;
			Get_Index_Path_Option(options, path, indexPath, indexPathLength);
			if (strlen(sort->sortPath) == indexPathLength &&
				memcmp(sort->sortPath, indexPath, indexPathLength) == 0)
			{
				break;
			}
		}

		if (column == index->nkeycolumns)
		{
			break;
		}

		int queryDirection = SortPathKeyStrategy(sort->sortPathKey) ==
							 BTGreaterStrategyNumber ? -1 : 1;
		pathSortOrders[column] = index->reverse_sort[column] ?
								 -queryDirection : queryDirection;
		queryOrderPaths[column] = sort->sortPath;
		minOrderByColumn = Min(minOrderByColumn, column);
		maxOrderByColumn = column;
	}

	if (maxOrderByColumn >= 0)
	{
		foreach(cell, path->indexclauses)
		{
			IndexClause *clause = lfirst_node(IndexClause, cell);
			ListCell *qualCell;
			foreach(qualCell, clause->indexquals)
			{
				RestrictInfo *qual = lfirst_node(RestrictInfo, qualCell);
				if (IsA(qual->clause, OpExpr) &&
					get_op_opfamily_strategy(castNode(OpExpr, qual->clause)->opno,
											 index->opfamily[clause->indexcol]) ==
					BTEqualStrategyNumber)
				{
					equalityPrefixes[clause->indexcol] = true;
				}
			}
		}

		ProcessOrderByStatements(root, path, minOrderByColumn, maxOrderByColumn,
								 false, false, 0, false, false, queryOrderPaths,
								 equalityPrefixes, nonEqualityPrefixes, pathSortOrders);

		if (path->indexorderbys != NIL)
		{
			OpExpr *orderBy = linitial_node(OpExpr, path->indexorderbys);
			path->indexscandir = orderBy->opno == BsonOrderByReverseIndexOperatorId() ?
								 BackwardScanDirection : ForwardScanDirection;
		}

		/* Keep the validated pathkeys, but use native B-tree ordering, not AM operators. */
		list_free_deep(path->indexorderbys);
		path->indexorderbys = NIL;
		list_free(path->indexorderbycols);
		path->indexorderbycols = NIL;
	}

	list_free_deep(sortDetails);
}


static void
DocumentDBBtreeCostEstimate(PlannerInfo *root, IndexPath *path, double loopCount,
							Cost *indexStartupCost, Cost *indexTotalCost,
							Selectivity *indexSelectivity, double *indexCorrelation,
							double *indexPages)
{
	IndexOptInfo *index = path->indexinfo;
	if (index->indexkeys[0] == DOCUMENT_DATA_TABLE_DOCUMENT_VAR_ATTR_NUMBER)
	{
		/* Keep the pseudo keys available for matching other candidate paths. */
		IndexOptInfo *expressionIndex = palloc(sizeof(IndexOptInfo));
		memcpy(expressionIndex, index, sizeof(IndexOptInfo));
		expressionIndex->indexkeys = palloc0(sizeof(int) * index->ncolumns);
		path->indexinfo = expressionIndex;
		AddBtreeTypeBounds(root, path);
	}

	DocumentDBBtreePushOrderBy(root, path);
	documentdb_btcostestimate(root, path, loopCount, indexStartupCost, indexTotalCost,
							  indexSelectivity, indexCorrelation, indexPages);
}


static Oid
DocumentDBBtreeSinglePathOpFamilyOid(void)
{
	if (Cache.BsonDocumentDBBtreeSinglePathOperatorFamilyId == InvalidOid)
	{
		Cache.BsonDocumentDBBtreeSinglePathOperatorFamilyId = get_opfamily_oid(
			DocumentDBBtreeIndexAmId(),
			list_make2(makeString((char *) GetDocumentDBBtreeCatalogSchema()),
					   makeString("bson_btree_single_path_ops")), true);
	}

	return Cache.BsonDocumentDBBtreeSinglePathOperatorFamilyId;
}


static Oid
UnimplementedBtreeOpFamilyOid(void)
{
	return InvalidOid;
}


static const char *
GetDocumentDBBtreeCatalogSchema(void)
{
	return "documentdb_btree_catalog";
}
