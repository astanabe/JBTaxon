# JBTaxon の生成とインストール
#
#   make all          installmod・exec・fetch・tsv・db を順に行う
#   make install      installexec・installdata を行う (書き込み先によっては sudo で)
#
#   make installmod   生成スクリプトが使う不足モジュールを ./lib/perl5 へ入れる
#   make exec         検索コマンド sciname2japname / japname2sciname を作る
#                     (不足している DB 関連モジュールも build/dbmod に用意する)
#   make fetch        fetch_data.pl でデータを取得する
#   make tsv          generate_tables.pl で TSV を作る
#   make db           generate_database.pl で jbtaxon_VERSION_BUILDDATE.sqlite3 を作る
#   make installexec  検索コマンドを $(BINDIR) へ、DB 関連モジュールを
#                     $(DATADIR)/jbtaxon/lib/perl5 へ入れる
#   make installdata  DB を $(DATADIR)/jbtaxon へ入れる
#   make clean        make が作った一時ファイル (コマンド・build/・lib/・.builddate) を消す
#   make distclean    clean に加え、取得したデータと生成した TSV・DB も全て消す
#
# 取得したデータと生成した TSV・DB は clean では消さない (取得に約93分かかるため)。
# distclean でも、手で置いたもの (手動配置の情報源) と追跡しているファイルは残す。

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share
PERL ?= $(filter /%,$(shell /bin/sh -c 'type perl'))

ifeq ($(PERL),)
$(error perl が見つかりません。PERL=/path/to/perl を指定して下さい)
endif

VERSION := $(shell cat VERSION)

# BUILDDATE は tsv の実行時に .builddate へ書き、db はそれを読む。tsv と db を
# 別の日に実行しても入力 TSV と DB のファイル名の日付が揃うようにするため。
# 新しい日付で作り直すときは make clean するか BUILDDATE=YYYYMMDD を与える。
BUILDDATE ?= $(shell cat .builddate 2>/dev/null || date +%Y%m%d)

DB := jbtaxon_$(VERSION)_$(BUILDDATE).sqlite3
COMMANDS := sciname2japname japname2sciname
JBTAXON_DATADIR := $(DATADIR)/jbtaxon
INSTALL ?= install

# 動作環境のチェック。make を実行するたびに必要なコマンドを探し、無ければ止める
# (pdftotext が無いと、約93分の fetch が終わった後の tsv で初めて止まるため)。
# 前半はスクリプトが使うもの (curl・tar は fetch_data.pl、pdftotext は
# generate_tables.pl)、後半はこの Makefile が使うもの。
# clean と distclean は何も作らないので、コマンドが欠けていても消せるよう調べない。
# poppler-data は (コマンドではないので) 調べない。
REQUIRED_COMMANDS := curl tar pdftotext \
	cat cmp chmod cp date find mkdir rm $(firstword $(INSTALL))
NOCHECK_GOALS := clean distclean
ifneq ($(filter-out $(NOCHECK_GOALS),$(or $(MAKECMDGOALS),all)),)
MISSING_COMMANDS := $(foreach c,$(REQUIRED_COMMANDS),\
	$(if $(shell /bin/sh -c 'command -v $(c)' 2>/dev/null),,$(c)))
ifneq ($(strip $(MISSING_COMMANDS)),)
$(error 必要なコマンドがありません: $(strip $(MISSING_COMMANDS)) (pdftotext は Debian/Ubuntu なら sudo apt install poppler-utils poppler-data))
endif
endif

# 必要な非コアモジュール (各スクリプトの @REQUIRED_MODULES と同じ)
TABLES_MODULES := HTML::TreeBuilder HTML::TableExtract Text::CSV Encode::JIS2K
DB_MODULES     := DBI DBD::SQLite

LOCALLIB := $(CURDIR)/lib/perl5
DBLIB    := $(JBTAXON_DATADIR)/lib/perl5
# cpan の INSTALL_BASE は lib/perl5 のほかに bin/ と man/ も作るので、いったん
# build/ の下に入れてから lib/perl5 だけを写す
MODSTAGE   := $(CURDIR)/build/mod
DBMODSTAGE := $(CURDIR)/build/dbmod

