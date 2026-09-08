#!/usr/bin/perl
#
# generate_tables.pl - 分類群ごとのディレクトリ内で生データから
#                      和名→学名 / 学名→和名テーブルの TSV を生成する
#
# パイプラインの第2段。fetch_data.pl が取得した生データ (と手動配置分) を読み、
# 各ディレクトリに japname2sciname_VERSION_BUILDDATE.tsv と
# sciname2japname_VERSION_BUILDDATE.tsv を書き出す。
#
# 処理は2段構えになっている。
#   第1段 ... ソースごとに個別のパーサを走らせ、6列の中間 TSV を
#             <分類群>/.jbtaxon/<ソースID>.tsv に書く
#   第2段 ... ディレクトリ内の中間 TSV を統合し (衝突解決)、最終2ファイルを書く
#
# 衝突解決は2系統に分かれる。混同してはならない (CLAUDE.md 参照)。
#   どの名前を採用するか   ... より狭い分類群のソースを優先し、次いで新しい方
#   採用した名前が有効名か ... 「より新しいソースか」だけで決める (狭さは見ない)
#
# fetch_data.pl と違い、本スクリプトは UTF-8・cp932・PDF 抽出テキストが混ざるので
# use utf8 + Encode で文字列として扱い、出力を :encoding(UTF-8) で書く。

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use Encode ();
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long;
use IO::Uncompress::Unzip qw($UnzipError);
use POSIX qw(strftime);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

#-----------------------------------------------------------------------------
# 依存チェック
#
# fetch_data.pl はコアモジュールだけで書かれているが、本スクリプトは xlsx・HTML・
# CSV・PDF を解釈する必要があるため非コアの3モジュールと pdftotext に依存する。
# xlsx は自前のストリーミングリーダで読むので Spreadsheet::* は使わない。
# zip も IO::Uncompress::Unzip (コア) で展開する。
#-----------------------------------------------------------------------------
my @REQUIRED_MODULES = (
    [ 'HTML::TreeBuilder',  'libhtml-tree-perl',         'HTML の入れ子構造の解析' ],
    [ 'HTML::TableExtract', 'libhtml-tableextract-perl', 'HTML テーブルの列抽出' ],
    [ 'Text::CSV',          'libtext-csv-perl',          'CSV の解析' ],
);
my @REQUIRED_COMMANDS = (
    [ 'pdftotext', 'poppler-utils poppler-data', 'PDF からのテキスト抽出' ],
);

check_dependencies();

#-----------------------------------------------------------------------------
# 定数
#-----------------------------------------------------------------------------
my $WORKDIR_NAME = '.jbtaxon';    # 中間 TSV の置き場所 (分類群ディレクトリの直下)

# rank.def に定義のない中間階層に使う既定の subrank。
my $SUBRANK_INTERMEDIATE = 2;

# 正規化で潰す文字。NFKC は Itô / Bouchè / Váňa のような文字まで壊すので使わない。
# リガチャと康熙部首だけを明示的に直す。
my %CHAR_FIXUP = (
    "\x{FB00}" => 'ff', "\x{FB01}" => 'fi', "\x{FB02}" => 'fl',
    "\x{FB03}" => 'ffi', "\x{FB04}" => 'ffl', "\x{FB05}" => 'st', "\x{FB06}" => 'st',
    "\x{00A0}" => ' ',    # &nbsp;
    "\x{2010}" => '-', "\x{2011}" => '-', "\x{2012}" => '-', "\x{2013}" => '-',
    "\x{2014}" => '-', "\x{2212}" => '-',
    "\x{00D7}" => 'x',    # 雑種記号 × は x に統一する
    "\x{FF0D}" => '-',
);

# 和名から取り除く注記。
my @JAPNAME_NOTES = (
    '（和名新称）', '（和名改称）', '（新称）', '（仮称）', '（旧称）', '（p.p.）',
    '(和名新称)', '(和名改称)', '(新称)', '(仮称)', '(旧称)', '(p.p.)',
    '『和名新称』', '『和名改称』',
    '[NR]', '[要検討]', '[非合法名]', '[非正式名]', '[裸名]',
);

# Catalogue of Life (ColDP) の分類階級と、有効名として扱わない status。
# 「provisionally accepted」は暫定的な有効名なので有効名として扱う。
my %COL_RANK = (
    'domain' => 'domain', 'realm' => 'realm', 'kingdom' => 'kingdom',
    'subkingdom' => 'subkingdom', 'superphylum' => 'superphylum',
    'phylum' => 'phylum', 'subphylum' => 'subphylum',
    'superclass' => 'superclass', 'class' => 'class', 'subclass' => 'subclass',
    'infraclass' => 'infraclass', 'cohort' => 'cohort', 'subcohort' => 'subcohort',
    'superorder' => 'superorder', 'order' => 'order', 'suborder' => 'suborder',
    'infraorder' => 'infraorder', 'parvorder' => 'parvorder',
    'superfamily' => 'superfamily', 'family' => 'family', 'subfamily' => 'subfamily',
    'tribe' => 'tribe', 'subtribe' => 'subtribe',
    'genus' => 'genus', 'subgenus' => 'subgenus',
    'section' => 'section', 'subsection' => 'subsection', 'series' => 'series',
    'species group' => 'species group', 'species subgroup' => 'species subgroup',
    'species' => 'species', 'subspecies' => 'subspecies',
    'variety' => 'varietas', 'subvariety' => 'subvariety',
    'form' => 'forma', 'forma specialis' => 'forma specialis',
    'strain' => 'strain', 'morph' => 'morph',
    'unranked' => 'no rank', 'other' => 'no rank', 'clade' => 'clade',
);

my %COL_INVALID_STATUS = map { $_ => 1 } (
    'synonym', 'ambiguous synonym', 'misapplied', 'bare name',
);

# ファイル後方の実行ブロックより前に置かないと代入前に参照されてしまう。
# HTML の実体参照。数値参照と、情報源に実際に現れる名前付き参照だけを解く。
my %HTML_ENTITY = (
    'nbsp' => "\x{00A0}", 'amp' => '&', 'lt' => '<', 'gt' => '>', 'quot' => '"',
    'apos' => "'", 'rarr' => "\x{2192}", 'larr' => "\x{2190}", 'equiv' => "\x{2261}",
    'times' => "\x{00D7}", 'middot' => "\x{00B7}", 'hellip' => "\x{2026}",
    'ndash' => "\x{2013}", 'mdash' => "\x{2014}", 'deg' => "\x{00B0}",
    'prime' => "\x{2032}", 'sup2' => "\x{00B2}", 'sup3' => "\x{00B3}",
    'agrave' => "\x{00E0}", 'aacute' => "\x{00E1}", 'acirc' => "\x{00E2}",
    'atilde' => "\x{00E3}", 'auml' => "\x{00E4}", 'aring' => "\x{00E5}",
    'ccedil' => "\x{00E7}", 'egrave' => "\x{00E8}", 'eacute' => "\x{00E9}",
    'ecirc' => "\x{00EA}", 'euml' => "\x{00EB}", 'igrave' => "\x{00EC}",
    'iacute' => "\x{00ED}", 'icirc' => "\x{00EE}", 'iuml' => "\x{00EF}",
    'ntilde' => "\x{00F1}", 'ograve' => "\x{00F2}", 'oacute' => "\x{00F3}",
    'ocirc' => "\x{00F4}", 'otilde' => "\x{00F5}", 'ouml' => "\x{00F6}",
    'oslash' => "\x{00F8}", 'ugrave' => "\x{00F9}", 'uacute' => "\x{00FA}",
    'ucirc' => "\x{00FB}", 'uuml' => "\x{00FC}", 'szlig' => "\x{00DF}",
    'Auml' => "\x{00C4}", 'Ouml' => "\x{00D6}", 'Uuml' => "\x{00DC}",
    'Eacute' => "\x{00C9}", 'Aacute' => "\x{00C1}", 'Oacute' => "\x{00D3}",
);

my %KANGXI = (
    "\x{2F00}" => "\x{4E00}", "\x{2F04}" => "\x{4E36}", "\x{2F06}" => "\x{4E5A}",
    "\x{2F0F}" => "\x{51E0}", "\x{2F17}" => "\x{5341}", "\x{2F1D}" => "\x{53C8}",
    "\x{2F25}" => "\x{5915}", "\x{2F26}" => "\x{5927}", "\x{2F27}" => "\x{5973}",
    "\x{2F28}" => "\x{5B50}", "\x{2F2C}" => "\x{5C0F}", "\x{2F2F}" => "\x{5C71}",
    "\x{2F31}" => "\x{5DE5}", "\x{2F33}" => "\x{5DFE}", "\x{2F38}" => "\x{5F13}",
    "\x{2F3C}" => "\x{5FC3}", "\x{2F3F}" => "\x{6236}", "\x{2F40}" => "\x{624B}",
    "\x{2F44}" => "\x{6587}", "\x{2F47}" => "\x{65A5}", "\x{2F48}" => "\x{65B9}",
    "\x{2F4A}" => "\x{65E5}", "\x{2F4C}" => "\x{6708}", "\x{2F4D}" => "\x{6728}",
    "\x{2F51}" => "\x{6B62}", "\x{2F55}" => "\x{6BCD}", "\x{2F57}" => "\x{6C0F}",
    "\x{2F59}" => "\x{6C34}", "\x{2F5A}" => "\x{706B}", "\x{2F5D}" => "\x{7236}",
    "\x{2F60}" => "\x{7247}", "\x{2F62}" => "\x{7259}", "\x{2F63}" => "\x{725B}",
    "\x{2F64}" => "\x{72AC}", "\x{2F6A}" => "\x{751F}", "\x{2F6D}" => "\x{7530}",
    "\x{2F74}" => "\x{767D}", "\x{2F77}" => "\x{76BF}", "\x{2F78}" => "\x{76EE}",
    "\x{2F7C}" => "\x{77F3}", "\x{2F7E}" => "\x{79BE}", "\x{2F82}" => "\x{7ACB}",
    "\x{2F83}" => "\x{7AF9}", "\x{2F85}" => "\x{7CF8}", "\x{2F8A}" => "\x{8033}",
    "\x{2F8C}" => "\x{8089}", "\x{2F92}" => "\x{81F3}", "\x{2F95}" => "\x{820C}",
    "\x{2F98}" => "\x{8272}", "\x{2F99}" => "\x{8278}", "\x{2F9B}" => "\x{866B}",
    "\x{2F9C}" => "\x{8840}", "\x{2F9E}" => "\x{897F}", "\x{2FA0}" => "\x{89D2}",
    "\x{2FA1}" => "\x{8A00}", "\x{2FA4}" => "\x{8C9D}", "\x{2FA7}" => "\x{8DB3}",
    "\x{2FA9}" => "\x{8ECA}", "\x{2FAD}" => "\x{9091}", "\x{2FAE}" => "\x{9149}",
    "\x{2FB0}" => "\x{91CC}", "\x{2FB1}" => "\x{91D1}", "\x{2FB3}" => "\x{9580}",
    "\x{2FB7}" => "\x{96B9}", "\x{2FB8}" => "\x{96E8}", "\x{2FBB}" => "\x{9762}",
    "\x{2FC0}" => "\x{97F3}", "\x{2FC1}" => "\x{9801}", "\x{2FC2}" => "\x{98A8}",
    "\x{2FC4}" => "\x{98DF}", "\x{2FC6}" => "\x{9996}", "\x{2FC8}" => "\x{99AC}",
    "\x{2FC9}" => "\x{9AA8}", "\x{2FCD}" => "\x{9B5A}", "\x{2FCE}" => "\x{9CE5}",
    "\x{2FD0}" => "\x{9E7F}", "\x{2FD1}" => "\x{9EA6}", "\x{2FD4}" => "\x{9EC4}",
);

my @ALLTAXA_LEVELS = (
    [  0,  1,  2, 'phylum'    ],
    [  3,  4,  5, 'subphylum' ],
    [  6,  7,  8, 'class'     ],
    [  9, 10, 11, 'subclass'  ],
    [ 12, 13, 14, 'order'     ],
    [ 15, 16, 17, 'family'    ],
    [ 18, 19, 20, 'subfamily' ],
    [ 21, 22, 23, 'genus'     ],
    [ 24, 26, 25, undef       ],    # 種 (rank は学名の形から決める)
);

#-----------------------------------------------------------------------------
# ソース定義テーブル
#
# dir          ... 分類群ディレクトリ名
# id           ... ソース識別子。中間 TSV のファイル名を兼ねる
# desc         ... 表示用の説明
# files        ... 入力ファイル (ディレクトリからの相対パス。glob 可)
# parser       ... do_parse の if/elsif ディスパッチのキー
# scope        ... 対象分類群の階層を rank.def の rank 番号で表したもの。
#                  大きいほど狭い。名前の採用順位に使う
# year         ... ソースの版の年。有効名／シノニムの判定に使う。
#                  版が明示されているものはその年、継続更新のサイトは取得年
# sourcetitle / sourceauthor / sourceurl ... 最終 TSV の6〜8列目にそのまま出る。
#                  ライセンス上は出典明記が不要なソース (CC0 など) も含め、
#                  **全ソースで3列とも必ず埋める**。原典やページに著者の記載が
#                  あればその表記に従い、記載がなければ発行主体 (学会・機関) を書く。
# unzip        ... [zip, 展開後に存在するはずのファイル] 。パース前に展開する
# optional     ... 1 なら入力が無くても失敗として数えない
#-----------------------------------------------------------------------------
my @SOURCES = (
    {   dir => 'AllTaxa', id => 'ksn_zenseibutsu', parser => 'alltaxa',
        desc  => '河川水辺の国勢調査のための生物リスト (R01〜R07)',
        files => [ map { "R0${_}zenseibutsu.xlsx" } 1 .. 7 ],
        scope => 0, year => 2025,
        sourcetitle  => '河川水辺の国勢調査のための生物リスト',
        sourceauthor => [ '国土交通省 国土技術政策総合研究所' ],
        sourceurl    => 'https://www.nilim.go.jp/lab/fbg/ksnkankyo/mizukokuweb/system/seibutsuListfile.htm',
    },
    {   dir => 'AllTaxa', id => 'col', parser => 'col',
        desc  => 'Catalogue of Life (2026-08-26 XR)',
        files => [ 'NameUsage.tsv', 'VernacularName.tsv' ],
        # ColDP の書庫は 5.6GB・21,425 ファイルある。必要な2つだけ展開し、
        # source/*.yaml は書庫から直接読む。
        unzip => [ '2026-08-26_xr_coldp.zip', 'NameUsage.tsv' ],
        unzip_only => [ 'NameUsage.tsv', 'VernacularName.tsv' ],
        scope => 0, year => 2026,
        sourcetitle  => 'Catalogue of Life',
        # metadata.yaml の creator は50名以上いる。format_authors が3名以上を
        # 「先頭 et al.」に畳むので、先頭3名だけを持てば README の表記と一致する。
        sourceauthor => [ 'Olaf Bánki', 'Yury Roskov', 'Markus Döring' ],
        sourceurl    => 'https://download.checklistbank.org/col/monthly/2026-08-26_xr_coldp.zip',
    },
    {   dir => 'AllTaxa', id => 'wikidata', parser => 'wikidata',
        desc  => 'Wikidata 学名・和名対応 (QLever で取得した CSV)',
        files => [ 'wikidata.csv' ],
        scope => 0, year => 2026,
        sourcetitle  => 'Wikidata',
        sourceauthor => [ 'Wikidata contributors' ],
        sourceurl    => 'https://www.wikidata.org/',
    },
    {   dir => 'Mammals', id => 'mammal_society', parser => 'mammals',
        desc  => '世界哺乳類標準和名リスト (2021年度版)',
        files => [ 'list_20211223/list_20211223.xlsx' ],
        unzip => [ 'list_20211223.zip', 'list_20211223/list_20211223.xlsx' ],
        scope => 8, year => 2021,
        sourcetitle  => '世界哺乳類標準和名リスト',
        sourceauthor => [ '川田 伸一郎', '岩佐 真宏', '福井 大', '新宅 勇太', '天野 雅男', '下稲葉 さやか', '樽 創', '姉崎 智子', '鈴木 聡', '押田 龍夫', '横畑 泰志' ],
        sourceurl    => 'https://www.mammalogy.jp/list/index.html',
    },
    {   dir => 'Reptiles_Amphibians', id => 'herpetology_jp', parser => 'herpetology',
        desc  => '日本産爬虫両生類標準和名リスト',
        files => [ 'index_j.html' ],
        scope => 8, year => 2026,
        sourcetitle  => '日本産爬虫両生類標準和名リスト',
        sourceauthor => [ '日本爬虫両棲類学会' ],
        sourceurl    => 'https://herpetology.jp/wamei/index_j.php',
    },
    {   dir => 'Fishes', id => 'jaflist', parser => 'jaflist',
        desc  => '日本産魚類全種目録 (JAF List)',
        files => [ '20260827_JAFList.xlsx' ],
        scope => 8, year => 2026,
        sourcetitle  => '日本産魚類全種目録',
        sourceauthor => [ '本村 浩之' ],
        sourceurl    => 'https://www.museum.kagoshima-u.ac.jp/staff/motomura/jaf.html',
    },
    {   dir => 'Insects', id => 'naro_insecta', parser => 'naro',
        desc  => '昆虫情報データベース (Insecta)',
        files => [ 'naro_insecta_page*.html' ],
        scope => 8, year => 2026,
        sourcetitle  => '昆虫情報データベース',
        sourceauthor => [ '国立研究開発法人農業・食品産業技術総合研究機構 農業環境変動研究センター 環境情報基盤研究領域 昆虫分類評価ユニット' ],
        sourceurl    => 'https://insect-web.rad.naro.go.jp/flame/tree',
    },
    {   dir => 'Insects', id => 'shigainsect', parser => 'shigainsect',
        desc  => '滋賀県昆虫目録2025 (目別 Excel)',
        files => [ '*目*.xlsx' ],
        unzip => [ '*.zip', '*目*.xlsx' ],
        optional => 1,
        scope => 8, year => 2025,
        sourcetitle  => '滋賀県昆虫目録2025',
        sourceauthor => [ '滋賀県昆虫目録作成グループ' ],
        sourceurl    => 'https://sites.google.com/view/shigainsect/',
    },
    {   dir => 'Insects', id => 'listmj', parser => 'listmj',
        desc  => 'List-MJ 日本産蛾類総目録',
        files => [ 'ListMJ3-*.xlsx' ],
        scope => 14, year => 2021,
        sourcetitle  => 'List-MJ 日本産蛾類総目録',
        sourceauthor => [ '神保 宇嗣' ],
        sourceurl    => 'http://listmj.mothprog.com/',
    },
    {   dir => 'Insects', id => 'binran', parser => 'binran',
        desc  => '日本産蝶類和名学名便覧',
        files => [ 'binran_*.html' ],
        scope => 18, year => 2021,
        sourcetitle  => '日本産蝶類和名学名便覧',
        sourceauthor => [ '猪又 敏男', '植村 好延', '矢後 勝也', '上田 恭一郎', '神保 宇嗣' ],
        sourceurl    => 'https://web.archive.org/web/20211017231224/https://binran.lepimages.jp/',
    },
    {   dir => 'Insects', id => 'trichoptera', parser => 'trichoptera',
        desc  => '日本産トビケラの種リスト',
        files => [ 'trichoptera_names.html' ],
        scope => 14, year => 2026,
        sourcetitle  => '日本産トビケラの種リスト',
        sourceauthor => [ '野崎 隆夫' ],
        sourceurl    => 'https://tobikera.eco.coocan.jp/names.htm',
    },
    {   dir => 'Insects', id => 'staphylinidae', parser => 'staphylinidae',
        desc  => '日本産ハネカクシ科総目録',
        files => [ 'staphylinidae_p069.pdf' ],
        scope => 19, year => 2013,
        sourcetitle  => '日本産ハネカクシ科総目録（昆虫綱：甲虫目）',
        sourceauthor => [ '柴田 泰利', '丸山 宗利', '保科 英人', '岸本 年郎', '直海 俊一郎', '野村 周平', 'Volker Puthz', '島田 孝', '渡辺 泰明', '山本 周平' ],
        sourceurl    => 'https://doi.org/10.15017/26400',
    },
    {   dir => 'Insects', id => 'aculeata', parser => 'aculeata',
        desc  => '日本産有剣膜翅類目録 (2016年版)',
        files => [ 'aculeata_hym_list_2016_ver5.pdf' ],
        scope => 16, year => 2016,
        sourcetitle  => '日本産有剣膜翅類目録（2016 年版）',
        sourceauthor => [ '寺山 守' ],
        sourceurl    => 'https://web.archive.org/web/20220324223234/https://sc888fba2c6537423.jimcontent.com/download/version/1486475674/module/12561110890/name/Hym.list.%28Japan%292016.ver5.pdf',
    },
    {   dir => 'Spiders', id => 'naro_araneae', parser => 'naro',
        desc  => '昆虫情報データベース (Araneae)',
        files => [ 'naro_araneae_page*.html' ],
        scope => 14, year => 2026,
        sourcetitle  => '昆虫情報データベース',
        sourceauthor => [ '国立研究開発法人農業・食品産業技術総合研究機構 農業環境変動研究センター 環境情報基盤研究領域 昆虫分類評価ユニット' ],
        sourceurl    => 'https://insect-web.rad.naro.go.jp/flame/tree',
    },
    {   dir => 'Nematodes', id => 'naro_nematoda', parser => 'naro',
        desc  => '昆虫情報データベース (Nematoda)',
        files => [ 'naro_nematoda_page*.html' ],
        scope => 5, year => 2026,
        sourcetitle  => '昆虫情報データベース',
        sourceauthor => [ '国立研究開発法人農業・食品産業技術総合研究機構 農業環境変動研究センター 環境情報基盤研究領域 昆虫分類評価ユニット' ],
        sourceurl    => 'https://insect-web.rad.naro.go.jp/flame/tree',
    },
    {   dir => 'Tanaids', id => 'tanaids', parser => 'tanaids',
        desc  => '日本近海産タナイス類リスト',
        files => [ 'jpnlist.html' ],
        scope => 14, year => 2026,
        sourcetitle  => '日本近海産タナイス類リスト',
        sourceauthor => [ '角井 敬知' ],
        sourceurl    => 'https://sites.google.com/site/tnidjpn/tanaidacea/jpnlist',
    },
    {   dir => 'Earthworms', id => 'mimizu', parser => 'earthworms',
        desc  => '日本産大型陸棲ミミズの種名一覧',
        files => [ 'nihonsan_mimizu_list.xlsx' ],
        scope => 14, year => 2025,
        sourcetitle  => '日本産大型陸棲ミミズの種名一覧',
        sourceauthor => [ '南谷 幸雄' ],
        sourceurl    => 'https://japanese-mimizu.jimdofree.com/%E3%83%9F%E3%83%9F%E3%82%BA%E3%81%AE%E5%88%86%E9%A1%9E/',
    },
    {   dir => 'Isopods', id => 'warajimushi', parser => 'isopods',
        desc  => '日本産ワラジムシ亜目種リスト',
        files => [ 'List_species.html' ],
        scope => 15, year => 2026,
        sourcetitle  => '日本産ワラジムシ亜目種リスト',
        sourceauthor => [ '唐沢 重考' ],
        sourceurl    => 'https://www.warajimushi.com/Species/List_species.html',
    },
    {   dir => 'VascularPlants', id => 'ylist', parser => 'ylist',
        desc  => 'YList 植物和名-学名インデックス',
        files => [ '20210514YList_download.xlsx' ],
        scope => 6, year => 2021,
        sourcetitle  => 'YList',
        sourceauthor => [ '米倉 浩司', '梶田 忠' ],
        sourceurl    => 'http://ylist.info/',
    },
    {   dir => 'VascularPlants', id => 'ferngreenlist', parser => 'ferngreenlist',
        desc  => 'FernGreenList ver. 2.0',
        files => [ 'FernGreenListV2.0.csv' ],
        scope => 8, year => 2023,
        sourcetitle  => 'FernGreenList ver. 2.0',
        sourceauthor => [ 'Atsushi Ebihara', 'Tao Fujiwara', 'Masayuki Takamiya', 'Motomi Ito', 'Tetsukazu Yahara' ],
        sourceurl    => 'https://doi.org/10.57400/data.bnmnsbot.22696618',
    },
    {   dir => 'Bryophytes', id => 'hattoria7', parser => 'hattoria7',
        desc  => '日本産蘚類チェックリスト (Hattoria 7)',
        files => [ '7_9.pdf' ],
        scope => 5, year => 2016,
        sourcetitle  => 'A revised new catalog of the mosses of Japan',
        sourceauthor => [ 'Tadashi Suzuki' ],
        sourceurl    => 'https://doi.org/10.18968/hattoria.7.0_9',
    },
    {   dir => 'Bryophytes', id => 'hattoria9', parser => 'hattoria9',
        desc  => '日本産タイ類・ツノゴケ類チェックリスト (Hattoria 9)',
        files => [ '9_53.pdf' ],
        scope => 5, year => 2018,
        sourcetitle  => '日本産タイ類・ツノゴケ類チェックリスト，2018',
        sourceauthor => [ '片桐 知之', '古木 達郎' ],
        sourceurl    => 'https://doi.org/10.18968/hattoria.9.0_53',
    },
    {   dir => 'Lichens', id => 'lichenjapan', parser => 'lichens',
        desc  => '日本産地衣類チェックリスト',
        files => [ 'checklist.html' ],
        scope => 8, year => 2026,
        sourcetitle  => 'Checklist of Lichens and Allied Fungi of Japan',
        sourceauthor => [ 'Lichenological Society of Japan' ],
        sourceurl    => 'https://lichenjapan.jp/checklist/',
    },
    {   dir => 'Lichens', id => 'lichen_systematics', parser => 'lichen_systematics',
        desc  => '日本産地衣類・関連菌類の高次分類群',
        files => [ 'systematics.html' ],
        scope => 8, year => 2026,
        sourcetitle  => 'Classification of higher taxonomic groups of lichens and allied fungi in Japan',
        sourceauthor => [ 'Lichenological Society of Japan' ],
        sourceurl    => 'https://lichenjapan.jp/systematics/',
    },
    {   dir => 'Fungi', id => 'mycology_jp', parser => 'fungi',
        desc  => '日本産菌類チェックリスト',
        files => [ 'DB20200311.xlsx' ],
        scope => 2, year => 2020,
        sourcetitle  => '日本産菌類チェックリスト',
        sourceauthor => [ '日本菌学会 データベース委員会' ],
        sourceurl    => 'https://www.mycology-jp.org/html/checklist_clist.html',
    },
    {   dir => 'Seaweeds', id => 'seaweeds', parser => 'seaweeds',
        desc  => '日本産海藻リスト',
        files => [ 'Brown/*.html', 'Red/*.html', 'Green/*.html' ],
        scope => 4, year => 2026,
        sourcetitle  => '日本産海藻リスト',
        sourceauthor => [ '鈴木 雅大' ],
        sourceurl    => 'https://tonysharks.com/Seaweeds_list/Seaweed_list_top.html',
    },
    {   dir => 'Viruses', id => 'jsv_virus', parser => 'jsv_virus',
        desc  => 'ウイルス種名・英名・和名対応リスト',
        files => [ 'news241125.xlsx', 'news2411252.xlsx' ],
        scope => 1, year => 2024,
        sourcetitle  => 'ウイルス種名・英名・和名対応リスト',
        sourceauthor => [ '日本ウイルス学会' ],
        sourceurl    => 'https://jsv.umin.jp/news/news241125.html',
    },
);

