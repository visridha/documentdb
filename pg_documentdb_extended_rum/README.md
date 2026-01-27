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

## Vacuuming & Maintenance

### Original Authors
See [README](https://github.com/postgrespro/rum/blob/master/README.md)
