#!/usr/bin/perl
#
# sciname2japname.pl - 学名から和名を引く
#
# generate_database.pl が作った jbtaxon_VERSION_BUILDDATE.sqlite3 の
# sciname2japname テーブルを検索し、学名に対応する有効な和名を返す。
#
# japname2sciname.pl は検索の向きが逆なだけで、中身はこのスクリプトと同じ。
# 違うのは先頭の「検索の向き」の1行だけなので、片方を直したらもう片方にも
# 同じ変更を写すこと (スクリプト間でモジュールは共有しない)。
#
# 使い方は2通り:
#   クエリ   ... 引数1つ。「階層名:名前」を「,」か「;」で並べたもの
#                (class:Mammalia,species:"Homo sapiens")。結果を標準出力に1行で出す。
#   ファイル ... 引数2つ (入力ファイル、出力ファイル)。入力は1行目のラベルが
#                階層名のタブ区切りで、階層名の列のセルを引いて出力に書く。
#                ラベルが階層名でない列と見出し行はそのまま出す。
#
# 1つの名前の検索は次の順で候補を絞る。
#   1. 1列目がその名前の行を集める。rank (番号で比べ、subrank は見ない) が
#      一致する行があればそれだけ、無ければ rank を問わない (入力の階層の付け方が
#      DB と同じとは限らず、上位の名前を下の列へ埋めた入力もあるため)。
#      和名から引く向きで階層が種のときだけ、種の行が無ければ亜種・変種・品種…と
#      1段ずつ下げ、行のある最初の階層の行を使う (「ヒメギフチョウ北海道亜種」の
#      ように、種として引かれた和名が実は亜種の和名であることがあるため)
#   2. 1列目の名前が有効名である行があればそれだけ
#   3. 系統: 同じ行 (クエリなら他の項目) の名前が、候補の組の節点 (taxonlink の
#      colid / ncbiid) の祖先にいくつ含まれるかを数え、最大の候補だけを残す。
#      どの候補も1つも当たらなければ絞り込まない。名前だけで比べ rank は見ない
#      (NCBI・CoL・入力で階層の付け方が違うため)
#   4. ディレクトリの上下関係: 残った候補に上位のディレクトリのものがあれば、
#      下位のディレクトリのものは捨てる (generate_database.pl の上下関係と同じ。
#      AllTaxa は他の全てに、Lichens は Seaweeds と Fungi に従う)
#   5. 2列目の名前 (有効名) を sort して「,」で連結する
#
# 出力の形 (--mode):
#   ADD     ... 「元の名前 (引いた名前)」。当たらなければ元の名前のまま
#   CONVERT ... 引いた名前だけ。当たらなければ空
#   NEWCOL  ... 元の列はそのままにし、引いた列の直後に「列名_引いた名前の種類」の列
#               (sciname2japname.pl なら class_japname、japname2sciname.pl なら
#               class_sciname) を足して、CONVERT と同じ形で書く。ファイルのときだけ
# 「unidentified ～」は検索しない (ADD は元のまま、CONVERT・NEWCOL は空)。空のセルは空のまま。
#
# 種から下位の階層へ下げて引けたときは、クエリの CONVERT だけが下位の分類群の学名を
# その階層名で返す (species:ヒメギフチョウ北海道亜種 → subspecies:Luehdorfia puziloi
# yessoensis)。クエリの ADD とファイル (ADD・CONVERT・NEWCOL) は、列や項目の階層に合わせて
# 種の学名に直して返す (species:ヒメギフチョウ北海道亜種 (Luehdorfia puziloi))。

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use Encode ();
use File::Spec;
use Getopt::Long;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

#-----------------------------------------------------------------------------
# 版と DB の既定の場所
#
# make exec が作るコマンド (拡張子なし) は先頭に my $version と my $dbdir を
# 足してある。足していない .pl を直接実行したときは、スクリプトの隣の VERSION と、
# スクリプトのディレクトリ (generate_database.pl が DB を書く場所) を使う。
# 文字列の eval は変数が宣言されていなければ (strict により) undef を返す。
#-----------------------------------------------------------------------------
my $SCRIPT_VERSION = eval('$version') // read_version();
my $DEFAULT_DBDIR  = eval('$dbdir')   // dirname(abs_path($0));

#-----------------------------------------------------------------------------
# 検索の向き (japname2sciname.pl との違いはこの1行だけ)
#-----------------------------------------------------------------------------
my $DIRECTION = 'sciname2japname';

