#!/usr/bin/perl
#
# generate_dictionary.pl - 分類群ごとのテーブル TSV から日本語入力 IME 用の
#                          辞書 TSV を生成する
#
# パイプラインの第4段 (generate_database.pl と並列の枝)。generate_tables.pl が
# 各分類群ディレクトリに書き出した japname2sciname_VERSION_BUILDDATE.tsv を読み、
# リポジトリルートに次の2つを作る。
#   yomi2japname_VERSION_BUILDDATE.tsv ... 和名の読み → 和名
#   yomi2sciname_VERSION_BUILDDATE.tsv ... 和名の読み → 学名
#
# 行の作り方 (README「和名読み→和名辞書」「和名読み→学名辞書」):
#   yomi2japname ... 和名→学名テーブルの全ての和名 (有効名もシノニムも) について
#                    「読み → その和名」。和名がシノニムなら、さらに
#                    「シノニムの読み → 有効名の和名」も出す。有効名の和名は、同じ
#                    ディレクトリの和名→学名テーブルで同じ学名に有効 (japvalid=1)
#                    として付いている和名。ディレクトリをまたいで引かないのは、
#                    分類群をまたぐ同名異物の学名 (Prunella の鳥と植物) で別の生物の
#                    和名に結んでしまうため。
#   yomi2sciname ... 和名→学名テーブルの全ての行について「和名の読み → 学名」。
#                    和名→学名テーブルの2列目は有効な学名だけなので、学名のシノニムは
#                    出ない。
# 同じ (読み, 和名 / 学名) は1行にまとめる。出典 (comment) には、和名そのものの行を
# シノニムから引いた行より優先し、次いで専門のディレクトリ (sources.tsv の順) を
# AllTaxa より優先して、最初に見つかった行のものを使う (generate_database.pl の
# 「AllTaxa は他の全ディレクトリに従う」と同じ向き)。
#
# 読みの組み立て (make_yomi。add_to_yomi.pl の make_yomi と同じもの):
#   和名をかな1字とリポジトリルートの yomi.tsv の japname (読みが空でない行) で
#   隙間なく覆い、カタカナはひらがなに直し、yomi.tsv の部分はその読みに置き換える。
#   中黒「・」は読みに入れない (IME では区切らずに打つため)。長音符「ー」は残す。
#   覆い方が何通りもあれば区切りの数が最も少ないものだけを使い (yomi.tsv の長い
#   見出しの読みを優先する)、そこで yomi.tsv の読みが何通りもあれば異なる読みを
#   全て出す。**yomi.tsv の情報が足りず正確な読みが得られない和名は、その和名の
#   行を出さない** (覆えない和名と、読みが $MAX_YOMI 通りを超えて決められない
#   和名)。add_to_yomi.pl がそれらを yomi.tsv に追記するので、読みを埋めれば
#   入るようになる。シノニムの読みから引く行も、シノニムの読みが得られなければ
#   出さない。
#
# 形式 (--for で切り替える。いずれもタブ区切り・ヘッダ行なし):
#   generic (既定) ... yomi / japname|sciname / 名詞 / comment
#   mozc-user      ... yomi / japname|sciname / 短縮読み / comment
#   gboard         ... yomi / japname|sciname / ja-JP / 短縮読み
#   mozc-system    ... yomi / lid / rid / cost / japname
#                      yomi / lid / rid / cost / sciname / ENGLISH
#     lid・rid は種以下 (亜種・変種など) なら「名詞,固有名詞,一般」、種より上なら
#     「名詞,固有名詞,組織」の ID を --id-def で与えた Mozc の id.def から引く。
#     rank 0 (体系でも階層が決まらなかったもの。ウイルスの株や亜型が多い) は
#     「一般」にする (ユーザー決定)。
#     cost は既定で 9999 (--japcost / --scicost)。
# comment は「sourcetitle (sourceurl) by sourceauthor」。

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
# 定数
#-----------------------------------------------------------------------------
my $IN_KIND = 'japname2sciname';
my @OUT_KINDS = ('yomi2japname', 'yomi2sciname');

# 最終 TSV の列数 (1列目 / 2列目 / 有効性 / rank / subrank / 出典3列)
my $N_COLUMNS = 8;

