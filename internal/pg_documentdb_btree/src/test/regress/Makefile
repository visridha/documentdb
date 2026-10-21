BASEPATH:=../../../

REGRESS := 1

PG_CONFIG ?= pg_config
export PG_CONFIG

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

EXTENSIONLOAD := --load-extension=tsm_system_rows --load-extension=pg_cron --load-extension=vector --load-extension=postgis --load-extension=documentdb_core --load-extension=documentdb --load-extension=documentdb_btree

export PG_REGRESS_DIFF_OPTS = -dU10

.PHONY: all check-basic

define common_test
	mkdir -p log && { $(top_builddir)/src/test/regress/pg_regress --encoding=UTF8 --dlpath=$(BASEPATH) $(EXTENSIONLOAD) --temp-instance ./tmp --temp-config ./postgresql.conf --host localhost --port 58050 $(1) 2>&1; echo $$? > log/.exitcode; } | tee log/summary.out; test $$(cat log/.exitcode) -eq 0 || (cat regression.diffs && false)
endef

check-basic:
	$(call common_test,--schedule=./basic_schedule)

all: check-basic
