# DocumentDB Extended RUM - RUM access method

## Introduction

The documentdb_extended_rum (or extended_rum for short) access method derives its storage from the RUM index access method which originally derives from Postgres's GIN access method.
GIN and RUM were optimized for full text search type scenarios and were then extended to handle JSONB based schema-free inverted index queries as well. 
As this was extended towards the documentdb's BSON types, modifications were made to support more schema free scenarios.

Note that the folloiwng invariants are true:
1) From a storage standpoint, its content on disk is backwards compatible with that of RUM (it is fully back-wards compatible)
2) All changes must be made only on the query path and operator class extensibility path or in a way that works for indexes that are built with the default RUM repo.
3) Storage changes were made such that RUM itself could continue functioning on the same stored index

## License

This module is available under the [license](LICENSE) similar to
[PostgreSQL](http://www.postgresql.org/about/licence/).


## Index Structure

The extended_rum index layout consists of 3 types of PostgreSQL pages:
1) The META page - Stored at Block 0 and contains metadata about the index
2) ENTRY Pages - These store the core index entries that are used for lookups and are laid out as a BTree. The root page for this tree is stored at Block 1.
3) DATA Pages - These are posting trees storing bitmaps of rows matching a given entry The root of each posting tree is committed in the Entry that roots the tree.

![Index structure](./images/extended_rum_index_structure.png)


### The Entry Tree

The entry tree is the primary B-Tree like data structure that is used for queries. The tree is rooted at the ROOT block (Block 1) and extends outwards with the standard Btree
structure that is similar to GIN. 
Each index entry key structure (by default) in a extended_rum index looks similar to a GIN index tuple:
The index starts out with a single ROOT block containing a LEAF Entry page. Each entry inserted into the tree is encoded with an IndexTuple that
contains the serialized index tuple. The index tuple's TID is used to encode row information about the index key. Each key starts out as a Posting List. This is encoded with the
TID containing a `numPostings > 0` into the Offset Number. The IndexTuple is then followed by a variable length PostingList for the index tuple. If the `numPostings` exceeds 65534
or if the indexKey and postings do not fit within a page, then the index key is converted to a Posting Tree. The CTID's offsetNumber is marked as `0xffff`, the BlockId of the CTID then
points to the root block number of the posting tree that will contain the set of rows matching this key.

