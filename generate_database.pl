#!/usr/bin/perl
#
# generate_database.pl - 分類群ごとのテーブル TSV を集約して
#                        単一の SQLite3 データベースを生成する
#
# パイプラインの第3段。generate_tables.pl が各分類群ディレクトリに書き出した
# japname2sciname_VERSION_BUILDDATE.tsv と sciname2japname_VERSION_BUILDDATE.tsv を
# 読み、リポジトリルートに jbtaxon_VERSION_BUILDDATE.sqlite3 を作る。
#
# 同じ名前がディレクトリをまたいで別の学名・和名・有効性フラグを持つことがある。
# ここで解決する衝突は**ディレクトリ間の衝突**だけで、名前ごとの有効名／シノニムの
# 判定 (Catalogue of Life・NCBI Taxonomy を引くもの) は第2段で済んでいる。
#
# 分類群ディレクトリどうしは扱う生物がまったく違うので、原則として比べない
# (どちらの行も残す)。比べるのは「上位」と決めたディレクトリとの間だけ。
#   AllTaxa ... 他の全ディレクトリが上位 (全生物を広く扱うので、専門のリストに従う)
#   Lichens ... Seaweeds と Fungi が上位 (藻類・菌類と重なる名前は藻類・菌類に従う)
# 上位のディレクトリの判定に従うのは、**上位が同じ組 (和名と学名の対) を持つとき
# だけ**。和名には分類群をまたぐ同名異物があるので (「ツルタケ」は YList では
# タケのシノニム、Wikidata では菌類の Amanita vaginata)、名前だけで比べると
# 別の生物についての判定を当ててしまう。
#   有効性 ... 上位が同じ組を持てば、その組での上位の判定に従う
#              (上位が複数あって割れたら、どれかが有効としていれば有効)
#   行     ... 同じ組を上位が持てば上位の行だけを残す。上下関係のない
#              ディレクトリどうしで同じ組を持つときは、どちらの行も残す
# 解決後に有効でなくなった名前を2列目に持つ行は落とす (2列目にシノニムは現れない)。
#
# もう1つの仕事は、Catalogue of Life と NCBI Taxonomy の**体系全体**を DB に入れ、
# DB の各組をその節点に結び付けること (taxonlink)。検索スクリプトが同名異物を
# 系統で絞り込むのに使う。参照データ (AllTaxa/NameUsage.tsv、NCBITaxonomy の
# nodes.dmp / names.dmp / merged.dmp、AllTaxa/qid2ncbi_VERSION_BUILDDATE.tsv) は
# **1回だけ**読み、DB の表に入れると同時にメモリ上にも表を作って結び付けを解く。
# 参照データが1つでも無ければ DB を作らない (体系の欠けた DB を正式な名前で
# 書くと、次の実行がそれを飛ばしてしまう)。
#
# スキーマ:
#   japname2sciname (japname, sciname, japvalid, rank, subrank,
#                    sourcetitle, sourceauthor, sourceurl, taxondir)
#   sciname2japname (sciname, japname, scivalid, rank, subrank,
#                    sourcetitle, sourceauthor, sourceurl, taxondir)
#     taxondir は行の由来の分類群ディレクトリ。同じ組がディレクトリごとに別の行に
#     なるので、主キーは (1列目, 2列目, taxondir)。2列目にも索引を張る。
#   rank (rank, name) ... rank.def をそのまま入れたもの (1つの番号に複数の名前)
#   meta (key, value) ... version / builddate
#   hierarchy_col (id, parent, status, rank, name, authorship, alternativeid,
#                  namealternativeid)
#     NameUsage.tsv の全行。シノニムの parent は有効名を指す (ColDP の定義のまま)。
#     status は 1 = 有効名 (accepted / provisionally accepted)、0 = それ以外。
#     rank・name は CoL の表記のまま (rank.def に無い階級がある)。
#   hierarchy_ncbi (taxid, parent, rank) ... nodes.dmp。rank は NCBI の表記のまま
#   names_ncbi (taxid, name, class)      ... names.dmp の全行 (authority 等も含む)
#   merged_ncbi (old_taxid, new_taxid)   ... merged.dmp
#   association_col_ncbi (colid, taxid, method)
#     CoL の有効名の節点と NCBI の節点の対応。method は根拠で、
#       ncbi     ... CoL の alternativeID の「ncbi:txid…」
#       wikidata ... CoL の alternativeID の Wikidata QID が P685 で taxid を持つ
#       name     ... 学名の一致。NCBI 側で最も近い対応済みの祖先が、CoL 側でも
#                    祖先にいるものだけ (系統で同名異物を除く)
#   taxonlink (japname, sciname, taxondir, colid, colmethod, ncbiid, ncbimethod)
#     DB の組 (ディレクトリごと) と体系の節点の対応。colid は CoL の有効名の節点、
#     ncbiid は NCBI の節点。決まらなければ空 (NULL)。method は根拠で、
#       id          ... taxonhint の col:<ID> / ncbi:<taxid>
#       wikidata    ... taxonhint の wikidata:<QID> を CoL の alternativeID /
#                       qid2ncbi で引いたもの
#       name        ... 学名の一致。手がかり (sources.tsv の root、taxonhint の
#                       anc、wdparent の名前) があれば、祖先に最も多く当たる
#                       ただ1つの候補だけを採り、1つも当たらなければ採らない
#       association ... もう一方の体系の節点から association_col_ncbi で引いたもの

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use Encode ();
use File::Spec;
use Getopt::Long;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

#-----------------------------------------------------------------------------
# 依存チェック
#
# SQLite3 は DBI + DBD::SQLite で書く。sqlite3 コマンドには依存しない。
#-----------------------------------------------------------------------------
my @REQUIRED_MODULES = (
    [ 'DBI',         'libdbi-perl',         'データベースへの接続' ],
    [ 'DBD::SQLite', 'libdbd-sqlite3-perl', 'SQLite3 データベースの作成' ],
);

check_dependencies();

#-----------------------------------------------------------------------------
# 定数
#-----------------------------------------------------------------------------
my @KINDS = ('japname2sciname', 'sciname2japname');

# 最終 TSV の列数 (1列目 / 2列目 / 有効性 / rank / subrank / 出典3列)
my $N_COLUMNS = 8;

# 系統の手がかり (第2段の出力。japname / sciname / sourceid / ids / anc)
my $HINT_KIND = 'taxonhint';
my $N_HINT_COLUMNS = 5;

# Catalogue of Life の col:status のうち有効名でないもの (generate_tables.pl と同じ)。
# 有効名の節点に辿るときは、このうち misapplied と bare name を使わない
# (誤用や裸名は、parent の指す分類群と同じものとは言えないため)。
my %COL_INVALID_STATUS = map { $_ => 1 } (
    'synonym', 'ambiguous synonym', 'misapplied', 'bare name',
);
my %COL_UNRELATED_STATUS = map { $_ => 1 } ('misapplied', 'bare name');

# NCBI Taxonomy の name class のうち、その節点の名前として学名を突き合わせるもの。
# includes / in-part は別の分類群、authority / type material は学名そのものではない。
my %NCBI_MATCH_CLASS = map { $_ => 1 } ('scientific name', 'synonym', 'equivalent name');

# 祖先を辿るときの上限 (循環への備え)
my $MAX_DEPTH = 300;

# 全生物を扱うディレクトリ。他の全ディレクトリを上位とする。
my $ALLTAXA_DIR = 'AllTaxa';