# yomi.tsv の先頭行 (列名)
my $YOMI_HEADER = "yomi\tjapname";

# 読みを自動生成できるかな (add_to_yomi.pl と同じ)。ゕ ゖ とカタカナの ヵ ヶ は
# 地名の「八ヶ岳」のように「が」とも読むので入れない。
my $KANA_CLASS = qr/[\x{3041}-\x{3094}\x{30A1}-\x{30F4}ー・]/;

# 1つの和名に出す読みの上限。超えたら正確な読みが決められないとして出さない
# (yomi.tsv の読みの組み合わせが膨らむことへの備え)
my $MAX_YOMI = 16;

# 全生物を扱うディレクトリ。出典を選ぶときは他のディレクトリより後に回す。
my $ALLTAXA_DIR = 'AllTaxa';

# --for の値ごとの形式
my %FORMAT = (
    'generic'     => { pos => '名詞' },
    'mozc-user'   => { pos => '短縮読み' },
    'gboard'      => { lang => 'ja-JP', pos => '短縮読み' },
    'mozc-system' => { system => 1 },
);

# Mozc の id.def から引く品詞 (先頭3つの項目)
my %MOZC_POS = (
    general      => '名詞,固有名詞,一般',
    organization => '名詞,固有名詞,組織',
);

my $DEFAULT_COST = 9999;

#-----------------------------------------------------------------------------
# ソース定義 (sources.tsv)。ここではディレクトリの一覧と並び順に使う。
#-----------------------------------------------------------------------------
my @SOURCES = read_sources();

#-----------------------------------------------------------------------------
# CLI
#-----------------------------------------------------------------------------
my $basedir;
my @only;
my $opt_ver;
my $opt_build;
my $opt_for = 'generic';
my $id_def;
my $japcost = $DEFAULT_COST;
my $scicost = $DEFAULT_COST;
my $dry_run = 0;
my $help    = 0;

Getopt::Long::Configure('bundling');
GetOptions(
    'dir=s'       => \$basedir,
    'only=s'      => \@only,
    'version=s'   => \$opt_ver,
    'builddate=s' => \$opt_build,
    'for=s'       => \$opt_for,
    'id-def=s'    => \$id_def,
    'japcost=s'   => \$japcost,
    'scicost=s'   => \$scicost,
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

#-----------------------------------------------------------------------------
# 下ごしらえ
#-----------------------------------------------------------------------------
# 入力の TSV と出力の辞書に同じ日付を使うので、ビルド日は省略させない。
unless (defined $opt_build) {
    print STDERR "--builddate を指定して下さい (入力の TSV と同じ日付)。\n\n";
    usage(2);
}
unless ($opt_build =~ /^\d{8}$/) {
    print STDERR "--builddate は YYYYMMDD 形式で指定して下さい: $opt_build\n";
    exit 2;
}
my $FMT = $FORMAT{$opt_for} or do {
    print STDERR "--for の値が不明です: $opt_for (" . join(' / ', sort keys %FORMAT) . ")\n";
    exit 2;
};
for my $c ([ '--japcost', $japcost ], [ '--scicost', $scicost ]) {
    next if $c->[1] =~ /^\d+$/;
    print STDERR "$c->[0] は 0 以上の整数で指定して下さい: $c->[1]\n";
    exit 2;
}
if ($FMT->{system} && !defined $id_def) {
    print STDERR "--for=mozc-system には --id-def で Mozc の id.def を指定して下さい。\n";
    exit 2;
}
my $VERSION   = defined $opt_ver ? $opt_ver : read_version();
my $BUILDDATE = $opt_build;
my @RANK_DEF  = read_rank_def();
my ($SPECIES_RANK) = map { $_->[0] } grep { $_->[1] eq 'species' } @RANK_DEF;

# yomi.tsv はリポジトリのファイルなので、--dir ではなくスクリプトの隣を見る。
my $YOMI_PATH = File::Spec->catfile(dirname(abs_path($0)), 'yomi.tsv');

my $t_start = time;
my $n_fail  = 0;
my @failures;

# 実際の処理はファイル末尾の「実行」ブロックで行う。

#-----------------------------------------------------------------------------
# 入力の読み込み
#-----------------------------------------------------------------------------
sub input_path {
    my ($dir) = @_;
    return File::Spec->catfile($basedir, $dir, "${IN_KIND}_${VERSION}_${BUILDDATE}.tsv");
}

sub output_path {
    my ($kind) = @_;
    return File::Spec->catfile($basedir, "${kind}_${VERSION}_${BUILDDATE}.tsv");
}

# 和名→学名テーブルを1つ読み、行を [ 和名, 学名, japvalid, rank, subrank,
# 表題, 著者, URL ] の配列で返す (読めなければ undef)。
sub read_table {
    my ($dir) = @_;
    my $path = input_path($dir);
    open my $fh, '<', $path or do {
        record_failure("$dir/$IN_KIND", '入力ファイルを読めません: ' . relname($path) . ": $!");
        return;
    };
    binmode $fh, ':encoding(UTF-8)';
    my @rows;
    my $n_bad = 0;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        next unless length $line;
        my @f = split /\t/, $line, -1;
        if (@f != $N_COLUMNS || !length $f[0] || !length $f[1]
            || $f[2] !~ /^[01]$/ || $f[3] !~ /^\d+$/ || $f[4] !~ /^\d+$/) {
            $n_bad++;
            next;
        }
        push @rows, \@f;
    }
    close $fh;
    record_failure("$dir/$IN_KIND", "形式の崩れた行が $n_bad 行あります (読み飛ばしました)")
        if $n_bad;
    return \@rows;
}