For the Posting list & tree itself, the primary difference between GIN and the extended_rum index is that each posting is not just a TID - but also optionally encodes an `addInfo` which is
an additional metadata datum that can be attached to each row. Therfore a posting item has a 7-bit encoded varbyte BlockId, followed by a 7-bit encoded offset
except for the last byte which is 6-bit encoded, and the 7th bit indicates whether the addInfo is null or not. If it's not null, then the posting is followed by a 1, 2, 4, or 8 byte Datum value
for the `AddInfo`. The usage of this is discussed further below and in the original RUM index [README](https://github.com/postgrespro/rum/blob/master/README.md).

The structure of the addInfo bits looks as follows: Note that the addinfo is only present when not null.
![image](https://github.com/postgrespro/rum/raw/master/img/gin_rum.svg)

Note that unlike GIN, the entry tree has Left and Right Page pointers to ensure we can walk the index forward and backward. Additionally, to support ordered and index scans, we eliminate the pending list.
To see why this is needed see the comment [here](https://github.com/postgres/postgres/blob/master/src/backend/access/gin/ginget.c#L1956)

The entry tree for extended_rum also allocates 2 unused bytes in the entry page header for the Vacuum Cycle Id. This is a concept that is borrowed from Btree to do disk order vacuuming for indexes. For further
discussion, please see the section on Vacuuming. DocumentDB Rum entries also set the LP_DEAD flag on index scans unlike RUM index entries to efficiently skip index entries in subsequent scans. This is taken as a reference implementation choice from GiST and Btree. Note that unlike Btree and GIST, we do not opportunistically prune these on page splits unlike Btree. This is because extended_rum uses Generic XLog for the WAL apply, and to handle the replica server's conflict XID horizon scenarios would require breaking the replica's transaction on XLogRedo. Since Generic XLog offers no opportunity to do this, we skip this and defer to Vacuum. Being able to do this would require a custom Rmgr implementation which is deferred at this time.

Note that unlike Btree, extended_rum pages do not store the high key offset in the page. The Max offset of a given key is the highest key on that page - this will become important when dealing with scenarios like
suffix truncation (see below).

Note that index entries must fit within the 2 KB limit to fit within 1 Postgres block. multi-column entries at the physical layer are handled by creating N disjoint trees within the index. Each index key is then tagged as a tuple of (ColumnId, IndexKey).
Queries against the index must handle these composite entires when scanning the tree. The tree is then layed out as an ordered set of entries that are prefixed by the column id (all column 0 appear before column 1 etc). For discussions on Composite ordered index (btree style) see the discussion on Operator class extensibility below.

### The Posting Tree
When a given index entry gets too big for a Block or does not fit within a block (factoring in page splits) etc, as discussed above, the posting list is then converted to a posting tree, and a pointer to it is stored
in the original entry. The posting tree itself starts out similarly, as a single LEAF block containing just a posting list. As the set of entries grows, the leaf page can be split into interior and leaf children through
page splits similar to the entry tree. Once again, similar to Entry Trees, extended_rum Posting Tree pages differ from GIN posting tree pages by having left and right pointers supporting forward and reverse walks of the
posting tree. Each posting can still be an ItemPointer with an addinfo similar to that of a PostingList. The Posting Tree leaves store the max item per page in the first entry (similar to that of a btree). Consequently, each
leaf page has a "RumItem" buffer in the prefix pointing to the highest entry stored in that block.

The tail of a Posting Tree page also has a set of "item indexes" which store the Posting at the "Nth" offset of the page. This is used in updates and fast scans to skip chunks of a posting tree page if a search reveals that it 
must continue from the middle of a page. These are maintained during updates/inserts.

Posting Tree leaf pages have similar metadata to GIN posting tree pages, with the following modifications:
1) The Vacuum CycleId is added to the page to ensure that disk order bulk delete can be done on posting trees as well
2) Additional bits are added to handle Incomplete Page Splits (to prevent lost path errors): This is ported from GIN and was missing in the original RUM index
3) In the case where addinfo is guaranteed to be null by construction, the root posting tree blockid is stored in the AddInfo Datum of the left most column. This is safe since this Datum is not accessed unless the AddInfo itself is not null
4) Metadata bit flags are added to track LP_DEAD page hints where the entire posting tree page is dead (similar to LP_DEAD handling for PostingLists in btree). Note that this doesn't exist for GIN or RUM but is a concept added to docmentdb_rum based on the reference implementation in GiST and Btree.

## Operator class Extensibility

The extended_rum index offers 3 types of index behaviors and the operator class extensibility is extended to handle each of these scenarios:
1) Classic GIN style indexes - these can be the inverted index text index style indexes or jsonb operator classes that support equality, or simple range scans with TID based intersections.
2) Extended information text indexes - These are the type of indexes that the RUM index was intended to deal with with order_by based on the full text score or relevance baked into the index
3) Btree style inverted indexes - these support btree style indexes on json style data that can do btree style operations, as well as GIN style operations on the same data.

Each type of index offers a subset of operator class support functions to emulate the behavior of the index.

Note that the extended_rum index offers arbitrary numbers of operators that can be declared for the operator class, as well as ORDER BY operators that can be used against the op-class. The following table lists the set of support functions for the index:

