# JBTaxon

A database of Japanese biological taxon names

## JBTaxonの生成について

JBTaxonが情報源にしている生物種名チェックリストのうちのいくつかは、再配布が禁止されている。そのため、JBTaxon自体を配布することができない。そこで、

1. データファイルをダウンロード
2. 和名→学名および学名→和名テーブルのTSVを生成
3. 和名→学名および学名→和名変換テーブルを持つSQLite3 DBを生成
4. 和名読み→和名および和名読み→学名を日本語入力IMEで実現する辞書ファイルTSV (汎用・Mozcユーザー辞書用・Mozcシステム辞書用・Gboard単語リスト用)を生成

をそれぞれ行うスクリプトを本リポジトリで配布し、各ユーザーが自ら自分に必要なファイルをローカル環境で生成して使用するものとする。

## 各スクリプトについて

1. `fetch_data.pl`
  - 各ディレクトリに生データファイルをダウンロードする
2. `generate_tables.pl`
  - 各ディレクトリ内で生データファイルから和名→学名および学名→和名テーブルのTSVを生成する
3. `generate_database.pl`
  - 和名→学名および学名→和名テーブルのTSVから単一の`jbtaxon_VERSION_BUILDDATE.sqlite3`を生成する
  - Catalogue of LifeとNCBI Taxonomyの分類体系全体もDBに格納し、和名と学名の組をそれぞれの体系の節点に結び付ける
4. `generate_dictionary.pl`
  - 和名→学名および学名→和名テーブルのTSVから和名読み→和名および和名読み→学名を日本語入力IMEで実現する単一の辞書ファイルTSVを生成する
5. `add_to_yomi.pl`
  - 和名→学名テーブルから、既存の`yomi.tsv`にyomiデータが存在しないためyomiを自動生成できない和名を検出して`yomi.tsv`の末尾にyomi空欄でjapnameを追加する
6. `sciname2japname.pl`
  - 学名をクエリとして`jbtaxon_VERSION_BUILDDATE.sqlite3`のsciname2japnameテーブルを検索し、和名を返す
7. `japname2sciname.pl`
  - 和名をクエリとして`jbtaxon_VERSION_BUILDDATE.sqlite3`のjapname2scinameテーブルを検索し、学名を返す

なお、種より上位の高次分類群(科や門など)や、種より下位の低次分類群(亜種・品種など)の和名・学名も生データファイルに含まれていれば出力します。

## 分類群和名の読みについて

分類群和名の漢字表記の読みに関しては以下のソースには十分に含まれていません。そのため、本リポジトリの`yomi.tsv`にて提供するものとします。フォーマットは以下の通りです。

```
yomi    japname
```

`generate_tables.pl`実行後に`add_to_yomi.pl`を実行することで、和名→学名テーブルから、既存の`yomi.tsv`にyomiデータが存在しないためyomiを自動生成できない和名を検出して`yomi.tsv`の末尾にyomi空欄でjapnameが追加されます。筆者が手動でそこにyomiを追加して本リポジトリの`yomi.tsv`を更新していきます。

## 種名チェックリストについて

以下にソースとなるチェックリストを全て掲載します。なお、同じ分類群ディレクトリ内の複数のソース間で衝突する場合は、(1) より狭い分類群のソースを優先、(2) 次いでより新しいソースを優先します。ただし、ディレクトリ内の学名の有効名とシノニムの判定には、Catalogue of Lifeを基本としつつ「より新しいソースか」だけを用い、より狭い分類群のソースかどうかは考慮しません。Catalogue of Lifeとその他ソースで学名の有効名が決められない場合、NCBI Taxonomyを使用します。分類群ディレクトリ間で衝突する場合は、AllTaxaとその他のディレクトリではその他のディレクトリを、LichensとSeaweeds・LichensとFungiではSeaweeds・Fungiを優先し、それ以外の組み合わせは比較せずに全て残します。ただし、優先する側に従うのは、優先する側が同じ和名と学名の組を持つ場合に限ります。和名の有効名の判定には、種以下のレベルでは「カナ名」を必須(ただしカナ文字以外が付いてもよい)、「階層レベルを示す単語」は付いていても構わないものとし、種より上の高次分類群名では「カナ名」(ただしカナ文字以外が付いてもよい)と「階層レベルを示す単語」の組み合わせを必須とします。「階層レベルを示す単語」は「rank・subrankについて」の項で示してあります。末尾が「類」の和名(「アメマス類」「真正双子葉類」など)は階層によらず有効名としません。ただし、ある学名に有効な和名が1つも無い場合に限り、末尾に「階層レベルを示す単語」が付いた和名を「カナ名」でなくても有効名とします(「Mammalia」に対する「哺乳綱」など)。このとき、ソースが有効名とした和名を優先し、それが無ければソースがシノニムとした和名を用います。その上で、同じ分類群ディレクトリ内の複数のソース間で衝突する場合は、(1) より狭い分類群のソースを優先、(2) 次いでより新しいソースを優先します。分類群ディレクトリ間の衝突は上記と同様に扱います。雑種の和名(「ヤマメxニジマス」のように和名を「x」で繋いだもの)は、学名が雑種を表すもの(「Rumex crispus x japonicus」のような雑種式や「Fallopia x bohemica」のような雑種の名前)である場合に限って出力し、学名が雑種式の場合は和名→学名テーブルにのみ出力します。また、種内の下位分類群(亜種・変種・品種など)の有効な和名は、その種の学名に対する和名としても学名→和名テーブルに出力します(種の行が無いソースでも出力します)。

