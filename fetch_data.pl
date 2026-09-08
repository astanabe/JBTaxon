#!/usr/bin/perl
#
# fetch_data.pl - JBTaxon の生データファイルを分類群ごとのディレクトリへ取得する
#
# 全ての http(s) 取得は curl 経由で行い、ダウンロードとダウンロードの間には
# 必ず 5 秒の間隔を空ける。この規則は fetch() に集約してあるので、
# fetch() 以外の場所で curl を呼んではならない。
#
# 情報源の URL は固定である。新しい版が出たときは本スクリプト自体を更新して
# 対応する (ページを解析して最新版へ自動追従する処理は意図的に持たない)。
# 版が変わると生データのフォーマット自体が変化している可能性があり、
# ダウンロードだけ追従しても generate_tables.pl が壊れるためである。

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long;

my $SLEEP_SECONDS = 5;    # 要件により固定。CLI からは変更できない。
my $NARO_PER_PAGE = 30;   # search/basic の1ページあたり件数

my @CURL_OPTS = (
    '--fail',                  # 4xx/5xx を異常終了として扱う
    '--silent', '--show-error',
    '--location',              # figshare・九大リポジトリのリダイレクト追従に必要
    '--connect-timeout', '30',
    '--max-time', '300',
    '--retry', '3', '--retry-delay', '5', '--retry-connrefused',
    '--user-agent', 'JBTaxon fetch_data.pl',
);

my $NILIM_BASE   = 'https://www.nilim.go.jp/lab/fbg/ksnkankyo/mizukokuweb/system/DownLoad/List';
my $NARO_BASE    = 'https://insect-web.rad.naro.go.jp/search/basic';
my $NARO_QUERY   = 'mon=1&kou=1&moku=1&ka=1&kazoku=1&zoku=1&syu=1'
                 . '&amon=1&akou=1&amoku=1&aka=1&azoku=1&asyu=1&lang=ja';
my $BINRAN_BASE  = 'https://web.archive.org/web/20211017231224/https://binran.lepimages.jp';
my $SEAWEED_BASE = 'https://tonysharks.com/Seaweeds_list/';