# yomi.tsv を読む。読みが空でない行だけを { 和名 => [ 読み, ... ] } にする
# (同じ和名に読みが複数あれば全て持つ)。最長の和名の字数も返す。
sub read_yomi {
    open my $fh, '<', $YOMI_PATH or do {
        print STDERR "yomi.tsv を読めません: $YOMI_PATH: $!\n";
        exit 2;
    };
    binmode $fh, ':encoding(UTF-8)';
    my (%yomi, %seen, @err);
    my $maxlen = 0;
    my ($n_blank, $n_line) = (0, 0);
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        $n_line++;
        if ($. == 1) {
            push @err, "1行目が列名 ($YOMI_HEADER) ではありません" unless $line eq $YOMI_HEADER;
            next;
        }
        next unless length $line;
        my @f = split /\t/, $line, -1;
        if (@f != 2 || !length $f[1]) {
            push @err, "$. 行目: yomi と japname の2列になっていません: $line";
            next;
        }
        my ($y, $jap) = @f;
        unless (length $y) { $n_blank++; next }
        push @err, "$. 行目: 読みにひらがなと「ー」以外の文字があります: $line"
            if $y !~ /^[\x{3041}-\x{3094}ー]+\z/;
        next if $seen{"$jap\t$y"}++;
        push @{ $yomi{$jap} }, $y;
        $maxlen = length $jap if length $jap > $maxlen;
    }
    close $fh;
    push @err, '中身が空です' unless $n_line;
    if (@err) {
        print STDERR "yomi.tsv の形式が崩れています: $YOMI_PATH\n";
        print STDERR "  $_\n" for @err;
        exit 2;
    }
    return { yomi => \%yomi, maxlen => $maxlen, blank => $n_blank };
}

# Mozc の id.def (「ID 品詞,…」の行) から、%MOZC_POS の品詞の ID を引く。
# 先頭3つの項目が一致する行のうち、残りの項目が全て「*」の行を採り、無ければ
# 最初に一致した行を採る。
sub read_id_def {
    my ($path) = @_;
    open my $fh, '<', $path or do {
        print STDERR "id.def を読めません: $path: $!\n";
        exit 2;
    };
    binmode $fh, ':encoding(UTF-8)';
    my (%plain, %first);
    my %want = reverse %MOZC_POS;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        next unless $line =~ /^\s*(\d+)\s+(\S+)/;
        my ($id, $pos) = ($1, $2);
        my @p = split /,/, $pos, -1;
        next unless @p >= 3;
        my $key = $want{ join ',', @p[0 .. 2] } or next;
        $first{$key} = $id unless defined $first{$key};
        $plain{$key} = $id if !defined $plain{$key} && !grep { $_ ne '*' } @p[3 .. $#p];
    }
    close $fh;
    my (%ids, @missing);
    for my $key (sort keys %MOZC_POS) {
        my $id = defined $plain{$key} ? $plain{$key} : $first{$key};
        if (defined $id) { $ids{$key} = $id }
        else             { push @missing, $MOZC_POS{$key} }
    }
    if (@missing) {
        print STDERR "id.def に品詞がありません: $path: " . join(' / ', @missing) . "\n";
        exit 2;
    }
    return \%ids;
}