#-----------------------------------------------------------------------------
# CLI
#-----------------------------------------------------------------------------
my $basedir;
my @only;
my @only_source;
my $force     = 0;
my $keep      = 0;
my $opt_ver;
my $opt_build;
my $do_list   = 0;
my $dry_run   = 0;
my $help      = 0;

Getopt::Long::Configure('bundling');
GetOptions(
    'dir=s'       => \$basedir,
    'only=s'      => \@only,
    'source=s'    => \@only_source,
    'force'       => \$force,
    'keep'        => \$keep,
    'version=s'   => \$opt_ver,
    'builddate=s' => \$opt_build,
    'list'        => \$do_list,
    'dry-run'     => \$dry_run,
    'help|h'      => \$help,
) or usage(2);
usage(0) if $help;

$basedir = defined $basedir ? $basedir : dirname(abs_path($0));
$basedir = abs_path($basedir) || $basedir;

my @selected = @SOURCES;
if (@only) {
    my %known = map { lc($_->{dir}) => 1 } @SOURCES;
    for my $name (@only) {
        next if $known{ lc $name };
        print STDERR "不明なディレクトリ名です: $name\n";
        print STDERR '指定可能な名前: ' . join(', ', uniq(map { $_->{dir} } @SOURCES)) . "\n";
        exit 2;
    }
    my %want = map { lc($_) => 1 } @only;
    @selected = grep { $want{ lc $_->{dir} } } @selected;
}
if (@only_source) {
    my %known = map { lc($_->{id}) => 1 } @SOURCES;
    for my $name (@only_source) {
        next if $known{ lc $name };
        print STDERR "不明なソース ID です: $name\n";
        print STDERR '指定可能な ID: ' . join(', ', map { $_->{id} } @SOURCES) . "\n";
        exit 2;
    }
    my %want = map { lc($_) => 1 } @only_source;
    @selected = grep { $want{ lc $_->{id} } } @selected;
}

if ($do_list) { list_sources(\@selected); exit 0 }

#-----------------------------------------------------------------------------
# 下ごしらえ
#-----------------------------------------------------------------------------
my $VERSION   = defined $opt_ver   ? $opt_ver   : read_version();
my $BUILDDATE = defined $opt_build ? $opt_build : strftime('%Y%m%d', localtime);
unless ($BUILDDATE =~ /^\d{8}$/) {
    print STDERR "--builddate は YYYYMMDD 形式で指定して下さい: $BUILDDATE\n";
    exit 2;
}
my %RANK = read_rank_def();

#-----------------------------------------------------------------------------
# 実行
#-----------------------------------------------------------------------------
my $t_start = time;
my ($n_parsed, $n_skipped, $n_fail, $n_records, $n_written) = (0, 0, 0, 0, 0);
my @failures;
my @notes;

# 実際の処理はファイル末尾の「実行」ブロックで行う。ソース定義以外の表を
# my で持っているため、それらの代入がすべて済んでから走らせる必要がある。