### 全体 (AllTaxa)

#### 河川水辺の国勢調査のための生物リスト (国土交通省 国土技術政策総合研究所)

以下のURLで提供されているExcelファイルがデータファイルです(令和元年度以降の「全生物種」)。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://www.nilim.go.jp/lab/fbg/ksnkankyo/mizukokuweb/system/seibutsuListfile.htm

#### Catalogue of Life (2026-09-25 XR) (Olaf Bánki et al.)

以下のURLから取得できるzipファイルがデータファイルを含む配布ファイルです。`fetch_data.pl`が実行されると自動的に`AllTaxa/2026-09-25_xr_coldp.zip`としてダウンロードされます。

- https://download.checklistbank.org/col/monthly/2026-09-25_xr_coldp.zip

#### Wikidata (Wikidata contributors)

以下のURLで提供されているデータのメタデータを使用します。`fetch_data.pl`が実行されると`AllTaxa/wikidata.rq`をクエリとして[QLever](https://qlever.dev/wikidata)からメタデータを取得してCSVファイル`AllTaxa/wikidata.csv`として保存します。

- https://www.wikidata.org/

### 哺乳類 (Mammals)

#### 世界哺乳類標準和名リスト (川田 伸一郎・岩佐 真宏・福井 大・新宅 勇太・天野 雅男・下稲葉 さやか・樽 創・姉崎 智子・鈴木 聡・押田 龍夫・横畑 泰志)

利用規約に同意する必要があるため、`fetch_data.pl`でダウンロードできません。以下のURLから手動でダウンロードして`Mammals`ディレクトリ内に配置して下さい(配布されているzipファイルのままで構いません。zipファイルは自動的に展開します)。

- https://www.mammalogy.jp/list/index.html

### 爬虫類・両生類 (Reptiles_Amphibians)

#### 日本産爬虫両生類標準和名リスト (日本爬虫両棲類学会)

以下のURLのHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://herpetology.jp/wamei/index_j.php

### 魚類 (Fishes)

#### 日本産魚類全種目録 ver. 42 (2026年8月27日版) (本村 浩之)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://www.museum.kagoshima-u.ac.jp/staff/motomura/jaf.html

### 昆虫 (Insects)

#### 昆虫情報データベース (国立研究開発法人農業・食品産業技術総合研究機構 農業環境変動研究センター 環境情報基盤研究領域 昆虫分類評価ユニット)

以下のURLとリンク先のHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://insect-web.rad.naro.go.jp/flame/tree

#### 滋賀県昆虫目録2025 (滋賀県昆虫目録作成グループ)

以下のURLで提供されているGoogle Spreadsheetシートがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://sites.google.com/view/shigainsect/

#### List-MJ 日本産蛾類総目録 2021.6.3版 (神保 宇嗣)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- http://listmj.mothprog.com/

#### 日本産蝶類の学名リスト (長田 庸平)

以下のURLとリンク先のHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://japanesebutterfly.wixsite.com/butterfly-list

#### 日本産トビケラの種名一覧 (日本トビケラ情報ネットワーク)

以下のURLに埋め込まれているGoogle Spreadsheetシートがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://sites.google.com/view/tobikera/home/checklist

#### 日本産ハネカクシ科総目録（昆虫綱：甲虫目）(柴田 泰利・丸山 宗利・保科 英人・岸本 年郎・直海 俊一郎・野村 周平・Volker Puthz・島田 孝・渡辺 泰明・山本 周平)

以下のURLで提供されているPDFファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://doi.org/10.15017/26400

#### 日本産有剣膜翅類目録（2016 年版）(寺山 守)

以下のURLで提供されているPDFファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://web.archive.org/web/20220324223234/https://sc888fba2c6537423.jimcontent.com/download/version/1486475674/module/12561110890/name/Hym.list.%28Japan%292016.ver5.pdf

### クモ類 (Spiders)

#### 昆虫情報データベース (国立研究開発法人農業・食品産業技術総合研究機構 農業環境変動研究センター 環境情報基盤研究領域 昆虫分類評価ユニット)

以下のURLとリンク先のHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://insect-web.rad.naro.go.jp/flame/tree

#### クモ図鑑 (塩崎 哲哉)

以下のURLのリンク先の和名索引と、和名索引のリンク先にある各種のページHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://araneae.web.fc2.com/kumozukan/

### 線形動物 (Nematodes)

#### 昆虫情報データベース (国立研究開発法人農業・食品産業技術総合研究機構 農業環境変動研究センター 環境情報基盤研究領域 昆虫分類評価ユニット)

以下のURLとリンク先のHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://insect-web.rad.naro.go.jp/flame/tree

### タナイス類 (Tanaids)

#### 日本近海産タナイス類リスト (角井 敬知)

以下のURLのHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://sites.google.com/site/tnidjpn/tanaidacea/jpnlist

### ミミズ (Earthworms)

#### 日本産大型陸棲ミミズの種名一覧 (南谷 幸雄)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://japanese-mimizu.jimdofree.com/%E3%83%9F%E3%83%9F%E3%82%BA%E3%81%AE%E5%88%86%E9%A1%9E/

### ワラジムシ (Isopods)

#### 日本産ワラジムシ亜目種リスト (唐沢 重考)

以下のURLのHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://www.warajimushi.com/Species/List_species.html

### 維管束植物 (VascularPlants)

#### YList (米倉 浩司・梶田 忠)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- http://ylist.info/

#### FernGreenList ver. 2.0 (Atsushi Ebihara, Tao Fujiwara, Masayuki Takamiya, Motomi Ito, Tetsukazu Yahara)

以下のURLで提供されているCSVファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://doi.org/10.57400/data.bnmnsbot.22696618

### コケ植物 (Bryophytes)

#### A revised new catalog of the mosses of Japan (Tadashi Suzuki)

以下のURLで提供されているPDFファイルがデータファイルです。J-Stageからは自動ダウンロードが禁止されているので、手動でダウンロードしてディレクトリ内に配置して下さい。

- https://doi.org/10.18968/hattoria.7.0_9

#### 日本産タイ類・ツノゴケ類チェックリスト，2018 (片桐 知之・古木 達郎)

以下のURLで提供されているPDFファイルがデータファイルです。J-Stageからは自動ダウンロードが禁止されているので、手動でダウンロードしてディレクトリ内に配置して下さい。

- https://doi.org/10.18968/hattoria.9.0_53

### 地衣類 (Lichens)

#### Checklist of Lichens and Allied Fungi of Japan (Lichenological Society of Japan)

以下のURLのHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://lichenjapan.jp/checklist/

#### Classification of higher taxonomic groups of lichens and allied fungi in Japan (Lichenological Society of Japan)

以下のURLのHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://lichenjapan.jp/systematics/

### 真菌 (Fungi)

#### 日本産菌類チェックリスト (日本菌学会 データベース委員会)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://www.mycology-jp.org/html/checklist_clist.html

### 海藻 (Seaweeds)

#### 日本産海藻リスト (鈴木 雅大)

以下のURLとリンク先のHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://tonysharks.com/Seaweeds_list/Seaweed_list_top.html

### ウイルス (Viruses)

#### ウイルス種名・英名・和名対応リスト (日本ウイルス学会)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://jsv.umin.jp/news/news241125.html

## ファイルフォーマット

学名(sciname)の出力に使われる文字は、半角英数字、半角スペース、.(ピリオド)、-(ハイフン)、'(シングルクオート)です。他の文字は正規化でこれらの文字に置換されるか、異常と見なして行ごと削除されます。

和名(japname)の出力に使われる文字は、漢字、ひらがな、全角カナ、踊り字(々)、長音符(ー)、半角英数字、ギリシャ文字、記号(・(中黒)、-(ハイフン)、.(ピリオド))です。他の文字は正規化でこれらの文字に置換されるか、異常と見なして行ごと削除されます。

### 和名→学名テーブル (japname2sciname_VERSION_BUILDDATE.tsv)

```
japname    sciname    japvalid    rank    subrank    sourcetitle    sourceauthor    sourceurl
```

実際にはスペースではなくタブを区切りとして使用する。和名シノニムがある場合、scinameが同一でjapnameが異なる行が生じる。scinameにはシノニムは使用しない。ソースの学名がCatalogue of Lifeでシノニムとされている場合、Catalogue of Lifeの有効名に修正して採用します。japvalidは和名が有効名かどうかを示す(0はinvalidで1はvalid)。和名がシノニムなら0になる。rank・subrankについては後述。sourceurlは上記URLが出力される。sourcetitleはソースのタイトル。sourceauthorは作者名。ただし、Catalogue of Lifeの場合は該当するエントリごとにsourceIDがあるため、それに基づいてsourcetitle、sourceauthor、sourceurlを出力する。sourceauthorが3名以上の場合、日本語なら「～ら」、英語なら「～ et al.」として2人目以降を省略する。

### 学名→和名テーブル (sciname2japname_VERSION_BUILDDATE.tsv)

```
sciname    japname    scivalid    rank    subrank    sourcetitle    sourceauthor    sourceurl
```

実際にはスペースではなくタブを区切りとして使用する。学名シノニムがある場合、japnameが同一でscinameが異なる行が生じる。japnameにはシノニムは使用しない。scivalidは学名が有効名かどうかを示す(0はinvalidで1はvalid)。学名がシノニムなら0になる。rank・subrankについては後述。sourceurlは上記URLが出力される。sourcetitleはソースのタイトル。sourceauthorは作者名。ただし、Catalogue of Lifeの場合は該当するエントリごとにsourceIDがあるため、それに基づいてsourcetitle、sourceauthor、sourceurlを出力する。sourceauthorが3名以上の場合、日本語なら「～ら」、英語なら「～ et al.」として2人目以降を省略する。

### データベース (jbtaxon_VERSION_BUILDDATE.sqlite3)

`generate_database.pl`が全ディレクトリの和名→学名テーブルと学名→和名テーブルを集約して生成する。以下のテーブルを持つ。

- `japname2sciname` / `sciname2japname` — 上記の2つのテーブルに、行の由来の分類群ディレクトリを示す`taxondir`列を加えたもの。同じ組が複数のディレクトリにあればディレクトリごとに別の行になる。
- `rank` — `rank.def`の内容 (`rank`, `name`)。
- `meta` — `version`と`builddate`。
- `hierarchy_col` — Catalogue of Lifeの`NameUsage.tsv`の全行 (`id`, `parent`, `status`, `rank`, `name`, `authorship`, `alternativeid`, `namealternativeid`)。シノニムの`parent`は有効名を指す。`status`は有効名なら1、それ以外は0。
- `hierarchy_ncbi` — NCBI Taxonomyの節点 (`taxid`, `parent`, `rank`)。
- `names_ncbi` — NCBI Taxonomyの全ての名前 (`taxid`, `name`, `class`)。
- `merged_ncbi` — NCBI Taxonomyで統合されたtaxid (`old_taxid`, `new_taxid`)。
- `association_col_ncbi` — Catalogue of Lifeの有効名の節点とNCBI Taxonomyの節点の対応 (`colid`, `taxid`, `method`)。`method`は対応の根拠で、`ncbi` (Catalogue of LifeのalternativeIDのNCBI taxid)、`wikidata` (Catalogue of LifeのalternativeIDのWikidata項目が持つNCBI taxid)、`name` (学名の一致を系統で確かめたもの) のいずれか。
- `taxonlink` — 和名と学名の組 (分類群ディレクトリごと) と体系の節点の対応 (`japname`, `sciname`, `taxondir`, `colid`, `colmethod`, `ncbiid`, `ncbimethod`)。決まらなければ空 (NULL)。`colmethod` / `ncbimethod`は根拠で、`id` (ソースが持つID)、`wikidata` (ソースが持つWikidata項目から引いたID)、`name` (学名の一致。ソースの分類群の範囲などの手がかりで同名異物を除いたもの)、`association` (もう一方の体系の節点から`association_col_ncbi`で引いたもの) のいずれか。

### 和名読み→和名辞書 (yomi2japname_VERSION_BUILDDATE.tsv)

```
yomi    japname    pos    comment
```

実際にはスペースではなくタブを区切りとして使用する。和名シノニムがある場合、和名シノニムの読みから有効名の和名を返す行と、和名シノニムの読みから和名シノニムを返す行も出力される。posはデフォルトでは常に`名詞`。`--for=mozc-user`のとき、`短縮読み`になる。commentにはsourcetitle, sourceauthor, sourceurlが「sourcetitle (sourceurl) by sourceauthor」として含まれる。

`--for=gboard`のとき、出力フォーマットは以下に変更される。

```
yomi    japname    lang    pos
```

langは常に`ja-JP`、posは常に`短縮読み`である。

`--for=mozc-system`のとき、出力フォーマットは以下に変更される。

```
yomi    lid    rid    cost    japname
```

ただし、`id.def`のファイルパスを`--id-def`オプションで与える必要がある。costはデフォルトで9999だが、`--japcost`オプションで変更可能。lidとridは、種名・亜種名では「名詞,固有名詞,一般」の値、種より上位の分類群名では「名詞,固有名詞,組織」の値とします。

### 和名読み→学名辞書 (yomi2sciname_VERSION_BUILDDATE.tsv)

```
yomi    sciname    pos    comment
```

実際にはスペースではなくタブを区切りとして使用する。和名シノニムがある場合、和名シノニムの読みから有効名の学名を返す行も出力される。学名のシノニムは出力されない。posはデフォルトでは常に`名詞`。`--for=mozc-user`のとき、`短縮読み`になる。commentにはsourcetitle, sourceauthor, sourceurlが「sourcetitle (sourceurl) by sourceauthor」として含まれる。

`--for=gboard`のとき、出力フォーマットは以下に変更される。

```
yomi    sciname    lang    pos
```

langは常に`ja-JP`、posは常に`短縮読み`である。

`--for=mozc-system`のとき、出力フォーマットは以下に変更される。

```
yomi    lid    rid    cost    sciname    ENGLISH
```

ただし、`id.def`のファイルパスを`--id-def`オプションで与える必要がある。costはデフォルトで9999だが、`--scicost`オプションで変更可能。lidとridは、種名・亜種名では「名詞,固有名詞,一般」の値、種より上位の分類群名では「名詞,固有名詞,組織」の値とします。`ENGLISH`はMozcに対して変換後の言語が他言語であることを示すラベルです。

## 検索スクリプト (sciname2japname.pl / japname2sciname.pl)

`sciname2japname.pl`は学名から有効な和名を、`japname2sciname.pl`は和名から有効な学名を引く。使い方は同じで、検索の向きだけが違う。

```
sciname2japname.pl --db=DBFILE [オプション] クエリ
sciname2japname.pl --db=DBFILE [オプション] 入力ファイル 出力ファイル
```

- `--db=DBFILE` — 検索するDB (`jbtaxon_VERSION_BUILDDATE.sqlite3`)。必須。`taxonlink`などの表を持たない古い版のDBはエラーになる。
- `--mode=ADD|CONVERT` — 出力の形 (既定は`ADD`)。`ADD`は「元の名前 (引いた名前)」で、引けなければ元の名前のまま。`CONVERT`は引いた名前だけで、引けなければ空。複数の名前が引けたら`sort`した順に`,`で連結する。
- `--targetrank=階層名` — 引く列を階層名で限定する (ファイルを与えたときだけ)。カンマ区切りでも、複数回指定してもよい。
- `--overwrite` — 出力ファイルが既にあれば上書きする。

### クエリ

`階層名:名前`を`,`か`;`で並べたものを1つの引数で与える。階層名は`rank.def`のもので、階層名の無いクエリや不明な階層名はエラーになる。名前や項目全体は二重引用符で括ってよい。区切りの前後の空白は無視する。

```
sciname2japname.pl --db=jbtaxon_X_Y.sqlite3 'species:"Homo sapiens"'
sciname2japname.pl --db=jbtaxon_X_Y.sqlite3 '"species:Homo sapiens"'
sciname2japname.pl --db=jbtaxon_X_Y.sqlite3 'class:Aves,genus:Prunella'
```

各項目を引き、他の項目を系統の手がかりに使う。結果は標準出力に1行で、`階層名:結果`を`; `で並べて出す (`class:Aves (鳥綱); genus:Prunella (イワヒバリ属,カヤクグリ属)`)。

### ファイル

1つ目が入力ファイル、2つ目が出力ファイル。クエリと同時には指定できない。入力ファイルはUTF-8のタブ区切りで、1行目のラベルが階層名の列のセルを引く (`japname2sciname.pl`ではラベルは英語の階層名、セルは和名)。ラベルが階層名でない列と1行目はそのまま出力する。空のセルは空のまま、`unidentified ～`は検索しない (`ADD`では元のまま、`CONVERT`では空)。出力ファイルはディレクトリが存在し、ファイルが無いこと (`--overwrite`なら上書き)。入力と同じファイルには書けない。

### 検索の規則

1つの名前は次の順で絞り込む。

1. 階層名のrankが一致する行があればそれだけを使い、無ければrankを問わない (上位の名前を下の列へ埋めた入力があるため)。比べるのはrankの番号で、subrankは見ない。
   - `japname2sciname.pl`で階層がspeciesのときに限り、種の行が無ければ亜種・変種・品種…と1段ずつ下げ、行のある最初の階層の行を使う (種として引いた和名が亜種の和名であることがあるため)。下げて引けたとき、クエリの`CONVERT`はその階層名で下位の分類群の学名を返し (`species:ヒメギフチョウ北海道亜種` → `subspecies:Luehdorfia puziloi yessoensis`)、クエリの`ADD`とファイルは種の学名に直して返す (`species:ヒメギフチョウ北海道亜種 (Luehdorfia puziloi)`)。
2. 1列目の名前が有効名である行があればそれだけを使う。
3. 系統: 同じ行 (クエリなら他の項目) の名前が、候補の組に結び付いたCatalogue of LifeとNCBI Taxonomyの節点 (`taxonlink`) の祖先にいくつ含まれるかを数え、最も多いものだけを残す。どれも1つも当たらなければ絞り込まない。和名は先に`japname2sciname`で学名に直してから比べる。
4. 分類群ディレクトリの上下関係: 残った候補に上位のディレクトリのもの (`AllTaxa`に対しては他の全て、`Lichens`に対しては`Seaweeds`と`Fungi`) があれば、下位のディレクトリのものは捨てる。

終了コードは、正常なら0 (引けない名前があっても0)、使い方の誤り・入出力の条件の違反・DBを開けないときは2。

## rank・subrankについて

rankは各分類階層に割り当てられた以下の数値です。

1. superkingdom (上界), domain (ドメイン), realm (レルム)
2. kingdom (界)
3. subkingdom (亜界)
4. superphylum (上門)
5. phylum (門)
6. subphylum (亜門)
7. superclass (上綱)
8. class (綱)
9. subclass (亜綱)
10. infraclass (下綱)
11. cohort (コホート)
12. subcohort (サブコホート)
13. superorder (上目)
14. order (目)
15. suborder (亜目)
16. infraorder (下目)
17. parvorder (小目)
18. superfamily (上科)
19. family (科)
20. subfamily (亜科)
21. tribe (族・連)
22. subtribe (亜族・亜連)
23. genus (属)
24. subgenus (亜属)
25. section (節)
26. subsection (亜節)
27. series (列)
28. species group (種群)
29. species subgroup (種亜群)
30. species (種)
31. subspecies (亜種), morph, subvariety, pathogroup, serogroup
32. varietas (変種), biotype, genotype, serotype
33. forma (品種)
34. forma specialis
35. strain (株)
36. isolate

subrankは、基本的には値は1になりますが、上記分類階層に当てはまらない階層が、例えばfamilyとsuperfamilyの間にある場合に、その階層をrank=18,subrank=2とすることで、familyとsuperfamilyの間の階層であることを表します。間の階層が複数ある場合は、subrankを3、4、5…と増加させていきます。なお、上記のrankの値は変更されることがあります。rank値の定義は`rank.def`に記述してあります。