#-----------------------------------------------------------------------------
# 読みの組み立て
#-----------------------------------------------------------------------------
# 和名の正確な読みを全て返す。正確な読みが得られなければ空リストを返し、その
# 和名は辞書に入らない。add_to_yomi.pl の make_yomi と同じもの (片方を直したら
# もう片方も直す) で、そちらは空リストになる和名を yomi.tsv に追記する。
#   - かな1字と yomi.tsv の japname で隙間なく覆えなければ、読みは得られない。
#   - 覆い方が何通りもあれば、区切りの数 (かな1字も yomi.tsv の1件も1つと数える)
#     が最も少ないものだけを使う。yomi.tsv の長い見出しは、その範囲を作者が
#     読みとして書いたものなので、短い見出しを繋いだ読みより正確 (「下目」が
#     「かもく」と載っていれば、「した 下」が足されても「したもく」を作らない)。
#   - そうして残った読みが $MAX_YOMI 通りを超えたら、どれが正しいか決められない
#     ので読みは得られないとする (途中で打ち切った読みを出さない)。
# $best[i] は「先頭から i 字目の手前まで」を覆う最少の区切りの数、$sets[i] はその
# 区切りの数で得られる読みの集合、$over[i] はそれが上限を超えたか。
sub make_yomi {
    my ($name, $Y) = @_;
    my $len = length $name;
    my (@best, @sets, @over);
    ($best[0], $sets[0]) = (0, { '' => 1 });
    my $add = sub {
        my ($to, $from, $part) = @_;
        my $n = $best[$from] + 1;
        return if defined $best[$to] && $best[$to] < $n;
        if (!defined $best[$to] || $best[$to] > $n) {
            ($best[$to], $sets[$to], $over[$to]) = ($n, {}, 0);
        }
        $over[$to] ||= $over[$from];
        my $set = $sets[$to];
        for my $y (keys %{ $sets[$from] }) {
            $set->{ $y . $part } = 1;
            if (keys %$set > $MAX_YOMI) { $over[$to] = 1; last }
        }
    };
    for my $i (0 .. $len - 1) {
        next unless defined $best[$i];
        my $c = substr($name, $i, 1);
        if ($c =~ /^$KANA_CLASS\z/) {
            my $part = $c eq '・' ? '' : $c;
            $part =~ tr/\x{30A1}-\x{30F4}/\x{3041}-\x{3094}/;
            $add->($i + 1, $i, $part);
        }
        for my $k (1 .. $Y->{maxlen}) {
            last if $i + $k > $len;
            my $ys = $Y->{yomi}{ substr($name, $i, $k) } or next;
            $add->($i + $k, $i, $_) for @$ys;
        }
    }
    return () if !defined $best[$len] || $over[$len];
    return grep { length } sort keys %{ $sets[$len] };
}

#-----------------------------------------------------------------------------
# 辞書の行を集める
#-----------------------------------------------------------------------------
# ディレクトリを出典の優先順に並べる (専門のディレクトリを sources.tsv の順、
# AllTaxa を最後)。
sub dirs_by_priority {
    my ($dirs) = @_;
    return ((grep { $_ ne $ALLTAXA_DIR } @$dirs), (grep { $_ eq $ALLTAXA_DIR } @$dirs));
}