#-----------------------------------------------------------------------------
# 第1段: ソース1つを処理して中間 TSV を書く
#-----------------------------------------------------------------------------
sub do_source {
    my ($src) = @_;
    my $dir = File::Spec->catdir($basedir, $src->{dir});

    # zip が置かれていて展開物が無ければ展開する。手動配置は fetch_data.pl の
    # 実行後に行われるので、展開は本スクリプトの仕事になっている。
    expand_zip($src, $dir) if $src->{unzip} && !$dry_run;

    my @paths = resolve_files($src, $dir);
    if (!@paths && $dry_run && $src->{unzip}
        && resolve_files({ files => [ $src->{unzip}[0] ] }, $dir)) {
        logmsg('dry', '書庫が未展開です (実行時に展開します): '
            . join(', ', map { relname($_) } resolve_files({ files => [ $src->{unzip}[0] ] }, $dir)));
        $n_parsed++;
        return;
    }
    unless (@paths) {
        if ($src->{optional}) {
            $n_skipped++;
            logmsg('skip', '入力ファイルがありません (省略可能な情報源)');
        }
        else {
            record_failure($src, '入力ファイルがありません: '
                . join(', ', map { "$src->{dir}/$_" } @{ $src->{files} }));
        }
        return;
    }

    my $out = intermediate_path($src);
    if ($dry_run) {
        logmsg('dry', sprintf('入力 %d ファイル -> %s', scalar @paths, relname($out)));
        logmsg('dry', '  ' . relname($_)) for @paths[0 .. ($#paths > 4 ? 4 : $#paths)];
        logmsg('dry', sprintf('  ... 他 %d ファイル', @paths - 5)) if @paths > 5;
        $n_parsed++;
        return;
    }

    if (-e $out && !$force) {
        $n_skipped++;
        logmsg('skip', relname($out) . ' (--force で作り直します)');
        return;
    }

    my $records = eval { do_parse($src, \@paths) };
    if ($@) {
        my $why = $@; $why =~ s/\s+\z//;
        record_failure($src, "パースに失敗しました: $why");
        return;
    }
    $records = [] unless ref $records eq 'ARRAY';

    my $n = write_intermediate($out, $records);
    $n_parsed++;
    $n_records += $n;
    logmsg('parse', sprintf('%d ファイル -> %s (%d レコード)',
                            scalar @paths, relname($out), $n));
}

# ソースごとのパーサへの振り分け。fetch_data.pl と同じくコードリファレンスの表は
# 作らず if/elsif で書く。
sub do_parse {
    my ($src, $paths) = @_;
    my $p = $src->{parser};
    return parse_alltaxa($src, $paths)       if $p eq 'alltaxa';
    return parse_mammals($src, $paths)       if $p eq 'mammals';
    return parse_herpetology($src, $paths)   if $p eq 'herpetology';
    return parse_jaflist($src, $paths)       if $p eq 'jaflist';
    return parse_naro($src, $paths)          if $p eq 'naro';
    return parse_listmj($src, $paths)        if $p eq 'listmj';
    return parse_staphylinidae($src, $paths) if $p eq 'staphylinidae';
    return parse_aculeata($src, $paths)      if $p eq 'aculeata';
    return parse_trichoptera($src, $paths)   if $p eq 'trichoptera';
    return parse_binran($src, $paths)        if $p eq 'binran';
    return parse_shigainsect($src, $paths)   if $p eq 'shigainsect';
    return parse_tanaids($src, $paths)       if $p eq 'tanaids';
    return parse_earthworms($src, $paths)    if $p eq 'earthworms';
    return parse_isopods($src, $paths)       if $p eq 'isopods';
    return parse_ylist($src, $paths)         if $p eq 'ylist';
    return parse_ferngreenlist($src, $paths) if $p eq 'ferngreenlist';
    return parse_hattoria7($src, $paths)     if $p eq 'hattoria7';
    return parse_hattoria9($src, $paths)     if $p eq 'hattoria9';
    return parse_lichens($src, $paths)       if $p eq 'lichens';
    return parse_fungi($src, $paths)         if $p eq 'fungi';
    return parse_seaweeds($src, $paths)      if $p eq 'seaweeds';
    return parse_col($src, $paths)           if $p eq 'col';
    return parse_wikidata($src, $paths)      if $p eq 'wikidata';
    return parse_lichen_systematics($src, $paths) if $p eq 'lichen_systematics';
    return parse_jsv_virus($src, $paths)     if $p eq 'jsv_virus';
    die "未知のパーサです: $p\n";
}

#-----------------------------------------------------------------------------
# 中間 TSV
#
# 内部形式は6列。この1レコードから両方の最終テーブルを導ける。
#   japname / sciname / japvalid / scivalid / rank / subrank / nos2j
#   sourcetitle / sourceauthor / sourceurl
# japname か sciname が空のレコードはどちらの表にも寄与しないので落とす。
#
# nos2j は「有効な和名だが sciname2japname の2列目には使わない」印。
# JAFList の「サツキマス・アマゴ」のように、分割前の和名を代表として残しつつ
# 分割後の和名も有効名として和名→学名テーブルに載せたい場合に使う。
#
# 末尾の出典3列はレコード単位の上書き。空なら @SOURCES の値を使う。
# Catalogue of Life はエントリごとに sourceID を持ち、その提供元を出典にするため
# ここに入れる。他の情報源はすべて空。
#-----------------------------------------------------------------------------
sub intermediate_path {
    my ($src) = @_;
    return File::Spec->catfile($basedir, $src->{dir}, $WORKDIR_NAME, "$src->{id}.tsv");
}

sub write_intermediate {
    my ($path, $records) = @_;
    my $dir = dirname($path);
    unless (-d $dir) {
        make_path($dir);
        die "ディレクトリを作成できません: $dir: $!\n" unless -d $dir;
    }
    my $tmp = "$path.part";
    open my $fh, '>', $tmp or die "書き込めません: $tmp: $!\n";
    binmode $fh, ':encoding(UTF-8)';
    my $n = 0;
    my %seen;
    for my $r (@$records) {
        my ($jap, $sci, $jv, $sv, $rank, $subrank, $nos2j, $st, $sa, $su) = @$r;
        next unless defined $jap && defined $sci && length $jap && length $sci;
        $rank    = 0 unless defined $rank;
        $subrank = 1 unless defined $subrank && $subrank >= 1;
        $jv = $jv ? 1 : 0;
        $sv = $sv ? 1 : 0;
        $nos2j = $nos2j ? 1 : 0;
        $_ = defined $_ ? $_ : '' for ($st, $sa, $su);
        s/[\t\n\r]+/ /g for ($st, $sa, $su);
        my $line = join("\t", $jap, $sci, $jv, $sv, $rank, $subrank, $nos2j, $st, $sa, $su);
        next if $seen{$line}++;
        print $fh "$line\n";
        $n++;
    }
    close $fh;
    rename $tmp, $path or die "rename に失敗しました: $tmp -> $path: $!\n";
    return $n;
}

sub read_intermediate {
    my ($path) = @_;
    open my $fh, '<', $path or return ();
    binmode $fh, ':encoding(UTF-8)';
    my @out;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my @f = split /\t/, $line, -1;
        next unless @f == 10;
        push @out, \@f;
    }
    close $fh;
    return @out;
}

sub cleanup_intermediates {
    my ($sources) = @_;
    my %dirs;
    for my $src (@$sources) {
        my $p = intermediate_path($src);
        unlink $p if -e $p;
        $dirs{ dirname($p) } = 1;
    }
    rmdir $_ for keys %dirs;    # 空でなければ黙って失敗する
}

#-----------------------------------------------------------------------------
# 第2段: ディレクトリ内の中間 TSV を統合して最終2ファイルを書く
#
# 衝突解決は2系統。CLAUDE.md の規定どおり混同しないよう別々の表に持つ。
#   %adopt_j2s / %adopt_s2j ... 対応付け。狭さ優先 → 次いで新しさ → 定義順
#   %validity               ... 有効性。新しさのみ (狭さは考慮しない)
#-----------------------------------------------------------------------------
sub merge_directory {
    my ($dir, $sources, $colv, $ncbiv) = @_;
    my @have;
    for my $i (0 .. $#$sources) {
        my $src  = $sources->[$i];
        my $path = intermediate_path($src);
        next unless -e $path;
        push @have, { src => $src, order => $i, path => $path };
    }
    unless (@have) {
        logmsg('info', "$dir: 中間 TSV がないので統合をスキップします");
        return;
    }

    # 第1周: 名前ごとの有効性を決める。ここでは狭さを見ず、最も新しいソースの
    # 判定だけを採る (CLAUDE.md の規定)。
    my (%validity, @records);
    for my $h (@have) {
        my $src = $h->{src};
        for my $r (read_intermediate($h->{path})) {
            my ($jap, $sci, $jv, $sv) = @$r;
            update_validity(\%validity, "j\t$jap", $jv, $src->{year}, $h->{order});
            update_validity(\%validity, "s\t$sci", $sv, $src->{year}, $h->{order});
            push @records, [ $r, $h ];
        }
    }

    # 学名の有効性は Catalogue of Life を基本とする (README の規定)。CoL が知って
    # いる学名は CoL の判定で上書きし、CoL にない学名でソース間の判定が食い違って
    # いるものだけ NCBI Taxonomy で決める。和名の有効性はどちらも判定材料を持たない
    # ので、ソースの新しさによる判定のままにする。
    my ($n_col, $n_ncbi) = (0, 0);
    for my $key (keys %validity) {
        next unless substr($key, 0, 2) eq "s\t";
        my $name = substr($key, 2);
        if (exists $colv->{$name}) {
            $n_col++ if $validity{$key}[0] != $colv->{$name};
            $validity{$key}[0] = $colv->{$name};
        }
        elsif ($validity{$key}[3] && exists $ncbiv->{$name}) {
            $n_ncbi++ if $validity{$key}[0] != $ncbiv->{$name};
            $validity{$key}[0] = $ncbiv->{$name};
        }
    }
    logmsg('valid', sprintf('%s: 学名の有効性を Catalogue of Life で %d 件、NCBI Taxonomy で %d 件 上書きしました',
                            $dir, $n_col, $n_ncbi))
        if $n_col || $n_ncbi;

    # 第2周: 対応付けを決める。2列目に来る名前は、解決後の有効性が 1 のものに
    # 限る。こうしておけば「2列目にシノニムは使わない」が構造として保証される。
    my (%adopt_j2s, %adopt_s2j);
    for my $e (@records) {
        my ($r, $h) = @$e;
        my ($jap, $sci, $jv, $sv, $rank, $subrank, $nos2j, $st, $sa, $su) = @$r;
        my $jvalid = valid_of(\%validity, "j\t$jap");
        my $svalid = valid_of(\%validity, "s\t$sci");
        my $cand = { sci => $sci, jap => $jap, rank => $rank, subrank => $subrank,
                     src => $h->{src}, order => $h->{order},
                     st => $st, sa => $sa, su => $su };
        adopt(\%adopt_j2s, $jap, $cand) if $sv && $svalid;
        adopt(\%adopt_s2j, $sci, $cand) if $jv && $jvalid && !$nos2j;
    }

    my $j2s = write_final($dir, 'japname2sciname', \%adopt_j2s, \%validity, 'j');
    my $s2j = write_final($dir, 'sciname2japname', \%adopt_s2j, \%validity, 's');
    $n_written += $j2s + $s2j;
    logmsg('merge', sprintf('%s: %d ソース / %d レコード -> japname2sciname %d 行 / sciname2japname %d 行',
                            $dir, scalar @have, scalar @records, $j2s, $s2j));
}

sub valid_of {
    my ($validity, $key) = @_;
    my $v = $validity->{$key};
    return $v ? $v->[0] : 1;
}

sub update_validity {
    my ($validity, $key, $valid, $year, $order) = @_;
    my $cur = $validity->{$key};
    if (!$cur) { $validity->{$key} = [ $valid, $year, $order, 0 ]; return }
    # 別のソースが違う判定をしたら印を付ける (NCBI Taxonomy を引く条件になる)
    my $conflict = ($cur->[0] != $valid && $cur->[2] != $order) ? 1 : $cur->[3];
    if ($cur->[1] > $year) { $cur->[3] = $conflict; return }   # 既存の方が新しい
    if ($cur->[1] < $year) { $validity->{$key} = [ $valid, $year, $order, $conflict ]; return }
    $cur->[3] = $conflict;
    return if $cur->[2] < $order;                      # 同年なら定義順の先を優先
    # 同一ソース内では有効名としての出現を優先する
    $cur->[0] = 1 if $valid;
}

sub adopt {
    my ($table, $key, $cand) = @_;
    my $cur = $table->{$key};
    if (!$cur) { $table->{$key} = $cand; return }
    return unless better_source($cand, $cur);
    $table->{$key} = $cand;
}

# (a) scope が大きい (= より狭い分類群) / (b) 同じなら year が新しい /
# (c) それも同じなら @SOURCES の定義順が先
sub better_source {
    my ($a, $b) = @_;
    return 1 if $a->{src}{scope} > $b->{src}{scope};
    return 0 if $a->{src}{scope} < $b->{src}{scope};
    return 1 if $a->{src}{year} > $b->{src}{year};
    return 0 if $a->{src}{year} < $b->{src}{year};
    return $a->{order} < $b->{order} ? 1 : 0;
}

sub write_final {
    my ($dir, $kind, $table, $validity, $vprefix) = @_;
    my $path = File::Spec->catfile($basedir, $dir,
                                   "${kind}_${VERSION}_${BUILDDATE}.tsv");
    my $tmp = "$path.part";
    open my $fh, '>', $tmp or die "書き込めません: $tmp: $!\n";
    binmode $fh, ':encoding(UTF-8)';
    my $n = 0;
    for my $key (sort keys %$table) {
        my $c = $table->{$key};
        my $other = $kind eq 'japname2sciname' ? $c->{sci} : $c->{jap};
        my $v = $validity->{"$vprefix\t$key"};
        my $valid = $v ? $v->[0] : 1;
        # レコード単位の出典があればそれを使う (Catalogue of Life の sourceID 由来)
        my $title  = length $c->{st} ? $c->{st} : $c->{src}{sourcetitle};
        my $author = length $c->{sa} ? $c->{sa} : format_authors($c->{src}{sourceauthor});
        my $url    = length $c->{su} ? $c->{su} : $c->{src}{sourceurl};
        print $fh join("\t", $key, $other, $valid, $c->{rank}, $c->{subrank},
                       $title, $author, $url), "\n";
        $n++;
    }
    close $fh;
    rename $tmp, $path or die "rename に失敗しました: $tmp -> $path: $!\n";
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
    my ($src, $why) = @_;
    $n_fail++;
    push @failures, { dir => $src->{dir}, id => $src->{id}, why => $why };
    logmsg('FAIL', "$src->{dir}/$src->{id}: $why");
}

sub note {
    my ($src, $msg) = @_;
    push @notes, "$src->{dir}/$src->{id}: $msg";
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

# 著者名の並びを出力用の1つの文字列にする。3名以上は2人目以降を省略し、
# 日本語なら「ら」、英語なら「 et al.」を付ける (README の規定)。
sub format_authors {
    my ($authors) = @_;
    return '' unless $authors;
    my @a = ref $authors eq 'ARRAY' ? @$authors : ($authors);
    @a = grep { defined && length } @a;
    return '' unless @a;
    my $jp = looks_japanese($a[0]);
    return $a[0] . ($jp ? 'ら' : ' et al.') if @a >= 3;
    return join($jp ? '・' : ', ', @a);
}

sub list_sources {
    my ($sources) = @_;
    printf "対象ディレクトリ: %s\n\n", $basedir;
    printf "%-20s %-16s %5s %5s %s\n", 'ディレクトリ', 'ソースID', 'scope', 'year', '内容';
    print '-' x 92, "\n";
    for my $src (@$sources) {
        printf "%-20s %-16s %5d %5d %s\n",
            $src->{dir}, $src->{id}, $src->{scope}, $src->{year}, $src->{desc};
        printf "  入力: %s\n", join(', ', @{ $src->{files} });
        printf "  展開: %s -> %s\n", @{ $src->{unzip} } if $src->{unzip};
        printf "  出典: %s / %s\n", $src->{sourcetitle}, format_authors($src->{sourceauthor});
    }
    print "\n最終出力: <ディレクトリ>/japname2sciname_VERSION_BUILDDATE.tsv\n";
    print "          <ディレクトリ>/sciname2japname_VERSION_BUILDDATE.tsv\n";
    print "中間出力: <ディレクトリ>/$WORKDIR_NAME/<ソースID>.tsv (--keep で残す)\n";
}

sub report_summary {
    my $elapsed = time - $t_start;
    print "\n=== 集計 ===\n";
    if ($dry_run) {
        printf "パース対象: %d ソース / 入力なし: %d ソース / 失敗: %d 件\n",
            $n_parsed, $n_skipped, $n_fail;
    }
    else {
        printf "パース: %d ソース / スキップ: %d ソース / 失敗: %d 件\n",
            $n_parsed, $n_skipped, $n_fail;
        printf "中間レコード: %d 件 / 最終出力: %d 行 / 所要時間: %d分%02d秒\n",
            $n_records, $n_written, int($elapsed / 60), $elapsed % 60;
    }
    if (@notes) {
        print "\n--- 注意 ---\n";
        print "  $_\n" for @notes;
    }
    return unless @failures;
    print "\n--- 失敗したソース ---\n";
    printf "  %s/%s: %s\n", $_->{dir}, $_->{id}, $_->{why} for @failures;
    print "再実行すると成功済みの中間 TSV はスキップされます (--force で作り直し)。\n";
}

sub usage {
    my ($status) = @_;
    my $fh = $status ? *STDERR : *STDOUT;
    binmode $fh, ':encoding(UTF-8)';
    my $dirs = join ', ', uniq(map { $_->{dir} } @SOURCES);
    my $ids  = join ', ', map { $_->{id} } @SOURCES;
    print $fh <<"USAGE";
使い方: generate_tables.pl [オプション]

分類群ごとのディレクトリ内で生データファイルを読み、そのディレクトリに
和名→学名テーブルと学名→和名テーブルの TSV を生成します。

オプション:
  --dir=PATH            ベースディレクトリ (既定: スクリプトのあるディレクトリ)
  --only=NAME           分類群ディレクトリを限定する (複数指定可)
  --source=ID           ソース ID を限定する (複数指定可)
  --force               既存の中間 TSV・展開済み zip も作り直す
  --keep                中間 TSV を削除せず残す (既定は削除)
  --version=X.Y.Z       VERSION ファイルの値を上書きする
  --builddate=YYYYMMDD  ビルド日 (既定: 実行日) を上書きする
  --list                ソース定義テーブルを表示して終了する (パースしません)
  --dry-run             入力ファイルの存在確認だけを行う (パースしません)
  --help, -h            このヘルプを表示する

指定可能な --only の名前:
  $dirs

指定可能な --source の ID:
  $ids
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
        eval "require $mod; 1" or push @missing, [ "Perl モジュール $mod", $pkg, $why ];
    }
    for my $c (@REQUIRED_COMMANDS) {
        my ($cmd, $pkg, $why) = @$c;
        my $found = 0;
        for my $d (split /:/, ($ENV{PATH} || '')) {
            next unless length $d;
            if (-x "$d/$cmd") { $found = 1; last }
        }
        push @missing, [ "コマンド $cmd", $pkg, $why ] unless $found;
    }
    return unless @missing;

    print STDERR "generate_tables.pl の実行に必要なものが不足しています。\n\n";
    printf STDERR "  %s (%s)\n    Debian/Ubuntu: apt install %s\n",
        $_->[0], $_->[2], $_->[1] for @missing;
    print STDERR "\nCPAN から入れる場合は cpanm "
        . join(' ', map { $_->[0] =~ /モジュール (\S+)/ ? $1 : () } @missing) . "\n";
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

# rank.def が rank 値の唯一の正。README の一覧はハードコードしない。
# 形式はタブ区切りの「rank番号<TAB>階層名」で、同一 rank 番号に複数の階層名が
# 対応する (31 に subspecies/morph/subvariety など)。
sub read_rank_def {
    my $path = File::Spec->catfile(dirname(abs_path($0)), 'rank.def');
    open my $fh, '<', $path or do {
        print STDERR "rank.def を読めません: $path: $!\n";
        exit 2;
    };
    binmode $fh, ':encoding(UTF-8)';
    my %rank;
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /^\s*(\d+)\t(.+?)\s*$/;
        $rank{$2} = $1 + 0;
    }
    close $fh;
    unless (exists $rank{species}) {
        print STDERR "rank.def に species の定義がありません: $path\n";
        exit 2;
    }
    return %rank;
}

# rank.def の階層名から rank 番号を引く。定義にない名前は実装のミスなので落とす。
sub rk {
    my ($name) = @_;
    return $RANK{$name} if exists $RANK{$name};
    die "rank.def に定義のない階層名です: $name\n";
}

sub resolve_files {
    my ($src, $dir) = @_;
    my @paths;
    my %seen;
    for my $pat (@{ $src->{files} }) {
        my $full = File::Spec->catfile($dir, $pat);
        if ($full =~ /[*?\[]/) {
            (my $glob = $full) =~ s/([ ()'"])/\\$1/g;
            for my $p (sort glob $glob) {
                push @paths, $p if -f $p && !$seen{$p}++;
            }
        }
        else {
            push @paths, $full if -f $full && !$seen{$full}++;
        }
    }
    return @paths;
}

# zip が置かれていれば展開する。展開先は zip と同じディレクトリ。
# 期待するファイルが既にあればスキップし、--force で再展開する。
sub expand_zip {
    my ($src, $dir) = @_;
    my ($zippat, $wantpat) = @{ $src->{unzip} };

    my @want = resolve_files({ files => [ $wantpat ] }, $dir);
    return if @want && !$force;

    my @zips = resolve_files({ files => [ $zippat ] }, $dir);
    return unless @zips;

    for my $zip (@zips) {
        my $n = eval { unzip_into($zip, $dir, $src->{unzip_only}) };
        if ($@) {
            my $why = $@; $why =~ s/\s+\z//;
            record_failure($src, "zip を展開できません: " . relname($zip) . ": $why");
            next;
        }
        logmsg('unzip', sprintf('%s -> %d ファイル', relname($zip), $n));
    }
}

# IO::Uncompress::Unzip で書庫を展開する。サブディレクトリ付きのエントリに対応する
# (哺乳類の zip は list_20211223/ を1階層挟む)。
sub unzip_into {
    my ($zip, $dest, $only) = @_;
    my %want = $only ? map { $_ => 1 } @$only : ();
    my $z = IO::Uncompress::Unzip->new($zip, MultiStream => 0)
        or die "$UnzipError\n";
    my $n = 0;
    for (my $status = 1; $status > 0; $status = $z->nextStream) {
        my $name = $z->getHeaderInfo->{Name};
        next unless defined $name && length $name;
        $name =~ s{\\}{/}g;
        die "書庫に不正なパスが含まれています: $name\n" if $name =~ m{(?:^|/)\.\.(?:/|$)} || $name =~ m{^/};
        next if $name =~ m{/$};
        next if %want && !$want{$name};
        my $out = File::Spec->catfile($dest, split m{/}, $name);
        my $odir = dirname($out);
        make_path($odir) unless -d $odir;
        open my $fh, '>', $out or die "書き込めません: $out: $!\n";
        binmode $fh;
        my $buf;
        print $fh $buf while $z->read($buf) > 0;
        close $fh;
        $n++;
    }
    $z->close;
    return $n;
}

#-----------------------------------------------------------------------------
# 共通ユーティリティ: xlsx (自前ストリーミングリーダ)
#
# Spreadsheet::ParseXLSX はブック全体をメモリに展開するため、AllTaxa の
# 6〜8MB×7 ファイルや YList (109,651 共有文字列) で不利になる。ここでは
# xl/sharedStrings.xml と該当シートの XML を直接読み、行単位でコールバックへ渡す。
#   - ルビ (<rPh>) は共有文字列から除去する (魚類に 16,903 個ある)
#   - inlineStr と結合セル (左上の値の繰り下ろし) に対応する
#   - <dimension> は信用しない (R06 は 1048576 行と書いてある)
#-----------------------------------------------------------------------------
sub xlsx_member {
    my ($path, $name) = @_;
    my $z = IO::Uncompress::Unzip->new($path, Name => $name, MultiStream => 0) or return undef;
    my $buf = '';
    my $chunk;
    $buf .= $chunk while $z->read($chunk, 262144) > 0;
    $z->close;
    return $buf;
}

sub xml_unescape {
    my ($s) = @_;
    return '' unless defined $s;
    return $s unless $s =~ /&/;
    $s =~ s/&#x([0-9A-Fa-f]+);/chr(hex $1)/ge;
    $s =~ s/&#([0-9]+);/chr($1)/ge;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&apos;/'/g;
    $s =~ s/&amp;/&/g;
    return $s;
}

sub xlsx_shared_strings {
    my ($path) = @_;
    my $xml = xlsx_member($path, 'xl/sharedStrings.xml');
    return [] unless defined $xml;
    $xml = Encode::decode('UTF-8', $xml, Encode::FB_DEFAULT);
    my @out;
    while ($xml =~ m{<si(?:\s[^>]*)?>(.*?)</si>|<si\s*/>}gs) {
        my $si = defined $1 ? $1 : '';
        $si =~ s{<rPh\b.*?</rPh>}{}gs;      # ふりがなは名前の一部ではない
        $si =~ s{<rPh\b[^>]*/>}{}gs;
        $si =~ s{<phoneticPr\b[^>]*/>}{}gs;
        my $t = '';
        $t .= xml_unescape($1) while $si =~ m{<t(?:\s[^>]*)?>(.*?)</t>}gs;
        push @out, $t;
    }
    return \@out;
}

sub xlsx_col_index {
    my ($ref) = @_;
    my ($col) = $ref =~ /^([A-Z]+)/;
    return 0 unless defined $col;
    my $n = 0;
    $n = $n * 26 + (ord($_) - 64) for split //, $col;
    return $n - 1;
}

# workbook.xml と rels からシート番号 -> パーツ名の対応を得る。
sub xlsx_sheets {
    my ($path) = @_;
    my $wb = xlsx_member($path, 'xl/workbook.xml');
    return () unless defined $wb;
    $wb = Encode::decode('UTF-8', $wb, Encode::FB_DEFAULT);
    my $rels = xlsx_member($path, 'xl/_rels/workbook.xml.rels');
    my %target;
    if (defined $rels) {
        while ($rels =~ m{<Relationship\b([^>]*?)/?>}g) {
            my $a = $1;
            my ($id) = $a =~ /\bId="([^"]*)"/;
            my ($tg) = $a =~ /\bTarget="([^"]*)"/;
            next unless defined $id && defined $tg;
            $tg =~ s{^/xl/}{}; $tg =~ s{^\./}{};
            $target{$id} = $tg =~ m{^xl/} ? $tg : "xl/$tg";
        }
    }
    my @sheets;
    while ($wb =~ m{<sheet\b([^>]*?)/?>}g) {
        my $a = $1;
        my ($nm) = $a =~ /\bname="([^"]*)"/;
        my ($ri) = $a =~ /\br:id="([^"]*)"/;
        push @sheets, { name => xml_unescape(defined $nm ? $nm : ''),
                        part => (defined $ri && $target{$ri}) ? $target{$ri} : undef };
    }
    return @sheets;
}

# 結合セルの範囲を集める。<mergeCells> は sheetData の後ろにあるので、
# ストリームを最後まで読み飛ばして末尾だけ残す。
sub xlsx_merges {
    my ($path, $part) = @_;
    my @m;
    my $z = IO::Uncompress::Unzip->new($path, Name => $part, MultiStream => 0) or return @m;
    my $tail = '';
    my $buf;
    while ($z->read($buf, 262144) > 0) {
        $tail .= $buf;
        next if $tail =~ /<mergeCells/;
        $tail = substr($tail, -64) if length $tail > 64;
    }
    $z->close;
    while ($tail =~ /<mergeCell\b[^>]*\bref="([A-Z]+)(\d+):([A-Z]+)(\d+)"/g) {
        push @m, [ xlsx_col_index($1), $2 + 0, xlsx_col_index($3), $4 + 0 ];
    }
    return @m;
}

# $cb->($rownum, \@cells) を行ごとに呼ぶ。%opt に merge => 1 で結合セルを繰り下ろす。
sub read_xlsx {
    my ($path, $sheet_idx, $cb, %opt) = @_;
    my @sheets = xlsx_sheets($path);
    my $part = ($sheets[$sheet_idx] && $sheets[$sheet_idx]{part})
             ? $sheets[$sheet_idx]{part}
             : sprintf('xl/worksheets/sheet%d.xml', $sheet_idx + 1);
    my $ss = xlsx_shared_strings($path);
    my @merges = $opt{merge} ? xlsx_merges($path, $part) : ();
    my %fill;

    my $z = IO::Uncompress::Unzip->new($path, Name => $part, MultiStream => 0)
        or die "worksheet を読めません: $path ($part): $UnzipError\n";
    my $pending = '';
    my $buf;
    while (1) {
        my $n = $z->read($buf, 262144);
        last unless defined $n;
        $pending .= $buf if $n > 0;
        while ($pending =~ s{^(.*?)</row>}{}s) {
            xlsx_row($1, $ss, $cb, \@merges, \%fill);
        }
        last if $n <= 0;
    }
    $z->close;
}

sub xlsx_row {
    my ($chunk, $ss, $cb, $merges, $fill) = @_;
    my $body = $chunk;
    return unless $body =~ s{^.*<row\b([^>]*?)>}{}s;
    my $attr = $1;
    my ($rn) = $attr =~ /\br="(\d+)"/;
    my @cells;
    while ($body =~ m{<c\b([^>]*?)(?:/>|>(.*?)</c>)}gs) {
        my ($ca, $cbody) = ($1, $2);
        my ($ref) = $ca =~ /\br="([A-Z]+\d+)"/;
        my ($ty)  = $ca =~ /\bt="([^"]*)"/;
        my $idx = defined $ref ? xlsx_col_index($ref) : scalar @cells;
        my $val = '';
        if (defined $cbody && length $cbody) {
            if (defined $ty && $ty eq 'inlineStr') {
                my $is = $cbody;
                $is =~ s{<rPh\b.*?</rPh>}{}gs;
                $val .= xml_unescape($1) while $is =~ m{<t(?:\s[^>]*)?>(.*?)</t>}gs;
            }
            elsif (defined $ty && $ty eq 's') {
                $val = (defined $ss->[$1] ? $ss->[$1] : '') if $cbody =~ m{<v>(.*?)</v>}s;
            }
            else {
                $val = xml_unescape($1) if $cbody =~ m{<v>(.*?)</v>}s;
            }
        }
        $cells[$idx] = $val;
    }
    for my $c (@cells) { $c = '' unless defined $c }

    if (@$merges && defined $rn) {
        for my $m (@$merges) {
            my ($c1, $r1, $c2, $r2) = @$m;
            next unless $rn >= $r1 && $rn <= $r2;
            if ($rn == $r1) {
                $fill->{"$c1:$r1"} = defined $cells[$c1] ? $cells[$c1] : '';
            }
            my $v = $fill->{"$c1:$r1"};
            next unless defined $v && length $v;
            for my $c ($c1 .. $c2) {
                $cells[$c] = $v if !defined $cells[$c] || $cells[$c] eq '';
            }
        }
        for my $c (@cells) { $c = '' unless defined $c }
    }
    $cb->($rn, \@cells);
}

