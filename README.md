# JBTaxon

A database of Japanese biological taxon names

## JBTaxonの生成について

JBTaxonが情報源にしている生物種名チェックリストのうちのいくつかは、再配布が禁止されている。そのため、JBTaxon自体を配布することができない。そこで、

1. データファイルをダウンロード
2. 和名→学名および学名→和名テーブルのTSVを生成
3. 和名→学名および学名→和名変換テーブルを持つSQLite3 DBを生成
4. 和名読み→和名および和名読み→学名を日本語入力IMEで実現する辞書ファイルTSV (汎用・Mozcユーザー辞書用・Mozcシステム辞書用)を生成

をそれぞれ行うスクリプトを本リポジトリで配布し、各ユーザーが自ら自分に必要なファイルをローカル環境で生成して使用するものとする。

## 各スクリプトについて

1. `fetch_data.pl`
  - 各ディレクトリに生データファイルをダウンロードする
2. `generate_tables.pl`
  - 各ディレクトリ内で生データファイルから和名→学名および学名→和名テーブルのTSVを生成する
3. `generate_database.pl`
  - 和名→学名および学名→和名テーブルのTSVから単一の`jbtaxon_VERSION_BUILDDATE.sqlite3`を生成する
4. `generate_dictionary.pl`
  - 和名→学名および学名→和名テーブルのTSVから和名読み→和名および和名読み→学名を日本語入力IMEで実現する単一の辞書ファイルTSVを生成する
5. `add_to_yomi.pl`
  - 和名→学名テーブルから、既存の`yomi.tsv`にyomiデータが存在しないためyomiを自動生成できない和名を検出して`yomi.tsv`の末尾にyomi空欄でjapnameを追加する

なお、種より上位の高次分類群(科や門など)や、種より下位の低次分類群(亜種・品種など)の和名・学名も生データファイルに含まれていれば出力します。

## 分類群和名の読みについて

分類群和名の漢字表記の読みに関しては以下のソースには十分に含まれていません。そのため、本リポジトリの`yomi.tsv`にて提供するものとします。フォーマットは以下の通りです。

```
yomi    japname
```

`generate_tables.pl`実行後に`add_to_yomi.pl`を実行することで、和名→学名テーブルから、既存の`yomi.tsv`にyomiデータが存在しないためyomiを自動生成できない和名を検出して`yomi.tsv`の末尾にyomi空欄でjapnameが追加されます。筆者が手動でそこにyomiを追加して本リポジトリの`yomi.tsv`を更新していきます。

## 種名チェックリストについて

以下にソースとなるチェックリストを全て掲載します。なお、複数のソース間で衝突する場合は、(1) より狭い分類群のソースを優先、(2) 次いでより新しいソースを優先します。ただし、有効名とシノニムの判定には、Catalogue of Lifeを基本としつつ「より新しいソースか」だけを用い、より狭い分類群のソースかどうかは考慮しません。Catalogue of Lifeとその他ソースで有効名が決められない場合、NCBI Taxonomyを使用します。

### 全体 (AllTaxa)

#### 河川水辺の国勢調査のための生物リスト (国土交通省 国土技術政策総合研究所)

以下のURLで提供されているExcelファイルがデータファイルです(令和元年度以降の「全生物種」)。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://www.nilim.go.jp/lab/fbg/ksnkankyo/mizukokuweb/system/seibutsuListfile.htm

#### Catalogue of Life (2026-08-26 XR) (Olaf Bánki et al.)

以下のURLから取得できるzipファイルがデータファイルを含む配布ファイルです。`fetch_data.pl`が実行されると自動的に`AllTaxa/2026-08-26_xr_coldp.zip`としてダウンロードされます。

- https://download.checklistbank.org/col/monthly/2026-08-26_xr_coldp.zip

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

#### 日本産魚類全種目録 (本村 浩之)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://www.museum.kagoshima-u.ac.jp/staff/motomura/jaf.html

### 昆虫 (Insects)

#### 昆虫情報データベース (国立研究開発法人農業・食品産業技術総合研究機構 農業環境変動研究センター 環境情報基盤研究領域 昆虫分類評価ユニット)

以下のURLとリンク先のHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://insect-web.rad.naro.go.jp/flame/tree

#### 滋賀県昆虫目録2025 (滋賀県昆虫目録作成グループ)

以下のURLで提供されているExcelファイルがデータファイルです。Google Driveからは自動ダウンロードが禁止されているので、手動でダウンロードして`Insects`ディレクトリ内に配置して下さい(一括ダウンロードzipファイルでも各目のxlsxファイルでもどちらでも構いません。zipファイルは自動的に展開します)。

- https://sites.google.com/view/shigainsect/

#### List-MJ 日本産蛾類総目録 (神保 宇嗣)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- http://listmj.mothprog.com/

#### 日本産蝶類の学名リスト (長田 庸平)

以下のURLとリンク先のHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://japanesebutterfly.wixsite.com/butterfly-list

#### 日本産トビケラの種リスト (野崎 隆夫)

以下のURLのHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://tobikera.eco.coocan.jp/names.htm

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

### 和名読み→和名辞書 (yomi2japname_VERSION_BUILDDATE.tsv)

```
yomi    japname    pos    comment
```

実際にはスペースではなくタブを区切りとして使用する。和名シノニムがある場合、和名シノニムの読みから有効名の和名を返す行と、和名シノニムの読みから和名シノニムを返す行も出力される。posはデフォルトでは常に`名詞`。`--for=mozc-user`のとき、`短縮読み`になる。commentにはsourcetitle, sourceauthor, sourceurlが「sourcetitle (sourceurl) by sourceauthor」として含まれる。

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

`--for=mozc-system`のとき、出力フォーマットは以下に変更される。

```
yomi    lid    rid    cost    sciname    ENGLISH
```

ただし、`id.def`のファイルパスを`--id-def`オプションで与える必要がある。costはデフォルトで9999だが、`--scicost`オプションで変更可能。lidとridは、種名・亜種名では「名詞,固有名詞,一般」の値、種より上位の分類群名では「名詞,固有名詞,組織」の値とします。`ENGLISH`はMozcに対して変換後の言語が他言語であることを示すラベルです。

## rank・subrankについて

rankは各分類階層に割り当てられた以下の数値です。

1. superkingdom, domain, realm
2. kingdom
3. subkingdom
4. superphylum
5. phylum
6. subphylum
7. superclass
8. class
9. subclass
10. infraclass
11. cohort
12. subcohort
13. superorder
14. order
15. suborder
16. infraorder
17. parvorder
18. superfamily
19. family
20. subfamily
21. tribe
22. subtribe
23. genus
24. subgenus
25. section
26. subsection
27. series
28. species group
29. species subgroup
30. species
31. subspecies, morph, subvariety, pathogroup, serogroup
32. varietas, biotype, genotype, serotype
33. forma
34. forma specialis
35. strain
36. isolate

subrankは、基本的には値は1になりますが、上記分類階層に当てはまらない階層が、例えばfamilyとsuperfamilyの間にある場合に、その階層をrank=18,subrank=2とすることで、familyとsuperfamilyの間の階層であることを表します。間の階層が複数ある場合は、subrankを3、4、5…と増加させていきます。なお、上記のrankの値は変更されることがあります。rank値の定義は`rank.def`に記述してあります。