# AllTaxa 以外で上下関係のあるディレクトリ。キーのディレクトリは、値の
# ディレクトリと同じ組を持つときにそちらに従う。地衣類は菌類と藻類の共生体で、
# 名前が菌類・藻類のリストと重なったときはそちらを優先する。
my %SUPERIOR_DIRS = (
    'Lichens' => [ 'Seaweeds', 'Fungi' ],
);

#-----------------------------------------------------------------------------
# ソース定義 (sources.tsv)。ここではディレクトリの一覧と並び順に使う。
#-----------------------------------------------------------------------------
my @SOURCES = read_sources();

#-----------------------------------------------------------------------------
# CLI
#-----------------------------------------------------------------------------
my $basedir;
my @only;
my $force   = 0;
my $opt_ver;
my $opt_build;
my $do_list = 0;
my $dry_run = 0;
my $help    = 0;

Getopt::Long::Configure('bundling');
GetOptions(
    'dir=s'       => \$basedir,
    'only=s'      => \@only,
    'force'       => \$force,
    'version=s'   => \$opt_ver,
    'builddate=s' => \$opt_build,
    'list'        => \$do_list,
    'dry-run'     => \$dry_run,
    'help|h'      => \$help,
) or usage(2);
usage(0) if $help;

$basedir = defined $basedir ? $basedir : dirname(abs_path($0));
$basedir = abs_path($basedir) || $basedir;

my @dirs = uniq(map { $_->{dir} } @SOURCES);
if (@only) {
    my %known = map { lc($_) => 1 } @dirs;
    for my $name (@only) {
        next if $known{ lc $name };
        print STDERR "不明なディレクトリ名です: $name\n";
        print STDERR '指定可能な名前: ' . join(', ', @dirs) . "\n";
        exit 2;
    }
    my %want = map { lc($_) => 1 } @only;
    @dirs = grep { $want{ lc $_ } } @dirs;
}

if ($do_list) { list_dirs(\@dirs); exit 0 }

#-----------------------------------------------------------------------------
# 下ごしらえ
#-----------------------------------------------------------------------------
# 入力の TSV と出力の DB に同じ日付を使うので、ビルド日は省略させない。
unless (defined $opt_build) {
    print STDERR "--builddate を指定して下さい (入力の TSV と同じ日付)。\n\n";
    usage(2);
}
unless ($opt_build =~ /^\d{8}$/) {
    print STDERR "--builddate は YYYYMMDD 形式で指定して下さい: $opt_build\n";
    exit 2;
}
my $VERSION   = defined $opt_ver ? $opt_ver : read_version();
my $BUILDDATE = $opt_build;
my @RANK_DEF  = read_rank_def();

my $t_start = time;
my $n_fail  = 0;
my @failures;

# 実際の処理はファイル末尾の「実行」ブロックで行う。

#-----------------------------------------------------------------------------
# 入力の読み込み
#-----------------------------------------------------------------------------
sub input_path {
    my ($dir, $kind) = @_;
    return File::Spec->catfile($basedir, $dir, "${kind}_${VERSION}_${BUILDDATE}.tsv");
}

# 1ファイルを読み、行を [ 1列目, 2列目, 有効性, rank, subrank, 表題, 著者, URL,
# ディレクトリ ] の配列で返す。
sub read_table {
    my ($dir, $kind) = @_;
    my $path = input_path($dir, $kind);
    my @rows;
    open my $fh, '<', $path or do {
        record_failure("$dir/$kind", "入力ファイルを読めません: " . relname($path) . ": $!");
        return \@rows;
    };
    binmode $fh, ':encoding(UTF-8)';
    my $n_bad = 0;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        next unless length $line;
        my @f = split /\t/, $line, -1;
        if (@f != $N_COLUMNS || $f[2] !~ /^[01]$/ || $f[3] !~ /^\d+$/ || $f[4] !~ /^\d+$/) {
            $n_bad++;
            next;
        }
        push @rows, [ @f, $dir ];
    }
    close $fh;
    record_failure("$dir/$kind", "形式の崩れた行が $n_bad 行あります (読み飛ばしました)")
        if $n_bad;
    return \@rows;
}

#-----------------------------------------------------------------------------
# 衝突解決
#-----------------------------------------------------------------------------
# そのディレクトリが従う上位のディレクトリ (読み込んだものだけ)。
sub superiors {
    my ($dir, $loaded) = @_;
    my @sup = $dir eq $ALLTAXA_DIR
            ? grep { $_ ne $ALLTAXA_DIR } keys %$loaded
            : @{ $SUPERIOR_DIRS{$dir} || [] };
    return grep { $loaded->{$_} } @sup;
}

# ディレクトリごとの判定を集める。ディレクトリ内では名前の有効性は第2段が1つに
# 決めている (1列目はその行のフラグ、2列目は必ず有効名)。組はどちらの表に
# 出てきても同じ組として扱う。
#   $ctx->{own}{$dir}{"j\t和名"} / {"s\t学名"} ... そのディレクトリでの有効性
#   $ctx->{pair}{$dir}{"和名\t学名"}            ... そのディレクトリが持つ組
sub collect_judgments {
    my ($tables, $stats) = @_;
    my (%own, %flagged, %pair);
    my $note = sub {
        my ($dir, $key, $valid, $is_flag) = @_;
        my $cur = $own{$dir}{$key};
        if (!defined $cur) {
            $own{$dir}{$key} = $valid;
            $flagged{$dir}{$key} = $is_flag;
            return;
        }
        return if $cur == $valid;
        # 第2段が整合を保証しているので食い違いは起きないはずだが、起きたら
        # 数えて報告する。1列目のフラグを2列目の「有効」より優先する。
        $stats->{inconsistent}++;
        if ($is_flag && !$flagged{$dir}{$key}) {
            $own{$dir}{$key} = $valid;
            $flagged{$dir}{$key} = 1;
        }
    };
    for my $r (@{ $tables->{japname2sciname} }) {
        $note->($r->[8], "j\t$r->[0]", $r->[2], 1);
        $note->($r->[8], "s\t$r->[1]", 1,       0);
        $pair{ $r->[8] }{"$r->[0]\t$r->[1]"} = 1;
    }
    for my $r (@{ $tables->{sciname2japname} }) {
        $note->($r->[8], "s\t$r->[0]", $r->[2], 1);
        $note->($r->[8], "j\t$r->[1]", 1,       0);
        $pair{ $r->[8] }{"$r->[1]\t$r->[0]"} = 1;
    }
    return { own => \%own, pair => \%pair, memo => {} };
}

# 組 (和名, 学名) のそのディレクトリでの有効性 [ 和名, 学名 ] を返す。
# 上位のディレクトリが同じ組を持っていれば、その組での上位の判定に従う
# (上位にも上位があればそれに従った判定)。上位が複数あって割れたら、どれかが
# 有効としていれば有効にする。
sub resolve_pair {
    my ($ctx, $dir, $jap, $sci, $loaded) = @_;
    my $key = "$jap\t$sci";
    my $memo = $ctx->{memo}{$dir}{$key};
    return $memo if $memo;
    my @judges = map  { resolve_pair($ctx, $_, $jap, $sci, $loaded) }
                 grep { $ctx->{pair}{$_}{$key} } superiors($dir, $loaded);
    my $res;
    if (@judges) {
        $res = [ (grep { $_->[0] } @judges) ? 1 : 0, (grep { $_->[1] } @judges) ? 1 : 0 ];
    }
    else {
        $res = [ $ctx->{own}{$dir}{"j\t$jap"}, $ctx->{own}{$dir}{"s\t$sci"} ];
    }
    return $ctx->{memo}{$dir}{$key} = $res;
}