#-----------------------------------------------------------------------------
# 共通ユーティリティ: HTML / PDF の読み込み
#-----------------------------------------------------------------------------
# 文字コードの混在に耐えること。海藻の4ファイル (Asterocladales / Desmarestiales /
# Dictyotales / Discosporangiales) は charset の指定がなく中身が cp932 なので、
# UTF-8 として厳密に解釈できなければ cp932 を試す。どちらでも die させない。
sub read_html {
    my ($path) = @_;
    open my $fh, '<', $path or die "読めません: $path: $!\n";
    binmode $fh;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return '' unless defined $bytes;
    my $text = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK) };
    return $text if defined $text;
    $text = eval { Encode::decode('cp932', $bytes, Encode::FB_CROAK) };
    return $text if defined $text;
    return Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT);
}

# pdftotext -layout でテキストを取り出す。-layout でないと字下げが失われ、
# レコードと継続行を見分けられなくなる。
sub read_pdf_text {
    my ($path, $from, $to) = @_;
    my @cmd = ('pdftotext', '-layout');
    push @cmd, '-f', $from if defined $from;
    push @cmd, '-l', $to   if defined $to;
    push @cmd, '--', $path, '-';
    open my $ph, '-|', @cmd or die "pdftotext を実行できません: $!\n";
    binmode $ph;
    local $/;
    my $bytes = <$ph>;
    close $ph;
    die "pdftotext がテキストを返しませんでした: $path\n" unless defined $bytes && length $bytes;
    return Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT);
}

# タグを落として素のテキストにする。<br> と </p> などは空白に潰す。
sub html_text {
    my ($html) = @_;
    return '' unless defined $html;
    my $t = $html;
    $t =~ s{<br\s*/?>}{ }gi;
    $t =~ s{<[^>]*>}{}gs;
    return html_unescape($t);
}


sub html_unescape {
    my ($s) = @_;
    return '' unless defined $s;
    return $s unless $s =~ /&/;
    $s =~ s/&#x([0-9A-Fa-f]+);/chr(hex $1)/ge;
    $s =~ s/&#([0-9]+);/chr($1)/ge;
    $s =~ s/&([A-Za-z][A-Za-z0-9]*);/exists $HTML_ENTITY{$1} ? $HTML_ENTITY{$1} : "&$1;"/ge;
    return $s;
}

#-----------------------------------------------------------------------------
# 共通ユーティリティ: 正規化
#
# NFKC は使わない。Itô / Bouchè / Váňa のような文字まで分解・置換されてしまう。
# リガチャと康熙部首だけを %CHAR_FIXUP と下の変換で明示的に直す。
#-----------------------------------------------------------------------------
sub fixup_chars {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/([\x{FB00}-\x{FB06}\x{00A0}\x{2010}-\x{2014}\x{2212}\x{00D7}\x{FF0D}])/$CHAR_FIXUP{$1}/g;
    # 康熙部首 (U+2F00-U+2FD5) を対応する CJK 統合漢字へ寄せる
    $s =~ s/([\x{2F00}-\x{2FD5}])/kangxi_to_cjk($1)/ge;
    return $s;
}

# 康熙部首ブロックは CJK 統合漢字と1対1に対応する。表は持たず、Unicode の
# 対応表のうち本リポジトリの情報源に現れうる範囲だけを直接引く。
sub kangxi_to_cjk { my ($c) = @_; return exists $KANGXI{$c} ? $KANGXI{$c} : $c }

sub trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

sub squeeze {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\s+/ /g;
    return trim($s);
}

# 和名の正規化。全角空白は除去し、末尾の句点や注記を落とす。
# 「（和名新称）」「(新称)」のような注記を落とす。括弧内シノニムの切り出しより
# 先に行わないと、注記そのものが和名シノニムとして拾われてしまう。
sub strip_japnotes {
    my ($s) = @_;
    return '' unless defined $s;
    for my $note (@JAPNAME_NOTES) {
        my $q = quotemeta $note;
        $s =~ s/$q//g;
    }
    return $s;
}

sub norm_japname {
    my ($s) = @_;
    return '' unless defined $s;
    $s = strip_japnotes(fixup_chars($s));
    $s =~ s/\x{3000}//g;
    $s = squeeze($s);
    $s =~ s/[．。\.]+\z//;
    $s =~ s/\A[\s・,、，\x{201C}\x{201D}"]+//;
    $s =~ s/[\s・,、，\x{201C}\x{201D}"]+\z//;
    $s = squeeze($s);
    return $s;
}

# 学名の正規化。著者名・年・ライフステージ注記を落とし、
# var. / subsp. / f. の前後を半角空白1つに整える。
sub norm_sciname {
    my ($s) = @_;
    return '' unless defined $s;
    $s = fixup_chars($s);
    $s =~ s/\x{3000}/ /g;
    $s =~ s/\((?:adult|copepodid|larva|nymph|juvenile)\)//gi;
    # var.bidens のように空白が抜けている表記を直す
    $s =~ s/\b(subsp|ssp|var|subvar|f|sect|nothosubsp|nothovar)\.\s*/$1. /g;
    $s = squeeze($s);
    return '' unless length $s;

    # 先頭から「名前らしいトークン」だけを採る。著者名 (大文字始まり) や括弧、
    # 数字が現れた時点で打ち切る。
    my @tok = split /\s+/, $s;
    my @out;
    my $prev_connector = 0;
    for my $i (0 .. $#tok) {
        my $t = $tok[$i];
        if ($i == 0) {
            last unless $t =~ /\A[A-Z][A-Za-z-]*\z/ || $t =~ /\A\xd7\z/;
            push @out, $t;
            next;
        }
        # 名前の一部ではない語。ここから先は書誌情報なので打ち切る。
        last if $t =~ /\A(?:sensu|auct\.?|non|nec|complex|group|aggr?\.?|Type|type|of)\z/;
        if ($t =~ /\A(?:subsp|ssp|var|subvar|f|sect|nothosubsp|nothovar)\.\z/) {
            push @out, $t; $prev_connector = 1; next;
        }
        if ($t =~ /\A(?:sp|spp|cf|aff)\.?\z/) { push @out, $t; $prev_connector = 1; next }
        # 「sp. 1」「subsp. 2」「sp. L」のように接続語の直後には識別子が来る。
        # 接続語の直後だけ許すことで、著者名を種小名と取り違えずに済む。
        if ($prev_connector && $t =~ /\A[0-9]+\z|\A[A-Z][0-9]*\z|\A[a-z]?[0-9]+\z|\A'[A-Za-z][A-Za-z-]*'\z/) {
            push @out, $t; $prev_connector = 0; next;
        }
        $prev_connector = 0;
        if ($t =~ /\Ax\z/)                                                     { push @out, $t; next }
        # 括弧付きの亜属名は属名の直後にしか現れない。それ以外の括弧は著者名。
        if ($i == 1 && $t =~ /\A\([A-Z][A-Za-z-]*\)\z/)                       { push @out, $t; next }
        if ($t =~ /\A[a-z][a-z-]*\z/)                                          { push @out, $t; next }
        last;
    }
    return '' unless @out;
    my $name = join ' ', @out;
    $name =~ s/\s+\z//;
    # 末尾に接続語だけが残った場合は落とす (「Genus var.」など)
    $name =~ s/\s+(?:subsp|ssp|var|subvar|f|sect|nothosubsp|nothovar|x)\.?\z//;
    return $name;
}

# 和名から括弧内のシノニムと区切り文字で併記された別名を切り出す。
# 戻り値は (代表和名, シノニムの配列)。
sub split_japsyn {
    my ($s, $seps) = @_;
    return ('', ()) unless defined $s;
    $s = strip_japnotes(fixup_chars($s));
    $s =~ s/\x{3000}//g;
    my @syn;
    # 括弧の中身は別名。閉じ括弧が欠けている情報源があるので末尾まで許す。
    while ($s =~ s/[（(]([^）)]*)[）)]?\s*\z//) {
        my $inner = $1;
        unshift @syn, $inner;
    }
    # 括弧の外は既定では「・」で切らない (「日本本土・大陸亜種」のような修飾語を
    # 壊すため)。「・」で別名を併記する情報源だけが $seps で明示的に指定する。
    my @primary = split_japnames($s, defined $seps ? $seps : '，、,');
    my @rest;
    push @rest, split_japnames($_) for @syn;
    my $head = shift @primary;
    $head = '' unless defined $head;
    return ($head, @primary, @rest);
}

sub split_japnames {
    my ($s, $seps) = @_;
    return () unless defined $s;
    $seps = '，、,・' unless defined $seps;
    my $re = '[' . quotemeta($seps) . ']';
    my @out;
    for my $p (split /$re/, $s) {
        my $n = norm_japname($p);
        push @out, $n if length $n;
    }
    return @out;
}

# 学名の形から rank を推定する。複合表記 (var. の下の f. など) は
# 最後に現れたマーカで決める。
sub rank_from_sciname {
    my ($s) = @_;
    return (rk('no rank'), 1) unless defined $s && length $s;
    my $last_rank;
    my $pos = -1;
    my %marker = (
        'subsp.' => 'subspecies', 'ssp.' => 'subspecies', 'nothosubsp.' => 'subspecies',
        'var.'   => 'varietas',   'nothovar.' => 'varietas',
        'subvar.' => 'subvariety',
        'f.'     => 'forma',
        'sect.'  => 'section',
    );
    while ($s =~ /(?:\A|\s)((?:notho)?(?:subsp|ssp|var|subvar|f|sect)\.)(?=\s)/g) {
        my $m = $1;
        next unless exists $marker{$m};
        if (pos($s) > $pos) { $pos = pos($s); $last_rank = $marker{$m} }
    }
    return (rk($last_rank), 1) if defined $last_rank;

    # 接続語のない三名法は亜種として扱う (Elephantomyia dietziana dietziana)。
    my @tok = grep { !/\A\([A-Z]/ && !/\A(?:sp|spp|cf|aff|x)\.?\z/ } split /\s+/, $s;
    return (rk('subspecies'), 1) if @tok >= 3;
    return (rk('species'), 1)    if @tok == 2;

    my $w = $tok[0];
    return (rk('no rank'), 1) unless defined $w;
    return (rk('superfamily'), 1) if $w =~ /oidea\z/;
    return (rk('suborder'), 1)    if $w =~ /(?:ineae|ina)\z/ && $w =~ /ineae\z/;
    return (rk('subtribe'), 1)    if $w =~ /ina\z/;
    return (rk('subfamily'), 1)   if $w =~ /(?:inae|oideae)\z/;
    return (rk('tribe'), 1)       if $w =~ /(?:ini|eae)\z/;
    return (rk('family'), 1)      if $w =~ /(?:idae|aceae)\z/;
    return (rk('order'), 1)       if $w =~ /ales\z/;
    return (rk('subphylum'), 1)   if $w =~ /(?:phytina|mycotina)\z/;
    return (rk('phylum'), 1)      if $w =~ /(?:phyta|mycota)\z/;
    return (rk('subclass'), 1)    if $w =~ /(?:phycidae|mycetidae)\z/;
    return (rk('class'), 1)       if $w =~ /(?:phyceae|mycetes|opsida)\z/;
    return (rk('genus'), 1);
}

# プレースホルダと偽の和名を弾く。
#   - 河川水辺の国勢調査の「ダミー科」「ダミー亜科」「ダミー属」
#   - 魚類の「和名なし」
#   - NARO の「Eucharitidae科」「Colfax属」のような学名+階層名
#   - NARO の「…属の1種」「…属の一種」
#   - 和名欄に学名がそのまま入っている行
sub is_placeholder {
    my ($jap, $sci) = @_;
    return 1 unless defined $jap && length $jap;
    return 1 if $jap =~ /\Aダミー/;
    return 1 if $jap =~ /\A(?:和名なし|なし|不明|未定|-|―|‐)\z/;
    return 1 if $jap !~ /[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}\x{FF66}-\x{FF9D}]/;
    return 1 if $jap =~ /\A[A-Za-z][A-Za-z0-9 .()\x{2019}'-]*(?:属|亜属|節|科|亜科|族|亜族|目|亜目|上科|綱|亜綱|門|亜門|界|種|亜種)\z/;
    return 1 if $jap =~ /(?:界|門|亜門|綱|亜綱|目|亜目|上科|科|亜科|族|属|亜属)の(?:1|一)種\z/;
    return 1 if defined $sci && length $sci && $jap eq $sci;
    return 0;
}

#-----------------------------------------------------------------------------
# パーサ共通のヘルパ
#
# パーサは [ japname, sciname, japvalid, scivalid, rank, subrank ] の配列を返す。
# add_pair() を通すことで正規化・プレースホルダ除去・和名シノニムの分離を
# ひとところに集約する。
#-----------------------------------------------------------------------------
# 有効名どうしの対応を1件足す。和名に括弧付きの別名が含まれていれば
# それも和名シノニムとして足す。
sub add_pair {
    my ($out, $jap, $sci, $rank, $subrank, %opt) = @_;
    # rawsci は学名欄に著者名が入らない情報源用。norm_sciname の
    # 「名前らしいトークンだけ採る」規則は ICTV の Alfamovirus AMV や
    # Duamitovirus crpa1 のような種小名を切り落としてしまう。
    $sci = $opt{rawsci} ? squeeze(fixup_chars($sci)) : norm_sciname($sci);
    return unless length $sci;
    my ($head, @syn);
    if ($opt{nosplit}) { $head = norm_japname(defined $jap ? $jap : '') }
    else { ($head, @syn) = split_japsyn(defined $jap ? $jap : '', $opt{seps}) }
    $subrank = 1 unless defined $subrank && $subrank >= 1;
    unless (defined $rank) { ($rank, $subrank) = rank_from_sciname($sci) }
    my $jv = exists $opt{japvalid} ? ($opt{japvalid} ? 1 : 0) : 1;
    my $sv = exists $opt{scivalid} ? ($opt{scivalid} ? 1 : 0) : 1;
    # 和名欄の末尾に学名がそのまま付いている行があるので落とす
    $_ = strip_trailing_sciname($_, $sci) for ($head, @syn);
    my $nos2j = $opt{nos2j} ? 1 : 0;
    my @si = $opt{srcinfo} ? @{ $opt{srcinfo} } : ('', '', '');
    if (length $head && !is_placeholder($head, $sci)) {
        push @$out, [ $head, $sci, $jv, $sv, $rank, $subrank, $nos2j, @si ];
    }
    # 括弧内の別名は和名シノニム扱い。学名側の有効性はそのまま引き継ぐ。
    for my $s (@syn) {
        next if is_placeholder($s, $sci);
        push @$out, [ $s, $sci, 0, $sv, $rank, $subrank, $nos2j, @si ];
    }
}

sub strip_trailing_sciname {
    my ($jap, $sci) = @_;
    return $jap unless defined $jap && length $jap && length $sci;
    $jap =~ s/\s*\Q$sci\E\s*\z//;
    return trim($jap);
}

# 「和名 (ここは学名)」のような列の組をまとめて足す。空の組は黙って飛ばす。
sub add_levels {
    my ($out, $cells, $levels) = @_;
    for my $lv (@$levels) {
        my ($jcol, $scol, $rank, $subrank) = @$lv;
        my $jap = defined $cells->[$jcol] ? $cells->[$jcol] : '';
        my $sci = defined $cells->[$scol] ? $cells->[$scol] : '';
        next unless length trim($jap) && length trim($sci);
        add_pair($out, $jap, $sci, $rank, $subrank);
    }
}

# 学名らしい文字列か (ラテン文字だけで始まり日本語を含まない)。
sub looks_latin {
    my ($s) = @_;
    return 0 unless defined $s && $s =~ /\S/;
    return 0 if $s =~ /[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}\x{FF66}-\x{FF9D}]/;
    return $s =~ /\A\s*[A-Z\x{00C0}-\x{024F}]/ ? 1 : 0;
}

sub looks_japanese {
    my ($s) = @_;
    return 0 unless defined $s;
    return $s =~ /[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}\x{FF66}-\x{FF9D}]/ ? 1 : 0;
}