#-----------------------------------------------------------------------------
# ソース定義テーブル
#
# type は以下の5種:
#   file    ... 固定 URL の列挙
#   naro    ... NARO 昆虫DB search/basic のページング
#   binran  ... 日本産蝶類和名学名便覧 (Web Archive) の階層巡回
#   seaweed ... 海藻リストのリンク抽出巡回
#   manual  ... 自動取得せず、未配置を案内するだけ
#
# Insects/ はサブディレクトリを作らずフラットに配置する。generate_tables.pl は
# ファイル名でソースを判別するため、ここでのリネーム後の名前がソース識別子を
# 兼ねる契約になっている。安易に変更しないこと。
#-----------------------------------------------------------------------------
my @SOURCES = (
    {   dir  => 'AllTaxa',
        type => 'file',
        desc => '河川水辺の国勢調査 全生物種リスト (令和元年度以降)',
        files => [ map { [ "$NILIM_BASE/R0${_}List/R0${_}zenseibutsu.xlsx",
                           "R0${_}zenseibutsu.xlsx" ] } 1 .. 7 ],
    },
    {   dir  => 'Mammals',
        type => 'manual',
        desc => '世界哺乳類標準和名リスト2021年度版',
        files  => [ 'list_20211223.zip' ],
        reason => '利用規約に同意した上で取得し、上記パスに配置して下さい:',
        urls   => [ 'https://www.mammalogy.jp/list/index.html' ],
    },
    {   dir  => 'Reptiles_Amphibians',
        type => 'file',
        desc => '日本産爬虫両生類標準和名リスト',
        files => [ [ 'https://herpetology.jp/wamei/index_j.php', 'index_j.html' ] ],
    },
    {   dir  => 'Fishes',
        type => 'file',
        desc => '日本産魚類全種リスト',
        files => [ [ 'https://www.museum.kagoshima-u.ac.jp/staff/motomura/20260827_JAFList.xlsx',
                     '20260827_JAFList.xlsx' ] ],
    },
    {   dir  => 'Insects',
        type => 'naro',
        desc => 'NARO 昆虫DB (Insecta)',
        category => 'BB00000004',
        prefix   => 'naro_insecta',
        count    => '365',
    },
    {   dir  => 'Insects',
        type => 'file',
        desc => 'List-MJ 日本産蛾類総目録',
        files => [ [ 'http://listmj.mothprog.com/dl/ListMJ3-210603DL.xlsx',
                     'ListMJ3-210603DL.xlsx' ] ],
    },
    {   dir  => 'Insects',
        type => 'file',
        desc => '日本産ハネカクシ科総目録',
        files => [ [ 'https://catalog.lib.kyushu-u.ac.jp/opac_download_md/26400/p069.pdf',
                     'staphylinidae_p069.pdf' ] ],
    },
    {   dir  => 'Insects',
        type => 'file',
        desc => '日本産有剣膜翅類目録 (2016年版)',
        files => [ [ 'https://web.archive.org/web/20220324223234/https://sc888fba2c6537423.jimcontent.com/download/version/1486475674/module/12561110890/name/Hym.list.%28Japan%292016.ver5.pdf',
                     'aculeata_hym_list_2016_ver5.pdf' ] ],
    },
    {   dir  => 'Insects',
        type => 'file',
        desc => '日本産トビケラの種リスト',
        files => [ [ 'https://tobikera.eco.coocan.jp/names.htm',
                     'trichoptera_names.html' ] ],
    },
    {   dir  => 'Insects',
        type => 'binran',
        desc => '日本産蝶類和名学名便覧 (Web Archive)',
        count => '37',
    },
    {   dir  => 'Insects',
        type => 'manual',
        desc => 'shigainsect (滋賀県昆虫目録)',
        files  => [],
        always => 1,
        reason => 'shigainsect の目別 Excel (2025年版は28ファイル) を Insects/ に配置して下さい:',
        urls   => [ 'https://sites.google.com/view/shigainsect/' ],
    },
    {   dir  => 'Spiders',
        type => 'naro',
        desc => 'NARO 昆虫DB (Araneae)',
        category => 'BB00006378',
        prefix   => 'naro_araneae',
        count    => '9',
    },
    {   dir  => 'Nematodes',
        type => 'naro',
        desc => 'NARO 昆虫DB (Nematoda)',
        category => 'BB00011689',
        prefix   => 'naro_nematoda',
        count    => '22',
    },
    {   dir  => 'Tanaids',
        type => 'file',
        desc => '日本産タナイス類目録',
        files => [ [ 'https://sites.google.com/site/tnidjpn/tanaidacea/jpnlist',
                     'jpnlist.html' ] ],
    },
    {   dir  => 'Earthworms',
        type => 'file',
        desc => '日本産ミミズのリスト',
        files => [ [ 'https://japanese-mimizu.jimdofree.com/app/download/9610532191/11.+%E6%97%A5%E6%9C%AC%E7%94%A3%E3%83%9F%E3%83%9F%E3%82%BA%E3%81%AE%E3%83%AA%E3%82%B9%E3%83%88.xlsx?t=1759044652',
                     'nihonsan_mimizu_list.xlsx' ] ],
    },
    {   dir  => 'Isopods',
        type => 'file',
        desc => '日本産ワラジムシ亜目種名リスト',
        files => [ [ 'https://www.warajimushi.com/Species/List_species.html',
                     'List_species.html' ] ],
    },
    {   dir  => 'VascularPlants',
        type => 'file',
        desc => 'YList 植物和名-学名インデックス',
        # タブ区切りテキスト版 (_tab.txt) は使用しない。Excel 版が正本。
        files => [ [ 'http://ylist.info/20210514YList_download.xlsx',
                     '20210514YList_download.xlsx' ] ],
    },
    {   dir  => 'VascularPlants',
        type => 'file',
        desc => 'FernGreenList ver 2.0',
        files => [ [ 'https://ndownloader.figshare.com/files/41467776',
                     'FernGreenListV2.0.csv' ] ],
    },
    {   dir  => 'Bryophytes',
        type => 'manual',
        desc => 'Hattoria 日本産蘚苔類チェックリスト',
        # J-STAGE がダウンロード時に付けるファイル名のまま配置する
        files  => [ '7_9.pdf', '9_53.pdf' ],
        reason => 'J-Stage は robots.txt で PDF の自動取得を禁じています:',
        urls   => [ 'https://doi.org/10.18968/hattoria.7.0_9',
                    'https://doi.org/10.18968/hattoria.9.0_53' ],
    },
    {   dir  => 'Lichens',
        type => 'file',
        desc => '日本産地衣類チェックリスト',
        files => [ [ 'https://lichenjapan.jp/checklist/', 'checklist.html' ] ],
    },
    {   dir  => 'Fungi',
        type => 'file',
        desc => '日本産菌類チェックリスト',
        files => [ [ 'https://www.mycology-jp.org/_userdata/DB20200311.xlsx',
                     'DB20200311.xlsx' ] ],
    },
    {   dir  => 'Seaweeds',
        type => 'seaweed',
        desc => '日本産海藻リスト',
        count => '57',
    },
);