# 1ディレクトリの行から辞書の行を集める。%$out は
#   { yomi2japname => { "読み\t和名" => [ 優先度, rank, comment ] }, yomi2sciname => … }
# 優先度は小さいほど優先 ([ 和名そのものの行なら 0・シノニムから引いた行なら 1,
# ディレクトリの順, 行の順 ] を1つの数にしたもの)。最初に入った行より優先度の
# 高い行が来たときだけ置き換える。
sub collect_entries {
    my ($rows, $dir_rank, $Y, $out, $memo, $stats) = @_;
    my %valid_of;    # 学名 => [ 有効な和名, ... ] (このディレクトリ内)
    for my $r (@$rows) {
        push @{ $valid_of{ $r->[1] } }, $r->[0] if $r->[2];
    }
    my $put = sub {
        my ($kind, $key, $prio, $rank, $comment) = @_;
        my $cur = $out->{$kind}{$key};
        return if $cur && $cur->[0] <= $prio;
        $out->{$kind}{$key} = [ $prio, $rank, $comment ];
    };
    my $i = 0;
    for my $r (@$rows) {
        my ($jap, $sci, $jv, $rank, undef, $title, $author, $url) = @$r;
        my $comment = "$title ($url) by $author";
        my $order = $dir_rank * 1e7 + $i++;
        my $ys = $memo->{$jap} ||= [ make_yomi($jap, $Y) ];
        unless (@$ys) {
            $stats->{no_yomi}{$jap} = 1;
            next;
        }
        for my $y (@$ys) {
            $put->('yomi2japname', "$y\t$jap", $order,         $rank, $comment);
            $put->('yomi2sciname', "$y\t$sci", $order,         $rank, $comment);
            next if $jv;
            for my $v (@{ $valid_of{$sci} || [] }) {
                next if $v eq $jap;
                $put->('yomi2japname', "$y\t$v", 1e15 + $order, $rank, $comment);
            }
        }
    }
}

#-----------------------------------------------------------------------------
# 書き出し
#-----------------------------------------------------------------------------
# 辞書の1行を形式に合わせて作る。
sub format_line {
    my ($kind, $yomi, $name, $rank, $comment, $ids) = @_;
    if ($FMT->{system}) {
        my $id = (!$rank || $rank >= $SPECIES_RANK) ? $ids->{general} : $ids->{organization};
        return $kind eq 'yomi2japname'
             ? join("\t", $yomi, $id, $id, $japcost, $name)
             : join("\t", $yomi, $id, $id, $scicost, $name, 'ENGLISH');
    }
    return join("\t", $yomi, $name, $FMT->{lang}, $FMT->{pos}) if $FMT->{lang};
    return join("\t", $yomi, $name, $FMT->{pos}, $comment);
}