#-----------------------------------------------------------------------------
# 依存チェック
#-----------------------------------------------------------------------------
my @REQUIRED_MODULES = (
    [ 'DBI',         'libdbi-perl',         'データベースへの接続' ],
    [ 'DBD::SQLite', 'libdbd-sqlite3-perl', 'SQLite3 データベースの読み込み' ],
);

check_dependencies();

#-----------------------------------------------------------------------------
# 定数
#-----------------------------------------------------------------------------
# 向きごとの表と列。key は1列目 (検索する名前)、value は2列目 (返す名前)、
# valid は1列目の有効性フラグ。
my %TABLE = (
    sciname2japname => { key => 'sciname', value => 'japname', valid => 'scivalid',
                         keyword => '学名', answer => '和名' },
    japname2sciname => { key => 'japname', value => 'sciname', valid => 'japvalid',
                         keyword => '和名', answer => '学名' },
);
my $T = $TABLE{$DIRECTION};

# DB に必要な表 (generate_database.pl が作るもの)
my @REQUIRED_TABLES = qw(japname2sciname sciname2japname rank taxonlink
                         hierarchy_col hierarchy_ncbi names_ncbi);

# NCBI Taxonomy の name class のうち、祖先の名前として突き合わせるもの
# (generate_database.pl の %NCBI_MATCH_CLASS と同じ)
my @NCBI_MATCH_CLASS = ('scientific name', 'synonym', 'equivalent name');

# 祖先を辿るときの上限 (循環への備え)
my $MAX_DEPTH = 300;

# ディレクトリの上下関係 (generate_database.pl と同じ)
my $ALLTAXA_DIR = 'AllTaxa';
my %SUPERIOR_DIRS = (
    'Lichens' => [ 'Seaweeds', 'Fungi' ],
);

my %MODES = map { $_ => 1 } qw(ADD CONVERT NEWCOL);

#-----------------------------------------------------------------------------
# CLI
#-----------------------------------------------------------------------------
my $db_path;
my $mode = 'ADD';
my @target_opt;
my $overwrite = 0;
my $help      = 0;

@ARGV = map { decode_arg($_) } @ARGV;
Getopt::Long::Configure('bundling');
GetOptions(
    'db=s'         => \$db_path,
    'mode=s'       => \$mode,
    'targetrank=s' => \@target_opt,
    'overwrite'    => \$overwrite,
    'help|h'       => \$help,
) or usage(2);
usage(0) if $help;

$mode = uc $mode;
die_usage("--mode は ADD か CONVERT か NEWCOL です: $mode") unless $MODES{$mode};
$db_path = default_db() unless defined $db_path;
print STDERR basename($0) . " $SCRIPT_VERSION (DB: $db_path)\n";
die_usage('クエリか、入力ファイルと出力ファイルを指定して下さい。') unless @ARGV;
die_usage('引数が多すぎます (クエリは1つの引数に、ファイルは入力と出力の2つ)。') if @ARGV > 2;

#-----------------------------------------------------------------------------
# 名前の正規化
#
# 学名は generate_tables.pl の norm_sciname が出力の形に揃えているので、ここでは
# 入力の書き方の揺れだけを均す (generate_database.pl の ref_sciname_bytes と同じ
# 規則を文字列に当てたもの)。DB の体系の表 (hierarchy_col / names_ncbi) の名前は
# 正規化前の表記なので、祖先の名前にも同じ関数を通す。大文字小文字は区別する。
#-----------------------------------------------------------------------------
sub norm_sciname {
    my ($name) = @_;
    return '' unless defined $name;
    $name =~ s/\s+/ /g;
    $name =~ s/\A //;
    $name =~ s/ \z//;
    $name =~ s/\ACandidatus\b *//;
    $name =~ s/\A[A-Z][A-Za-z-]* \(([A-Z][A-Za-z-]*)\)\z/$1/;
    $name =~ s/\A([A-Z][A-Za-z-]*) \([A-Z][A-Za-z-]*\) /$1 /;
    if ($name =~ /[0-9]/) {
        $name =~ s/([0-9]+)/ $1 /g;
        $name =~ s/ +/ /g;
        $name =~ s/\A //;
        $name =~ s/ \z//;
    }
    $name =~ s/\x{00D7}/x/g;
    $name =~ s/ ssp\. / subsp. /g;
    return $name;
}

# 和名には空白が入らない (generate_tables.pl の norm_japname が全て除く)
sub norm_japname {
    my ($name) = @_;
    return '' unless defined $name;
    $name =~ s/[\s\x{3000}]+//g;
    return $name;
}

sub norm_query {
    my ($name) = @_;
    return $T->{key} eq 'sciname' ? norm_sciname($name) : norm_japname($name);
}