# 和名と学名が区切りなしで連結された文字列を、日本語の連なりとラテン文字の
# 連なりに切り分ける。shigainsect の「異名・旧名」列は和名と学名が同じセルに
# 混在し、区切りも「、」「，」「；」「/」と一定しないのでこの形で読む。
# 戻り値は [ 'jap'|'sci', 文字列 ] の配列。
sub split_mixed_names {
    my ($s) = @_;
    return () unless defined $s;
    $s = fixup_chars($s);
    my @out;
    while ($s =~ /([\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}\x{FF66}-\x{FF9D}\x{3005}\x{30FC}]+)|([A-Za-z\x{00C0}-\x{024F}][A-Za-z\x{00C0}-\x{024F} .()'-]*)/g) {
        if (defined $1) { push @out, [ 'jap', $1 ] }
        else            { push @out, [ 'sci', trim($2) ] }
    }
    return @out;
}

#-----------------------------------------------------------------------------
# FernGreenList (CSV)
#
# 列は Taxon ID / 雑種・品種 / 和名 / 和名異名 / 学名 / 科番号 / 科和名 /
#      科学名 / Endemism / RL2020 / v1.01 の学名。
# 引用符付きフィールドを含むので Text::CSV を使う (split /,/ は不可)。
#-----------------------------------------------------------------------------
sub parse_ferngreenlist {
    my ($src, $paths) = @_;
    require Text::CSV;
    my @out;
    for my $path (@$paths) {
        my $csv = Text::CSV->new({ binary => 1, auto_diag => 0 });
        open my $fh, '<:encoding(UTF-8)', $path or die "読めません: $path: $!\n";
        my $header = $csv->getline($fh);
        while (my $row = $csv->getline($fh)) {
            my ($jap, $japsyn, $sci, $famjap, $famsci, $old)
                = @$row[2, 3, 4, 6, 7, 10];
            $_ = defined $_ ? $_ : '' for ($jap, $japsyn, $sci, $famjap, $famsci, $old);
            add_pair(\@out, $famjap, $famsci, rk('family'), 1);
            next unless length trim($sci);
            my ($rank, $subrank) = rank_from_sciname(norm_sciname($sci));
            add_pair(\@out, $jap, $sci, $rank, $subrank);
            for my $s (split_japnames($japsyn)) {
                add_pair(\@out, $s, $sci, $rank, $subrank, japvalid => 0);
            }
            # v 1.01 の学名は旧学名。N/A は空欄の意味で使われている。
            next unless length trim($old) && uc(trim($old)) ne 'N/A';
            my $oldsci = norm_sciname($old);
            next if !length $oldsci || $oldsci eq norm_sciname($sci);
            add_pair(\@out, $jap, $oldsci, $rank, $subrank, scivalid => 0);
        }
        close $fh;
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 外部の分類データベースによる有効名の判定
#
# 1つの和名に2つの学名が併記されている情報源があるので、どちらが有効名かを
# 外部データベースで決める。Catalogue of Life は WoRMS を含む多数のデータベースを
# 統合しているので、これと NCBI Taxonomy の2段で足りる。優先順位は
#   1) Catalogue of Life (AllTaxa/NameUsage.tsv) の col:status
#   2) NCBI Taxonomy (NCBITaxonomy/names.dmp) の name class
#
# Catalogue of Life のスコアは 3=有効名 / 2=シノニムだがその有効名と属名が同じ
# (＝現在の組み合わせ) / 1=登録はあるがそのどちらでもない / 0=見つからない。
# 「ヤマドリ」の Synchiropus ijimai と Neosynchiropus ijimai はどちらも
# Neosynchiropus ijimae のシノニムなので、属名の一致する後者が 2 になる。
# で、どちらでも決められなければ実行末尾の「注意」で報告する。
#
# どちらのファイルも巨大なので、候補の属名を並べた正規表現で行を絞ってから
# 分解する。ファイルが無い場合はその段を飛ばす (取得していなくても動く)。
#-----------------------------------------------------------------------------
sub taxonomy_scores {
    my ($names) = @_;
    my %want = map { $_ => 1 } @$names;
    my %col  = map { $_ => 0 } @$names;
    my %ncbi = map { $_ => 0 } @$names;
    return (\%col, \%ncbi) unless %want;

    my %genus;
    for my $n (@$names) { $genus{$1} = 1 if $n =~ /\A(\S+)/ }
    my $alt = join '|', map { quotemeta } sort keys %genus;
    my $re  = qr/(?:$alt)[ \t]/;

    my (%seen_status, %parent);
    my $usage = File::Spec->catfile($basedir, 'AllTaxa', 'NameUsage.tsv');
    if (-f $usage) {
        open my $fh, '<', $usage or die "読めません: $usage: $!\n";
        binmode $fh;
        my $hdr = <$fh>;
        while (my $line = <$fh>) {
            next unless $line =~ $re;
            chomp $line;
            my @f = split /\t/, $line, 11;
            my $name = Encode::decode('UTF-8', (defined $f[7] ? $f[7] : ''), Encode::FB_DEFAULT);
            next unless exists $want{$name};
            my $status = defined $f[6] ? $f[6] : '';
            next if ($seen_status{$name} || '') eq 'accepted';
            $seen_status{$name} = $COL_INVALID_STATUS{$status} ? 'synonym' : 'accepted';
            $parent{$name} = defined $f[4] ? $f[4] : '';
        }
        close $fh;

        # シノニムの有効名を引く。属名が一致する方が現在の組み合わせなので優先する。
        my %needp = map { $_ => 1 } grep { length } values %parent;
        my %pname;
        col_scan($usage, \%needp, sub {
            my ($id, $f) = @_;
            $pname{$id} = Encode::decode('UTF-8', (defined $f->[7] ? $f->[7] : ''),
                                         Encode::FB_DEFAULT);
        }) if %needp;

        for my $name (@$names) {
            my $st = $seen_status{$name};
            next unless defined $st;
            if ($st eq 'accepted') { $col{$name} = 3; next }
            my ($genus)  = $name =~ /\A(\S+)/;
            my $pn = $pname{ $parent{$name} || '' };
            my ($pgenus) = (defined $pn && length $pn) ? ($pn =~ /\A(\S+)/) : ();
            $col{$name} = (defined $pgenus && defined $genus && $pgenus eq $genus) ? 2 : 1;
        }
    }

    my $dmp = File::Spec->catfile($basedir, 'NCBITaxonomy', 'names.dmp');
    if (-f $dmp) {
        open my $fh, '<', $dmp or die "読めません: $dmp: $!\n";
        binmode $fh;
        while (my $line = <$fh>) {
            next unless $line =~ $re;
            chomp $line;
            my @f = split /\s*\|\s*/, $line;
            my $nm = Encode::decode('UTF-8', (defined $f[1] ? $f[1] : ''), Encode::FB_DEFAULT);
            next unless exists $want{$nm};
            my $class = defined $f[3] ? $f[3] : '';
            my $score = $class eq 'scientific name' ? 2 : 1;
            $ncbi{$nm} = $score if $score > $ncbi{$nm};
        }
        close $fh;
    }
    return (\%col, \%ncbi);
}

# 候補のうち有効名を1つ選ぶ。渡されたスコア表を順に見て、最上位が単独で
# 0 より大きくなった時点で決める。決められなければ ($cands->[0], 0) を返す。
sub choose_valid_sciname {
    my ($cands, @tables) = @_;
    return ($cands->[0], 1) if @$cands == 1;
    for my $tbl (@tables) {
        next unless $tbl;
        my @sorted = sort { ($tbl->{$b} || 0) <=> ($tbl->{$a} || 0) } @$cands;
        next unless ($tbl->{ $sorted[0] } || 0) > 0;
        next if ($tbl->{ $sorted[0] } || 0) == ($tbl->{ $sorted[1] } || 0);
        return ($sorted[0], 1);
    }
    return ($cands->[0], 0);
}

#-----------------------------------------------------------------------------
# 日本産魚類全種目録 (xlsx)
#
# 目の列は1セルに「和名\n学名」、科の列と Family の列はそれぞれ1セルに
# 「科\n亜科」が改行で入る。sheet2 (日本産から削除) は列がずれているので使わない。
# 共有文字列にルビ (<rPh>) が 16,903 個あるが read_xlsx が除去する。
#
# この情報源に固有の扱いが3つある。
#   - 学名の欄に2つの学名が入ることがある。セル内で改行して並べる形と
#     「属名 (属名) 種小名」の形の2通りで、後者の括弧付きの形は出力しない。
#     どちらが有効名かは taxonomy_scores() で外部データベースに問い合わせる。
#   - 「X型Z」「～X型」という和名からは、型の指定を外した和名も出す (japvalid=0)。
#     「太平洋系陸封型イトヨ」→「イトヨ」、「ヤマトシマドジョウA型」→「ヤマトシマドジョウ」。
#     型の直前が英数字1文字の場合だけ「～X型」とみなす (「トミヨ属雄物型」は分割しない)。
#   - 「サツキマス・アマゴ」のように「・」で2つの和名を併記した行は、分割前の和名に
#     加えて分割後の和名も有効名として出す。ただし分割後の和名は
#     sciname2japname の2列目には使わない (nos2j)。
# いずれもこの情報源に限った規則である。Wikidata の「ロベリア・ラキシフローラ」や
# ウイルスの「A型肝炎ウイルス」に同じ規則を当てると壊れるため他へ広げないこと。
#-----------------------------------------------------------------------------
sub parse_jaflist {
    my ($src, $paths) = @_;
    my @out;
    my @rows;
    for my $path (@$paths) {
        my $first = 1;
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            if ($first) { $first = 0; return }
            my ($ord, $famj, $fams, $jap, $sci) = map { defined $_ ? $_ : '' } @$c[2, 3, 4, 5, 6];

            if (length trim($ord)) {
                my @l = grep { length } map { trim($_) } split /\n/, $ord;
                add_pair(\@out, $l[0], $l[1], rk('order'), 1) if @l >= 2;
            }
            if (length trim($famj) && length trim($fams)) {
                my @j = grep { length } map { trim($_) } split /\n/, $famj;
                my @s = grep { length } map { trim($_) } split /\n/, $fams;
                add_pair(\@out, $j[0], $s[0], rk('family'), 1) if @j && @s;
                add_pair(\@out, $j[1], $s[1], rk('subfamily'), 1) if @j > 1 && @s > 1;
            }
            return unless length trim($sci);
            my @cands = jaflist_scinames($sci);
            return unless @cands;
            push @rows, [ $jap, \@cands ];
        }, merge => 1);
    }

    my %need;
    for my $r (@rows) {
        next unless @{ $r->[1] } > 1;
        $need{$_} = 1 for @{ $r->[1] };
    }
    my ($col, $ncbi) = taxonomy_scores([ sort keys %need ]);

    for my $r (@rows) {
        my ($jap, $cands) = @$r;
        my @japnames = jaflist_japnames($jap);
        # 和名のない行は出力に寄与しないので、決められなくても通知しない
        @japnames = grep { !is_placeholder($_->[0], undef) } @japnames;
        next unless @japnames;
        my ($valid, $decided) = choose_valid_sciname($cands, $col, $ncbi);
        note($src, sprintf('有効名を決められませんでした (%s を採用): %s',
                           $valid, join(' / ', @$cands)))
            if !$decided && @$cands > 1;
        my ($rank, $subrank) = rank_from_sciname($valid);
        for my $j (@japnames) {
            my ($name, $jv, $nos2j) = @$j;
            add_pair(\@out, $name, $valid, $rank, $subrank,
                     japvalid => $jv, nos2j => $nos2j);
            for my $alt (@$cands) {
                next if $alt eq $valid;
                add_pair(\@out, $name, $alt, rank_from_sciname($alt),
                         japvalid => $jv, scivalid => 0, nos2j => $nos2j);
            }
        }
    }
    return \@out;
}

# 学名の欄から候補の学名を取り出す。
sub jaflist_scinames {
    my ($cell) = @_;
    my @lines;
    for my $l (split /\n/, $cell) {
        $l = trim($l);
        next unless length $l;
        # 学名で始まらない行は前の行の続き (著者名や年が折り返したもの)。
        if ($l =~ /\A[A-Z][a-z]/ ) { push @lines, $l }
        elsif (@lines)              { $lines[-1] .= " $l" }
    }
    my (@out, %seen);
    for my $l (@lines) {
        my @names = ($l);
        # 「属名 (属名) 種小名」は2つの属名の併記。括弧付きの形は出力しない。
        if ($l =~ /\A([A-Z][A-Za-z-]*)\s+\(([A-Z][A-Za-z-]*)\)\s+(.+)\z/) {
            @names = ("$1 $3");
            push @names, "$2 $3" if $2 ne $1;
        }
        for my $n (@names) {
            my $norm = norm_sciname($n);
            next unless length $norm;
            push @out, $norm unless $seen{$norm}++;
        }
    }
    return @out;
}

# 和名の欄から [和名, japvalid, nos2j] の並びを作る。
sub jaflist_japnames {
    my ($cell) = @_;
    my $jap = norm_japname($cell);
    return () unless length $jap;
    my @out = ( [ $jap, 1, 0 ] );

    # 「～X型」(型の直前が英数字1文字) と「X型Z」から型指定を外した和名
    my $base;
    if ($jap =~ /\A(.+?)\s*[0-9A-Za-z\x{FF10}-\x{FF19}\x{FF21}-\x{FF3A}\x{FF41}-\x{FF5A}]\s*型\z/) {
        $base = trim($1);
    }
    elsif ($jap =~ /\A.*型(.+)\z/) {
        $base = trim($1);
    }
    push @out, [ $base, 0, 0 ] if defined $base && length $base && $base ne $jap;

    # 「サツキマス・アマゴ」のように2つの和名を併記したもの
    if ($jap =~ /・/) {
        my @parts = grep { length } map { trim($_) } split /・/, $jap;
        if (@parts >= 2 && !grep { !looks_japanese($_) || length($_) < 2 } @parts) {
            push @out, [ $_, 1, 1 ] for @parts;
        }
    }
    return @out;
}

#-----------------------------------------------------------------------------
# List-MJ 日本産蛾類総目録 (xlsx)
#
# 科/亜科/族/亜族/属/亜属/種小名/亜種小名がそれぞれ列になっている。
# 学名は属名と種小名 (と亜種小名) を連結して組み立てる。亜属名は他の情報源と
# 照合できなくなるので二名法の学名には入れない。
# 和名シノニムは「別名」と「その他の和名」の2列にあり、区切りは全角カンマ。
#-----------------------------------------------------------------------------
sub parse_listmj {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $first = 1;
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            if ($first) { $first = 0; return }
            my @f = map { defined $_ ? trim($_) : '' } @$c[0 .. 21];
            add_levels(\@out, \@f, [
                [ 2, 1, rk('family'),    1 ],
                [ 4, 3, rk('subfamily'), 1 ],
                [ 6, 5, rk('tribe'),     1 ],
                [ 8, 7, rk('subtribe'),  1 ],
            ]);
            my ($genus, $sp, $ssp) = @f[9, 11, 12];
            return unless length $genus && length $sp;
            my $sci  = "$genus $sp";
            my $rank = rk('species');
            if (length $ssp) { $sci .= " $ssp"; $rank = rk('subspecies') }

            my $jap = $f[16];
            add_pair(\@out, $jap, $sci, $rank, 1) if length $jap;
            for my $col (17, 18) {
                for my $s (split_japnames(strip_alias_prefix($f[$col]))) {
                    add_pair(\@out, $s, $sci, $rank, 1, japvalid => 0);
                }
            }
        });
    }
    return \@out;
}

# 「標準図鑑：ナントカ」「旧名：ナントカ」のような接頭辞を落とす。
sub strip_alias_prefix {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/(?:\A|(?<=[，、,]))\s*(?:標準図鑑|旧名|別名|図鑑|新称)\s*[：:]\s*//g;
    return $s;
}

#-----------------------------------------------------------------------------
# 世界哺乳類標準和名リスト2021年度版 (zip 内の xlsx)
#
# ヘッダが2行 (縦結合) で、データは3行目から。5,526行目以降は A〜T 列が空の
# 付録ブロック (1,288行) なので、目の列が空の行を落として除外する。
# 同 zip 内の PDF は同内容だが列の桁位置がページごとに変わるので使わない。
# U/V/W 列 (MSW3 / CMW / MDD1.6 の学名) が採用学名と異なる場合は学名シノニム。
#-----------------------------------------------------------------------------
sub parse_mammals {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            return unless defined $rn && $rn >= 3;
            my @f = map { defined $_ ? trim($_) : '' } @$c[0 .. 23];
            return unless length $f[0];    # 付録ブロックは Order 列が空
            add_levels(\@out, \@f, [
                [ 1,  0,  rk('order'),      1 ],
                [ 3,  2,  rk('suborder'),   1 ],
                [ 5,  4,  rk('infraorder'), 1 ],
                [ 7,  6,  rk('family'),     1 ],
                [ 9,  8,  rk('subfamily'),  1 ],
                [ 11, 10, rk('tribe'),      1 ],
                [ 13, 12, rk('genus'),      1 ],
            ]);
            my ($genus, $epithet, $jap) = @f[12, 14, 15];
            return unless length $genus && length $epithet && length $jap;
            my $sci = "$genus $epithet";
            add_pair(\@out, $jap, $sci, rk('species'), 1);
            my $canon = norm_sciname($sci);
            for my $col (20, 21, 22) {
                my $alt = norm_sciname($f[$col]);
                next if !length $alt || $alt eq $canon;
                add_pair(\@out, $jap, $alt, rk('species'), 1, scivalid => 0);
            }
        }, merge => 1);
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# shigainsect 滋賀県昆虫目録2025 (目別 xlsx)
#
# 列はヘッダ行から決める。ただし「ガロアムシ目2025.xlsx」だけはヘッダの
# 種名（学名）と種名（和名）が入れ替わっていてデータの並びと合わないので、
# 2列の内容 (ラテン文字か日本語か) を見て毎行ふり分ける。
# 「亜目名」が「亜目」になっているファイルがあるのでヘッダ名も揺れを許す。
# 「異名・旧名」列には和名の異名と学名の異名が混在する。
#-----------------------------------------------------------------------------
sub parse_shigainsect {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my @head;
        my $first = 1;
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            my @f = map { defined $_ ? trim($_) : '' } @$c;
            if ($first) {
                $first = 0;
                @head = @f;
                return;
            }
            return unless @head;
            my $idx = sub {
                my (@names) = @_;
                for my $want (@names) {
                    for my $i (0 .. $#head) { return $i if $head[$i] eq $want }
                }
                return undef;
            };
            my @levels;
            my @spec = (
                [ [ '目名' ],           [ 'Order' ],      rk('order') ],
                [ [ '亜目名', '亜目' ], [ 'Suborder' ],   rk('suborder') ],
                [ [ '科名' ],           [ 'Family' ],     rk('family') ],
                [ [ '亜科名' ],         [ 'Subfamily' ],  rk('subfamily') ],
                [ [ '族名' ],           [ 'Tribe' ],      rk('tribe') ],
            );
            for my $s (@spec) {
                my $j = $idx->(@{ $s->[0] });
                my $l = $idx->(@{ $s->[1] });
                push @levels, [ $j, $l, $s->[2], 1 ] if defined $j && defined $l;
            }
            add_levels(\@out, \@f, \@levels);

            my $c1 = $idx->('種名（学名）');
            my $c2 = $idx->('種名（和名）');
            return unless defined $c1 && defined $c2;
            my ($a, $b) = ($f[$c1] // '', $f[$c2] // '');
            my ($sci, $jap) = looks_japanese($a) && !looks_japanese($b) ? ($b, $a) : ($a, $b);
            return unless length trim($sci) && length trim($jap);
            my ($rank, $subrank) = rank_from_sciname(norm_sciname($sci));
            add_pair(\@out, $jap, $sci, $rank, $subrank);

            my $ci = $idx->('異名・旧名');
            return unless defined $ci && length $f[$ci];
            my $canon = norm_sciname($sci);
            for my $seg (split_mixed_names($f[$ci])) {
                my ($type, $tok) = @$seg;
                if ($type eq 'jap') {
                    next unless length $tok >= 2;
                    add_pair(\@out, $tok, $sci, $rank, $subrank, japvalid => 0);
                }
                else {
                    my $alt = norm_sciname($tok);
                    next if !length $alt || $alt eq $canon;
                    add_pair(\@out, $jap, $alt, $rank, $subrank, scivalid => 0);
                }
            }
        });
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 日本産ミミズのリスト (xlsx)
#
# 「学名」列が旧名、「最新の分類」列が有効名という特殊な構造で、182行中147行で
# 両者が異なる。科の列は結合セルなので繰り下ろしが要る。
# 「? 」を前置した不確実マーカがある。
#-----------------------------------------------------------------------------
sub parse_earthworms {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $first = 1;
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            if ($first) { $first = 0; return }
            my @f = map { defined $_ ? trim($_) : '' } @$c[0 .. 8];
            s/\A\?\s*// for @f[4, 5];
            add_levels(\@out, \@f, [ [ 1, 2, rk('family'), 1 ] ]);
            my ($jap, $old, $new) = @f[3, 4, 5];
            my $valid = norm_sciname(length $new ? $new : $old);
            return unless length $valid && length $jap;
            my ($rank, $subrank) = rank_from_sciname($valid);
            add_pair(\@out, $jap, $valid, $rank, $subrank);
            my $oldn = norm_sciname($old);
            return if !length $oldn || $oldn eq $valid;
            add_pair(\@out, $jap, $oldn, $rank, $subrank, scivalid => 0);
        }, merge => 1);
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# YList 植物和名-学名インデックス (xlsx)
#
# A列「学名 withAuthor」を学名の正本とする (O列の学名は雑種記号 x が落ちている)。
# ステータスは 標準 / synonym / 広義 / 狭義 / 異分類 の5種で、標準以外は
# その学名を有効名として扱わない。シノニム学名から有効名への対応は和名の一致
# でしか辿れないので、和名 -> 標準学名の対応表を先に作ってから結び付ける。
#-----------------------------------------------------------------------------
sub parse_ylist {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my @rows;
        my %std;      # 和名 -> 標準の学名
        my %std_dup;
        my $first = 1;
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            if ($first) { $first = 0; return }
            my @f = map { defined $_ ? trim($_) : '' } @$c[0 .. 14];
            my ($sci, $jap, $alias, $status, $famj, $fams) = @f[0, 1, 2, 3, 4, 5];
            return unless length $sci;
            push @rows, [ $sci, $jap, $alias, $status, $famj, $fams ];
            return unless $status eq '標準' && length $jap;
            my $n = norm_sciname($sci);
            return unless length $n;
            if (exists $std{$jap} && $std{$jap} ne $n) { $std_dup{$jap} = 1; return }
            $std{$jap} = $n;
        });

        for my $r (@rows) {
            my ($sci, $jap, $alias, $status, $famj, $fams) = @$r;
            add_pair(\@out, $famj, $fams, rk('family'), 1) if length $famj && length $fams;
            next unless length $jap;
            my $n = norm_sciname($sci);
            next unless length $n;
            my ($rank, $subrank) = rank_from_sciname($n);
            if ($status eq '標準') {
                add_pair(\@out, $jap, $n, $rank, $subrank);
                for my $s (split_japnames($alias)) {
                    add_pair(\@out, $s, $n, $rank, $subrank, japvalid => 0);
                }
            }
            else {
                # 標準がひとつに定まる和名にだけシノニム学名を結び付ける
                my $std = (!$std_dup{$jap} && exists $std{$jap}) ? $std{$jap} : undef;
                next unless defined $std;
                next if $n eq $std;
                add_pair(\@out, $jap, $n, $rank, $subrank, scivalid => 0);
            }
        }
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 日本産菌類チェックリスト (xlsx)
#
# 学名は Genus + SpEpithet (+ ISRank + ISEpithet) を連結して作る。
# 和名 (Wamei 列) があるのは 426 行中 46 行だけ。
# Genus / SpEpithet に余分な空白やセル内改行が入っている行がある。
#-----------------------------------------------------------------------------
sub parse_fungi {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $first = 1;
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            if ($first) { $first = 0; return }
            my @f = map { defined $_ ? squeeze($_) : '' } @$c[0 .. 21];
            my ($genus, $sp, $israk, $isep, $jap) = @f[2, 3, 5, 6, 16];
            return unless length $genus && length $sp && length $jap;
            my $sci = "$genus $sp";
            $sci .= " $israk $isep" if length $israk && length $isep;
            add_pair(\@out, $jap, $sci, undef, undef);
        });
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 河川水辺の国勢調査 全生物種リスト (xlsx 7年度分)
#
# 門/亜門/綱/亜綱/目/科/亜科/属/種の9階層が列になっており、それぞれに
# コード列がある。有効名/シノニムの情報は持たないので、最新年度 (R07) を
# 有効名とし、コードが同じで名前が異なる旧年度の名前をシノニムとして出す。
# 「ダミー科」などのプレースホルダと、種和名欄に学名が入る行は is_placeholder が弾く。
#-----------------------------------------------------------------------------

