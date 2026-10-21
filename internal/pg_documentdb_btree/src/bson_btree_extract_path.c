/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/bson_btree_extract_path.c
 *
 * Path-extraction entry point for DocumentDB B-tree index expressions.
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"

#include "io/bson_core.h"
#include "io/bson_traversal.h"

static bool ExtractBtreePathValue(pgbsonelement *element,
								  const StringView *traversePath, void *state);
static bool ContinueBtreeIntermediateArray(void *state, const bson_value_t *value,
										   bool isArrayIndexSearch);
static void CheckBtreeIntermediateArray(void *state, bool isStart);
pg_noreturn static void ThrowBtreeArrayTraversalError(void);

static const TraverseBsonExecutionFuncs BtreePathExecutionFuncs = {
	.VisitTopLevelField = ExtractBtreePathValue,
	.ContinueProcessIntermediateArray = ContinueBtreeIntermediateArray,
	.SetIntermediateArrayStartEnd = CheckBtreeIntermediateArray,
};

PG_FUNCTION_INFO_V1(bson_btree_extract_path);

Datum
bson_btree_extract_path(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
	{
		PG_RETURN_NULL();
	}

	pgbson *document = PG_GETARG_PGBSON_PACKED(0);
	char *path = text_to_cstring(PG_GETARG_TEXT_PP(1));
	bson_iter_t documentIterator;
	PgbsonInitIterator(document, &documentIterator);

	pgbson_writer writer;
	PgbsonWriterInit(&writer);
	TraverseBson(&documentIterator, path, &writer, &BtreePathExecutionFuncs);
	if (IsPgbsonWriterEmptyDocument(&writer))
	{
		PgbsonWriterAppendNull(&writer, "$", 1);
	}

	pgbson *result = PgbsonWriterGetPgbson(&writer);
	pfree(path);
	PG_FREE_IF_COPY(document, 0);
	PG_RETURN_POINTER(result);
}


static bool
ExtractBtreePathValue(pgbsonelement *element, const StringView *traversePath,
					  void *state)
{
	pgbson_writer *writer = (pgbson_writer *) state;
	PgbsonWriterAppendValue(writer, "$", 1, &element->bsonValue);
	return false;
}


static bool
ContinueBtreeIntermediateArray(void *state, const bson_value_t *value,
							   bool isArrayIndexSearch)
{
	ThrowBtreeArrayTraversalError();
}


static void
CheckBtreeIntermediateArray(void *state, bool isStart)
{
	if (isStart)
	{
		ThrowBtreeArrayTraversalError();
	}
}


pg_noreturn static void
ThrowBtreeArrayTraversalError(void)
{
	ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					errmsg(
						"B-tree BSON path extraction through arrays is not supported")));
	pg_unreachable();
}