| Name |   Description   | Required | Number | Scenario | Notes |
| ---------------| -------- | ---------| ------------| ------| --- |
| compare | compare two keys and return an integer less than zero, zero, or greater than zero, indicating whether the first key is less than, equal to, or greater than the second | Yes | 1 | All | Same as GIN/RUM |
| extractValue | 	extract 0 or more keys from a value to be indexed (can be arbitrarily many) | Yes | 2 | All | Same as GIN/RUM
| extractQuery | extract keys from a query condition | Yes | 3 | All | Same as GIN/RUM |
| consistent | determine whether value matches query condition (Boolean variant) (optional if support function 6 is present) | Yes | 4 | All | Same as GIN/RUM |
| comparePartial | compare partial key from query and key from index, and return an integer less than zero, zero, or greater than zero, indicating whether the scan should ignore this index entry, treat the entry as a match, or stop the index scan | No | 5 | All | Same as GIN/RUM |	
| config | Configure the index_am behavior - for addinfo, natural sorting behavior for metadata, sparse key behavior etc. | No | 6 | 2 & 3 | Used in RUM, Extended in extended_rum to handle sparse index storage, etc |
| preconsistent | Similar to the consistent function - if implemented, supports a fast intersection between a high cardinality & low cardinality term | No | 7 | All | Same as RUM |
| ordering | Defines ordering behavior for order by distance for text-like indexes, or addinfo style indexes. On Btree style indexes, used to project the order operator result from the index key in the type of the operator's return type | No | 8 | 2 & 3 | Used in RUM for distance ordering. Used in Btree for covered index queries as well as order scan queries | Used in RUM, extended in extended_rum for ordering of Btree style indexes |
| outer/inner ordering | Defines ordering behavior when an order by attach index is specified with an alternate ordering for text style indexes. For Btree style indexes, provides a way to project the index key for various internal operations needed within the index (e.g. suffix truncation, skip scans, etc where operator class cooperation is needed) | No | 9 | 2 & 3 | Present in RUM, extended in extended_rum to handle skip_scan queries |
| addinfo join | | No | 10 | 2 | |
| operator class config | Custom proc that allows operator class options to be configured | No | 11 | All | Same as GIN but with a different support number. Not supported in RUM |
| canPreconsistent | Preconsistent assumes that all operators in the operator class support fast scans. This allows opt-in for specific operators as needed | No | 12 | All | Net new in extended_rum for opt-in for fast scans |

The section on query scans describes how these operator class support functions are used in various paths.

## Index Builds & Inserts
The index build and insert process follows the GIN logic pretty closely - including the integration for parallel index build. The primary difference is that extended_rum uses Generic_Xlog for writing out WAL (which is also elided in the case of build) One important callout is that extended_rum adds an option in the `config` proc such that documents that don't generate any index keys can opt to not insert any terms into the index. This is different than GIN and RUM that insert an "EMPTY" entry in this case. This helps reduce storage overhead for sparse or wildcard style indexes.

Additionally, the logic from GIN around incomplete page splits was missed when RUM was ported, and extended_rum ports that logic over to the index to avoid "Lost path" errors during inserts.

## Scans
The extended_rum index supports 4 types of scans of the index:
1) Fast Scans: These are scans that try to get fast intersections of equality keys between high cardinality and low cardinality keys by skipping TID ranges of high cardinality keys during the intersection. These require preconsistent to be implemented in the op-class and only work on equality joins.
2) Regular Scans: These are the bread-and-butter type scans of the GIN index and are implemented pretty-close to the GIN implementation. Some of the performance improvements of skipping posting tree ranges are added which model past attempts to add these into GIN (which was based off of the Fast scan approach RUM added originally).
3) Full Scans: These are scans that end up scanning the entire GIN/RUM index - used primarily in JSONB/Text style scans that may need to scan non-empty entries or ordering entries on the index.
4) Ordered Scans: These are net-new and added in documentdb to support BTree style index scans against an inverted index.

Note that extended_rum supports both bitmap scans and index scans. Characteristics for each are called out below.