sub parse_alltaxa {
    my ($src, $paths) = @_;
    # R07 → R01 の順に処理する。最初に読んだ年度が有効名の基準になる。
    my @sorted = sort { alltaxa_year($b) <=> alltaxa_year($a) } @$paths;
    my @out;
    my %base;      # 階層 -> コード -> [和名, 学名]
    my $is_base = 1;

    for my $path (@sorted) {
        my $first = 1;
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            if ($first) { $first = 0; return }
            my @f = map { defined $_ ? trim($_) : '' } @$c[0 .. 27];
            for my $lv (0 .. $#ALLTAXA_LEVELS) {
                my ($ccol, $jcol, $scol, $rname) = @{ $ALLTAXA_LEVELS[$lv] };
                my ($code, $jap, $sci) = @f[$ccol, $jcol, $scol];
                next unless length $code && length $sci;
                my ($rank, $subrank) = defined $rname ? (rk($rname), 1)
                                                      : rank_from_sciname(norm_sciname($sci));
                if ($is_base) {
                    $base{$lv}{$code} = [ $jap, $sci ];
                    add_pair(\@out, $jap, $sci, $rank, $subrank);
                    next;
                }
                my $b = $base{$lv}{$code};
                unless ($b) {
                    # 最新年度にない分類群。古いというだけで無効とは言えない。
                    add_pair(\@out, $jap, $sci, $rank, $subrank);
                    next;
                }
                my ($bjap, $bsci) = @$b;
                if (norm_sciname($sci) ne norm_sciname($bsci)) {
                    add_pair(\@out, $bjap, $sci, $rank, $subrank, scivalid => 0);
                }
                if (length $jap && norm_japname($jap) ne norm_japname($bjap)) {
                    add_pair(\@out, $jap, $bsci, $rank, $subrank, japvalid => 0);
                }
            }
        });
        $is_base = 0;
    }
    return \@out;
}

# R01zenseibutsu.xlsx から令和年度を取り出す。西暦は 2018 + 年度。
sub alltaxa_year {
    my ($path) = @_;
    my $name = basename($path);
    return $name =~ /R(\d+)/ ? 2018 + $1 : 0;
}

#-----------------------------------------------------------------------------
# HTML パーサ共通のヘルパ
#-----------------------------------------------------------------------------
# 「学名 著者, 年 和名」のように1行に混在した文字列を切り分ける。
# 和名は末尾の日本語の連なりとして取る (途中の「sensu 布村 (2011)」のような
# 日本語を拾わないため)。
sub split_sci_jap {
    my ($text) = @_;
    return ('', '') unless defined $text;
    my $t = squeeze(fixup_chars($text));
    my $jap = '';
    if ($t =~ s/((?:[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}\x{FF66}-\x{FF9D}\x{3005}\x{30FC}\x{FF08}\x{FF09}]|\s)+)\z//) {
        $jap = $1;
    }
    return (norm_sciname($t), norm_japname($jap));
}

# 「（55）」「(2)」のような種数の注記を落とす。
sub strip_count_note {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/[（(]\s*\d+\s*[）)]\s*\z//;
    return trim($s);
}

# HTML::TreeBuilder を1ファイル分作る。
sub html_tree {
    my ($path) = @_;
    require HTML::TreeBuilder;
    my $tree = HTML::TreeBuilder->new;
    $tree->ignore_unknown(0);
    $tree->no_space_compacting(1);
    $tree->parse(read_html($path));
    $tree->eof;
    return $tree;
}

#-----------------------------------------------------------------------------
# 日本産爬虫両生類標準和名リスト (HTML)
#
# <ul class="rank_XXX"> の入れ子で階層を表しており、XXX が rank.def の階層名
# そのものになっている。各 <li> の <div class="taxon"> に
# <span class="wamei"> と <span class="sciname"> が入っている。
#-----------------------------------------------------------------------------
sub parse_herpetology {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $tree = html_tree($path);
        for my $ul ($tree->look_down(_tag => 'ul')) {
            my $class = $ul->attr('class');
            next unless defined $class && $class =~ /\brank_(\w+)\b/;
            my $rname = $1;
            $rname =~ s/_/ /g;
            unless (exists $RANK{$rname}) {
                note($src, "rank.def にない階層名です: $rname");
                next;
            }
            for my $li ($ul->content_list) {
                next unless ref $li && $li->tag eq 'li';
                my ($div) = $li->look_down(_tag => 'div', class => 'taxon');
                next unless $div;
                my ($w) = $div->look_down(_tag => 'span', sub { ($_[0]->attr('class') || '') =~ /\bwamei\b/ });
                my ($s) = $div->look_down(_tag => 'span', sub { ($_[0]->attr('class') || '') =~ /\bsciname\b/ });
                next unless $w && $s;
                add_pair(\@out, $w->as_text, $s->as_text, $RANK{$rname}, 1);
            }
        }
        $tree->delete;
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 日本産地衣類チェックリスト (HTML)
#
# <h2>GENUS 和名属</h2> が属、<p class="entry"> が有効名、
# <p class="entry syn"> がシノニムで、すべて「シノニム → 有効名」の形をしている。
# シノニムの行に和名はないので、有効名の和名を引いて結び付ける。
#-----------------------------------------------------------------------------
sub parse_lichens {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $html = read_html($path);
        my %jap_of;    # 有効な学名 -> 和名

        while ($html =~ m{<h2\b[^>]*>(.*?)</h2>}gs) {
            my $t = squeeze(html_text($1));
            next unless $t =~ /\A([A-Z][A-Za-z-]+)\s*(.*)\z/;
            my ($genus, $jap) = (ucfirst(lc $1), $2);
            next unless length $jap;
            add_pair(\@out, $jap, $genus, rk('genus'), 1);
            my ($head) = split_japsyn($jap);
            $jap_of{$genus} = $head if length $head;
        }

        while ($html =~ m{<p\b[^>]*class="entry"[^>]*>(.*?)</p>}gs) {
            my $body = $1;
            my ($name) = $body =~ m{<span\b[^>]*class="name"[^>]*>(.*?)</span>}s;
            next unless defined $name;
            my ($ja) = $body =~ m{<span\b[^>]*class="ja"[^>]*>(.*?)</span>}s;
            my $sci = norm_sciname(html_text($name));
            next unless length $sci;
            next unless defined $ja && length squeeze(html_text($ja));
            my $jap = squeeze(html_text($ja));
            my ($rank, $subrank) = rank_from_sciname($sci);
            add_pair(\@out, $jap, $sci, $rank, $subrank);
            my ($head) = split_japsyn($jap);
            $jap_of{$sci} = $head if length $head && !exists $jap_of{$sci};
        }

        while ($html =~ m{<p\b[^>]*class="entry syn"[^>]*>(.*?)</p>}gs) {
            my $body = $1;
            $body =~ s{<span\b[^>]*class="refs".*?</span>\s*\z}{}s;
            my $t = squeeze(html_text($body));
            next unless $t =~ /\A(.*?)\s*\x{2192}\s*(.*)\z/;
            my ($syn, $acc) = (norm_sciname($1), norm_sciname($2));
            next unless length $syn && length $acc;
            my $jap = $jap_of{$acc};
            next unless defined $jap && length $jap;
            my ($rank, $subrank) = rank_from_sciname($syn);
            add_pair(\@out, $jap, $syn, $rank, $subrank, scivalid => 0);
        }
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 日本産ワラジムシ亜目種名リスト (HTML)
#
# <h3> が科、<details><summary> が属、<ul><li> が種。無効名は <del> で囲まれ、
# 入れ子の <ul><li>accepted as ...</li></ul> に有効名が書いてあるので、
# 学名シノニムと和名シノニムの両方をそのまま取れる。
#-----------------------------------------------------------------------------
sub parse_isopods {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $tree = html_tree($path);
        for my $h3 ($tree->look_down(_tag => 'h3')) {
            my ($jap, $sci) = paren_pair($h3->as_text);
            add_pair(\@out, $jap, $sci, rk('family'), 1);
        }
        for my $sm ($tree->look_down(_tag => 'summary')) {
            my ($jap, $sci) = paren_pair($sm->as_text);
            add_pair(\@out, $jap, $sci, rk('genus'), 1);
        }
        for my $li ($tree->look_down(_tag => 'li')) {
            my ($del) = $li->look_down(_tag => 'del');
            unless ($del) {
                # 入れ子の「accepted as ...」側の <li> はここでは扱わない
                next if $li->look_up(_tag => 'del');
                my $text = $li->as_text;
                next if $text =~ /\Aaccepted as\b/;
                my ($sci, $jap) = split_sci_jap($text);
                add_pair(\@out, $jap, $sci, undef, undef);
                next;
            }
            my ($bad_sci, $bad_jap) = split_sci_jap($del->as_text);
            my ($acc) = grep { $_->as_text =~ /\Aaccepted as\b/ } $li->look_down(_tag => 'li');
            unless ($acc) {
                add_pair(\@out, $bad_jap, $bad_sci, undef, undef, scivalid => 0);
                next;
            }
            (my $atext = $acc->as_text) =~ s/\Aaccepted as\s*//;
            my ($good_sci, $good_jap) = split_sci_jap($atext);
            next unless length $good_sci;
            my ($rank, $subrank) = rank_from_sciname($good_sci);
            add_pair(\@out, $good_jap, $good_sci, $rank, $subrank);
            add_pair(\@out, $good_jap, $bad_sci, $rank, $subrank, scivalid => 0)
                if length $bad_sci && $bad_sci ne $good_sci && length $good_jap;
            add_pair(\@out, $bad_jap, $good_sci, $rank, $subrank, japvalid => 0)
                if length $bad_jap && length $good_jap && $bad_jap ne $good_jap;
        }
        $tree->delete;
    }
    return \@out;
}

# 「フナムシ科（Ligiidae Leach, 1814）」を (和名, 学名) に分ける。
# 和名側に「(仮称)」が入る行があるので最後の括弧を学名として採り、
# 閉じ括弧が欠けている行も許す。
sub paren_pair {
    my ($text) = @_;
    my $t = squeeze(fixup_chars(defined $text ? $text : ''));
    return ('', '') unless $t =~ /\A(.*)[（(]([^（()）]+)[）)]?\s*\z/;
    return (norm_japname($1), norm_sciname($2));
}

#-----------------------------------------------------------------------------
# 日本産トビケラの種リスト (HTML)
#
# 文字コードは UTF-8。表は1つで、空セルと colspan による字下げが階層を表す。
# 先頭セルの開始列が 0=亜目 / 1=科 / 2=属 / 3=種 に対応する。
# 種の行は属名が頭文字省略形 (C. aira) なので直前の属名で展開する。
#-----------------------------------------------------------------------------
sub parse_trichoptera {
    my ($src, $paths) = @_;
    my @out;
    my @RANK_BY_COL = (rk('suborder'), rk('family'), rk('genus'), rk('species'));
    for my $path (@$paths) {
        my $html = read_html($path);
        my $genus = '';
        while ($html =~ m{<tr\b.*?</tr>}gsi) {
            my $row = $&;
            my @cells;
            my $col = 0;
            while ($row =~ m{<t[dh]\b([^>]*)>(.*?)</t[dh]>}gsi) {
                my ($attr, $body) = ($1, $2);
                my ($cs) = $attr =~ /colspan\s*=\s*"?(\d+)/i;
                my $text = squeeze(html_text($body));
                push @cells, [ $col, $text ] if length $text;
                $col += $cs ? $cs : 1;
            }
            next unless @cells;
            my ($start, $first) = @{ $cells[0] };
            next if $start > 3;
            if ($start < 3) {
                my ($sci, $jap) = split_sci_jap(strip_count_note($first));
                next unless length $sci;
                $genus = $sci if $start == 2;
                add_pair(\@out, $jap, $sci, $RANK_BY_COL[$start], 1);
                next;
            }
            # 種の行。4列目が学名、5列目が和名。
            my $sci = $first;
            $sci =~ s/\A([A-Z])\.\s*/expand_genus($genus, $1)/e;
            $sci = norm_sciname($sci);
            next unless length $sci;
            my $jap = '';
            for my $c (@cells) { $jap = $c->[1] if $c->[0] >= 4 }
            add_pair(\@out, $jap, $sci, undef, undef);
        }
    }
    return \@out;
}

sub expand_genus {
    my ($genus, $initial) = @_;
    return "$genus " if length $genus && substr($genus, 0, 1) eq $initial;
    return "$initial. ";
}

#-----------------------------------------------------------------------------
# 日本産蝶類和名学名便覧 (HTML)
#
# ファイル名が階層を表している。科・亜科・族・属のページは
# 「<th>科（学名）</th><th>科（和名）</th>」の表、種のページは <ol> と <ul> の
# 入れ子で、<i> の個数が種 (2) と亜種 (3) を区別する。
# 種レベルは和名シノニムの閉じ括弧が欠けている行がある。
#-----------------------------------------------------------------------------
my %BINRAN_RANK = (
    '科' => 'family', '亜科' => 'subfamily', '族' => 'tribe',
    '亜族' => 'subtribe', '属' => 'genus', '亜属' => 'subgenus',
);

sub parse_binran {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $html = read_html($path);
        if (basename($path) =~ /_species\.html\z/) {
            parse_binran_species($src, \@out, $html);
        }
        else {
            parse_binran_table($src, \@out, $html);
        }
    }
    return \@out;
}

sub parse_binran_table {
    my ($src, $out, $html) = @_;
    my ($thead) = $html =~ m{<tr>\s*<th>(.*?)</th>}s;
    return unless defined $thead;
    my ($word) = squeeze(html_text($thead)) =~ /\A(\S+?)[（(]/;
    return unless defined $word && exists $BINRAN_RANK{$word};
    my $rank = rk($BINRAN_RANK{$word});

    while ($html =~ m{<tr>(.*?)</tr>}gs) {
        my $row = $1;
        next if $row =~ /<th>/;
        my @cells;
        push @cells, squeeze(html_text($1)) while $row =~ m{<td\b[^>]*>(.*?)</td>}gs;
        next unless @cells >= 2;
        add_pair($out, $cells[1], $cells[0], $rank, 1);
    }
}

sub parse_binran_species {
    my ($src, $out, $html) = @_;
    while ($html =~ m{<li>(.*?)(?=<li>|</ol>|</ul>|\z)}gs) {
        my $item = $1;
        $item =~ s{<a\b.*?</a>}{}gs;             # 「詳細」へのリンクを落とす
        my @parts = $item =~ m{<i>(.*?)</i>}gs;
        next unless @parts >= 2;
        @parts = map { squeeze(html_text($_)) } @parts;
        next if $parts[-1] eq 'ssp.';            # 学名のない個体群は種と衝突する
        my $sci  = norm_sciname(join ' ', @parts);
        next unless length $sci;
        my $rank = @parts >= 3 ? rk('subspecies') : rk('species');

        my ($tail) = $item =~ m{.*</i>(.*)\z}s;
        $tail = squeeze(html_text(defined $tail ? $tail : ''));
        $tail =~ s/\A(.*?\d{4}[\]\)]*)\s*//;     # 著者名と年を落とす
        # 種レベルは閉じ括弧が欠けているので、開き括弧以降を別名として切り出す
        my ($jap, $syn) = $tail =~ /\A(.*?)\s*[（(](.*?)[）)]?\s*\z/ ? ($1, $2) : ($tail, '');
        add_pair($out, $jap, $sci, $rank, 1, nosplit => 1);
        add_pair($out, $syn, $sci, $rank, 1, nosplit => 1, japvalid => 0) if length $syn;
    }
}

#-----------------------------------------------------------------------------
# NARO 昆虫インベントリーDB (HTML / 昆虫・クモ類・線形動物で共通)
#
# search/basic の一覧ページ。門/綱/目/科/属/種の列に配置されているので rank が
# 列位置から得られ、セル内の「└」が中間階層 (上科・亜綱など) を表す。
#
# 実装上どうしても外せない点が3つある。
#   1. <a> 単位でパースしない。アンカーの境界は分類群の境界とずれる。セルの
#      HTML から <a> タグを除去し <br> で行分割して、「└」行を新しい分類群の
#      開始、「(…)」行をその和名として読む。
#   2. ページ先頭が祖先チェーンを再掲するので重複が出る。重複排除は
#      categorySelect('ID','4') の ID で行う。(学名,和名) では別属の同名種小名が
#      潰れてしまう。
#   3. 種の列は種小名だけなので、属の列の値を連結して二名法の学名を組み立てる。
#      亜種は「└」行を種の学名に連結する。
#-----------------------------------------------------------------------------
my @NARO_COL_RANK = ('phylum', 'class', 'order', 'family', 'genus', 'species');

# 和名の接尾辞から階層を決める。「└」の字下げは深さを表さないので使えない。
my %NARO_JAP_SUFFIX = (
    '亜界' => 'subkingdom', '上門' => 'superphylum', '亜門' => 'subphylum',
    '上綱' => 'superclass', '亜綱' => 'subclass', '下綱' => 'infraclass',
    '上目' => 'superorder', '亜目' => 'suborder', '下目' => 'infraorder',
    '上科' => 'superfamily', '亜科' => 'subfamily',
    '亜族' => 'subtribe', '族' => 'tribe',
    '亜属' => 'subgenus', '節' => 'section',
    '亜種' => 'subspecies', '変種' => 'varietas', '品種' => 'forma',
);

sub parse_naro {
    my ($src, $paths) = @_;
    require HTML::TableExtract;
    my @out;
    my %seen_id;
    my @cur;        # 列ごとの直近の分類群 (学名)
    for my $path (@$paths) {
        my $te = HTML::TableExtract->new(attribs => { class => 'result1' }, keep_html => 1);
        $te->parse(read_html($path));
        for my $ts ($te->tables) {
            for my $row ($ts->rows) {
                for my $col (0 .. 5) {
                    my $cell = $row->[$col];
                    next unless defined $cell && $cell =~ /categorySelect/;
                    naro_cell($src, \@out, \%seen_id, \@cur, $col, $cell);
                }
            }
        }
    }
    return \@out;
}

sub naro_cell {
    my ($src, $out, $seen_id, $cur, $col, $cell) = @_;
    my @ids = $cell =~ /categorySelect\('([^']+)','4'\)/g;
    (my $t = $cell) =~ s{</?a\b[^>]*>}{}g;
    my @lines = grep { length }
                map  { squeeze(html_text($_)) } split /<br\s*\/?>/i, $t;

    # 「(…)」の行は直前の分類群の和名。それ以外は新しい分類群の開始。
    my @taxa;
    for my $line (@lines) {
        if ($line =~ /\A[（(]/ && @taxa) { push @{ $taxa[-1] }, $line }
        else                             { push @taxa, [ $line ] }
    }

    for my $i (0 .. $#taxa) {
        my ($name, $jap) = @{ $taxa[$i] };
        my $id = $ids[$i];
        my $is_sub = $name =~ s/\A└\s*// ? 1 : 0;
        my $scivalid = $name =~ s/\Asyn\s*:\s*// ? 0 : 1;
        $name = trim($name);
        $jap  = defined $jap ? $jap : '';
        $jap =~ s/\A[（(]\s*//;
        $jap =~ s/\s*[）)]\s*\z//;
        next unless length $name;

        # 属の列の基底エントリは属名、種の列の基底エントリは種小名。
        my $bare = $name;
        $bare =~ s/\A\((.*)\)\z/$1/;

        my ($sci, $rank, $subrank);
        if ($col == 5) {
            my $genus = $cur->[4];
            next unless defined $genus && length $genus;
            if ($is_sub) {
                my $sp = $cur->[5];
                next unless defined $sp && length $sp;
                $sci = "$sp $bare";
                ($rank, $subrank) = naro_rank($col, $bare, $jap, 1);
            }
            else {
                $sci = "$genus $bare";
                $cur->[5] = $sci;
                ($rank, $subrank) = (rk('species'), 1);
            }
        }
        else {
            $sci = $bare;
            if ($is_sub) { ($rank, $subrank) = naro_rank($col, $bare, $jap, 1) }
            else {
                ($rank, $subrank) = (rk($NARO_COL_RANK[$col]), 1);
                $cur->[$col] = $bare;
                $cur->[$_] = '' for ($col + 1) .. 5;
            }
        }

        next if defined $id && $seen_id->{$id}++;
        $sci = norm_sciname($sci);
        next unless length $sci;
        add_pair($out, $jap, $sci, $rank, $subrank, scivalid => $scivalid);
    }
}

