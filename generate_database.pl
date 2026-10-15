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
# ここで解決するのは**ディレクトリ間の衝突**だけで、名前ごとの有効名／シノニムの
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
# スキーマ:
#   japname2sciname (japname, sciname, japvalid, rank, subrank,
#                    sourcetitle, sourceauthor, sourceurl, taxondir)
#   sciname2japname (sciname, japname, scivalid, rank, subrank,
#                    sourcetitle, sourceauthor, sourceurl, taxondir)
#     taxondir は行の由来の分類群ディレクトリ。同じ組がディレクトリごとに別の行に
#     なるので、主キーは (1列目, 2列目, taxondir)。2列目にも索引を張る。
#   rank (rank, name) ... rank.def をそのまま入れたもの (1つの番号に複数の名前)
#   meta (key, value) ... version / builddate

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
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
# データベースの書き出し
#-----------------------------------------------------------------------------
sub write_database {
    my ($path, $adopted) = @_;
    my $tmp = "$path.part";
    unlink $tmp if -e $tmp;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$tmp", '', '',
                           { RaiseError => 1, PrintError => 0, AutoCommit => 1,
                             sqlite_unicode => 1 });
    # 一括作成なので途中で落ちたら .part ごと作り直す。ジャーナルも同期も要らない。
    $dbh->do('PRAGMA journal_mode = OFF');
    $dbh->do('PRAGMA synchronous = OFF');
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
                $sth->execute(@$r[0 .. 8]);
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
    $sth->execute(@$_) for @RANK_DEF;

    $dbh->do('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
    $sth = $dbh->prepare('INSERT INTO meta VALUES (?, ?)');
    $sth->execute('version',   $VERSION);
    $sth->execute('builddate', $BUILDDATE);

    $dbh->commit;
    $dbh->do('ANALYZE');
    $dbh->disconnect;
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
生成します。

オプション:
  --builddate=YYYYMMDD  ビルド日 (必須)。入力の TSV と出力の DB の両方に使う
  --dir=PATH            ベースディレクトリ (既定: スクリプトのあるディレクトリ)
  --only=NAME           分類群ディレクトリを限定する (複数指定可)
  --force               出力の DB が既にあっても作り直す
  --version=X.Y.Z       VERSION ファイルの値を上書きする
  --list                ディレクトリの上下関係を表示して終了する
  --dry-run             入力ファイルの存在確認だけを行う (DB を作りません)
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
    my %is_array = map { $_ => 1 } qw(sourceauthor files unzip unzip_only);
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
print "(dry-run: 入力ファイルの存在確認だけを行います)\n" if $dry_run;

my $out = File::Spec->catfile($basedir, "jbtaxon_${VERSION}_${BUILDDATE}.sqlite3");

if ($dry_run) {
    for my $dir (@dirs) {
        for my $kind (@KINDS) {
            my $path = input_path($dir, $kind);
            if (-e $path) { logmsg('dry', relname($path)) }
            else          { record_failure("$dir/$kind", '入力ファイルがありません: ' . relname($path)) }
        }
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
my $n = $n_missing ? undef : eval { write_database($out, \%adopted) };
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