# 検索しない名前 (空と「unidentified ～」)
sub is_unidentified {
    my ($name) = @_;
    return $name =~ /\A\s*unidentified(?:\s|\z)/i;
}

#-----------------------------------------------------------------------------
# DB
#-----------------------------------------------------------------------------
my $dbh;
my %RANK_NO;      # 階層名 → rank 番号
my %RANK_LABEL;   # rank 番号 → 階層名 (rank.def でその番号の最初の名前)
my $SPECIES_RANK; # 種の rank 番号
my %STH;

sub open_db {
    my ($path) = @_;
    die_io("DB がありません: $path") unless -f $path;
    require DBI;
    require DBD::SQLite;
    $dbh = eval {
        DBI->connect("dbi:SQLite:dbname=$path", '', '', {
            RaiseError        => 1,
            PrintError        => 0,
            AutoCommit        => 1,
            sqlite_unicode    => 1,
            sqlite_open_flags => DBD::SQLite::OPEN_READONLY(),
        });
    };
    die_io("DB を開けません: $path: " . ($@ || DBI->errstr || "")) unless $dbh;
    my %have = eval {
        map { $_->[0] => 1 }
            @{ $dbh->selectall_arrayref(q{SELECT name FROM sqlite_master WHERE type = 'table'}) };
    };
    die_io("DB を読めません: $path: $@") if $@;
    my @missing = grep { !$have{$_} } @REQUIRED_TABLES;
    die_io("DB に必要な表がありません (generate_database.pl の古い版で作った DB です): "
           . join(', ', @missing)) if @missing;

    for my $r (@{ $dbh->selectall_arrayref('SELECT rank, name FROM rank ORDER BY rowid') }) {
        $RANK_NO{ $r->[1] } = $r->[0];
        $RANK_LABEL{ $r->[0] } = $r->[1] unless exists $RANK_LABEL{ $r->[0] };
    }
    die_io("DB の rank 表が空です: $path") unless %RANK_NO;
    $SPECIES_RANK = $RANK_NO{species};
    die_io("DB の rank 表に species がありません: $path") unless defined $SPECIES_RANK;

    my ($key, $value, $valid) = @$T{qw(key value valid)};
    %STH = (
        rows     => $dbh->prepare("SELECT $value, $valid, rank, taxondir FROM $DIRECTION WHERE $key = ?"),
        link     => $dbh->prepare('SELECT colid, ncbiid FROM taxonlink'
                                  . ' WHERE japname = ? AND sciname = ? AND taxondir = ?'),
        col      => $dbh->prepare('SELECT parent, name FROM hierarchy_col WHERE id = ?'),
        ncbi     => $dbh->prepare('SELECT parent FROM hierarchy_ncbi WHERE taxid = ?'),
        ncbiname => $dbh->prepare('SELECT name FROM names_ncbi WHERE taxid = ? AND class IN ('
                                  . join(', ', ('?') x @NCBI_MATCH_CLASS) . ')'),
        j2s      => $dbh->prepare('SELECT DISTINCT sciname FROM japname2sciname WHERE japname = ?'),
    );
}

#-----------------------------------------------------------------------------
# 系統
#
# 節点ごとに、自身と祖先の名前 (正規化した学名) の集合を覚えておく。
# 祖先の集合は親の集合に自身の名前を足したものなので、親から順に共有できる。
#-----------------------------------------------------------------------------
my (%col_anc, %ncbi_anc);

sub col_ancestors {
    my ($id) = @_;
    return $col_anc{$id} if $col_anc{$id};
    my @chain;
    my %seen;
    my $cur = $id;
    while (defined $cur && !$col_anc{$cur} && !$seen{$cur}++ && @chain < $MAX_DEPTH) {
        my $r = $dbh->selectrow_arrayref($STH{col}, undef, $cur) or last;
        push @chain, [ $cur, $r->[1] ];
        $cur = $r->[0];
    }
    my $base = (defined $cur && $col_anc{$cur}) ? $col_anc{$cur} : {};
    for my $c (reverse @chain) {
        my %set = (%$base);
        $set{ norm_sciname($c->[1]) } = 1 if defined $c->[1];
        $base = $col_anc{ $c->[0] } = \%set;
    }
    return $col_anc{$id} || {};
}