### Fast Scans
Fast Scans are typically used for equality joins of `A && B` where A and B are equality predicates and is optimized for the case where A has high cardinality and B has low cardinality. This only works on an opclass that has:
- compare
- extractValue
- extractQuery 
- consistent
- preconsistent
- (optional) canPreconsistent

Fast Scans start the scan by running extractQuery against the given keys. If none of them require range scans (partialMatch), then they're eligible for fast scans if canPreconsistent doesn't exist or canPreconsistent says it's available.
The query then traverses the entry tree to each entry's leaf entry. The query then sorts the entries by estimated number of postings (for posting trees this is calculated).

The query then walks the entries in order (from lowest cardinality to highest cardinality) and intersects TIDs, binary searching the posting trees for the next available TIDs as needed. Once a TID is found that matches all predicates, it is returned to the calling indexscan/bitmap scan. Note that in the case of fast scans, if the candidate TID is not found in the current page, the search will walk up to the parent page and 'search' the appropriate posting tree page - skipping irrelevant chunks of the posting tree in the process using the intermediate nodes.

### Regular Scans
Regular scans are the bread & butter of the standard GIN and RUM Text Search and Json style queries. This works using the following operator classes:
- compare
- extractValue
- extractQuery
- consistent
- comparePartial

TO DO.

## Vacuuming & Maintenance

TO DO.

### Bulk Delete
As a refresher, at a high level vacuum for GIN/RUM indexes work as follows:
- Vacuum walks to the left-most leaf child of the entry tree from the root. Entry leaves are then visited from left to right (in tree order).
- For each leaf, the postings for each entry are cleaned up. Note: The empty entries are not cleaned up from the tree. While walking the entries, the posting tree roots are collected in memory.
- Once the entry page is cleaned up, the posting trees on that page are visited. For each posting tree, it walks to th eleft most leaf and prunes postings from the posting tree.
- After the leaves of each posting tree is cleaned up, the root posting tree is locked exclusively, and the tree is walked again, and empty posting tree pages are pruned.

The downsides of this vacuum process (specifically around documentdb style indexes) are the following:
- The tree ordered walk for bulk delete meant that for large indexes and slower disks, where buffer reading latency may be non-trivial, the vacuum performance can degrade

## Deltas over the default RUM index

The following list cover the changes made over PostgresPro RUM's physical implementation. The grouping is done by file/intent. Files that were left identical (outside of style changes) are marked as N/A.

- rumbtree.c
    -  `[INCOMPLETE SPLIT]` This file has deltas to support lost path errors/incomplete splits. This ported the changes that were already present in the GIN index. RUM was forked from GIN in Postgres 9.3. Over PG 9.4 to PG 15, there were many changes in the GIN index to support incomplete splits and lost path errors. rumInsertOld tracks the logic that was present in RUM. rumInsertNew ports the same logic from ginbtree.c for rumPlaceToPage, rumFinishOldSplit, and rumFinishSplit. The main delta is on the actual page contents which uses the RUM leaf page state. There was one additional refactor to remove some local fields to make them function parameters in RumBtreeStack which are not ported.
- rumdatapage.c
    - `[REFACTOR]` Calls to `RumPageGetOpaque(page)->maxoff` was replaced with a macro `RumDataPageMaxOff(page)` for clarity. Calls to `RumPostingItemGetBlockNumber` got renamed to `PostingItemGetBlockNumber`. Calls to `RumPageGetOpaque(page)->freespace` got replaced with a macro `RumDataPageReadFreeSpaceValue`. Calls to `RumItemPointerSetMin` got renamed to `ItemPointerSetMin`
    - `[TESTING]` There's a test GUC for `RumDataPageIntermediateSplitSize` which forces a page split if the number of entries exceeds this test GUC to be able to test page splits on data pages. Never on in prod.
    - `[LP_DEAD]` dataPlaceToPage/dataSplitPageLeaf/dataSplitPageInternal/rumInsertItemPointers: Adds support for `LP_DEAD` on data pages. On place to/split of a page, revive the page (set the page flags to not be dead).
    - `[VACUUM]` dataSplitPageLeaf/dataSplitPageInternal: If the disk order vacuum is enabled, then set the vacuum cycle id on the page header from the shared memory state on a page split (borrowed logic from btree vacuum).
    - `[PERFORMANCE]` updateItemIndexes: Improve performance of reading ItemPointers from a posting list. Use static state blocknoIncr that we use to recompute delta state. This is borrowing the idea from gin's logic to read ItemPointers from a posting list. This uses a test GUC `RumUseNewItemPtrDecoding`
    - `[INCOMPLETE SPLIT]` rumPrepareDataScan: Add support for filling RumBtreeStack for incomplete split. This is similar to the logic in GIN for incomplete split - but the WAL logic is ported to generic xlog.