#-----------------------------------------------------------------------------
# CLI
#-----------------------------------------------------------------------------
my $basedir;
my @only;
my $force   = 0;
my $do_list = 0;
my $dry_run = 0;
my $help    = 0;

Getopt::Long::Configure('bundling');
GetOptions(
    'dir=s'   => \$basedir,
    'only=s'  => \@only,
    'force'   => \$force,
    'list'    => \$do_list,
    'dry-run' => \$dry_run,
    'help|h'  => \$help,
) or usage(2);
usage(0) if $help;

$basedir = defined $basedir ? $basedir : dirname(abs_path($0));
$basedir = abs_path($basedir) || $basedir;

my @selected = @SOURCES;
if (@only) {
    my %want = map { lc($_) => 1 } @only;
    my %known = map { lc($_->{dir}) => $_->{dir} } @SOURCES;
    for my $name (@only) {
        next if $known{ lc $name };
        print STDERR "不明なディレクトリ名です: $name\n";
        print STDERR "指定可能な名前: " . join(', ', uniq(map { $_->{dir} } @SOURCES)) . "\n";
        exit 2;
    }
    @selected = grep { $want{ lc $_->{dir} } } @SOURCES;
}

if ($do_list) {
    list_sources(\@selected);
    exit 0;
}

#-----------------------------------------------------------------------------
# 実行
#-----------------------------------------------------------------------------
my $net_count  = 0;   # 実際にネットワークアクセスした回数 (sleep 判定に使う)
my $n_get      = 0;
my $n_skip     = 0;
my $n_fail     = 0;
my $n_would    = 0;
my @failures;
my $current_tmp;

$SIG{INT} = $SIG{TERM} = sub {
    unlink $current_tmp if defined $current_tmp;
    print "\n中断しました。取得済みのファイルは次回スキップされます。\n";
    exit 130;
};

my $t_start = time;
my @manual;

printf "出力先: %s\n", $basedir;
print "(dry-run: ダウンロードは行いません)\n" if $dry_run;

for my $src (@selected) {
    if ($src->{type} eq 'manual') { push @manual, $src; next; }
    printf "\n--- %s: %s ---\n", $src->{dir}, $src->{desc};
    if    ($src->{type} eq 'file')    { do_file($src) }
    elsif ($src->{type} eq 'naro')    { do_naro($src) }
    elsif ($src->{type} eq 'binran')  { do_binran($src) }
    elsif ($src->{type} eq 'seaweed') { do_seaweed($src) }
    else { die "未知の type です: $src->{type}\n" }
}

report_manual(\@manual);
report_summary();

exit($n_fail ? 1 : 0);