# 読み → 名前の順に並べて書く。.part に書いてから rename する。行数を返す。
sub write_dictionary {
    my ($kind, $entries, $ids) = @_;
    my $path = output_path($kind);
    my $part = "$path.part";
    open my $fh, '>', $part or die "$part を書けません: $!\n";
    binmode $fh, ':encoding(UTF-8)';
    my $n = 0;
    for my $key (sort keys %$entries) {
        my ($yomi, $name) = split /\t/, $key, 2;
        my (undef, $rank, $comment) = @{ $entries->{$key} };
        print $fh format_line($kind, $yomi, $name, $rank, $comment, $ids), "\n";
        $n++;
    }
    close $fh or die "$part を書けません: $!\n";
    rename $part, $path or die "$part を $path に置き換えられません: $!\n";
    return $n;
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

sub report_summary {
    my ($stats) = @_;
    my $elapsed = time - $t_start;
    print "\n=== 集計 ===\n";
    if ($stats) {
        printf "入力: %d 行 / 和名 %d 件 (正確な読みが得られず出さなかった和名 %d 件)\n",
            $stats->{in} || 0, $stats->{names} || 0, scalar keys %{ $stats->{no_yomi} || {} };
        printf "出力: %s %d 行\n", $_, $stats->{"out_$_"} || 0 for @OUT_KINDS;
        print "正確な読みが得られない和名は add_to_yomi.pl で yomi.tsv に追記し、読みを埋めて下さい"
            . ($stats->{blank} ? " (yomi.tsv の読みが空欄の行: $stats->{blank} 行)" : '') . "\n"
            if %{ $stats->{no_yomi} || {} };
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
使い方: generate_dictionary.pl --builddate=YYYYMMDD [オプション]

分類群ごとのディレクトリにある和名→学名テーブルの TSV から、和名の読み → 和名の
辞書 yomi2japname_VERSION_BUILDDATE.tsv と、和名の読み → 学名の辞書
yomi2sciname_VERSION_BUILDDATE.tsv を生成します。読みは yomi.tsv を使って
組み立てます (組み立てられない和名は辞書に入りません)。

オプション:
  --builddate=YYYYMMDD  ビルド日 (必須)。入力の TSV と出力の辞書の両方に使う
  --for=TYPE            辞書の形式 (既定: generic)
                          generic      yomi / 名前 / 名詞 / comment
                          mozc-user    yomi / 名前 / 短縮読み / comment
                          gboard       yomi / 名前 / ja-JP / 短縮読み
                          mozc-system  yomi / lid / rid / cost / 名前 (学名は / ENGLISH を付ける)
  --id-def=PATH         Mozc の id.def (--for=mozc-system では必須)
  --japcost=N           mozc-system の和名の cost (既定: $DEFAULT_COST)
  --scicost=N           mozc-system の学名の cost (既定: $DEFAULT_COST)
  --dir=PATH            ベースディレクトリ (既定: スクリプトのあるディレクトリ)
  --only=NAME           分類群ディレクトリを限定する (複数指定可)
  --version=X.Y.Z       VERSION ファイルの値を上書きする
  --dry-run             入力ファイルの存在確認だけを行う (辞書を作りません)
  --help, -h            このヘルプを表示する

出力は既にあっても作り直します。yomi.tsv はスクリプトと同じディレクトリのものを
読みます (--dir に依らない)。

指定可能な --only の名前:
  $dirs
USAGE
    exit $status;
}

#-----------------------------------------------------------------------------
# 共通ユーティリティ: 環境まわり
#-----------------------------------------------------------------------------
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
printf "VERSION=%s BUILDDATE=%s 形式=%s\n", $VERSION, $BUILDDATE, $opt_for;
print "(dry-run: 入力ファイルの存在確認だけを行います)\n" if $dry_run;

my $Y = read_yomi();
logmsg('read', sprintf('%s (読みのある和名 %d 件)', relname($YOMI_PATH), scalar keys %{ $Y->{yomi} }));
my $ids = $FMT->{system} ? read_id_def($id_def) : undef;
logmsg('read', sprintf('%s (一般 %d / 組織 %d)', relname($id_def), $ids->{general}, $ids->{organization}))
    if $ids;

if ($dry_run) {
    for my $dir (@dirs) {
        my $path = input_path($dir);
        if (-e $path) { logmsg('dry', relname($path)) }
        else          { record_failure("$dir/$IN_KIND", '入力ファイルがありません: ' . relname($path)) }
    }
    logmsg('dry', '出力: ' . relname(output_path($_))) for @OUT_KINDS;
    report_summary();
    exit($n_fail ? 1 : 0);
}

my %stats = (blank => $Y->{blank});
my (%entries, %memo);
my @order = dirs_by_priority(\@dirs);
for my $d (0 .. $#order) {
    my $dir = $order[$d];
    my $path = input_path($dir);
    unless (-e $path) {
        record_failure("$dir/$IN_KIND", '入力ファイルがありません: ' . relname($path));
        next;
    }
    my $rows = read_table($dir) or next;
    logmsg('read', sprintf('%s (%d 行)', relname($path), scalar @$rows));
    $stats{in} += @$rows;
    collect_entries($rows, $d, $Y, \%entries, \%memo, \%stats);
}
$stats{names} = scalar keys %memo;

# 入力が欠けていても書き出す (辞書は毎回作り直すので、揃えてから実行し直せばよい)。
for my $kind (@OUT_KINDS) {
    my $n = eval { write_dictionary($kind, $entries{$kind} || {}, $ids) };
    if (defined $n) {
        $stats{"out_$kind"} = $n;
        logmsg('write', sprintf('%s (%d 行)', relname(output_path($kind)), $n));
    }
    else {
        my $why = $@; $why =~ s/\s+\z//;
        record_failure(relname(output_path($kind)), "書き込みに失敗しました: $why");
    }
}

report_summary(\%stats);
exit($n_fail ? 1 : 0);
