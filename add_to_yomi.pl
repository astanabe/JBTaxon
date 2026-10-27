#!/usr/bin/perl
#
# add_to_yomi.pl - 読みを自動生成できない和名を yomi.tsv の末尾に追記する
#
# generate_tables.pl が各分類群ディレクトリに書き出した
# japname2sciname_VERSION_BUILDDATE.tsv の和名 (1列目。有効名もシノニムも) を集め、
# リポジトリルートの yomi.tsv にある読みだけでは正確な読みが得られない和名を、
# yomi を空欄にして yomi.tsv の末尾に追記する。筆者が手で読みを埋めて
# リポジトリの yomi.tsv を更新していく (README「分類群和名の読みについて」)。
#
# 読みは generate_dictionary.pl と同じ make_yomi で組み立て、読みが得られない
# (generate_dictionary.pl が辞書に入れない) 和名を追記する。読みが得られるのは、
# 先頭から次のどちらかで隙間なく覆えるもの。
#   - かな1字 ... ひらがな・全角カタカナ (ヴ を含む)・長音符「ー」・中黒「・」。
#                 カタカナはひらがなに直せば読みになる
#   - yomi.tsv の japname ... 読み (1列目) が空でない行のもの
# 全ての切り方を調べ (先頭から最長一致で切ると覆えない名前もある)、区切りの数が
# 最も少ない覆い方の読みを使う。その読みが $MAX_YOMI 通りを超えたら正確な読みが
# 決められないとして、覆えても追記する (和名全体の読みを書けば1通りに決まる)。
# 漢字・数字・ラテン文字・ギリシャ文字・「々」・「ヵ」「ヶ」(「八ヶ岳」の「ヶ」は
# 「が」と読む) はかなではないので、yomi.tsv に載っていない限り読みにならない。
#
# 追記するのは「正確な読みが得られず、かつ yomi.tsv にまだ載っていない」和名だけ
# (読みが空欄の行も「載っている」とみなす)。何度実行しても同じ和名は二重に
# 足されない。追記する和名は Unicode の符号位置の順に並べる。
#
# yomi.tsv は .part に書いてから rename する (中断で切り詰められた yomi.tsv が
# 残ると、手で埋めた読みが失われるため)。

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
my $KIND = 'japname2sciname';

# 最終 TSV の列数 (1列目 / 2列目 / 有効性 / rank / subrank / 出典3列)
my $N_COLUMNS = 8;

# yomi.tsv の先頭行 (列名)
my $YOMI_HEADER = "yomi\tjapname";

# 読みを自動生成できるかな (ひらがな、ヴ までのカタカナ、長音符、中黒)。
# ゕ ゖ (U+3095 / U+3096) とカタカナの ヵ ヶ は地名の「八ヶ岳」のように「が」
# とも読むので入れない。
my $KANA_CLASS = qr/[\x{3041}-\x{3094}\x{30A1}-\x{30F4}ー・]/;

# 1つの和名の読みの上限。超えたら正確な読みが決められないとする
# (generate_dictionary.pl と同じ値)
my $MAX_YOMI = 16;

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
my $dry_run = 0;
my $help    = 0;

Getopt::Long::Configure('bundling');
GetOptions(
    'dir=s'       => \$basedir,
    'only=s'      => \@only,
    'version=s'   => \$opt_ver,
    'builddate=s' => \$opt_build,
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
# 入力の TSV はビルド日ごとにあるので、どれを読むかを省略させない。
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
    return File::Spec->catfile($basedir, $dir, "${KIND}_${VERSION}_${BUILDDATE}.tsv");
}

# 和名→学名テーブルを1つ読み、1列目の和名を %$names に数える。
# 読んだ行数を返す (読めなければ undef)。
sub read_japnames {
    my ($dir, $names) = @_;
    my $path = input_path($dir);
    open my $fh, '<', $path or do {
        record_failure("$dir/$KIND", '入力ファイルを読めません: ' . relname($path) . ": $!");
        return;
    };
    binmode $fh, ':encoding(UTF-8)';
    my ($n, $n_bad) = (0, 0);
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        next unless length $line;
        my @f = split /\t/, $line, -1;
        if (@f != $N_COLUMNS || !length $f[0]) {
            $n_bad++;
            next;
        }
        $names->{ $f[0] }++;
        $n++;
    }
    close $fh;
    record_failure("$dir/$KIND", "形式の崩れた行が $n_bad 行あります (読み飛ばしました)")
        if $n_bad;
    return $n;
}