sub ncbi_ancestors {
    my ($taxid) = @_;
    return $ncbi_anc{$taxid} if $ncbi_anc{$taxid};
    my @chain;
    my %seen;
    my $cur = $taxid;
    while (defined $cur && !$ncbi_anc{$cur} && !$seen{$cur}++ && @chain < $MAX_DEPTH) {
        my $r = $dbh->selectrow_arrayref($STH{ncbi}, undef, $cur) or last;
        push @chain, $cur;
        # 根 (taxid 1) は自身を親とする
        $cur = (defined $r->[0] && $r->[0] != $cur) ? $r->[0] : undef;
    }
    my $base = (defined $cur && $ncbi_anc{$cur}) ? $ncbi_anc{$cur} : {};
    for my $t (reverse @chain) {
        my %set = (%$base);
        my $names = $dbh->selectcol_arrayref($STH{ncbiname}, undef, $t, @NCBI_MATCH_CLASS);
        $set{ norm_sciname($_) } = 1 for @$names;
        $base = $ncbi_anc{$t} = \%set;
    }
    return $ncbi_anc{$taxid} || {};
}

# DB の組 (和名, 学名, ディレクトリ) の節点の祖先の名前。CoL と NCBI の和集合。
# 節点が1つも決まっていなければ undef。
my %pair_anc;

sub pair_ancestors {
    my ($japname, $sciname, $dir) = @_;
    my $k = join "\t", $japname, $sciname, $dir;
    return $pair_anc{$k} if exists $pair_anc{$k};
    my $r = $dbh->selectrow_arrayref($STH{link}, undef, $japname, $sciname, $dir);
    my ($colid, $ncbiid) = $r ? @$r : ();
    return $pair_anc{$k} = undef unless defined $colid || defined $ncbiid;
    my %set;
    %set = (%set, %{ col_ancestors($colid) })   if defined $colid;
    %set = (%set, %{ ncbi_ancestors($ncbiid) }) if defined $ncbiid;
    return $pair_anc{$k} = \%set;
}

# 系統の手がかりの名前を、祖先の名前と比べられる学名の集合にする。
# 学名はそのまま正規化し、和名は japname2sciname で学名に直す (2列目なので有効名)。
my %hint_memo;

sub hint_scinames {
    my ($name) = @_;
    return $hint_memo{$name} ||= do {
        $T->{key} eq 'sciname'
            ? [ norm_sciname($name) ]
            : [ map { norm_sciname($_) }
                    @{ $dbh->selectcol_arrayref($STH{j2s}, undef, norm_japname($name)) } ];
    };
}

#-----------------------------------------------------------------------------
# 検索
#-----------------------------------------------------------------------------
my %rows_memo;

sub lookup_rows {
    my ($name) = @_;
    return $rows_memo{$name} ||= $dbh->selectall_arrayref($STH{rows}, undef, $name);
}

# そのディレクトリが従う上位のディレクトリ
sub superiors {
    my ($dir, $present) = @_;
    my @sup = $dir eq $ALLTAXA_DIR
            ? grep { $_ ne $ALLTAXA_DIR } keys %$present
            : @{ $SUPERIOR_DIRS{$dir} || [] };
    return grep { $present->{$_} } @sup;
}

# 1つの名前を引く。$rank は rank 番号、$hints は系統の手がかりの名前の並び
# (同じ行の他の階層の名前)。有効名の並び (sort 済み・重複なし) の参照と、
# 種から下位の階層へ下げて引けたときはその rank 番号 (下げていなければ undef) を返す。
my %search_memo;