# 行を採用する。2列目の名前がその組で有効でなければ落とし、1列目の有効性の
# フラグはその組での解決後の値に置き換える。同じ組を上位のディレクトリも
# 残していれば、下位の行は上位に譲る。
# 返り値は「1列目<TAB>2列目」=> [ 行, ... ] (ディレクトリごとに1行)。
sub adopt_rows {
    my ($kind, $rows, $ctx, $loaded, $stats) = @_;
    my $is_j2s = $kind eq 'japname2sciname';
    my %adopt;
    for my $r (@$rows) {
        my ($jap, $sci) = $is_j2s ? @$r[0, 1] : @$r[1, 0];
        my ($jv, $sv) = @{ resolve_pair($ctx, $r->[8], $jap, $sci, $loaded) };
        my ($v1, $v2) = $is_j2s ? ($jv, $sv) : ($sv, $jv);
        unless ($v2) {
            $stats->{"dropped_$kind"}++;
            next;
        }
        $stats->{"flipped_$kind"}++ if $v1 != $r->[2];
        $r->[2] = $v1;
        push @{ $adopt{"$r->[0]\t$r->[1]"} }, $r;
    }
    for my $key (keys %adopt) {
        my $list = $adopt{$key};
        next unless @$list > 1;
        my %has = map { $_->[8] => 1 } @$list;
        my @keep = grep { my $d = $_->[8]; !grep { $has{$_} } superiors($d, $loaded) } @$list;
        $stats->{"yielded_$kind"} += @$list - @keep;
        $stats->{"multi_$kind"}++ if @keep > 1;
        $adopt{$key} = \@keep;
    }
    return \%adopt;
}

#-----------------------------------------------------------------------------
# 参照データ (Catalogue of Life と NCBI Taxonomy の体系)
#
# どれも巨大なので decode せず UTF-8 のバイト列のまま扱う。DB にもバイト列の
# まま入れる (接続は sqlite_unicode を使わず、既存の2表も UTF-8 に直して入れる)。
# メモリ上の表 ($R) は次のとおり。ID の集合は空白区切りの文字列で持つ
# (1千万件のハッシュに配列を持たせるとメモリが足りなくなるため)。
#   cpar{ID} 親 (シノニムなら有効名)   cacc{ID} 有効名   cbad{ID} 誤用・裸名
#   cname{ID} 正規化した学名           cidx{学名} ID の集合 (誤用・裸名を除く)
#   qid2col{QID} CoL の ID の集合      altncbi [ [ID, taxid], ... ]
#   npar{taxid} 親                     nsci{taxid} 正規化した scientific name
#   nidx{学名} taxid の集合            nmerged{旧 taxid} 新 taxid
#   qid2tax{QID} taxid の集合
#   c2n{CoL の有効名の ID}{taxid} / n2c{taxid}{ID} 対応 (値は根拠)
#-----------------------------------------------------------------------------
# 参照データのファイル。[ 名前, パス ] の並び。
sub reference_files {
    return (
        [ 'col',      File::Spec->catfile($basedir, $ALLTAXA_DIR, 'NameUsage.tsv') ],
        [ 'nodes',    File::Spec->catfile($basedir, 'NCBITaxonomy', 'nodes.dmp') ],
        [ 'names',    File::Spec->catfile($basedir, 'NCBITaxonomy', 'names.dmp') ],
        [ 'merged',   File::Spec->catfile($basedir, 'NCBITaxonomy', 'merged.dmp') ],
        [ 'qid2ncbi', input_path($ALLTAXA_DIR, 'qid2ncbi') ],
    );
}

# 参照データの学名を、第2段の学名と突き合わせられる形にする。generate_tables.pl の
# ref_sciname_bytes (と strip_candidatus / strip_subgenus / space_digits_bytes /
# unify_ssp) と同じことをする。片側だけ直すと突き合わせが外れるので、第2段を
# 直したらここも直すこと。
sub ref_sciname_bytes {
    my ($name) = @_;
    return '' unless defined $name;
    $name =~ s/\ACandidatus\b[ \t]*// if index($name, 'Candidatus') == 0;
    $name =~ s/\A[A-Z][A-Za-z-]* \(([A-Z][A-Za-z-]*)\)\z/$1/;
    $name =~ s/\A([A-Z][A-Za-z-]*) \([A-Z][A-Za-z-]*\) /$1 /;
    if ($name =~ /[0-9]/) {
        $name =~ s/([0-9]+)/ $1 /g;
        $name =~ s/[ \t]+/ /g;
        $name =~ s/\A //;
        $name =~ s/ \z//;
    }
    $name =~ s/\xc3\x97/x/g;    # 雑種記号 × (UTF-8 で C3 97) は x に寄せる
    $name =~ s/ ssp\. / subsp. /g;
    return $name;
}

sub split_ids {
    my ($s) = @_;
    return () unless defined $s;
    return grep { length } split / /, $s;
}

sub nz {
    my ($v) = @_;
    return (defined $v && length $v) ? $v : undef;
}

# NameUsage.tsv を読み、hierarchy_col に入れながらメモリ上の表を作る。
sub load_col {
    my ($dbh, $path, $R, $stats) = @_;
    open my $fh, '<', $path or die "読めません: $path: $!\n";
    binmode $fh;
    my $hdr = <$fh>;
    $hdr = '' unless defined $hdr;
    $hdr =~ s/\r?\n\z//;
    my %col;
    my @h = split /\t/, $hdr, -1;
    $col{ $h[$_] } = $_ for 0 .. $#h;
    my @want = map { "col:$_" } qw(ID alternativeID nameAlternativeID parentID status
                                   scientificName authorship rank);
    for my $c (@want) {
        die "$path: 列 $c がありません\n" unless exists $col{$c};
    }
    my @ix = map { $col{$_} } @want;
    my $lim = 2 + (sort { $b <=> $a } @ix)[0];

    my $sth = $dbh->prepare('INSERT INTO hierarchy_col VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
    my ($cpar, $cacc, $cbad, $cname, $cidx, $qid) = @$R{qw(cpar cacc cbad cname cidx qid2col)};
    my $alt = $R->{altncbi};
    my $n = 0;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        my @f = split /\t/, $line, $lim;
        my ($id, $aid, $naid, $parent, $status, $sci, $auth, $rank) = @f[@ix];
        next unless defined $id && length $id;
        $status = '' unless defined $status;
        my $valid = $COL_INVALID_STATUS{$status} ? 0 : 1;
        $sth->execute($id, nz($parent), $valid, nz($rank), nz($sci), nz($auth),
                      nz($aid), nz($naid));
        $n++;
        $cpar->{$id} = $parent if defined $parent && length $parent;
        if ($valid)                            { $cacc->{$id} = 1 }
        elsif ($COL_UNRELATED_STATUS{$status}) { $cbad->{$id} = 1 }
        my $nm = ref_sciname_bytes($sci);
        $cname->{$id} = $nm;
        $cidx->{$nm} .= " $id" if length $nm && !$cbad->{$id};
        next unless defined $aid && length $aid;
        for my $a (split /,/, $aid) {
            if    ($a =~ /\Awikidata:(Q[0-9]+)\z/)         { $qid->{$1} .= " $id" }
            elsif ($a =~ /\Ancbi:(?:txid)?([0-9]+)\z/)     { push @$alt, [ $id, $1 ] }
        }
    }
    close $fh;
    $stats->{hierarchy_col} = $n;
    return $n;
}