# yomi.tsv を読む。返り値は
#   { raw => ファイルの中身 (文字列), listed => { 和名 => 1 },
#     yomi => { 和名 => [ 読み, ... ] } (読みが空でないもの),
#     maxlen => yomi の和名の最長の字数 }
# 先頭行が列名でない・列が2つでない行があれば、追記せずに終える (手で埋めた
# 読みの行が崩れているのに末尾へ足すと、崩れたまま気付かれにくくなるため)。
sub read_yomi {
    open my $fh, '<', $YOMI_PATH or do {
        print STDERR "yomi.tsv を読めません: $YOMI_PATH: $!\n";
        exit 2;
    };
    binmode $fh, ':encoding(UTF-8)';
    local $/;
    my $raw = <$fh>;
    close $fh;
    $raw = '' unless defined $raw;

    my (%listed, %yomi, %seen, @err);
    my $maxlen = 0;
    my @lines = split /\n/, $raw;
    for my $i (0 .. $#lines) {
        (my $line = $lines[$i]) =~ s/\r\z//;
        if ($i == 0) {
            push @err, "1行目が列名 ($YOMI_HEADER) ではありません" unless $line eq $YOMI_HEADER;
            next;
        }
        next unless length $line;
        my @f = split /\t/, $line, -1;
        if (@f != 2 || !length $f[1]) {
            push @err, sprintf('%d 行目: yomi と japname の2列になっていません: %s', $i + 1, $line);
            next;
        }
        my ($y, $jap) = @f;
        $listed{$jap} = 1;
        next unless length $y;
        push @{ $yomi{$jap} }, $y unless $seen{"$jap\t$y"}++;
        $maxlen = length $jap if length $jap > $maxlen;
    }
    push @err, '中身が空です' unless @lines;
    if (@err) {
        print STDERR "yomi.tsv の形式が崩れています: $YOMI_PATH\n";
        print STDERR "  $_\n" for @err;
        exit 2;
    }
    return { raw => $raw, listed => \%listed, yomi => \%yomi, maxlen => $maxlen };
}

#-----------------------------------------------------------------------------
# 読みの組み立て
#-----------------------------------------------------------------------------
# 和名の正確な読みを全て返す。正確な読みが得られなければ空リストを返し、その
# 和名は辞書に入らない。generate_dictionary.pl の make_yomi と同じもの (片方を直したら
# もう片方も直す) で、ここが空リストを返す和名は辞書に入らない。
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
# 書き出し
#-----------------------------------------------------------------------------
# yomi.tsv の末尾に「(空欄)<TAB>和名」の行を足す。元の中身はそのまま残す。
sub append_yomi {
    my ($yomi, $add) = @_;
    my $part = "$YOMI_PATH.part";
    open my $fh, '>', $part or die "$part を書けません: $!\n";
    binmode $fh, ':encoding(UTF-8)';
    my $raw = $yomi->{raw};
    print $fh $raw;
    print $fh "\n" if length $raw && $raw !~ /\n\z/;
    print $fh "\t$_\n" for @$add;
    close $fh or die "$part を書けません: $!\n";
    rename $part, $YOMI_PATH or die "$part を $YOMI_PATH に置き換えられません: $!\n";
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
        printf "和名: %d 件 (読みを自動生成できる %d / できない %d)\n",
            $stats->{names} || 0, $stats->{ok} || 0, $stats->{ng} || 0;
        printf "できないうち yomi.tsv に載っている (読みが空欄) %d / %s %d\n",
            $stats->{listed} || 0, $dry_run ? '追記する予定' : '追記した', $stats->{added} || 0;
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
使い方: add_to_yomi.pl --builddate=YYYYMMDD [オプション]

分類群ごとのディレクトリにある和名→学名テーブルの TSV から、yomi.tsv の読みでは
読みを自動生成できない和名を探し、yomi を空欄にして yomi.tsv の末尾に追記します。
かな (ひらがな・カタカナ・ー・・) と yomi.tsv の和名で隙間なく覆える和名は読みを
自動生成できます。yomi.tsv に既に載っている和名 (読みが空欄のものを含む) は
足しません。

オプション:
  --builddate=YYYYMMDD  入力の TSV のビルド日 (必須)
  --dir=PATH            ベースディレクトリ (既定: スクリプトのあるディレクトリ)
  --only=NAME           分類群ディレクトリを限定する (複数指定可)
  --version=X.Y.Z       VERSION ファイルの値を上書きする
  --dry-run             追記する和名を表示するだけで yomi.tsv を書き換えない
  --help, -h            このヘルプを表示する

yomi.tsv はスクリプトと同じディレクトリのものを読み書きします (--dir に依らない)。

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
print "(dry-run: 追記する和名を表示するだけで yomi.tsv は書き換えません)\n" if $dry_run;

my $yomi = read_yomi();
logmsg('read', sprintf('%s (読みのある和名 %d 件 / 載っている和名 %d 件)', relname($YOMI_PATH),
                       scalar keys %{ $yomi->{yomi} }, scalar keys %{ $yomi->{listed} }));

my %names;
for my $dir (@dirs) {
    my $path = input_path($dir);
    unless (-e $path) {
        record_failure("$dir/$KIND", '入力ファイルがありません: ' . relname($path));
        next;
    }
    my $n = read_japnames($dir, \%names);
    logmsg('read', sprintf('%s (%d 行)', relname($path), $n)) if defined $n;
}

my %stats = (names => scalar keys %names);
my @add;
for my $name (sort keys %names) {
    if (make_yomi($name, $yomi)) { $stats{ok}++; next }
    $stats{ng}++;
    if ($yomi->{listed}{$name}) { $stats{listed}++; next }
    push @add, $name;
}
$stats{added} = scalar @add;

if ($dry_run) {
    logmsg('dry', "追記する和名: $_") for @add;
}
elsif (@add) {
    eval { append_yomi($yomi, \@add); 1 } or do {
        my $why = $@; $why =~ s/\s+\z//;
        record_failure(relname($YOMI_PATH), "書き込みに失敗しました: $why");
        $stats{added} = 0;
    };
    logmsg('write', sprintf('%s の末尾に %d 件を追記しました', relname($YOMI_PATH), scalar @add))
        if $stats{added};
}
else {
    logmsg('skip', '追記する和名はありません');
}

report_summary(\%stats);
exit($n_fail ? 1 : 0);