#-----------------------------------------------------------------------------
# ダウンロード (5秒間隔の担保をここに集約する)
#-----------------------------------------------------------------------------
sub fetch {
    my ($url, $path) = @_;
    my $rel = relname($path);

    # 既存ファイルはスキップする。ネットワークアクセスが発生しないので
    # sleep もしない (中断後の再開が数秒で済む)。
    if (-e $path && !$force) { $n_skip++; logmsg('skip', $rel); return 1; }

    if ($dry_run) { $n_would++; logmsg('dry', "$rel <- $url"); return 0; }

    my $dir = dirname($path);
    unless (-d $dir) {
        make_path($dir);
        unless (-d $dir) { die "ディレクトリを作成できません: $dir: $!\n" }
    }

    # 2回目以降のダウンロードの「前」に5秒空ける。ミミズの robots.txt が
    # 要求する Crawl-Delay: 5 もこの全体規則で満たされる。
    sleep $SLEEP_SECONDS if $net_count++;

    # 中断で切り詰められたファイルが残り、スキップ判定で「取得済み」と
    # 誤認される事故を防ぐため、.part に落として成功時のみ rename する。
    my $tmp = "$path.part";
    unlink $tmp if -e $tmp;
    $current_tmp = $tmp;
    my $rc = system('curl', @CURL_OPTS, '-o', $tmp, '--', $url);
    $current_tmp = undef;

    if ($rc == 0 && -s $tmp) {
        unless (rename $tmp, $path) {
            unlink $tmp;
            record_failure($url, $rel, "rename に失敗しました: $!");
            return 0;
        }
        $n_get++;
        logmsg('get', sprintf('%s (%d bytes) <- %s', $rel, -s $path, $url));
        return 1;
    }

    unlink $tmp if -e $tmp;
    my $why = $rc == -1     ? "curl を実行できません: $!"
            : $rc & 127     ? sprintf('curl がシグナル %d で終了しました', $rc & 127)
            : $rc == 0      ? '空のファイルが返されました'
            :                 sprintf('curl exit %d', $rc >> 8);
    record_failure($url, $rel, $why);
    return 0;
}

