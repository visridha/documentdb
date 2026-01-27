# DocumentDB RUM - RUM access method

## Introduction

The documentdb_extended_rum access method derives its storage from the RUM index access method which originally derives from Postgres's GIN access method.
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

The documentdb_rum index layout consists of 3 types of PostgreSQL pages:
1) The META page - Stored at Block 0 and contains metadata about the index
2) ENTRY Pages - These store the core index entries that are used for lookups and are laid out as a BTree. The root page for this tree is stored at Block 1.
3) DATA Pages - These are posting trees storing bitmaps of rows matching a given entry The root of each posting tree is committed in the Entry that roots the tree.


### The Entry Tree

The entry tree is the primary B-Tree like data structure that is used for queries. The tree is rooted at the ROOT block (Block 1) and extends outwards with the standard Btree
structure that is similar to GIN. 
Each index entry key structure (by default) in a documentdb_rum index looks similar to a GIN index tuple:
The index starts out with a single ROOT block containing a LEAF Entry page. Each entry inserted into the tree is encoded with an IndexTuple that
contains the serialized index tuple. The index tuple's TID is used to encode row information about the index key. Each key starts out as a Posting List. This is encoded with the
TID containing a `numPostings > 0` into the Offset Number. The IndexTuple is then followed by a variable length PostingList for the index tuple. If the `numPostings` exceeds 65534
or if the indexKey and postings do not fit within a page, then the index key is converted to a Posting Tree. The CTID's offsetNumber is marked as `0xffff`, the BlockId of the CTID then
points to the root block number of the posting tree that will contain the set of rows matching this key.

For the Posting list & tree itself, the primary difference between GIN and the documentdb_rum index is that each posting is not just a TID - but also optionally encodes an `addInfo` which is
an additional metadata datum that can be attached to each row. Therfore a posting item has a 7-bit encoded varbyte BlockId, followed by a 7-bit encoded offset
except for the last byte which is 6-bit encoded, and the 7th bit indicates whether the addInfo is null or not. If it's not null, then the posting is followed by a 1, 2, 4, or 8 byte Datum value
for the `AddInfo`. The usage of this is discussed further below and in the original RUM index [README](https://github.com/postgrespro/rum/blob/master/README.md).

The structure of the addInfo bits looks as follows: Note that the addinfo is only present when not null.
![image](https://github.com/postgrespro/rum/raw/master/img/gin_rum.svg)

Note that unlike GIN, the entry tree has Left and Right Page pointers to ensure we can walk the index forward and backward. Additionally, to support ordered and index scans, we eliminate the pending list.
To see why this is needed see the comment [here](https://github.com/postgres/postgres/blob/master/src/backend/access/gin/ginget.c#L1956)

The entry tree for documentdb_rum also allocates 2 unused bytes in the entry page header for the Vacuum Cycle Id. This is a concept that is borrowed from Btree to do disk order vacuuming for indexes. For further
discussion, please see the section on Vacuuming. DocumentDB Rum entries also set the LP_DEAD flag on index scans unlike RUM index entries to efficiently skip index entries in subsequent scans. This is taken as a reference implementation choice from GiST and Btree. Note that unlike Btree and GIST, we do not opportunistically prune these on page splits unlike Btree. This is because documentdb_rum uses Generic XLog for the WAL apply, and to handle the replica server's conflict XID horizon scenarios would require breaking the replica's transaction on XLogRedo. Since Generic XLog offers no opportunity to do this, we skip this and defer to Vacuum. Being able to do this would require a custom Rmgr implementation which is deferred at this time.

Note that unlike Btree, documentdb_rum pages do not store the high key offset in the page. The Max offset of a given key is the highest key on that page - this will become important when dealing with scenarios like
suffix truncation (see below).

Note that index entries must fit within the 2 KB limit to fit within 1 Postgres block. multi-column entries at the physical layer are handled by creating N disjoint trees within the index. Each index key is then tagged as a tuple of (ColumnId, IndexKey).
Queries against the index must handle these composite entires when scanning the tree. The tree is then layed out as an ordered set of entries that are prefixed by the column id (all column 0 appear before column 1 etc). For discussions on Composite ordered index (btree style) see the discussion on Operator class extensibility below.

### The Posting Tree
When a given index entry gets too big for a Block or does not fit within a block (factoring in page splits) etc, as discussed above, the posting list is then converted to a posting tree, and a pointer to it is stored
in the original entry. The posting tree itself starts out similarly, as a single LEAF block containing just a posting list. As the set of entries grows, the leaf page can be split into interior and leaf children through
page splits similar to the entry tree. Once again, similar to Entry Trees, documentdb_rum Posting Tree pages differ from GIN posting tree pages by having left and right pointers supporting forward and reverse walks of the
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

The documentdb_rum index offers 3 types of index behaviors and the operator class extensibility is extended to handle each of these scenarios:
1) Classic GIN style indexes - these can be the inverted index text index style indexes or jsonb operator classes that support equality, or simple range scans with TID based intersections.
2) Extended information text indexes - These are the type of indexes that the RUM index was intended to deal with with order_by based on the full text score or relevance baked into the index
3) Btree style inverted indexes - these support btree style indexes on json style data that can do btree style operations, as well as GIN style operations on the same data.