# nodes.dmp / names.dmp / merged.dmp の1行を列に分ける (区切りは「<TAB>|<TAB>」、
# 行末は「<TAB>|」)。
sub dmp_fields {
    my ($line) = @_;
    $line =~ s/\r?\n\z//;
    $line =~ s/\t\|\z//;
    return split /\t\|\t/, $line, -1;
}

sub load_ncbi {
    my ($dbh, $files, $R, $stats) = @_;
    my ($npar, $nsci, $nidx, $nmerged) = @$R{qw(npar nsci nidx nmerged)};

    open my $fh, '<', $files->{nodes} or die "読めません: $files->{nodes}: $!\n";
    binmode $fh;
    my $sth = $dbh->prepare('INSERT INTO hierarchy_ncbi VALUES (?, ?, ?)');
    while (my $line = <$fh>) {
        my ($taxid, $parent, $rank) = dmp_fields($line);
        next unless defined $taxid && $taxid =~ /\A[0-9]+\z/;
        $sth->execute($taxid, $parent, nz($rank));
        $npar->{$taxid} = $parent;
        $stats->{hierarchy_ncbi}++;
    }
    close $fh;

    open $fh, '<', $files->{names} or die "読めません: $files->{names}: $!\n";
    binmode $fh;
    $sth = $dbh->prepare('INSERT INTO names_ncbi VALUES (?, ?, ?)');
    while (my $line = <$fh>) {
        my ($taxid, $name, undef, $class) = dmp_fields($line);
        next unless defined $class && $taxid =~ /\A[0-9]+\z/;
        $sth->execute($taxid, $name, $class);
        $stats->{names_ncbi}++;
        next unless $NCBI_MATCH_CLASS{$class};
        my $nm = ref_sciname_bytes($name);
        next unless length $nm;
        $nsci->{$taxid} = $nm if $class eq 'scientific name';
        $nidx->{$nm} .= " $taxid";
    }
    close $fh;

    open $fh, '<', $files->{merged} or die "読めません: $files->{merged}: $!\n";
    binmode $fh;
    $sth = $dbh->prepare('INSERT INTO merged_ncbi VALUES (?, ?)');
    while (my $line = <$fh>) {
        my ($old, $new) = dmp_fields($line);
        next unless defined $new && $old =~ /\A[0-9]+\z/ && $new =~ /\A[0-9]+\z/;
        $sth->execute($old, $new);
        $nmerged->{$old} = $new;
        $stats->{merged_ncbi}++;
    }
    close $fh;
}

# qid2ncbi_VERSION_BUILDDATE.tsv (qid / taxid) を読む。
sub load_qid2ncbi {
    my ($path, $R, $stats) = @_;
    open my $fh, '<', $path or die "読めません: $path: $!\n";
    binmode $fh;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        my ($q, $t) = split /\t/, $line, 3;
        next unless defined $t && $q =~ /\AQ[0-9]+\z/ && $t =~ /\A[0-9]+\z/;
        $R->{qid2tax}{$q} .= " $t";
        $stats->{qid2ncbi}++;
    }
    close $fh;
}

# CoL の ID を有効名の節点にする (シノニムなら parent を辿る)。誤用・裸名と、
# 有効名に辿り着かないものは undef。
sub col_accepted {
    my ($R, $id) = @_;
    for (1 .. 5) {
        return undef unless defined $id && length $id;
        return $id if $R->{cacc}{$id};
        return undef if $R->{cbad}{$id};
        $id = $R->{cpar}{$id};
    }
    return undef;
}

# NCBI の taxid を現行の節点にする (merged.dmp で統合されたものは統合先)。
sub ncbi_node {
    my ($R, $taxid) = @_;
    return undef unless defined $taxid;
    $taxid = $R->{nmerged}{$taxid} if exists $R->{nmerged}{$taxid};
    return exists $R->{npar}{$taxid} ? $taxid : undef;
}

# 節点自身と祖先の学名の集合
sub col_lineage_names {
    my ($R, $id) = @_;
    my %names;
    for (1 .. $MAX_DEPTH) {
        last unless defined $id && length $id;
        my $nm = $R->{cname}{$id};
        $names{$nm} = 1 if defined $nm && length $nm;
        my $p = $R->{cpar}{$id};
        last if !defined $p || $p eq $id;
        $id = $p;
    }
    return \%names;
}

sub ncbi_lineage_names {
    my ($R, $taxid) = @_;
    my %names;
    for (1 .. $MAX_DEPTH) {
        last unless defined $taxid;
        my $nm = $R->{nsci}{$taxid};
        $names{$nm} = 1 if defined $nm;
        my $p = $R->{npar}{$taxid};
        last if !defined $p || $p == $taxid;
        $taxid = $p;
    }
    return \%names;
}

#-----------------------------------------------------------------------------
# CoL と NCBI の節点の対応 (association_col_ncbi)
#-----------------------------------------------------------------------------
sub add_association {
    my ($R, $col, $taxid, $method) = @_;
    return 0 if exists $R->{c2n}{$col}{$taxid};
    $R->{c2n}{$col}{$taxid} = $method;
    $R->{n2c}{$taxid}{$col} = $method;
    return 1;
}

sub associate_col_ncbi {
    my ($R, $stats) = @_;

    # 1) CoL の alternativeID の ncbi:txid…
    for my $p (@{ $R->{altncbi} }) {
        my $c = col_accepted($R, $p->[0]);
        my $t = ncbi_node($R, $p->[1]);
        next unless defined $c && defined $t;
        $stats->{assoc_ncbi} += add_association($R, $c, $t, 'ncbi');
    }
    $R->{altncbi} = [];

    # 2) CoL の alternativeID の Wikidata QID -> P685
    for my $q (keys %{ $R->{qid2col} }) {
        my @t = grep { defined } map { ncbi_node($R, $_) } split_ids($R->{qid2tax}{$q});
        next unless @t;
        for my $c (map { col_accepted($R, $_) } split_ids($R->{qid2col}{$q})) {
            next unless defined $c;
            $stats->{assoc_wikidata} += add_association($R, $c, $_, 'wikidata') for @t;
        }
    }

    # 3) 学名の一致。1) 2) で対応の付いていない NCBI の節点を上から順に見て、
    # 同じ学名の CoL の有効名 (これも対応が無いもの) のうち、NCBI 側で最も近い
    # 対応済みの祖先に対応する CoL の節点を祖先に持つものだけを採る。上から順に
    # 見るので、ここで付けた対応も下の節点の祖先として使われる。
    my ($npar, $nsci, $cidx, $cpar, $cacc) = @$R{qw(npar nsci cidx cpar cacc)};
    my (%depth, @cand);
    for my $t (keys %$nsci) {
        next if $R->{n2c}{$t};
        next unless exists $cidx->{ $nsci->{$t} };
        push @cand, $t;
    }
    for my $t (@cand) {
        my @path;
        my $x = $t;
        while (!exists $depth{$x}) {
            push @path, $x;
            my $p = $npar->{$x};
            if (!defined $p || $p == $x || @path > $MAX_DEPTH) { $depth{$x} = 0; pop @path; last }
            $x = $p;
        }
        my $d = $depth{$x};
        $depth{$_} = ++$d for reverse @path;
    }
    @cand = sort { $depth{$a} <=> $depth{$b} || $a <=> $b } @cand;
    %depth = ();
    for my $t (@cand) {
        my @cols = grep { $cacc->{$_} && !$R->{c2n}{$_} } split_ids($cidx->{ $nsci->{$t} });
        next unless @cols;
        my ($a, $anchor) = ($npar->{$t}, undef);
        for (1 .. $MAX_DEPTH) {
            last unless defined $a;
            if ($R->{n2c}{$a}) { $anchor = $a; last }
            my $p = $npar->{$a};
            last if !defined $p || $p == $a;
            $a = $p;
        }
        next unless defined $anchor;
        my $acol = $R->{n2c}{$anchor};
        for my $c (@cols) {
            my $x = $cpar->{$c};
            for (1 .. $MAX_DEPTH) {
                last unless defined $x && length $x;
                if ($acol->{$x}) {
                    $stats->{assoc_name} += add_association($R, $c, $t, 'name');
                    last;
                }
                $x = $cpar->{$x};
            }
        }
    }
}