# 取得した (あるいは既にディスク上にある) ファイルの中身を返す。
# 巡回系はレスポンスではなく必ずディスク上のファイルから読む。そうしないと
# 再開時にスキップされたページの内容が手元に来ない。
sub fetch_text {
    my ($url, $path) = @_;
    return undef unless fetch($url, $path);
    return slurp($path);
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    binmode $fh;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub record_failure {
    my ($url, $rel, $why) = @_;
    $n_fail++;
    push @failures, { url => $url, path => $rel, why => $why };
    logmsg('FAIL', "$rel <- $url ($why)");
}

#-----------------------------------------------------------------------------
# type: file
#-----------------------------------------------------------------------------
sub do_file {
    my ($src) = @_;
    my $dir = File::Spec->catdir($basedir, $src->{dir});
    for my $ent (@{ $src->{files} }) {
        my ($url, $name) = @$ent;
        fetch($url, File::Spec->catfile($dir, $name));
    }
}

#-----------------------------------------------------------------------------
# type: naro (search/basic のページング)
#-----------------------------------------------------------------------------
sub naro_url {
    my ($category, $page) = @_;
    return "$NARO_BASE?category=$category&$NARO_QUERY&page=$page";
}

sub naro_path {
    my ($dir, $src, $page) = @_;
    return File::Spec->catfile($dir, sprintf('%s_page%03d.html', $src->{prefix}, $page));
}

sub do_naro {
    my ($src) = @_;
    my $dir   = File::Spec->catdir($basedir, $src->{dir});
    my $page1 = naro_path($dir, $src, 1);

    my $html = fetch_text(naro_url($src->{category}, 1), $page1);
    unless (defined $html) {
        logmsg('info', 'page=1 が手元にないため以降のページを取得できません');
        return;
    }

    my $total = naro_total($html);
    unless (defined $total) {
        record_failure(naro_url($src->{category}, 1), relname($page1), '総件数を抽出できません');
        return;
    }

    my $pages = int(($total + $NARO_PER_PAGE - 1) / $NARO_PER_PAGE);
    $pages = 1 if $pages < 1;
    logmsg('info', sprintf('総件数 %d 件 → %d ページ', $total, $pages));

    for my $n (2 .. $pages) {
        fetch(naro_url($src->{category}, $n), naro_path($dir, $src, $n));
    }
}

# 一覧ページ冒頭の「10,931 件」から総件数を取り出す。
# ファイルはバイト列として読んでいるので、「件」も UTF-8 のバイト列として
# 照合する (念のため cp932 も試す)。
sub naro_total {
    my ($html) = @_;
    for my $ken ("\xe4\xbb\xb6", "\x8c\x8f") {
        if ($html =~ /([0-9][0-9,]*)\s*\Q$ken\E/) {
            my $n = $1;
            $n =~ tr/,//d;
            return $n + 0;
        }
    }
    return undef;
}

#-----------------------------------------------------------------------------
# type: binran (日本産蝶類和名学名便覧の階層巡回)
#
#   /                              科
#     /taxa/family/<F>/subfamily   亜科
#       /taxa/subfamily/<S>/tribe  族 (ここが最下層。「詳細」はない)
#     /taxa/family/<F>/genus       属
#     /taxa/family/<F>/species     種
#
# 科レベルの genus / species が族配下の属・種も網羅しているため、亜科・族
# レベルの genus / species は取得しない。/taxa/family/<F> のような中間パスは
# Web Archive に取得されていないので使わない。
#-----------------------------------------------------------------------------
sub do_binran {
    my ($src) = @_;
    my $dir = File::Spec->catdir($basedir, $src->{dir});

    my $index = File::Spec->catfile($dir, 'binran_index.html');
    my $html  = fetch_text("$BINRAN_BASE/", $index);
    unless (defined $html) {
        logmsg('info', 'トップページが手元にないため巡回できません');
        return;
    }

    my @families = uniq($html =~ m{/taxa/family/(\w+)/}g);
    unless (@families) {
        record_failure("$BINRAN_BASE/", relname($index), '科名を抽出できません');
        return;
    }
    @families = sort @families;
    logmsg('info', sprintf('科 %d件: %s', scalar @families, join(', ', @families)));

    for my $f (@families) {
        my $subpath = File::Spec->catfile($dir, "binran_family_${f}_subfamily.html");
        my $subhtml = fetch_text("$BINRAN_BASE/taxa/family/$f/subfamily", $subpath);
        fetch("$BINRAN_BASE/taxa/family/$f/genus",
              File::Spec->catfile($dir, "binran_family_${f}_genus.html"));
        fetch("$BINRAN_BASE/taxa/family/$f/species",
              File::Spec->catfile($dir, "binran_family_${f}_species.html"));

        next unless defined $subhtml;
        my @subfamilies = sort(uniq($subhtml =~ m{/taxa/subfamily/(\w+)/}g));
        next unless @subfamilies;
        logmsg('info', sprintf('%s: 亜科 %d件', $f, scalar @subfamilies));
        for my $s (@subfamilies) {
            fetch("$BINRAN_BASE/taxa/subfamily/$s/tribe",
                  File::Spec->catfile($dir, "binran_subfamily_${s}_tribe.html"));
        }
    }
}

#-----------------------------------------------------------------------------
# type: seaweed (トップからのリンク抽出巡回)
#
# Seaweed_list_top.html は更新履歴のポータルで、実データは Brown/*.html,
# Red/*.html, Green/*.html, Numbers/*.html に分散している。相対パスを保って
# Seaweeds/Brown/*.html のように保存する。
#-----------------------------------------------------------------------------
sub do_seaweed {
    my ($src) = @_;
    my $dir = File::Spec->catdir($basedir, $src->{dir});

    my $top  = File::Spec->catfile($dir, 'Seaweed_list_top.html');
    my $html = fetch_text($SEAWEED_BASE . 'Seaweed_list_top.html', $top);
    unless (defined $html) {
        logmsg('info', 'トップページが手元にないため巡回できません');
        return;
    }

    # #fragment を落として重複排除する
    my @rel;
    my %seen;
    while ($html =~ m{href\s*=\s*["'](?:\./)?((?:Brown|Red|Green|Numbers)/[^"'#>]+\.html)}gi) {
        my $r = $1;
        next if $seen{$r}++;
        push @rel, $r;
    }
    unless (@rel) {
        record_failure($SEAWEED_BASE . 'Seaweed_list_top.html', relname($top),
                       '分類群別ページのリンクを抽出できません');
        return;
    }
    @rel = sort @rel;

    my %by_group;
    $by_group{ (split m{/}, $_)[0] }++ for @rel;
    logmsg('info', sprintf('分類群別ページ %d件 (%s)', scalar @rel,
                           join(', ', map { "$_ $by_group{$_}" } sort keys %by_group)));

    for my $r (@rel) {
        fetch($SEAWEED_BASE . $r, File::Spec->catfile($dir, split(m{/}, $r)));
    }
}

#-----------------------------------------------------------------------------
# type: manual (取得せず案内のみ)
#-----------------------------------------------------------------------------
sub report_manual {
    my ($manual) = @_;
    return unless @$manual;

    my @lines;
    for my $src (@$manual) {
        my $dir = File::Spec->catdir($basedir, $src->{dir});

        if ($src->{always}) {
            # shigainsect はファイル名が多数かつ不定なので存在チェックはしない
            push @lines, "[$src->{dir}] $src->{reason}";
            push @lines, map { "  $_" } @{ $src->{urls} };
            next;
        }

        my @missing = grep { !-e File::Spec->catfile($dir, $_) } @{ $src->{files} };
        next unless @missing;
        my @shown = @missing;
        $shown[0] = "$src->{dir}/$shown[0]";
        push @lines, "[$src->{dir}] 未配置: " . join(', ', @shown);
        push @lines, "  $src->{reason}";
        push @lines, map { "  $_" } @{ $src->{urls} };
    }
    return unless @lines;

    print "\n=== 手動配置が必要な情報源 ===\n";
    print "$_\n" for @lines;
}

#-----------------------------------------------------------------------------
# 出力まわり
#-----------------------------------------------------------------------------
sub logmsg {
    my ($tag, $msg) = @_;
    printf "[%-4s] %s\n", $tag, $msg;
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

sub list_sources {
    my ($sources) = @_;
    printf "出力先: %s\n\n", $basedir;
    print "ディレクトリ         種別     取得数   内容\n";
    print "-" x 78, "\n";
    for my $src (@$sources) {
        my $count = $src->{type} eq 'file'   ? scalar @{ $src->{files} }
                  : $src->{type} eq 'manual' ? '0'
                  :                            ($src->{count} || '?');
        printf "%-20s %-8s %-8s %s\n", $src->{dir}, $src->{type}, $count, $src->{desc};
        if ($src->{type} eq 'file') {
            printf "  %s <- %s\n", $_->[1], $_->[0] for @{ $src->{files} };
        }
        elsif ($src->{type} eq 'manual') {
            printf "  %s\n", (@{ $src->{files} } ? join(', ', @{ $src->{files} })
                                                 : '(ファイル名不定)');
            printf "  <- %s\n", $_ for @{ $src->{urls} };
        }
        elsif ($src->{type} eq 'naro') {
            printf "  %s_pageNNN.html <- %s\n", $src->{prefix}, naro_url($src->{category}, 'N');
        }
        elsif ($src->{type} eq 'binran') {
            printf "  binran_*.html <- %s/\n", $BINRAN_BASE;
        }
        elsif ($src->{type} eq 'seaweed') {
            printf "  Brown|Red|Green|Numbers/*.html <- %s\n", $SEAWEED_BASE;
        }
    }
}

sub report_summary {
    my $elapsed = time - $t_start;
    print "\n=== 集計 ===\n";
    if ($dry_run) {
        printf "取得予定: %d 件 / スキップ: %d 件\n", $n_would, $n_skip;
        return;
    }
    printf "取得: %d 件 / スキップ: %d 件 / 失敗: %d 件 / 所要時間: %d分%02d秒\n",
        $n_get, $n_skip, $n_fail, int($elapsed / 60), $elapsed % 60;
    return unless @failures;
    print "\n--- 失敗した取得 ---\n";
    for my $f (@failures) {
        printf "  %s <- %s (%s)\n", $f->{path}, $f->{url}, $f->{why};
    }
    print "再実行すると成功済みのファイルはスキップされ、失敗分だけ取得されます。\n";
}

sub usage {
    my ($status) = @_;
    my $fh = $status ? *STDERR : *STDOUT;
    print $fh <<"USAGE";
使い方: fetch_data.pl [オプション]

JBTaxon の生データファイルを分類群ごとのディレクトリへダウンロードします。
全ての取得は curl で行い、ダウンロードとダウンロードの間に必ず${SLEEP_SECONDS}秒空けます
(この間隔は変更できません)。全件取得の所要時間は約45分です。

オプション:
  --dir=PATH    出力先のベースディレクトリ (既定: スクリプトのあるディレクトリ)
  --only=NAME   指定した分類群ディレクトリのみ取得する (複数指定可)
  --force       既存ファイルも再取得する (既定では既存ファイルはスキップ)
  --list        ソース定義テーブルを表示して終了する (通信しません)
  --dry-run     取得/スキップの判定のみ表示する (通信しません)
  --help, -h    このヘルプを表示する

指定可能な --only の名前:
  @{[ join(', ', uniq(map { $_->{dir} } @SOURCES)) ]}

一部の情報源は利用規約や robots.txt により自動取得できません。実行の最後に
未配置のものを案内するので、手動でダウンロードして配置して下さい。
USAGE
    exit $status;
}