Each type of index offers a subset of operator class support functions to emulate the behavior of the index.

Note that the documentdb_rum index offers arbitrary numbers of operators that can be declared for the operator class, as well as ORDER BY operators that can be used against the op-class. The following table lists the set of support functions for the index:

| Name |   Description   | Required | Number | Scenario | Notes |
| ---------------| -------- | ---------| ------------| ------| --- |
| compare | compare two keys and return an integer less than zero, zero, or greater than zero, indicating whether the first key is less than, equal to, or greater than the second | Yes | 1 | All | Same as GIN/RUM |
| extractValue | 	extract 0 or more keys from a value to be indexed (can be arbitrarily many) | Yes | 2 | All | Same as GIN/RUM
| extractQuery | extract keys from a query condition | Yes | 3 | All | Same as GIN/RUM |
| consistent | determine whether value matches query condition (Boolean variant) (optional if support function 6 is present) | Yes | 4 | All | Same as GIN/RUM |
| comparePartial | compare partial key from query and key from index, and return an integer less than zero, zero, or greater than zero, indicating whether the scan should ignore this index entry, treat the entry as a match, or stop the index scan | No | 5 | All | Same as GIN/RUM |	
| config | Configure the index_am behavior - for addinfo, natural sorting behavior for metadata, sparse key behavior etc. | No | 6 | 2 & 3 | Used in RUM, Extended in documentdb_rum to handle sparse index storage, etc |
| preconsistent | Similar to the consistent function - if implemented, supports a fast intersection between a high cardinality & low cardinality term | No | 7 | All | Same as RUM |
| ordering | Defines ordering behavior for order by distance for text-like indexes, or addinfo style indexes. On Btree style indexes, used to project the order operator result from the index key in the type of the operator's return type | No | 8 | 2 & 3 | Used in RUM for distance ordering. Used in Btree for covered index queries as well as order scan queries | Used in RUM, extended in documentdb_rum for ordering of Btree style indexes |
| outer/inner ordering | Defines ordering behavior when an order by attach index is specified with an alternate ordering for text style indexes. For Btree style indexes, provides a way to project the index key for various internal operations needed within the index (e.g. suffix truncation, skip scans, etc where operator class cooperation is needed) | No | 9 | 2 & 3 | Present in RUM, extended in documentdb_rum to handle skip_scan queries |
| addinfo join | | No | 10 | 2 | |
| operator class config | Custom proc that allows operator class options to be configured | No | 11 | All | Same as GIN but with a different support number. Not supported in RUM |
| canPreconsistent | Preconsistent assumes that all operators in the operator class support fast scans. This allows opt-in for specific operators as needed | No | 12 | All | Net new in documentdb_rum for opt-in for fast scans |

The section on query scans describes how these operator class support functions are used in various paths.

## Index Builds & Inserts
The index build and insert process follows the GIN logic pretty closely - including the integration for parallel index build. The primary difference is that documentdb_rum uses Generic_Xlog for writing out WAL (which is also elided in the case of build) One important callout is that documentdb_rum adds an option in the `config` proc such that documents that don't generate any index keys can opt to not insert any terms into the index. This is different than GIN and RUM that insert an "EMPTY" entry in this case. This helps reduce storage overhead for sparse or wildcard style indexes.

Additionally, the logic from GIN around incomplete page splits was missed when RUM was ported, and documentdb_rum ports that logic over to the index to avoid "Lost path" errors during inserts.

## Scans
The documentdb_rum index supports 4 types of scans of the index:
1) Fast Scans: These are scans that try to get fast intersections of equality keys between high cardinality and low cardinality keys by skipping TID ranges of high cardinality keys during the intersection. These require preconsistent to be implemented in the op-class and only work on equality joins.
2) Regular Scans: These are the bread-and-butter type scans of the GIN index and are implemented pretty-close to the GIN implementation. Some of the performance improvements of skipping posting tree ranges are added which model past attempts to add these into GIN (which was based off of the Fast scan approach RUM added originally).
3) Full Scans: These are scans that end up scanning the entire GIN/RUM index - used primarily in JSONB/Text style scans that may need to scan non-empty entries or ordering entries on the index.
4) Ordered Scans: These are net-new and added in documentdb to support BTree style index scans against an inverted index.

Note that documentdb_rum supports both bitmap scans and index scans. Characteristics for each are called out below.

### Fast Scans
Fast Scans are typically used for equality joins of `A && B` where A and B are equality predicates and is optimized for the case where A has high cardinality and B has low cardinality. This only works on an opclass that has:
- compare
- extractValue
- extractQuery
- consistent
- preconsistent
- (optional) canPreconsistent

Fast Scans start the scan by running extractQuery against the given keys. If none of them require range scans (comparePartial), then they're eligible for fast scans if canPreconsistent doesn't exist or canPreconsistent says it's available.
The query then traverses the entry tree to each entry's leaf entry. The query then sorts the entries by estimated number of postings (for posting trees this is calculated).

The query then walks the entries in order (from lowest cardinality to highest cardinality) and intersects TIDs, binary searching the posting trees for the next available TIDs as needed. Once a TID is found that matches all predicates, it is returned to the calling indexscan/bitmap scan.

## Vacuuming & Maintenance

### Original Authors
See [README](https://github.com/postgrespro/rum/blob/master/README.md)