sub write_associations {
    my ($dbh, $R) = @_;
    my $sth = $dbh->prepare('INSERT INTO association_col_ncbi VALUES (?, ?, ?)');
    my $c2n = $R->{c2n};
    for my $c (sort keys %$c2n) {
        $sth->execute($c, $_, $c2n->{$c}{$_}) for sort { $a <=> $b } keys %{ $c2n->{$c} };
    }
}

#-----------------------------------------------------------------------------
# DB の組と体系の節点の対応 (taxonlink)
#-----------------------------------------------------------------------------
# 採用した組をディレクトリごとに集める (UTF-8 のバイト列)。
# 返り値は「ディレクトリ<TAB>和名<TAB>学名」=> 1。
sub adopted_pairs {
    my ($adopted) = @_;
    my %pairs;
    for my $kind (@KINDS) {
        my $is_j2s = $kind eq 'japname2sciname';
        for my $list (values %{ $adopted->{$kind} }) {
            for my $r (@$list) {
                my ($jap, $sci) = $is_j2s ? @$r[0, 1] : @$r[1, 0];
                $pairs{ Encode::encode('UTF-8', "$r->[8]\t$jap\t$sci") } = 1;
            }
        }
    }
    return \%pairs;
}

# taxonhint を読み、採用した組の手がかりを集める。
#   {ids}{手がかり} / {cons}{上位の学名} (root・anc)
sub read_hints {
    my ($dirs, $pairs, $roots, $stats) = @_;
    my %hint;
    for my $dir (@$dirs) {
        my $path = input_path($dir, $HINT_KIND);
        open my $fh, '<', $path or do {
            record_failure("$dir/$HINT_KIND", '入力ファイルを読めません: ' . relname($path) . ": $!");
            next;
        };
        binmode $fh;
        my $n_bad = 0;
        while (my $line = <$fh>) {
            $line =~ s/\r?\n\z//;
            next unless length $line;
            my @f = split /\t/, $line, -1;
            if (@f != $N_HINT_COLUMNS) { $n_bad++; next }
            my $key = "$dir\t$f[0]\t$f[1]";
            next unless $pairs->{$key};
            my $h = $hint{$key} ||= { ids => {}, cons => {} };
            $h->{ids}{$_}  = 1 for grep { length } split /\|/, $f[3];
            $h->{cons}{$_} = 1 for grep { length } split /\|/, $f[4];
            $h->{cons}{$_} = 1 for @{ $roots->{ $f[2] } || [] };
        }
        close $fh;
        record_failure("$dir/$HINT_KIND", "形式の崩れた行が $n_bad 行あります (読み飛ばしました)")
            if $n_bad;
    }
    return \%hint;
}

# 候補の節点から1つを選ぶ。手がかりの名前 (cons) が祖先 (自身を含む) に最も多く
# 当たる候補がただ1つならそれを採る。手がかりが無いときは候補がただ1つなら採る。
# $strict なら、手がかりがあるのに1つも当たらない候補は採らない (名前だけの一致は
# 同名異物のことがあるため)。ID で指定された候補は $strict にしない。
sub pick_node {
    my ($cands, $cons, $lineage, $strict) = @_;
    return undef unless @$cands;
    return $cands->[0] if @$cands == 1 && (!$strict || !%$cons);
    return undef unless %$cons;
    my ($best, @top) = (0);
    for my $c (@$cands) {
        my $names = $lineage->($c);
        my $score = grep { $names->{$_} } keys %$cons;
        next unless $score;
        if    ($score > $best)  { ($best, @top) = ($score, $c) }
        elsif ($score == $best) { push @top, $c }
    }
    return @top == 1 ? $top[0] : undef;
}

sub uniq_defined {
    my %seen;
    return sort grep { defined && !$seen{$_}++ } @_;
}

# 1つの組の節点を決める。[ colid, colmethod, ncbiid, ncbimethod ] を返す。
sub resolve_link {
    my ($R, $sci, $h) = @_;
    my (@cid, @cwd, @nid, @nwd, %cons);
    %cons = %{ $h->{cons} } if $h;
    for my $x ($h ? keys %{ $h->{ids} } : ()) {
        my ($type, $v) = split /:/, $x, 2;
        next unless defined $v;
        if ($type eq 'col') {
            push @cid, col_accepted($R, $v);
        }
        elsif ($type eq 'ncbi') {
            push @nid, ncbi_node($R, $v);
        }
        elsif ($type eq 'wikidata') {
            push @cwd, map { col_accepted($R, $_) } split_ids($R->{qid2col}{$v});
            push @nwd, map { ncbi_node($R, $_) }    split_ids($R->{qid2tax}{$v});
        }
        elsif ($type eq 'wdparent') {
            # 親の項目の学名を手がかりの名前に加える
            for my $c (map { col_accepted($R, $_) } split_ids($R->{qid2col}{$v})) {
                $cons{ $R->{cname}{$c} } = 1 if defined $c && length $R->{cname}{$c};
            }
            for my $t (map { ncbi_node($R, $_) } split_ids($R->{qid2tax}{$v})) {
                $cons{ $R->{nsci}{$t} } = 1 if defined $t && defined $R->{nsci}{$t};
            }
        }
    }
    my $cl = sub { col_lineage_names($R, $_[0]) };
    my $nl = sub { ncbi_lineage_names($R, $_[0]) };

    my ($colid, $colm, $ncbiid, $ncbim);
    for my $try ([ \@cid, 'id', 0 ], [ \@cwd, 'wikidata', 0 ],
                 [ [ map { col_accepted($R, $_) } split_ids($R->{cidx}{$sci}) ], 'name', 1 ]) {
        my @c = uniq_defined(@{ $try->[0] });
        next unless @c;
        $colid = pick_node(\@c, \%cons, $cl, $try->[2]);
        if (defined $colid) { $colm = $try->[1]; last }
    }
    for my $try ([ \@nid, 'id', 0 ], [ \@nwd, 'wikidata', 0 ],
                 [ [ map { ncbi_node($R, $_) } split_ids($R->{nidx}{$sci}) ], 'name', 1 ]) {
        my @c = uniq_defined(@{ $try->[0] });
        next unless @c;
        $ncbiid = pick_node(\@c, \%cons, $nl, $try->[2]);
        if (defined $ncbiid) { $ncbim = $try->[1]; last }
    }

    # 片方しか決まらなければ、対応がただ1つのときだけ対応から補う
    if (defined $colid && !defined $ncbiid) {
        my @t = keys %{ $R->{c2n}{$colid} || {} };
        ($ncbiid, $ncbim) = ($t[0], 'association') if @t == 1;
    }
    elsif (!defined $colid && defined $ncbiid) {
        my @c = keys %{ $R->{n2c}{$ncbiid} || {} };
        ($colid, $colm) = ($c[0], 'association') if @c == 1;
    }
    return [ $colid, $colm, $ncbiid, $ncbim ];
}