# 引数のモジュールのうち読み込めないものを空白区切りで出す
CHECKMOD = for (@ARGV) { eval "require $$_; 1" or print "$$_ " }

# モジュールを CPAN から入れる前に、CPAN.pm と C コンパイラ ($(PERL) を作った
# ときのもの。XS のモジュールがあるため) があるかを確かめる。入れるものが無ければ
# 要らないので、起動時のチェックには入れない。
CHECK_CPAN_TOOLS = $(PERL) -MCPAN -e 1 2>/dev/null \
	    || { echo "$(PERL) に CPAN.pm がありません" >&2; exit 1; }; \
	cc=`$(PERL) -MConfig -e 'print +(split " ", $$Config{cc})[0]'`; \
	command -v "$$cc" >/dev/null \
	    || { echo "C コンパイラ $$cc がありません (Perl の XS モジュールのビルドに要る)" >&2; exit 1; }

# $(call cpan_install,入れる先,モジュール,追加の検索パス)
# cpan は $(PERL) の CPAN.pm を使う (PATH の cpan が別の perl を指していることがあるため)。
# cpan は失敗しても終了コードを返さないことがあるので、呼び出し側で入ったかを確かめる。
cpan_install = PERL_MM_USE_DEFAULT=1 PERL_MM_OPT="INSTALL_BASE=$(1)" \
	PERL_MB_OPT="--install_base $(1)" PERL5LIB="$(1)/lib/perl5$(if $(3),:$(3))" \
	$(PERL) -MCPAN -e 'CPAN::Shell->install($$_) for @ARGV' $(2)

# PERL・DATADIR・VERSION が変わったら検索コマンドを作り直す (コマンドに埋め込むため)
CONFIG_STAMP := build/config
$(shell mkdir -p build && echo '$(PERL) $(DATADIR) $(VERSION)' | cmp -s - $(CONFIG_STAMP) \
	|| echo '$(PERL) $(DATADIR) $(VERSION)' > $(CONFIG_STAMP))

# 取得したデータと生成した TSV を置くディレクトリ (.gitignore の /<分類群>/* と同じ)
DATA_DIRS := AllTaxa Bryophytes Earthworms Fishes Fungi Insects Isopods Lichens \
	Mammals Nematodes Reptiles_Amphibians Seaweeds Spiders Tanaids VascularPlants \
	Viruses NCBITaxonomy
# DATA_DIRS の中で distclean が残すもの。README.md と wikidata.rq はリポジトリで
# 追跡しているもの、残りは手動配置の情報源 (fetch_data.pl の manual)。
# zip から展開したもの (Mammals/list_20211223/) は消す
KEEP_FILES := AllTaxa/wikidata.rq Mammals/list_20211223.zip \
	Bryophytes/7_9.pdf Bryophytes/9_53.pdf

.PHONY: all install installmod exec dbmod fetch tsv db installexec installdata clean distclean

all:
	$(MAKE) installmod
	$(MAKE) exec
	$(MAKE) fetch
	$(MAKE) tsv
	$(MAKE) db

install:
	$(MAKE) installexec
	$(MAKE) installdata

#-----------------------------------------------------------------------------
# モジュール
#-----------------------------------------------------------------------------
# generate_tables.pl と generate_database.pl は先頭の use lib で
# スクリプトの隣の lib/perl5 を見るので、ここに入れれば使える。
installmod:
	@missing=`$(PERL) -Mlib=$(LOCALLIB) -e '$(CHECKMOD)' $(TABLES_MODULES) $(DB_MODULES)`; \
	if [ -z "$$missing" ]; then \
	    echo "不足している Perl モジュールはありません"; exit 0; \
	fi; \
	echo "不足している Perl モジュール: $$missing"; \
	$(CHECK_CPAN_TOOLS); \
	$(call cpan_install,$(MODSTAGE),$$missing,$(LOCALLIB)); \
	if [ -d $(MODSTAGE)/lib/perl5 ]; then \
	    mkdir -p $(LOCALLIB) && cp -R $(MODSTAGE)/lib/perl5/. $(LOCALLIB)/; \
	fi; \
	still=`$(PERL) -Mlib=$(LOCALLIB) -e '$(CHECKMOD)' $$missing`; \
	if [ -n "$$still" ]; then \
	    echo "インストールできなかった Perl モジュール: $$still" >&2; exit 1; \
	fi