- rumentrypage.c
    - `[PERFORMANCE]` rumReadTuple: Apply the faster reads of ItemPointers under `RumUseNewItemPtrDecoding`
    - `[VACUUM]`: entryIsMoveRight: skip half dead pages when traversing the tree. Similar to btree.
    - `[VACUUM]`: entrySplitPage: If the disk order vacuum is enabled, then set the vacuum cycle id on the page header from the shared memory state on a page split (borrowed logic from btree vacuum).
    - `[TESTING]`: Add some asserts for the itemId written into a page
    - `[INCOMPLETE SPLIT]` rumPrepareEntryScan: Add support for filling RumBtreeStack for incomplete split. This is similar to the logic in GIN for incomplete split.
- rumvalidate.c
    - `[OPCLASS]`: Add validation of the operator classes to support ordering functions and auxiliary support functions for ordered scans.
- rumsort.c
    - `[REFACTOR]`: Strip all the includes below pg15 for the tuplesort copy
    - `[REGULARSCAN]`: Add support for minimal tuples in the tuplestore that has JUST the TID and no extra data for the collectMatchBitmap
- rumutil.c
    - `[REFACTOR]`: Move all the rum options and GUCs into rumconfigs.c.
    - `[PARALLELBUILD]`: Register options in the indexamhandler for `amcanbuildparallel`. Also port `rumbuildphasename` from GIN's parallel build, and add stage names for Writing WAL a the end of the build.
    - `[VACUUM]`: port adding amusemaintenanceworkmem, amparallelvacuumoptions to match what was set in GIN (RUM was missing this).
    - `[OPCLASS]`: Add amoptsprocnum into the indexam handler to match what GIN does to support operator class options in Postgres.
    - `[PARALLELSCAN]`: Register entrypoints for amestimateparallelscan, ruminitparallelscan, rumparallelrescan in the index am
    - `[SPARSEINDEX]`: Add option for `skipGenerateEmptyEntries` to skip generating the `NULL` entry on datums that don't generate terms. Populate this from the rumConfig struct. in `rumExtractEntries`, honor that and don't generate a null term if requested.
    - `[FASTSCAN]`: Add a support function `RUM_CAN_PRE_CONSISTENT_PROC` that allows operator classes to declare whether they support fast scans on that operator or not (RUM default assumes that all non-compare partial operators can support fast scans, but some operators can have disjunctions in the entries). Populate the RumState with it.

- rumconfigs.c
    - `[REFACTOR]` New file in extended_rum. Has all the GUCs and rum options that was previously in rumutil.c.
    - `[REFACTOR]`: Add GUCs for all the different new settings introduced.


- btree_rum.c: N/A
- disable_core_macros.h: N/A
- qsort_tuple.c: N/A
- rum_arr_utils.c: N/A
- rumbulk.c: N/A
- rumtsquery.c: N/A


TODO Files:
- rumvacuum.c
- rumscan.c
- ruminsert.c
- rumget.c
- rum.h/pg_documentdb_rum.h

### Original Authors
See [README](https://github.com/postgrespro/rum/blob/master/README.md)