sub search {
    my ($query, $rank, $hints) = @_;
    my $name = norm_query($query);
    return ([], undef) unless length $name;
    my @hint = grep { length && $_ ne $query && !is_unidentified($_) } @$hints;
    my %hseen;
    @hint = grep { !$hseen{$_}++ } @hint;
    my $memo = join "\x{1}", $name, $rank, sort @hint;
    return @{ $search_memo{$memo} } if $search_memo{$memo};

    # 1. rank の一致する行を優先する。和名から引く向きで種のときは、種の行が
    #    無ければ下位の階層へ1段ずつ下げる (行のある最初の階層で止める)
    my @cand = @{ lookup_rows($name) };
    my @same = grep { $_->[2] == $rank } @cand;
    my $descended;
    if (!@same && $T->{key} eq 'japname' && $rank == $SPECIES_RANK) {
        my ($lower) = sort { $a <=> $b } grep { $_ > $rank } map { $_->[2] } @cand;
        if (defined $lower) {
            @same = grep { $_->[2] == $lower } @cand;
            $descended = $lower;
        }
    }
    @cand = @same if @same;

    # 2. 1列目が有効名の行を優先する
    my @valid = grep { $_->[1] } @cand;
    @cand = @valid if @valid;

    # 3. 系統で絞る
    if (@cand > 1 && @hint) {
        my @hset = map { hint_scinames($_) } @hint;
        my (@score, $max);
        for my $c (@cand) {
            my ($jap, $sci) = $T->{key} eq 'sciname' ? ($c->[0], $name) : ($name, $c->[0]);
            my $anc = pair_ancestors($jap, $sci, $c->[3]);
            my $n = 0;
            if ($anc) {
                for my $h (@hset) {
                    $n++ if grep { $anc->{$_} } @$h;
                }
            }
            push @score, $n;
            $max = $n if !defined $max || $n > $max;
        }
        @cand = @cand[ grep { $score[$_] == $max } 0 .. $#cand ] if $max;
    }

    # 4. ディレクトリの上下関係
    my %present = map { $_->[3] => 1 } @cand;
    @cand = grep { !superiors($_->[3], \%present) } @cand;

    # 5. 有効名を並べる
    my %seen;
    my @out = sort { $a cmp $b } grep { !$seen{$_}++ } map { $_->[0] } @cand;
    $search_memo{$memo} = [ \@out, $descended ];
    return (\@out, $descended);
}

# 下位の階層へ下げて引いた学名を種の学名に直す (重複を除いて並べ直す)。
sub to_species {
    my ($names) = @_;
    my %seen;
    return [ sort { $a cmp $b } grep { !$seen{$_}++ }
             map { my $sp = species_of_infra($_); defined $sp ? $sp : $_ } @$names ];
}

# ウイルス名か (generate_tables.pl の looks_virus_name の写し)。
sub looks_virus_name {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    return 1 if $s =~ /vir(?:us|oid|usoid)/i;
    return 1 if $s =~ /\b(?:phages?|satellite)\b/i;
    # 綴りに virus を含まない高次分類群 (「Adenoviridae」「Herpesvirales」)。ICTV の
    # 門〜亜科の語尾を1語の学名に限って見る。レルム・亜レルム (-viria・-vira) は
    # 昆虫や植物の属 (「Elviria」「Rovira」) にも当たるので見ない。
    return 1 if $s =~ /\A[A-Z][a-z]+vir(?:icota|icotina|icetes|icetidae|ales|ineae|idae|inae)\z/;
    return 0;
}

# 種内の下位分類群の学名から種の学名を取り出す (generate_tables.pl の
# species_of_infra と同じ規則。「Acer pictum subsp. dissectum」→「Acer pictum」、
# 「Luehdorfia puziloi yessoensis」→「Luehdorfia puziloi」)。取り出せなければ undef。
my $INFRA_CONNECTOR = qr/(?:subsp|ssp|var|subvar|f|forma|morph|nothosubsp|nothovar)\./;

sub species_of_infra {
    my ($sci) = @_;
    return undef unless defined $sci && $sci =~ /\A[A-Za-z .-]+\z/;
    # ウイルスには厳密な二名法がないので、名前の形から種を取り出せない
    # (「Merkel cell polyomavirus」が「Merkel cell」になる)
    return undef if looks_virus_name($sci);
    my @t = split / /, $sci;
    for my $i (1 .. $#t - 1) {
        return undef if $t[$i] eq 'x' && ($i >= 2 || $t[ $i + 1 ] =~ /\A[A-Z]/);
    }
    my $n = (@t > 1 && $t[1] eq 'x') ? 3 : 2;
    return undef unless @t > $n;
    return undef unless $t[0] =~ /\A[A-Z][a-z]+(?:-[a-z]+)*\z/;
    return undef unless $t[ $n - 1 ] =~ /\A[a-z][a-z-]*\z/;
    return undef unless $t[$n] =~ /\A(?:$INFRA_CONNECTOR|[a-z][a-z-]*\z)/;
    return join ' ', @t[ 0 .. $n - 1 ];
}

# 1つのセルを出力の形にする (NEWCOL は足した列に CONVERT と同じ形で書く)
sub render {
    my ($orig, $found) = @_;
    if (!@$found) {
        return $mode eq 'ADD' ? $orig : '';
    }
    my $ans = join ',', @$found;
    return $mode eq 'ADD' ? "$orig ($ans)" : $ans;
}

sub rank_number {
    my ($label) = @_;
    return undef unless defined $label;
    return $RANK_NO{$label};
}

#-----------------------------------------------------------------------------
# クエリ
#-----------------------------------------------------------------------------
# 「階層名:名前」を「,」か「;」で並べたものを [ 階層名, 名前 ] の並びにする。
# 名前 (と項目全体) は二重引用符で括ってよく、引用符の中の区切りは名前の一部。
# 学名には単引用符が入る (Cobitis sp. 'yamato') ので、括るのは二重引用符だけ。
sub split_query {
    my ($q) = @_;
    my (@items, $cur, $inq);
    $cur = '';
    for my $ch (split //, $q) {
        if ($ch eq '"') { $inq = !$inq; $cur .= $ch; next }
        if (!$inq && ($ch eq ',' || $ch eq ';')) { push @items, $cur; $cur = ''; next }
        $cur .= $ch;
    }
    die_usage("クエリの二重引用符が閉じていません: $q") if $inq;
    push @items, $cur;

    my @out;
    for my $item (@items) {
        my $s = $item;
        $s =~ s/\A\s+//;
        $s =~ s/\s+\z//;
        die_usage("クエリに空の項目があります: $q") unless length $s;
        $s = $1 if $s =~ /\A"(.*)"\z/s && $1 !~ /"/;
        die_usage("階層名がありません (「階層名:名前」の形で指定して下さい): $s")
            unless $s =~ /\A([^:"]+?)\s*:\s*(.*)\z/s;
        my ($label, $name) = ($1, $2);
        $name = $1 if $name =~ /\A"(.*)"\z/s;
        die_usage("名前が空です: $s") unless $name =~ /\S/;
        die_usage("名前に二重引用符が残っています: $s") if $name =~ /"/;
        $name =~ s/\A\s+//;
        $name =~ s/\s+\z//;
        $name =~ s/\s+/ /g;
        push @out, [ $label, $name ];
    }
    return @out;
}

# 引数がクエリの形 (先頭が「階層名:」) か。階層名は DB を開く前でも分かる形だけで見る。
sub looks_like_query {
    my ($arg) = @_;
    return $arg =~ /\A\s*"?\s*[A-Za-z][A-Za-z ]*?\s*:/;
}

sub run_query {
    my ($q) = @_;
    die_usage('--mode=NEWCOL はファイルを与えたときだけ使えます。') if $mode eq 'NEWCOL';
    my @items = split_query($q);
    for my $it (@items) {
        die_usage("不明な階層名です: $it->[0] (rank.def の階層名を指定して下さい)")
            unless defined rank_number($it->[0]);
    }
    my @out;
    for my $i (0 .. $#items) {
        my ($label, $name) = @{ $items[$i] };
        my @hints = map { $items[$_][1] } grep { $_ != $i } 0 .. $#items;
        my ($found, $descended) = is_unidentified($name) ? ([], undef)
                                : search($name, rank_number($label), \@hints);
        # 下位の階層へ下げて引けたとき、CONVERT はその階層名で下位の分類群の
        # 学名を返し、ADD は項目の階層 (種) に合わせて種の学名を返す
        if (defined $descended) {
            if ($mode eq 'CONVERT') { $label = $RANK_LABEL{$descended} }
            else                    { $found = to_species($found) }
        }
        push @out, "$label:" . render($name, $found);
    }
    print join('; ', @out), "\n";
}

#-----------------------------------------------------------------------------
# ファイル
#-----------------------------------------------------------------------------
sub check_paths {
    my ($in, $out) = @_;
    die_io("入力ファイルがありません: $in") unless -e $in;
    die_io("入力ファイルが通常のファイルではありません: $in") unless -f $in;
    die_io("入力ファイルを読めません: $in") unless -r $in;
    my $odir = dirname($out);
    die_io("出力ファイルのディレクトリがありません: $odir") unless -d $odir;
    die_io("出力ファイルのディレクトリに書き込めません: $odir") unless -w $odir;
    my $in_abs  = abs_path($in);
    my $out_abs = File::Spec->catfile(abs_path($odir), basename($out));
    $out_abs = abs_path($out_abs) if -e $out_abs;
    die_io("入力ファイルと出力ファイルが同じです: $in") if defined $out_abs && $in_abs eq $out_abs;
    if (-e $out) {
        die_io("出力ファイルが既にあります (上書きするには --overwrite): $out") unless $overwrite;
        die_io("出力ファイルが通常のファイルではありません: $out") unless -f $out;
        die_io("出力ファイルに書き込めません: $out") unless -w $out;
    }
}

sub run_file {
    my ($in, $out) = @_;
    check_paths($in, $out);

    open my $ifh, '<:raw', $in or die_io("入力ファイルを開けません: $in: $!");
    my $header = <$ifh>;
    die_io("入力ファイルが空です: $in") unless defined $header;
    $header = decode_line($header, $in, 1);
    my @labels = split /\t/, $header, -1;
    my %col_rank;
    for my $i (0 .. $#labels) {
        my $n = rank_number($labels[$i]);
        $col_rank{$i} = $n if defined $n;
    }
    die_io("入力ファイルの1行目に階層名の列がありません: $in") unless %col_rank;

    my %target;
    if (@target_opt) {
        my %have = map { $labels[$_] => 1 } keys %col_rank;
        for my $label (map { split /\s*,\s*/ } @target_opt) {
            $label =~ s/\A\s+//;
            $label =~ s/\s+\z//;
            next unless length $label;
            die_usage("--targetrank の階層名が不明です: $label (rank.def の階層名を指定して下さい)")
                unless defined rank_number($label);
            die_usage("--targetrank の階層名の列が入力ファイルにありません: $label")
                unless $have{$label};
            $target{$label} = 1;
        }
    }
    my @rank_cols = sort { $a <=> $b } keys %col_rank;
    my @conv_cols = grep { !%target || $target{ $labels[$_] } } @rank_cols;

    # NEWCOL では引いた列の直後に「列名_$T->{value}」の列を足す
    my %newcol;
    if ($mode eq 'NEWCOL') {
        my %have = map { $_ => 1 } @labels;
        for my $i (@conv_cols) {
            my $label = "$labels[$i]_$T->{value}";
            die_io("足す列と同じ名前の列が入力ファイルにあります: $label") if $have{$label};
            $newcol{$i} = $label;
        }
    }

    my $part = "$out.part";
    open my $ofh, '>:encoding(UTF-8)', $part or die_io("出力ファイルを作れません: $part: $!");
    print $ofh join("\t", add_columns(\@labels, \%newcol)), "\n";

    my (%stat, %miss);
    while (my $line = <$ifh>) {
        $line = decode_line($line, $in, $.);
        my @f = split /\t/, $line, -1;
        my @hints = grep { defined && length } map { $f[$_] } @rank_cols;
        my %cell;
        for my $i (@conv_cols) {
            my $v = $f[$i];
            next unless defined $v && length $v;
            if (is_unidentified($v)) {
                $cell{$i} = render($v, []);
                $stat{unidentified}++;
                next;
            }
            # 下位の階層へ下げて引けたときは、列の階層 (種) に合わせて種の学名にする
            my ($found, $descended) = search($v, $col_rank{$i}, \@hints);
            $found = to_species($found) if defined $descended;
            $cell{$i} = render($v, $found);
            if (@$found) { $stat{found}++ } else { $stat{miss}++; $miss{$v} = 1 }
        }
        if (%newcol) {
            # 足す列のセルは、元の列が空か行が短くて無いときも空にする
            my %add = map { $_ => $cell{$_} // '' } keys %newcol;
            print $ofh join("\t", add_columns(\@f, \%add)), "\n";
        }
        else {
            $f[$_] = $cell{$_} for keys %cell;
            print $ofh join("\t", @f), "\n";
        }
    }
    close $ifh;
    close $ofh or die_io("出力ファイルを書けません: $part: $!");
    rename $part, $out or die_io("出力ファイルの名前を変えられません: $part → $out: $!");

    printf STDERR "%s: 引けたセル %d / 引けなかったセル %d (異なり %d) / unidentified %d\n",
        $out, $stat{found} || 0, $stat{miss} || 0, scalar(keys %miss), $stat{unidentified} || 0;
}

# 列 $i の直後に $add->{$i} を差し込んだ列の並びを返す (行が短ければ足りない列を空で埋める)
sub add_columns {
    my ($f, $add) = @_;
    my ($last) = sort { $b <=> $a } keys %$add;
    my $n = $#$f;
    $n = $last if defined $last && $last > $n;
    my @out;
    for my $i (0 .. $n) {
        push @out, $f->[$i] // '';
        push @out, $add->{$i} if exists $add->{$i};
    }
    return @out;
}

# 入力の1行を UTF-8 として読む (改行と BOM を落とす)
sub decode_line {
    my ($line, $path, $lineno) = @_;
    $line =~ s/\r?\n\z//;
    $line =~ s/\A\xEF\xBB\xBF// if $lineno == 1;
    my $s = eval { Encode::decode('UTF-8', $line, Encode::FB_CROAK) };
    die_io("入力ファイルが UTF-8 ではありません: $path 行 $lineno") unless defined $s;
    return $s;
}

#-----------------------------------------------------------------------------
# 共通ユーティリティ
#-----------------------------------------------------------------------------
sub decode_arg {
    my ($arg) = @_;
    my $s = eval { Encode::decode('UTF-8', $arg, Encode::FB_CROAK) };
    return defined $s ? $s : $arg;
}

# スクリプトの隣の VERSION を読む (make exec で作ったコマンドでは使わない)
sub read_version {
    my $path = File::Spec->catfile(dirname(abs_path($0)), 'VERSION');
    open my $fh, '<', $path or return 'unknown';
    my $v = <$fh>;
    close $fh;
    $v = '' unless defined $v;
    $v =~ s/\s+//g;
    return length $v ? $v : 'unknown';
}

# --db を省いたときの DB。$DEFAULT_DBDIR にある、このスクリプトと同じ版の
# jbtaxon_VERSION_BUILDDATE.sqlite3 のうち BUILDDATE が最も新しいもの。
sub default_db {
    my $prefix = "jbtaxon_${SCRIPT_VERSION}_";
    my @found;
    if (opendir my $dh, $DEFAULT_DBDIR) {
        @found = sort grep { /\A\Q$prefix\E[0-9]{8}\.sqlite3\z/ } readdir $dh;
        closedir $dh;
    }
    die_usage("--db を省きましたが、$DEFAULT_DBDIR に ${prefix}YYYYMMDD.sqlite3 がありません。")
        unless @found;
    return File::Spec->catfile($DEFAULT_DBDIR, $found[-1]);
}

sub die_usage {
    my ($msg) = @_;
    print STDERR "$msg\n\n";
    usage(2);
}

sub die_io {
    my ($msg) = @_;
    print STDERR "$msg\n";
    exit 2;
}

sub usage {
    my ($status) = @_;
    my $fh = $status ? *STDERR : *STDOUT;
    my $me = basename($0);
    print $fh <<"USAGE";
$me $SCRIPT_VERSION

使い方: $me [--db=DBFILE] [オプション] クエリ
        $me [--db=DBFILE] [オプション] 入力ファイル 出力ファイル

jbtaxon_VERSION_BUILDDATE.sqlite3 の $DIRECTION テーブルを検索し、
$T->{keyword}に対応する有効な$T->{answer}を返します。

クエリは「階層名:名前」を「,」か「;」で並べたもの (階層名は rank.def のもの)。
  species:"Homo sapiens"
  "species:Homo sapiens"
  class:Mammalia,species:"Homo sapiens"
各項目を引き、他の項目を系統の手がかりに使います。結果は標準出力に1行で
「階層名:結果」を「; 」で並べて出します。

ファイルを与えると、入力ファイル (タブ区切り、1行目のラベルが階層名) の
階層名の列のセルを引いて出力ファイルに書きます。同じ行の他の階層の名前を
系統の手がかりに使います。ラベルが階層名でない列と見出し行はそのまま出します。

オプション:
  --db=DBFILE          検索する DB。省くと $DEFAULT_DBDIR の
                       jbtaxon_${SCRIPT_VERSION}_YYYYMMDD.sqlite3 のうち最も新しいもの
  --mode=ADD|CONVERT|NEWCOL
                       出力の形 (既定: ADD)
                         ADD     「元の名前 (引いた名前)」。引けなければ元のまま
                         CONVERT 引いた名前だけ。引けなければ空
                         NEWCOL  元の列はそのままにし、直後に足した「列名_$T->{value}」
                                 の列に CONVERT と同じ形で書く (ファイルのときだけ)
                       複数の名前が引けたら「,」で連結します
  --targetrank=NAME    引く列を階層名で限定する (ファイルのときだけ。カンマ区切り可、
                       複数指定可)
  --overwrite          出力ファイルが既にあれば上書きする
  --help, -h           このヘルプを表示する
USAGE
    exit $status;
}

sub check_dependencies {
    my @missing;
    for my $m (@REQUIRED_MODULES) {
        my ($mod, $pkg, $why) = @$m;
        eval "require $mod; 1" or push @missing, [ "Perl モジュール $mod", $pkg, $why, $mod ];
    }
    return unless @missing;

    print STDERR basename($0) . " の実行に必要なものが不足しています。\n\n";
    printf STDERR "  %s (%s)\n    Debian/Ubuntu: sudo apt install %s\n",
        $_->[0], $_->[2], $_->[1] for @missing;
    print STDERR "\nCPAN から入れる場合は cpanm " . join(' ', map { $_->[3] } @missing) . "\n";
    exit 2;
}

#-----------------------------------------------------------------------------
# 実行 (ファイル末尾に置く。上のサブルーチン群が使う表の代入を先に済ませるため)
#-----------------------------------------------------------------------------
if (@ARGV == 1) {
    die_usage('--targetrank はファイルを与えたときだけ使えます。') if @target_opt;
    die_usage("クエリは「階層名:名前」の形で指定して下さい: $ARGV[0]")
        unless looks_like_query($ARGV[0]);
    open_db($db_path);
    run_query($ARGV[0]);
}
else {
    die_usage('クエリとファイルは同時に指定できません。')
        if grep { looks_like_query($_) && !-e $_ } @ARGV;
    open_db($db_path);
    run_file(@ARGV);
}
exit 0;