# 検索コマンドが使う DB 関連モジュールのうち、$(PERL)・インストール先・build/dbmod の
# どれにも無いものを build/dbmod に用意する。インストール先へ写すのは installexec。
dbmod:
	@missing=`$(PERL) -Mlib=$(DBLIB) -Mlib=$(DBMODSTAGE)/lib/perl5 -e '$(CHECKMOD)' $(DB_MODULES)`; \
	if [ -z "$$missing" ]; then \
	    echo "不足している DB 関連 Perl モジュールはありません"; exit 0; \
	fi; \
	echo "不足している DB 関連 Perl モジュール: $$missing"; \
	$(CHECK_CPAN_TOOLS); \
	$(call cpan_install,$(DBMODSTAGE),$$missing,); \
	still=`$(PERL) -Mlib=$(DBMODSTAGE)/lib/perl5 -e '$(CHECKMOD)' $$missing`; \
	if [ -n "$$still" ]; then \
	    echo "インストールできなかった Perl モジュール: $$still" >&2; exit 1; \
	fi

#-----------------------------------------------------------------------------
# 検索コマンド
#-----------------------------------------------------------------------------
exec: dbmod $(COMMANDS)

# 先頭に足す $dbdir は --db を省いたときに DB を探すディレクトリ
$(COMMANDS): %: %.pl VERSION $(CONFIG_STAMP)
	echo '#!'$(PERL) > $@
	echo "use lib '$(DBLIB)';" >> $@
	echo "my \$$version = '$(VERSION)';" >> $@
	echo "my \$$dbdir = '$(JBTAXON_DATADIR)';" >> $@
	cat $< >> $@
	chmod 755 $@

#-----------------------------------------------------------------------------
# 生成
#-----------------------------------------------------------------------------
# fetch_data.pl は情報源側のリンク切れ (Seaweeds の Erythropeltidales.html と
# Spiders の naranukagumo) のため全件取得でも常に exit 1 になるので、失敗しても止めない。
# 失敗の一覧は fetch_data.pl の出力の末尾で確かめること。
fetch:
	-$(PERL) fetch_data.pl

tsv:
	echo $(BUILDDATE) > .builddate
	$(PERL) generate_tables.pl --version=$(VERSION) --builddate=$(BUILDDATE)

db:
	$(PERL) generate_database.pl --version=$(VERSION) --builddate=$(BUILDDATE)

#-----------------------------------------------------------------------------
# インストール
#-----------------------------------------------------------------------------
installexec: $(COMMANDS)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL) -m 755 $(COMMANDS) $(DESTDIR)$(BINDIR)/
	@if [ -d $(DBMODSTAGE)/lib/perl5 ]; then \
	    echo "DB 関連 Perl モジュールを $(DESTDIR)$(DBLIB) へ入れます"; \
	    $(INSTALL) -d $(DESTDIR)$(DBLIB) && cp -R $(DBMODSTAGE)/lib/perl5/. $(DESTDIR)$(DBLIB)/; \
	fi

installdata:
	@if [ ! -f $(DB) ]; then \
	    echo "$(DB) がありません。make db で作るか BUILDDATE=YYYYMMDD を指定して下さい" >&2; \
	    exit 1; \
	fi
	$(INSTALL) -d $(DESTDIR)$(JBTAXON_DATADIR)
	$(INSTALL) -m 644 $(DB) $(DESTDIR)$(JBTAXON_DATADIR)/

clean:
	rm -f $(COMMANDS) .builddate
	rm -rf build lib

distclean: clean
	find $(wildcard $(DATA_DIRS)) -mindepth 1 -maxdepth 1 ! -name README.md \
	    $(foreach f,$(KEEP_FILES),! -path $(f)) -exec rm -rf {} +
	rm -f jbtaxon_*.sqlite3 jbtaxon_*.sqlite3.part
