EXTENSION = documentdb_btree
MODULE_big = pg_$(EXTENSION)
EXTVERSION = 1.0
PGFILEDESC = "DocumentDB experimental B-tree index access method"

OSS_SRC_DIR = ../../

SOURCES = $(wildcard src/*.c)
OBJS = $(patsubst %.c,%.o,$(SOURCES)) $(WIN32RES)

SQL_DEPDIR=.deps/sql
SQL_BUILDDIR=build/sql

template_sql_files = $(wildcard sql/*.sql)
generated_sql_files = $(patsubst %,build/%,$(template_sql_files))
DATA_built = $(generated_sql_files)

OSS_COMMON_SQL_HEADER = $(wildcard $(OSS_SRC_DIR)/common_header.sql)

SKIP_API_SCHEMA = yes
USE_DOCUMENTDB = 1
USE_DOCUMENTDB_CORE = 1
CORE_SCHEMA_NAME=documentdb_core
EXTENSION_OBJECT_PREFIX=documentdb_btree
include $(OSS_SRC_DIR)/Makefile.cflags
include $(OSS_SRC_DIR)/Makefile.global

override LDFLAGS_SL += -fvisibility=hidden -DHAVE_VISIBILITY_ATTRIBUTE=1
override CFLAGS += -fvisibility=hidden -DHAVE_VISIBILITY_ATTRIBUTE=1
override CXXFLAGS += -fvisibility=hidden -DHAVE_VISIBILITY_ATTRIBUTE=1

.PHONY: check check-regress build-sql clean-sql citus-indent

check:
	$(MAKE) -C src/test all

check-regress:
	$(MAKE) -C src/test check-regress

build-sql: $(generated_sql_files)

clean-sql:
	rm -rf .deps/ build/

citus-indent:
	citus_indent

$(generated_sql_files): build/%: % $(OSS_COMMON_SQL_HEADER)
	@mkdir -p $(SQL_DEPDIR) $(SQL_BUILDDIR)
	cpp -undef -w $(SQL_DEFINES) -imacros $(OSS_COMMON_SQL_HEADER) -I$(OSS_SRC_DIR) -P -MMD -MP -MF$(SQL_DEPDIR)/$(*F).Po -MT$@ $< > $@