# 「└」で始まる中間階層の rank を決める。和名の接尾辞を最優先し、
# 次に学名の語尾を見る。決められないものは列の基底 rank に subrank=2 を当てる。
sub naro_rank {
    my ($col, $name, $jap, $is_sub) = @_;
    if (length $jap) {
        for my $suffix (sort { length($b) <=> length($a) } keys %NARO_JAP_SUFFIX) {
            return (rk($NARO_JAP_SUFFIX{$suffix}), 1) if $jap =~ /\Q$suffix\E\z/;
        }
    }
    return (rk('subspecies'), 1)  if $col == 5;
    return (rk('subgenus'), 1)    if $col == 4;
    return (rk('superfamily'), 1) if $name =~ /oidea\z/;
    return (rk('subfamily'), 1)   if $name =~ /inae\z/;
    return (rk('tribe'), 1)       if $name =~ /ini\z/;
    return (rk('subtribe'), 1)    if $name =~ /ina\z/;
    return (rk('family'), 1)      if $name =~ /idae\z/;
    return (rk($NARO_COL_RANK[$col]), $SUBRANK_INTERMEDIATE);
}

#-----------------------------------------------------------------------------
# 日本近海産タナイス類リスト (HTML)
#
# Google Sites のページ。<p> の中の font-style: italic の span が学名で、
# 全角空白の後ろが和名。129種のうち和名を持つのは29種だけ。
# 上位分類群 (Apseudoidea (25 spp) など) には和名がないので出力に寄与しない。
#-----------------------------------------------------------------------------
sub parse_tanaids {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $html = read_html($path);
        while ($html =~ m{<p\b[^>]*>(.*?)</p>}gs) {
            my $body = $1;
            my @ital = $body =~ m{<span\b[^>]*font-style:\s*italic[^>]*>(.*?)</span>}gs;
            next unless @ital;
            my $sci = norm_sciname(join ' ', map { squeeze(html_text($_)) } @ital);
            next unless length $sci;
            my $text = html_unescape(html_text($body));
            next unless $text =~ /\x{3000}\s*(.+?)\s*\z/;
            add_pair(\@out, $1, $sci, undef, undef);
        }
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 日本産海藻リスト (HTML)
#
# 分類群別ページに分かれており、列とランクの対応はページごとに異なるので
# 列位置は使わない。上位分類群の行は「和名 RankWord 学名 著者」の形で、
# 和名の直後の英語のランク語がそのまま階層を示す。種の行は <em> が学名の
# 目印になる。シノニムは class="Reference" のセルに [≡ …] (ホモタイプ) /
# [= …] (ヘテロタイプ) / [和名 学名 auct. non …] (誤用) の形で並ぶ。
#
# Brown/Asterocladales.html など4ファイルは charset の指定がなく中身が cp932。
# read_html が UTF-8 として解釈できなければ cp932 で読み直す。
# Red/Erythropeltidales.html は情報源側が 404 なので存在しない (欠損を許容する)。
#-----------------------------------------------------------------------------
my %SEAWEED_RANK = (
    'Kingdom' => 'kingdom', 'Subkingdom' => 'subkingdom',
    'Superphylum' => 'superphylum', 'Phylum' => 'phylum', 'Division' => 'phylum',
    'Subphylum' => 'subphylum', 'Subdivision' => 'subphylum',
    'Superclass' => 'superclass', 'Class' => 'class', 'Subclass' => 'subclass',
    'Superorder' => 'superorder', 'Order' => 'order', 'Suborder' => 'suborder',
    'Superfamily' => 'superfamily', 'Family' => 'family', 'Subfamily' => 'subfamily',
    'Tribe' => 'tribe', 'Subtribe' => 'subtribe',
    'Genus' => 'genus', 'Subgenus' => 'subgenus',
    'Section' => 'section', 'Subsection' => 'subsection', 'Series' => 'series',
);

sub parse_seaweeds {
    my ($src, $paths) = @_;
    my $rankwords = join '|', sort { length($b) <=> length($a) } keys %SEAWEED_RANK;
    my @out;
    for my $path (@$paths) {
        my $html = read_html($path);
        my ($cur_sci, $cur_jap, $cur_rank, $cur_subrank) = ('', '', undef, 1);
        while ($html =~ m{<tr\b.*?</tr>}gsi) {
            my $row = $&;
            next if $row =~ /class="(?:Author|Remarks)"/;
            my $inner = join ' ', ($row =~ m{<t[dh]\b[^>]*>(.*?)</t[dh]>}gsi);
            my $text = squeeze(html_unescape(html_text($inner)));
            next unless length $text;
            next if $text =~ /\A(?:Note|Reference|参考)\b/;

            if ($text =~ /\A\[/) {
                seaweed_synonym(\@out, $inner, $text, $cur_sci, $cur_jap,
                                $cur_rank, $cur_subrank);
                next;
            }
            if ($text =~ /\A(.*?)\s*\b($rankwords)\s+([A-Z][A-Za-z].*)\z/) {
                my ($jap, $word, $rest) = ($1, $2, $3);
                my $sci = norm_sciname($rest);
                next unless length $sci;
                ($cur_sci, $cur_jap) = ($sci, $jap);
                ($cur_rank, $cur_subrank) = (rk($SEAWEED_RANK{$word}), 1);
                add_pair(\@out, $jap, $sci, $cur_rank, $cur_subrank);
                next;
            }
            # 種の行。<em> の手前までが和名。
            next unless $inner =~ /<em\b/i;
            my ($jap) = $inner =~ m{\A(.*?)<em\b}si;
            my ($sci) = $inner =~ m{(<em\b.*)\z}si;
            $jap = squeeze(html_unescape(html_text(defined $jap ? $jap : '')));
            $sci = norm_sciname(squeeze(html_unescape(html_text(defined $sci ? $sci : ''))));
            next unless length $sci;
            ($cur_sci, $cur_jap) = ($sci, $jap);
            ($cur_rank, $cur_subrank) = rank_from_sciname($sci);
            add_pair(\@out, $jap, $sci, $cur_rank, $cur_subrank);
        }
    }
    return \@out;
}

sub seaweed_synonym {
    my ($out, $inner, $text, $cur_sci, $cur_jap, $rank, $subrank) = @_;
    return unless length $cur_sci;
    (my $body = $inner) =~ s{\A.*?\[}{}s;
    $body =~ s{\]\s*\z}{}s;
    $body =~ s{\[[^\[\]]*\]\s*\z}{}s;         # 末尾の [裸名] [非正式名] を落とす
    my $flat = squeeze(html_unescape(html_text($body)));
    $flat =~ s/\A[\x{2261}=＝]\s*//;          # ≡ / = のシノニム記号
    return unless length $flat;

    my ($jap, $sci);
    if ($body =~ /<em\b/i) {
        ($jap) = $body =~ m{\A(.*?)<em\b}si;
        ($sci) = $body =~ m{(<em\b.*)\z}si;
        $jap = squeeze(html_unescape(html_text(defined $jap ? $jap : '')));
        $jap =~ s/\A[\x{2261}=＝]\s*//;
        $sci = norm_sciname(squeeze(html_unescape(html_text(defined $sci ? $sci : ''))));
    }
    else {
        ($sci, $jap) = ('', '');
        if ($flat =~ /\A(.*?)\s*([A-Z][A-Za-z].*)\z/) { ($jap, $sci) = ($1, norm_sciname($2)) }
    }
    if (length $sci && $sci ne $cur_sci) {
        my $with = length $jap ? $jap : $cur_jap;
        add_pair($out, $with, $sci, $rank, $subrank, scivalid => 0);
    }
    if (length $jap && length $cur_jap) {
        my ($h) = split_japsyn($jap);
        my ($c) = split_japsyn($cur_jap);
        add_pair($out, $jap, $cur_sci, $rank, $subrank, japvalid => 0)
            if length $h && $h ne $c;
    }
}

#-----------------------------------------------------------------------------
# PDF パーサ共通のヘルパ
#
# PDF の CJK は行折り返しのときに空白なしで連結されるのが全ソース共通の規則
# (「アツバ」+「サイハイゴケ」)。継続行は必ず空白を入れずに繋ぐこと。
#-----------------------------------------------------------------------------
# 和名の接尾辞から階層を決める。決められなければ undef。
my %JAP_RANK_SUFFIX = (
    '亜界' => 'subkingdom', '上門' => 'superphylum', '亜門' => 'subphylum', '門' => 'phylum',
    '上綱' => 'superclass', '亜綱' => 'subclass', '下綱' => 'infraclass', '綱' => 'class',
    '上目' => 'superorder', '亜目' => 'suborder', '下目' => 'infraorder', '目' => 'order',
    '上科' => 'superfamily', '亜科' => 'subfamily', '科' => 'family',
    '亜族' => 'subtribe', '族' => 'tribe',
    '亜属' => 'subgenus', '属' => 'genus', '節' => 'section',
    '亜種' => 'subspecies', '変種' => 'varietas', '品種' => 'forma',
);

sub jap_rank_suffix {
    my ($jap) = @_;
    return undef unless defined $jap && length $jap;
    for my $suffix (sort { length($b) <=> length($a) } keys %JAP_RANK_SUFFIX) {
        return $JAP_RANK_SUFFIX{$suffix} if $jap =~ /\Q$suffix\E\z/;
    }
    return undef;
}

# 行内の日本語の連なりを取り出す。$last が真なら末尾側、偽なら最初の連なり。
sub japanese_run {
    my ($line, $last) = @_;
    return '' unless defined $line;
    $line = strip_japnotes($line);
    my @runs = $line =~ /((?:[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}\x{FF66}-\x{FF9D}\x{3005}\x{30FC}\x{FF08}\x{FF09}\x{FF0C}\x{3001}\x{30FB}]|(?<=[\x{3040}-\x{9FFF}])\s(?=[\x{3040}-\x{9FFF}]))+)/g;
    return '' unless @runs;
    return $last ? $runs[-1] : $runs[0];
}

# PDF から取り出した行を、レコードの開始行かどうかで束ねる。
# $is_record->($line) が真なら新しいレコード、偽なら直前のレコードへ空白なしで連結。
sub fold_pdf_lines {
    my ($text, $is_record, $is_noise) = @_;
    my @recs;
    for my $raw (split /\n/, $text) {
        my $line = $raw;
        $line =~ s/\x{000C}//g;
        $line = fixup_chars($line);
        $line =~ s/\s+\z//;
        next unless $line =~ /\S/;
        my $trimmed = trim($line);
        next if $is_noise && $is_noise->($trimmed);
        if ($is_record->($trimmed)) { push @recs, $trimmed; next }
        next unless @recs;
        $recs[-1] .= $trimmed;
    }
    return @recs;
}

#-----------------------------------------------------------------------------
# 日本産ハネカクシ科総目録 (PDF p.7〜109)
#
# 行頭のキーワード (Family / Subfamily / Tribe / Subtribe / Genus / subgenus) で
# rank が明示されている。種は小文字の種小名で始まり、シノニムは「= 」で始まる。
# 左マージンが偶数ページと奇数ページで変わるので字下げの絶対値は使わない。
# 「d. fujimontanus」のように種小名が頭文字省略される行は直前の種名で展開する。
#-----------------------------------------------------------------------------
my %STAPH_KEYWORD = (
    'Family' => 'family', 'Subfamily' => 'subfamily',
    'Tribe' => 'tribe', 'Subtribe' => 'subtribe',
    'Genus' => 'genus', 'Subgenus' => 'subgenus', 'subgenus' => 'subgenus',
);

sub parse_staphylinidae {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $text = read_pdf_text($path, 7, 109);
        my @recs = fold_pdf_lines($text,
            sub {
                my ($l) = @_;
                return 1 if $l =~ /\A(?:Family|Subfamily|Tribe|Subtribe|Genus|[Ss]ubgenus)\s+[A-Z]/;
                return 1 if $l =~ /\A=\s/;
                return 1 if $l =~ /\A[a-z][a-z-]*(?:\s|\z)/;
                return 1 if $l =~ /\A[a-z]\.\s/;
                return 0;
            },
            sub {
                my ($l) = @_;
                return 1 if $l =~ /\A[\d\s]+\z/;
                return 1 if $l =~ /University Museum|The Kyushu|Catalogue of Japanese Staphylinidae/;
                return 1 if $l =~ /\A日本産ハネカクシ科総目録/;
                # ページ上部の著者行。日本語で始まるので継続行として連結されてしまう
                return 1 if $l =~ /\A柴田泰利・/;
                return 1 if $l =~ /\AYasutoshi Shibata,/;
                return 0;
            });

        my $genus    = '';
        my $species  = '';
        my $last_jap = '';
        for my $rec (@recs) {
            if ($rec =~ /\A([A-Za-z]+)\s+([A-Z][A-Za-z-]*)/ && exists $STAPH_KEYWORD{$1}) {
                my ($word, $name) = ($1, $2);
                my $jap = japanese_run($rec, 0);
                $genus = $name if $STAPH_KEYWORD{$word} eq 'genus';
                $last_jap = $jap;
                add_pair(\@out, $jap, $name, rk($STAPH_KEYWORD{$word}), 1);
                next;
            }
            next unless length $genus;
            my $scivalid = 1;
            my $body = $rec;
            if ($body =~ s/\A=\s*//) { $scivalid = 0 }
            # 「= 」の行に和名はないので直前の有効名の和名を引き継ぐ
            # 頭文字省略の種小名を直前の種名で展開する
            $body =~ s/\A([a-z])\.\s+/staph_expand($species, $1)/e;
            my @ep;
            push @ep, $1 while $body =~ /\G([a-z][a-z-]*)\s+/gc;
            next unless @ep;
            my $sci  = join ' ', $genus, @ep;
            my $rank = @ep >= 2 ? rk('subspecies') : rk('species');
            my $jap  = japanese_run($rec, 0);
            if ($scivalid) {
                $species  = $ep[0];
                $last_jap = $jap;
            }
            else { $jap = $last_jap unless length $jap }
            add_pair(\@out, $jap, $sci, $rank, 1, scivalid => $scivalid);
        }
    }
    return \@out;
}

sub staph_expand {
    my ($species, $initial) = @_;
    return "$species " if length $species && substr($species, 0, 1) eq $initial;
    return "$initial. ";
}

#-----------------------------------------------------------------------------
# 日本産蘚類チェックリスト Hattoria 7: 9-223 (PDF p.4〜203)
#
# レコードは列0から始まり、継続行は5〜6桁の字下げになっている。
# 「= 」で有効名が明示されるシノニムが 2,382 件あり、属和名・種和名・変種和名が
# 安定して取れる。属の行は「Genus 著者 (科名). 和名属.」の形。
#-----------------------------------------------------------------------------
sub parse_hattoria7 {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $text = read_pdf_text($path, 4, 203);
        my @recs = fold_pdf_lines($text,
            sub { my ($l) = @_; return $_[0] =~ /\A[A-Z\x{00C0}-\x{024F}][A-Za-z\x{00C0}-\x{024F}-]+\s/ ? 1 : 0 },
            sub { my ($l) = @_; return $l =~ /\A[\d\s]+\z/ ? 1 : 0 });

        my %jap_of;
        my @pending;
        my $genus = '';
        for my $rec (@recs) {
            my ($head) = $rec =~ /\A([A-Z][A-Za-z\x{00C0}-\x{024F}-]+)/;
            $genus = $head if defined $head;
            my $jap = norm_japname(japanese_run($rec, 1));
            $jap = '' if length $jap && $jap =~ /\A[（(]/;

            if ($rec =~ /(.*?)\s=\s(.*)/s) {
                my ($left, $right) = ($1, $2);
                my $syn = norm_sciname($left);
                $right =~ s/,\s*fide\b.*\z//s;
                $right =~ s/\A([A-Z])\.\s+/hattoria_expand($genus, $1)/e;
                my $acc = norm_sciname($right);
                next unless length $syn && length $acc;
                push @pending, [ $syn, $acc ];
                next;
            }
            my $sci = norm_sciname($rec);
            next unless length $sci;
            my $rname = jap_rank_suffix((split_japsyn($jap))[0]);
            my ($rank, $subrank) = defined $rname ? (rk($rname), 1) : rank_from_sciname($sci);
            add_pair(\@out, $jap, $sci, $rank, $subrank);
            my ($h) = split_japsyn($jap);
            $jap_of{$sci} = $h if length $h && !exists $jap_of{$sci};
        }
        for my $p (@pending) {
            my ($syn, $acc) = @$p;
            my $jap = $jap_of{$acc};
            next unless defined $jap && length $jap;
            my ($rank, $subrank) = rank_from_sciname($syn);
            add_pair(\@out, $jap, $syn, $rank, $subrank, scivalid => 0);
        }
    }
    return \@out;
}

sub hattoria_expand {
    my ($genus, $initial) = @_;
    return "$genus " if length $genus && substr($genus, 0, 1) eq $initial;
    return "$initial. ";
}

#-----------------------------------------------------------------------------
# 日本産タイ類・ツノゴケ類チェックリスト Hattoria 9: 53-102 (PDF p.3〜26)
#
# 「1．日本産タイ類の分類表」から「5．注釈」の手前までが名前の一覧で、
# 行はすべて「学名 著者 和名 [注番号]」の形をしている。分類表の和名接尾辞が
# そのまま階層を示す。学名にリガチャが混入する行があるので正規化が要る。
#
# 本体には有効名しか載っていないので scivalid は常に 1。§5 の注釈にはシノニムの
# 記述があるが日本語の散文で、機械的に取り出すと誤った対応を作るため使わない。
#-----------------------------------------------------------------------------
sub parse_hattoria9 {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $text = read_pdf_text($path, 3, 26);
        my $started = 0;
        my @recs;
        for my $raw (split /\n/, $text) {
            my $line = fixup_chars($raw);
            $line =~ s/\x{000C}//g;
            my $t = trim($line);
            next unless length $t;
            if ($t =~ /\A(\d)．/) {
                my $n = $1;
                last if $n >= 5;
                $started = 1;
                next;
            }
            next unless $started;
            next if $t =~ /\A[\d\s]+\z/;
            if ($t =~ /\A[A-Z\x{00C0}-\x{024F}][A-Za-z\x{00C0}-\x{024F}.-]*\s/) { push @recs, $t }
            elsif (@recs) { $recs[-1] .= $t }
        }
        for my $rec (@recs) {
            (my $r = $rec) =~ s/\s*\[\d+\]\s*\z//;
            my $jap = norm_japname(japanese_run($r, 1));
            my $sci = norm_sciname($r);
            next unless length $sci && length $jap;
            my $rname = jap_rank_suffix((split_japsyn($jap))[0]);
            my ($rank, $subrank) = defined $rname ? (rk($rname), 1) : rank_from_sciname($sci);
            add_pair(\@out, $jap, $sci, $rank, $subrank);
        }
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 日本産有剣膜翅類目録 2016年版 (PDF p.12〜128)
#
# 有効名かシノニムかは「和名を持つか」で決める。字下げは不安定で、ページを
# 跨ぐと失われるため使えない。属和名は原典に存在しない。
# 「F amily」のような字送りの分解と、見出しの「カ マ バ チ 科」のような
# 1文字ずつの分解に対処する。「:」「nec」「[Misidentification.]」を含む行は
# 誤同定の記録なので捨てる。
#-----------------------------------------------------------------------------
my %ACULEATA_KEYWORD = (
    'Order' => 'order', 'Suborder' => 'suborder', 'Infraorder' => 'infraorder',
    'Superfamily' => 'superfamily', 'Family' => 'family', 'Subfamily' => 'subfamily',
    'Tribe' => 'tribe', 'Subtribe' => 'subtribe', 'Genus' => 'genus',
);

sub parse_aculeata {
    my ($src, $paths) = @_;
    my $keywords = join '|', keys %ACULEATA_KEYWORD;
    my @out;
    for my $path (@$paths) {
        my $text = read_pdf_text($path, 12, 128);
        my @recs = fold_pdf_lines($text,
            sub {
                my ($l) = @_;
                return 1 if $l =~ /\A[A-Z]/;
                return 0;
            },
            sub {
                my ($l) = @_;
                return 1 if $l =~ /\A[\d\s]+\z/;
                return 1 if $l =~ /\A目\s*録\z/;
                return 0;
            });

        for my $rec (@recs) {
            my $line = despace_latin($rec);
            # 誤同定の記録だけを落とす。全角コロンは分布欄にも現れるので条件にしない。
            next if $line =~ /\bnec\b|\[Misidentification/;
            if ($line =~ /\A($keywords)(?:-group)?\s+([A-Z][A-Za-z-]+)/) {
                my ($word, $name) = ($1, $2);
                my $jap = despace_japanese(japanese_run($line, 0));
                add_pair(\@out, $jap, $name, rk($ACULEATA_KEYWORD{$word}), 1);
                next;
            }
            next unless $line =~ /\A[A-Z][a-z]+\s+[a-z]/;
            my $jap = despace_japanese(japanese_run($line, 0));
            next unless length $jap;
            my $sci = norm_sciname($line);
            next unless length $sci;
            # この情報源は和名の別名を「・」で併記する
            add_pair(\@out, $jap, $sci, undef, undef, seps => '，、,・');
        }
    }
    return \@out;
}

# 「F amily」のように字送りで分解されたラテン語の見出しを繋ぎ直す。
sub despace_latin {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\A([A-Z])\s([a-z]{2,})\b/$1$2/;
    return $s;
}

# 「カ マ バ チ 科」のように1文字ずつ分かち書きされた和名を繋ぎ直す。
sub despace_japanese {
    my ($s) = @_;
    return '' unless defined $s;
    1 while $s =~ s/([\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}])\s+(?=[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}])/$1/;
    return $s;
}

#-----------------------------------------------------------------------------
# Catalogue of Life (ColDP)
#
# ColDP の配布 zip から展開した NameUsage.tsv (約3GB) と VernacularName.tsv を
# 突き合わせる。和名は VernacularName.tsv の language が jpn の行にあり (99,738件)、
# taxonID で NameUsage.tsv の学名・階級・status に結び付く。
#
# NameUsage.tsv は巨大なので :encoding(UTF-8) を通さずバイト列のまま行を読み、
# 必要な ID の行だけを split して該当フィールドを decode する。
# シノニムの有効名は parentID の先にあるので2周する。
#
# エントリごとに sourceID (提供元データセット) があり、README の規定により
# その提供元を出典として出す。提供元のメタデータは書庫の source/<ID>.yaml に
# あるので、必要なものだけを1回のストリーム走査で読む (21,409 ファイルあるため
# 展開はしない)。sourceID が空の行は Catalogue of Life 自体を出典にする。
#-----------------------------------------------------------------------------
sub parse_col {
    my ($src, $paths) = @_;
    my ($usage, $vern);
    for my $p (@$paths) {
        $usage = $p if basename($p) eq 'NameUsage.tsv';
        $vern  = $p if basename($p) eq 'VernacularName.tsv';
    }
    die "NameUsage.tsv と VernacularName.tsv が揃っていません\n" unless $usage && $vern;

    my %jap;
    open my $vh, '<', $vern or die "読めません: $vern: $!\n";
    binmode $vh;
    my $vhdr = <$vh>;
    while (my $line = <$vh>) {
        chomp $line;
        my @f = split /\t/, $line, 6;
        next unless @f >= 5;
        next unless $f[4] eq 'jpn' || $f[4] eq 'ja';
        push @{ $jap{ $f[0] } },
            [ Encode::decode('UTF-8', $f[2], Encode::FB_DEFAULT), $f[1] ];
    }
    close $vh;

    my (%rec, %need);
    col_scan($usage, \%jap, sub {
        my ($id, $f) = @_;
        my $parent = defined $f->[4] ? $f->[4] : '';
        my $status = defined $f->[6] ? $f->[6] : '';
        $rec{$id} = [
            Encode::decode('UTF-8', (defined $f->[7] ? $f->[7] : ''), Encode::FB_DEFAULT),
            (defined $f->[9] ? $f->[9] : ''),
            $status,
            (defined $f->[3] ? $f->[3] : ''),
            $parent,
        ];
        $need{$parent} = 1 if length $parent && $COL_INVALID_STATUS{$status};
    });
    delete $need{$_} for keys %rec;

    my %accepted;
    if (%need) {
        col_scan($usage, \%need, sub {
            my ($id, $f) = @_;
            $accepted{$id} =
                Encode::decode('UTF-8', (defined $f->[7] ? $f->[7] : ''), Encode::FB_DEFAULT);
        });
    }

    # 必要な提供元だけメタデータを読む
    my %srcids;
    for my $id (keys %rec) {
        my $usrc = $rec{$id}[3];
        $srcids{$usrc} = 1 if length $usrc;
        for my $j (@{ $jap{$id} }) { $srcids{ $j->[1] } = 1 if length $j->[1] }
    }
    my $zip = File::Spec->catfile(dirname($usage), $src->{unzip}[0]);
    my $meta = col_read_sources($zip, \%srcids);

    my @out;
    for my $id (keys %rec) {
        my ($sci, $crank, $status, $usrc, $parent) = @{ $rec{$id} };
        next unless length $sci;
        my ($rank, $subrank) = exists $COL_RANK{$crank}
                             ? (rk($COL_RANK{$crank}), 1)
                             : rank_from_sciname(norm_sciname($sci));
        my $valid = $COL_INVALID_STATUS{$status} ? 0 : 1;
        my $acc = (!$valid && length $parent)
                ? (exists $accepted{$parent} ? $accepted{$parent}
                                             : ($rec{$parent} ? $rec{$parent}[0] : ''))
                : '';
        for my $j (@{ $jap{$id} }) {
            my ($name, $vsrc) = @$j;
            my $sid  = length $vsrc ? $vsrc : $usrc;
            my $info = (length $sid && $meta->{$sid}) ? $meta->{$sid} : undef;
            add_pair(\@out, $name, $sci, $rank, $subrank,
                     scivalid => $valid, srcinfo => $info);
            add_pair(\@out, $name, $acc, $rank, $subrank, srcinfo => $info)
                if !$valid && length $acc && $acc ne $sci;
        }
    }
    return \@out;
}

# 1列目の ID が %$want にある行だけを split してコールバックへ渡す。
sub col_scan {
    my ($path, $want, $cb) = @_;
    open my $fh, '<', $path or die "読めません: $path: $!\n";
    binmode $fh;
    my $hdr = <$fh>;
    while (my $line = <$fh>) {
        my $tab = index($line, "\t");
        next if $tab < 1;
        my $id = substr($line, 0, $tab);
        next unless exists $want->{$id};
        chomp $line;
        my @f = split /\t/, $line, 11;
        $cb->($id, \@f);
    }
    close $fh;
}

# 書庫の source/<ID>.yaml を1回のストリーム走査で読む。
# 戻り値は sourceID => [sourcetitle, sourceauthor, sourceurl]。
sub col_read_sources {
    my ($zip, $want) = @_;
    my %out;
    return \%out unless -f $zip && %$want;
    my $z = IO::Uncompress::Unzip->new($zip, MultiStream => 0) or return \%out;
    for (my $status = 1; $status > 0; $status = $z->nextStream) {
        my $name = $z->getHeaderInfo->{Name};
        next unless defined $name && $name =~ m{\Asource/(\d+)\.yaml\z};
        my $id = $1;
        next unless $want->{$id};
        my $buf = '';
        my $chunk;
        $buf .= $chunk while $z->read($chunk, 65536) > 0;
        $out{$id} = col_parse_source_yaml(Encode::decode('UTF-8', $buf, Encode::FB_DEFAULT), $id);
    }
    $z->close;
    return \%out;
}

# ColDP の source/<ID>.yaml から出典に使う3つを取り出す。
# YAML の完全な解釈はせず、必要なキーだけを拾う。ただし title や description は
# 複数行にわたる二重引用符付きスカラで書かれることがあるので、そこだけは畳む。
sub col_parse_source_yaml {
    my ($text, $id) = @_;
    my @lines = split /\n/, $text, -1;
    my (%scalar, %people, $block);
    my $i = 0;
    while ($i <= $#lines) {
        my $line = $lines[$i];
        if ($line =~ /\A([A-Za-z]+):\s*(.*)\z/) {
            my ($key, $val) = ($1, $2);
            if ($val =~ /\A"/) { ($val, $i) = col_yaml_quoted($val, \@lines, $i) }
            $val = trim($val);
            $scalar{$key} = $val if length $val && !exists $scalar{$key};
            $block = (!length $val && $key =~ /\A(?:author|editor|creator|contact)\z/)
                   ? $key : undef;
            $i++;
            next;
        }
        if (defined $block) {
            if ($line =~ /\A\s+-\s*\z/) { push @{ $people{$block} }, {} }
            elsif ($line =~ /\A\s+(given|family|organisation):\s*(.*)\z/) {
                my ($what, $val) = ($1, $2);
                $val =~ s/\A"(.*)"\z/$1/;
                $val = trim($val);
                push @{ $people{$block} }, {} unless @{ $people{$block} || [] };
                $people{$block}[-1]{$what} = $val if length $val;
            }
            elsif ($line !~ /\A\s/) { $block = undef }
        }
        $i++;
    }

    my (@authors, $org);
    for my $key ('author', 'editor', 'creator', 'contact') {
        next unless $people{$key};
        for my $p (@{ $people{$key} }) {
            my $name = join ' ', grep { defined && length } ($p->{given}, $p->{family});
            push @authors, $name if length $name;
            $org = $p->{organisation} if !defined $org && defined $p->{organisation};
        }
        last if @authors;
    }
    # 人名が書かれていないデータベースは団体名、それも無ければ表題を著者に使う
    @authors = ($org) if !@authors && defined $org && length $org;
    @authors = ($scalar{title}) if !@authors && defined $scalar{title} && length $scalar{title};

    my $url = defined $scalar{url} && length $scalar{url} ? $scalar{url}
            : defined $scalar{doi} && length $scalar{doi} ? "https://doi.org/$scalar{doi}"
            : "https://www.checklistbank.org/dataset/$id";
    return [ (defined $scalar{title} ? $scalar{title} : ''), format_authors(\@authors), $url ];
}

# 二重引用符付きスカラを畳む。行末の「\」は改行も空白も入れない継続を表す。
sub col_yaml_quoted {
    my ($first, $lines, $i) = @_;
    my $buf = $first;
    while ($buf !~ /\A"(?:[^"\\]|\\.)*"\s*\z/ && $i < $#$lines) {
        $i++;
        (my $next = $lines->[$i]) =~ s/\A\s+//;
        if   ($buf =~ s/\\\z//) { $buf .= $next }
        else                    { $buf .= ' ' . $next }
    }
    $buf =~ s/\A"//;
    $buf =~ s/"\s*\z//;
    $buf =~ s/\\ / /g;
    $buf =~ s/\\n/\n/g;
    $buf =~ s/\\"/"/g;
    $buf =~ s/\\\\/\\/g;
    return ($buf, $i);
}

#-----------------------------------------------------------------------------
# Wikidata (QLever で取得した CSV)
#
# 列は qid / sci / ja / ranks / ranks_ja / parents / aliases / commons。
# ranks_ja が日本語の階級名 (種・属・科…) なので rank はそこから決める。
# aliases (skos:altLabel) と commons (P1843) は和名シノニムとして出す。
# 有効名／シノニムの情報は持たないので学名は常に有効名として扱う。
#-----------------------------------------------------------------------------
my %WIKIDATA_RANK = (
    '界' => 'kingdom', '亜界' => 'subkingdom',
    '上門' => 'superphylum', '門' => 'phylum', '亜門' => 'subphylum',
    '上綱' => 'superclass', '綱' => 'class', '亜綱' => 'subclass', '下綱' => 'infraclass',
    '上目' => 'superorder', '目' => 'order', '亜目' => 'suborder',
    '下目' => 'infraorder', '小目' => 'parvorder',
    '上科' => 'superfamily', '科' => 'family', '亜科' => 'subfamily',
    '族' => 'tribe', '亜族' => 'subtribe',
    '属' => 'genus', '亜属' => 'subgenus', '節' => 'section', '連' => 'tribe',
    '種' => 'species', '亜種' => 'subspecies',
    '変種' => 'varietas', '品種' => 'forma',
    '系統群' => 'clade', 'クレード' => 'clade',
);

sub parse_wikidata {
    my ($src, $paths) = @_;
    require Text::CSV;
    my @out;
    for my $path (@$paths) {
        my $csv = Text::CSV->new({ binary => 1, auto_diag => 0 });
        open my $fh, '<:encoding(UTF-8)', $path or die "読めません: $path: $!\n";
        my $hdr = $csv->getline($fh) or next;
        my %ix;
        $ix{ $hdr->[$_] } = $_ for 0 .. $#$hdr;
        while (my $r = $csv->getline($fh)) {
            my $get = sub { my ($k) = @_;
                            return exists $ix{$k} && defined $r->[$ix{$k}] ? $r->[$ix{$k}] : '' };
            my $sci = norm_sciname($get->('sci'));
            my $jap = $get->('ja');
            next unless length $sci && length $jap;
            my ($rank, $subrank);
            for my $r_ja (split /\|/, $get->('ranks_ja')) {
                next unless exists $WIKIDATA_RANK{$r_ja};
                ($rank, $subrank) = (rk($WIKIDATA_RANK{$r_ja}), 1);
                last;
            }
            ($rank, $subrank) = rank_from_sciname($sci) unless defined $rank;
            add_pair(\@out, $jap, $sci, $rank, $subrank);
            my $head = (split_japsyn($jap))[0];
            for my $col ('aliases', 'commons') {
                for my $a (split /\|/, $get->($col)) {
                    next unless looks_japanese($a);
                    next if (split_japsyn($a))[0] eq $head;
                    add_pair(\@out, $a, $sci, $rank, $subrank, japvalid => 0);
                }
            }
        }
        close $fh;
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 日本産地衣類および関連菌類の高次分類群 (HTML)
#
# 罫線文字 (｜ －) と全角空白による木構造で「学名 [*] 和名」を並べたページ。
# 字下げの深さは使わず、和名の接尾辞 (門/綱/亜綱/目/科/属) で rank を決める。
# 「*」は日本産の種を含む属などを示す印なので学名から取り除く。
#-----------------------------------------------------------------------------
sub parse_lichen_systematics {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my $html = read_html($path);
        $html =~ s{<br\s*/?>}{\n}gi;
        $html =~ s{</(?:p|div|li|h[1-6])>}{\n}gi;
        my $text = html_unescape(($html =~ s{<[^>]*>}{}gsr));
        for my $raw (split /\n/, $text) {
            my $line = fixup_chars($raw);
            $line =~ s/\x{3000}/ /g;
            $line =~ s/\A[\s\x{FF5C}\x{FF0D}|\-]+//;
            # 「(Syn.: Dolichousnea)」「（“ピンタケ目”の和名は却下）」は注記であって
            # 和名の別名ではないので、括弧ごと落としてから切り分ける。
            $line =~ s/[（(][^）)]*(?:Syn\.|却下)[^）)]*[）)]//g;
            $line = squeeze($line);
            next unless $line =~ /\A([A-Z][A-Za-z-]+)\s*\*?\s+(.+)\z/;
            my ($sci, $jap) = ($1, $2);
            next unless looks_japanese($jap);
            # 門のような上位の行は総大文字で書かれている
            $sci = ucfirst(lc $sci) if $sci =~ /\A[A-Z-]+\z/;
            my ($head) = split_japsyn($jap);
            my $rname = jap_rank_suffix($head);
            my ($rank, $subrank) = defined $rname ? (rk($rname), 1)
                                                  : rank_from_sciname($sci);
            add_pair(\@out, $jap, $sci, $rank, $subrank);
        }
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# ウイルス種名・英名・和名対応リスト (xlsx 2ファイル)
#
# ICTV の VMR (Virus Metadata Resource) MSL39 v1 に和名の列を足したもの。
# 植物・藻類・菌類のファイルは列名が「ウイルス和名」、ヒト動物のファイルは「和名」。
# Realm〜Genus の列はラテン名だけで和名がないため、種の行だけが出力に寄与する。
#-----------------------------------------------------------------------------
sub parse_jsv_virus {
    my ($src, $paths) = @_;
    my @out;
    for my $path (@$paths) {
        my ($ic_sp, $ic_ja);
        my $first = 1;
        read_xlsx($path, 0, sub {
            my ($rn, $c) = @_;
            my @f = map { defined $_ ? squeeze($_) : '' } @$c;
            if ($first) {
                $first = 0;
                for my $i (0 .. $#f) {
                    $ic_sp = $i if $f[$i] eq 'Species';
                    $ic_ja = $i if !defined $ic_ja && ($f[$i] eq 'ウイルス和名' || $f[$i] eq '和名');
                }
                return;
            }
            return unless defined $ic_sp && defined $ic_ja;
            my ($sci, $jap) = ($f[$ic_sp] // '', $f[$ic_ja] // '');
            return unless length $sci && length $jap;
            my ($rank, $subrank) = rank_from_sciname($sci);
            add_pair(\@out, $jap, $sci, $rank, $subrank, rawsci => 1);
        });
        note($src, '列を特定できませんでした: ' . relname($path))
            unless defined $ic_sp && defined $ic_ja;
    }
    return \@out;
}

#-----------------------------------------------------------------------------
# 外部の分類データベースによる学名の有効性判定 (全ディレクトリ共通)
#
# README の規定により、有効名／シノニムの判定は Catalogue of Life を基本とする。
# CoL が知っている学名は CoL の col:status で決め、CoL にない学名で
# ソース間の判定が食い違っているものだけ NCBI Taxonomy の name class で決める。
#
# 全ディレクトリの中間 TSV から学名を集めてから1回だけ走査する。NameUsage.tsv は
# 約3GB・1千万行あるので、比較は UTF-8 のバイト列のまま行い decode しない。
# ファイルが無ければその段を飛ばすので、AllTaxa を取得していなくても動く。
#-----------------------------------------------------------------------------
sub collect_scinames {
    my ($sources) = @_;
    my %names;
    for my $src (@$sources) {
        my $path = intermediate_path($src);
        next unless -e $path;
        open my $fh, '<', $path or next;
        binmode $fh;
        while (my $line = <$fh>) {
            my $i = index($line, "\t");
            next if $i < 1;
            my $j = index($line, "\t", $i + 1);
            next if $j < 0;
            $names{ substr($line, $i + 1, $j - $i - 1) } = 1;
        }
        close $fh;
    }
    return \%names;
}

sub external_validity {
    my ($name_bytes) = @_;
    my (%col, %ncbi);
    return (\%col, \%ncbi) unless %$name_bytes;

    my $usage = File::Spec->catfile($basedir, 'AllTaxa', 'NameUsage.tsv');
    if (-f $usage) {
        open my $fh, '<', $usage or die "読めません: $usage: $!\n";
        binmode $fh;
        my $hdr = <$fh>;
        while (my $line = <$fh>) {
            chomp $line;
            my @f = split /\t/, $line, 11;
            next unless defined $f[7] && exists $name_bytes->{ $f[7] };
            my $valid = $COL_INVALID_STATUS{ defined $f[6] ? $f[6] : '' } ? 0 : 1;
            # 同じ学名が別の提供元で有効名としても載っていれば有効名を採る
            $col{ $f[7] } = $valid if !exists $col{ $f[7] } || $valid;
        }
        close $fh;
    }

    my $dmp = File::Spec->catfile($basedir, 'NCBITaxonomy', 'names.dmp');
    if (-f $dmp) {
        open my $fh, '<', $dmp or die "読めません: $dmp: $!\n";
        binmode $fh;
        while (my $line = <$fh>) {
            chomp $line;
            my @f = split /\s*\|\s*/, $line, 5;
            next unless defined $f[1] && exists $name_bytes->{ $f[1] };
            my $valid = (defined $f[3] && $f[3] eq 'scientific name') ? 1 : 0;
            $ncbi{ $f[1] } = $valid if !exists $ncbi{ $f[1] } || $valid;
        }
        close $fh;
    }

    # バイト列のキーを文字列のキーに直す
    my (%colc, %ncbic);
    $colc{ Encode::decode('UTF-8', $_, Encode::FB_DEFAULT) }  = $col{$_}  for keys %col;
    $ncbic{ Encode::decode('UTF-8', $_, Encode::FB_DEFAULT) } = $ncbi{$_} for keys %ncbi;
    return (\%colc, \%ncbic);
}

#-----------------------------------------------------------------------------
# 実行 (ファイル末尾に置く。上のサブルーチン群が使う表の代入を先に済ませるため)
#-----------------------------------------------------------------------------
printf "対象ディレクトリ: %s\n", $basedir;
printf "VERSION=%s BUILDDATE=%s\n", $VERSION, $BUILDDATE;
print "(dry-run: 入力ファイルの存在確認だけを行います)\n" if $dry_run;

for my $src (@selected) {
    printf "\n--- %s/%s: %s ---\n", $src->{dir}, $src->{id}, $src->{desc};
    do_source($src);
}

unless ($dry_run) {
    my @dirs = uniq(map { $_->{dir} } @selected);
    my @all  = grep { my $d = $_->{dir}; grep { $_ eq $d } @dirs } @SOURCES;
    # 学名の有効性は Catalogue of Life を基本とする。巨大なファイルを何度も
    # 走査しないよう、全ディレクトリ分の学名を集めてから1回だけ引く。
    my ($colv, $ncbiv) = external_validity(collect_scinames(\@all));
    for my $dir (@dirs) {
        merge_directory($dir, [ grep { $_->{dir} eq $dir } @SOURCES ], $colv, $ncbiv);
    }
    cleanup_intermediates(\@selected) unless $keep;
}

report_summary();
exit($n_fail ? 1 : 0);