sub write_taxonlink {
    my ($dbh, $R, $pairs, $hint, $stats) = @_;
    my $sth = $dbh->prepare('INSERT INTO taxonlink VALUES (?, ?, ?, ?, ?, ?, ?)');
    for my $key (sort keys %$pairs) {
        my ($dir, $jap, $sci) = split /\t/, $key, 3;
        my $link = resolve_link($R, $sci, $hint->{$key});
        $sth->execute($jap, $sci, $dir, @$link);
        $stats->{link_total}++;
        $stats->{ 'link_col_'  . ($link->[1] || 'none') }++;
        $stats->{ 'link_ncbi_' . ($link->[3] || 'none') }++;
        $stats->{link_both}++ if defined $link->[0] && defined $link->[2];
    }
}

#-----------------------------------------------------------------------------
# データベースの書き出し
#-----------------------------------------------------------------------------
sub write_database {
    my ($path, $adopted, $dirs, $stats) = @_;
    my $tmp = "$path.part";
    unlink $tmp if -e $tmp;
    # 参照データは decode せずバイト列のまま入れるので sqlite_unicode は使わない。
    # 文字列 (既存の2表) は UTF-8 のバイト列に直してから入れる。
    my $dbh = DBI->connect("dbi:SQLite:dbname=$tmp", '', '',
                           { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
    # 一括作成なので途中で落ちたら .part ごと作り直す。ジャーナルも同期も要らない。
    $dbh->do('PRAGMA journal_mode = OFF');
    $dbh->do('PRAGMA synchronous = OFF');
    $dbh->do('PRAGMA cache_size = -1000000');
    $dbh->begin_work;

    my %n;
    for my $kind (@KINDS) {
        my ($c1, $c2, $cv) = $kind eq 'japname2sciname'
                           ? ('japname', 'sciname', 'japvalid')
                           : ('sciname', 'japname', 'scivalid');
        $dbh->do(<<"SQL");
CREATE TABLE $kind (
    $c1 TEXT NOT NULL,
    $c2 TEXT NOT NULL,
    $cv INTEGER NOT NULL,
    rank INTEGER NOT NULL,
    subrank INTEGER NOT NULL,
    sourcetitle TEXT,
    sourceauthor TEXT,
    sourceurl TEXT,
    taxondir TEXT NOT NULL,
    PRIMARY KEY ($c1, $c2, taxondir)
)
SQL
        my $sth = $dbh->prepare("INSERT INTO $kind VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)");
        my $table = $adopted->{$kind};
        # 主キーの順に入れると索引の構築が速い
        for my $key (sort keys %$table) {
            for my $r (sort { $a->[8] cmp $b->[8] } @{ $table->{$key} }) {
                $sth->execute(map { Encode::encode('UTF-8', $_) } @$r[0 .. 8]);
                $n{$kind}++;
            }
        }
        # 1列目は主キーの索引で引ける。前方一致も BINARY 照合の範囲検索
        # (>= ? AND < ?) なら索引を使えるので、照合は既定のままにする。
        $dbh->do("CREATE INDEX ${kind}_$c2 ON $kind ($c2)");
    }

    $dbh->do(<<'SQL');
CREATE TABLE rank (
    rank INTEGER NOT NULL,
    name TEXT NOT NULL,
    PRIMARY KEY (rank, name)
)
SQL
    my $sth = $dbh->prepare('INSERT INTO rank VALUES (?, ?)');
    $sth->execute($_->[0], Encode::encode('UTF-8', $_->[1])) for @RANK_DEF;

    $dbh->do('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
    $sth = $dbh->prepare('INSERT INTO meta VALUES (?, ?)');
    $sth->execute('version',   Encode::encode('UTF-8', $VERSION));
    $sth->execute('builddate', $BUILDDATE);

    # 体系の表。索引は行を入れ終えてから張る (その方が速い)。
    $dbh->do(<<'SQL');
CREATE TABLE hierarchy_col (
    id TEXT PRIMARY KEY,
    parent TEXT,
    status INTEGER NOT NULL,
    rank TEXT,
    name TEXT,
    authorship TEXT,
    alternativeid TEXT,
    namealternativeid TEXT
)
SQL
    $dbh->do('CREATE TABLE hierarchy_ncbi (taxid INTEGER PRIMARY KEY, parent INTEGER, rank TEXT)');
    $dbh->do('CREATE TABLE names_ncbi (taxid INTEGER NOT NULL, name TEXT NOT NULL, class TEXT NOT NULL)');
    $dbh->do('CREATE TABLE merged_ncbi (old_taxid INTEGER PRIMARY KEY, new_taxid INTEGER NOT NULL)');
    $dbh->do(<<'SQL');
CREATE TABLE association_col_ncbi (
    colid TEXT NOT NULL,
    taxid INTEGER NOT NULL,
    method TEXT NOT NULL,
    PRIMARY KEY (colid, taxid)
)
SQL
    $dbh->do(<<'SQL');
CREATE TABLE taxonlink (
    japname TEXT NOT NULL,
    sciname TEXT NOT NULL,
    taxondir TEXT NOT NULL,
    colid TEXT,
    colmethod TEXT,
    ncbiid INTEGER,
    ncbimethod TEXT,
    PRIMARY KEY (japname, sciname, taxondir)
)
SQL

    my %ref = map { $_->[0] => $_->[1] } reference_files();
    my $R = { altncbi => [] };
    $R->{$_} = {} for qw(cpar cacc cbad cname cidx qid2col npar nsci nidx nmerged
                         qid2tax c2n n2c);
    my $t0 = time;
    load_col($dbh, $ref{col}, $R, $stats);
    logmsg('read', sprintf('%s (%d 行, %d 秒)', relname($ref{col}), $stats->{hierarchy_col},
                           time - $t0));
    $t0 = time;
    load_ncbi($dbh, \%ref, $R, $stats);
    logmsg('read', sprintf('NCBITaxonomy (節点 %d / 名前 %d / 統合 %d, %d 秒)',
                           $stats->{hierarchy_ncbi} || 0, $stats->{names_ncbi} || 0,
                           $stats->{merged_ncbi} || 0, time - $t0));
    load_qid2ncbi($ref{qid2ncbi}, $R, $stats);
    logmsg('read', sprintf('%s (%d 行)', relname($ref{qid2ncbi}), $stats->{qid2ncbi} || 0));

    $t0 = time;
    associate_col_ncbi($R, $stats);
    write_associations($dbh, $R);
    logmsg('link', sprintf('CoL と NCBI の対応 (ncbi %d / wikidata %d / name %d, %d 秒)',
                           $stats->{assoc_ncbi} || 0, $stats->{assoc_wikidata} || 0,
                           $stats->{assoc_name} || 0, time - $t0));

    $t0 = time;
    my %roots = map { $_->{id} => $_->{root} || [] } @SOURCES;
    my $pairs = adopted_pairs($adopted);
    my $hint  = read_hints($dirs, $pairs, \%roots, $stats);
    write_taxonlink($dbh, $R, $pairs, $hint, $stats);
    logmsg('link', sprintf('taxonlink (%d 組, %d 秒)', $stats->{link_total} || 0, time - $t0));
    %$R = ();

    $t0 = time;
    $dbh->do('CREATE INDEX hierarchy_col_name ON hierarchy_col (name)');
    $dbh->do('CREATE INDEX hierarchy_col_parent ON hierarchy_col (parent)');
    $dbh->do('CREATE INDEX hierarchy_ncbi_parent ON hierarchy_ncbi (parent)');
    $dbh->do('CREATE INDEX names_ncbi_name ON names_ncbi (name)');
    $dbh->do('CREATE INDEX names_ncbi_taxid ON names_ncbi (taxid)');
    $dbh->do('CREATE INDEX association_col_ncbi_taxid ON association_col_ncbi (taxid)');
    $dbh->do('CREATE INDEX taxonlink_colid ON taxonlink (colid)');
    $dbh->do('CREATE INDEX taxonlink_ncbiid ON taxonlink (ncbiid)');

    $dbh->commit;
    $dbh->do('ANALYZE');
    $dbh->disconnect;
    logmsg('index', sprintf('索引と ANALYZE (%d 秒)', time - $t0));
    rename $tmp, $path or die "rename に失敗しました: $tmp -> $path: $!\n";
    return \%n;
}

#-----------------------------------------------------------------------------
# 出力まわり
#-----------------------------------------------------------------------------
sub logmsg {
    my ($tag, $msg) = @_;
    printf "[%-5s] %s\n", $tag, $msg;
}

sub record_failure {
    my ($what, $why) = @_;
    $n_fail++;
    push @failures, { what => $what, why => $why };
    logmsg('FAIL', "$what: $why");
}

sub relname {
    my ($path) = @_;
    my $rel = File::Spec->abs2rel($path, $basedir);
    return $rel =~ m{^\.\.} ? $path : $rel;
}

sub uniq {
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

sub list_dirs {
    my ($dirs) = @_;
    printf "対象ディレクトリ: %s\n\n", $basedir;
    printf "%-20s %s\n", 'ディレクトリ', '従う上位のディレクトリ (同じ組を持つときだけ)';
    print '-' x 72, "\n";
    my %loaded = map { $_ => 1 } @$dirs;
    for my $dir (@$dirs) {
        my @sup = superiors($dir, \%loaded);
        @sup = ('他の全ディレクトリ') if $dir eq $ALLTAXA_DIR && @sup;
        printf "%-20s %s\n", $dir, @sup ? join(', ', @sup) : '-';
    }
    print "\n入力: <ディレクトリ>/japname2sciname_VERSION_BUILDDATE.tsv\n";
    print "      <ディレクトリ>/sciname2japname_VERSION_BUILDDATE.tsv\n";
    print "      <ディレクトリ>/taxonhint_VERSION_BUILDDATE.tsv\n";
    print "参照: AllTaxa/NameUsage.tsv, AllTaxa/qid2ncbi_VERSION_BUILDDATE.tsv,\n";
    print "      NCBITaxonomy/nodes.dmp, names.dmp, merged.dmp\n";
    print "出力: jbtaxon_VERSION_BUILDDATE.sqlite3\n";
}

sub report_summary {
    my ($stats) = @_;
    my $elapsed = time - $t_start;
    print "\n=== 集計 ===\n";
    if ($stats) {
        for my $kind (@KINDS) {
            printf "%s: 入力 %d 行 / 2列目が無効で落とした %d 行 / 上位に譲った %d 行 / "
                 . "出力 %d 行\n", $kind, $stats->{"in_$kind"} || 0,
                $stats->{"dropped_$kind"} || 0, $stats->{"yielded_$kind"} || 0,
                $stats->{"out_$kind"} || 0;
            printf "  上位の判定で1列目の有効性が変わった行 %d / 同じ組を複数のディレクトリが残した組 %d\n",
                $stats->{"flipped_$kind"} || 0, $stats->{"multi_$kind"} || 0;
        }
        if ($stats->{link_total}) {
            printf "体系: CoL %d 行 / NCBI 節点 %d・名前 %d・統合 %d / qid2ncbi %d 行\n",
                map { $stats->{$_} || 0 } qw(hierarchy_col hierarchy_ncbi names_ncbi merged_ncbi qid2ncbi);
            printf "association_col_ncbi: ncbi %d / wikidata %d / name %d\n",
                map { $stats->{"assoc_$_"} || 0 } qw(ncbi wikidata name);
            for my $side (qw(col ncbi)) {
                printf "taxonlink の %s: id %d / wikidata %d / name %d / association %d / なし %d\n",
                    $side eq 'col' ? 'colid' : 'ncbiid',
                    map { $stats->{"link_${side}_$_"} || 0 } qw(id wikidata name association none);
            }
            printf "taxonlink: %d 組 (両方あり %d)\n", $stats->{link_total}, $stats->{link_both} || 0;
        }
        printf "ディレクトリ内で有効性が食い違った名前: %d (本来は 0)\n",
            $stats->{inconsistent} if $stats->{inconsistent};
        printf "所要時間: %d分%02d秒\n", int($elapsed / 60), $elapsed % 60;
    }
    printf "失敗: %d 件\n", $n_fail;
    return unless @failures;
    print "\n--- 失敗 ---\n";
    printf "  %s: %s\n", $_->{what}, $_->{why} for @failures;
}

sub usage {
    my ($status) = @_;
    my $fh = $status ? *STDERR : *STDOUT;
    binmode $fh, ':encoding(UTF-8)';
    my $dirs = join ', ', uniq(map { $_->{dir} } @SOURCES);
    print $fh <<"USAGE";
使い方: generate_database.pl --builddate=YYYYMMDD [オプション]

分類群ごとのディレクトリにある和名→学名テーブルと学名→和名テーブルの TSV を
集約し、ディレクトリ間の衝突を解決して jbtaxon_VERSION_BUILDDATE.sqlite3 を
生成します。Catalogue of Life と NCBI Taxonomy の体系全体も DB に入れ、各組を
その節点に結び付けます (taxonhint_VERSION_BUILDDATE.tsv の手がかりを使う)。

オプション:
  --builddate=YYYYMMDD  ビルド日 (必須)。入力の TSV と出力の DB の両方に使う
  --dir=PATH            ベースディレクトリ (既定: スクリプトのあるディレクトリ)
  --only=NAME           分類群ディレクトリを限定する (複数指定可)
  --force               出力の DB が既にあっても作り直す
  --version=X.Y.Z       VERSION ファイルの値を上書きする
  --list                ディレクトリの上下関係を表示して終了する
  --dry-run             入力ファイルと参照データの存在確認だけを行う (DB を作りません)
  --help, -h            このヘルプを表示する

指定可能な --only の名前:
  $dirs
USAGE
    exit $status;
}

#-----------------------------------------------------------------------------
# 共通ユーティリティ: 環境まわり
#-----------------------------------------------------------------------------
sub check_dependencies {
    my @missing;
    for my $m (@REQUIRED_MODULES) {
        my ($mod, $pkg, $why) = @$m;
        eval "require $mod; 1" or push @missing, [ "Perl モジュール $mod", $pkg, $why, $mod ];
    }
    return unless @missing;

    print STDERR "generate_database.pl の実行に必要なものが不足しています。\n\n";
    printf STDERR "  %s (%s)\n    Debian/Ubuntu: apt install %s\n",
        $_->[0], $_->[2], $_->[1] for @missing;
    print STDERR "\nCPAN から入れる場合は cpanm " . join(' ', map { $_->[3] } @missing) . "\n";
    exit 2;
}

# リポジトリルートの VERSION を読む。1行のバージョン文字列。
sub read_version {
    my $path = File::Spec->catfile(dirname(abs_path($0)), 'VERSION');
    open my $fh, '<', $path or do {
        print STDERR "VERSION ファイルを読めません: $path: $!\n";
        exit 2;
    };
    my $v = <$fh>;
    close $fh;
    $v = '' unless defined $v;
    $v =~ s/\s+//g;
    unless (length $v) {
        print STDERR "VERSION ファイルが空です: $path\n";
        exit 2;
    }
    return $v;
}

# rank.def が rank 値の唯一の正。形式はタブ区切りの「rank番号<TAB>階層名」で、
# 同一 rank 番号に複数の階層名が対応する。[ 番号, 階層名 ] の並びを返す。
sub read_rank_def {
    my $path = File::Spec->catfile(dirname(abs_path($0)), 'rank.def');
    open my $fh, '<', $path or do {
        print STDERR "rank.def を読めません: $path: $!\n";
        exit 2;
    };
    binmode $fh, ':encoding(UTF-8)';
    my @def;
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /^\s*(\d+)\t(.+?)\s*$/;
        push @def, [ $1 + 0, $2 ];
    }
    close $fh;
    unless (grep { $_->[1] eq 'species' } @def) {
        print STDERR "rank.def に species の定義がありません: $path\n";
        exit 2;
    }
    return @def;
}

# リポジトリルートの sources.tsv を読む (generate_tables.pl と共通の情報源の定義)。
# 先頭の行が列名のヘッダ、'#' で始まる行と空行は読み飛ばす。配列の列は '|' で
# 区切り、空欄の項目はハッシュに入れない。行の順番を定義順 (order) として持つ。
sub read_sources {
    my $path = File::Spec->catfile(dirname(abs_path($0)), 'sources.tsv');
    open my $fh, '<', $path or do {
        print STDERR "sources.tsv を読めません: $path: $!\n";
        exit 2;
    };
    binmode $fh, ':encoding(UTF-8)';
    my %is_array = map { $_ => 1 } qw(sourceauthor files unzip unzip_only root);
    my (@cols, @sources, %seen, @err);
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        next if $line =~ /^#/ || $line !~ /\S/;
        my @f = split /\t/, $line, -1;
        unless (@cols) { @cols = @f; next }
        my %src;
        for my $i (0 .. $#cols) {
            my $v = defined $f[$i] ? $f[$i] : '';
            next unless length $v;
            $src{ $cols[$i] } = $is_array{ $cols[$i] } ? [ split /\|/, $v ] : $v;
        }
        my $where = "$path 行 $.";
        for my $c (qw(dir id parser scope year sourcetitle sourceauthor sourceurl files)) {
            push @err, "$where: $c がありません" unless defined $src{$c};
        }
        push @err, "$where: scope が数字ではありません"
            if defined $src{scope} && $src{scope} !~ /^\d+$/;
        push @err, "$where: year が数字ではありません"
            if defined $src{year} && $src{year} !~ /^\d+$/;
        push @err, "$where: id が重複しています: $src{id}"
            if defined $src{id} && $seen{ $src{id} }++;
        $src{order} = scalar @sources;
        push @sources, \%src;
    }
    close $fh;
    push @err, "$path: ソースの定義がありません" unless @sources;
    if (@err) {
        print STDERR "$_\n" for @err;
        exit 2;
    }
    return @sources;
}

#-----------------------------------------------------------------------------
# 実行 (ファイル末尾に置く。上のサブルーチン群が使う表の代入を先に済ませるため)
#-----------------------------------------------------------------------------
printf "対象ディレクトリ: %s\n", $basedir;
printf "VERSION=%s BUILDDATE=%s\n", $VERSION, $BUILDDATE;
print "(dry-run: 入力ファイルと参照データの存在確認だけを行います)\n" if $dry_run;

my $out = File::Spec->catfile($basedir, "jbtaxon_${VERSION}_${BUILDDATE}.sqlite3");

if ($dry_run) {
    for my $dir (@dirs) {
        for my $kind (@KINDS, $HINT_KIND) {
            my $path = input_path($dir, $kind);
            if (-e $path) { logmsg('dry', relname($path)) }
            else          { record_failure("$dir/$kind", '入力ファイルがありません: ' . relname($path)) }
        }
    }
    for my $ref (reference_files()) {
        my $path = $ref->[1];
        if (-e $path) { logmsg('dry', '参照データ: ' . relname($path)) }
        else          { record_failure("参照データ $ref->[0]", 'ファイルがありません: ' . relname($path)) }
    }
    logmsg('dry', '出力: ' . relname($out) . (-e $out ? ' (既にあります。--force で作り直し)' : ''));
    report_summary();
    exit($n_fail ? 1 : 0);
}

if (-e $out && !$force) {
    logmsg('skip', relname($out) . ' は既にあります (--force で作り直し)');
    exit 0;
}

my (%tables, %stats);
my $n_missing = 0;
for my $dir (@dirs) {
    for my $kind (@KINDS) {
        unless (-e input_path($dir, $kind)) {
            record_failure("$dir/$kind", "入力ファイルがありません: " . relname(input_path($dir, $kind)));
            $n_missing++;
            next;
        }
        my $rows = read_table($dir, $kind);
        push @{ $tables{$kind} }, @$rows;
        logmsg('read', sprintf('%s (%d 行)', relname(input_path($dir, $kind)), scalar @$rows));
    }
    unless (-e input_path($dir, $HINT_KIND)) {
        record_failure("$dir/$HINT_KIND", "入力ファイルがありません: " . relname(input_path($dir, $HINT_KIND)));
        $n_missing++;
    }
}
for my $ref (reference_files()) {
    next if -e $ref->[1];
    record_failure("参照データ $ref->[0]", 'ファイルがありません: ' . relname($ref->[1]));
    $n_missing++;
}
$stats{"in_$_"} = scalar @{ $tables{$_} || [] } for @KINDS;

my %loaded = map { $_ => 1 } @dirs;
my $ctx = collect_judgments(\%tables, \%stats);
my %adopted;
for my $kind (@KINDS) {
    $adopted{$kind} = adopt_rows($kind, $tables{$kind} || [], $ctx, \%loaded, \%stats);
}
%tables = ();
$ctx = undef;

# 入力が欠けた DB を正式な名前で書くと、次の実行が「既にある」として飛ばして
# しまう。欠けたまま作らず、揃えてから実行し直させる。
my $n = $n_missing ? undef : eval { write_database($out, \%adopted, \@dirs, \%stats) };
if ($n_missing) {
    logmsg('skip', "入力ファイルが $n_missing 件欠けているので " . relname($out) . ' は作りません');
}
elsif ($@) {
    my $why = $@; $why =~ s/\s+\z//;
    record_failure(relname($out), "データベースの作成に失敗しました: $why");
}
else {
    $stats{"out_$_"} = $n->{$_} || 0 for @KINDS;
    logmsg('write', sprintf('%s (japname2sciname %d 行 / sciname2japname %d 行)',
                            relname($out), $stats{out_japname2sciname}, $stats{out_sciname2japname}));
}

report_summary(\%stats);
exit($n_fail ? 1 : 0);
