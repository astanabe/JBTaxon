# JBTaxon

A database of Japanese biological taxon names

## JBTaxonの生成について

JBTaxonが情報源にしている生物種名チェックリストは、いずれも改変や再配布が禁止されている。そのため、JBTaxon自体を配布することができない。そこで、

1. データファイルをダウンロード
2. 和名→学名および学名→和名テーブルのTSVを生成
3. 和名→学名および学名→和名変換テーブルを持つSQLite3 DBを生成
4. 和名読み→和名および和名読み→学名を日本語入力IMEで実現する辞書ファイルTSV (汎用・Mozcユーザー辞書用・Mozcシステム辞書用)を生成

をそれぞれ行うスクリプトを本リポジトリで配布し、各ユーザーが自ら自分に必要なファイルをローカル環境で生成して使用する。

## 各スクリプトについて

1. `fetch_data.pl`
  - 各ディレクトリに生データファイルをダウンロードする
2. `generate_tables.pl`
  - 各ディレクトリ内で生データファイルから和名→学名および学名→和名テーブルのTSVを生成する
3. `generate_database.pl`
  - 和名→学名および学名→和名テーブルのTSVから単一の`jbtaxon_VERSION_BUILDDATE.sqlite3`を生成する
4. `generate_dictionary.pl`
  - 和名→学名および学名→和名テーブルのTSVから和名読み→和名および和名読み→学名を日本語入力IMEで実現する単一の辞書ファイルTSVを生成する

## 種名チェックリストについて

### 哺乳類 (Mammals)

利用規約に同意する必要があるため、`fetch_data.pl`でダウンロードできません。以下のURLから手動でダウンロードしてディレクトリ内に配置して下さい。

- https://www.mammalogy.jp/list/index.html

### 爬虫類・両生類 (Reptiles_Amphibians)

以下のURLのHTML自体がデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://herpetology.jp/wamei/index_j.php

### 魚類 (Fishes)

以下のURLで提供されているExcelファイルがデータファイルです。`fetch_data.pl`が実行されると自動的にダウンロードされます。

- https://www.museum.kagoshima-u.ac.jp/staff/motomura/jaf.html

現在はver.42です。

### 昆虫 (Insects)

#### 滋賀県昆虫目録2025

- https://sites.google.com/view/shigainsect/

#### List-MJ 日本産蛾類総目録

- http://listmj.mothprog.com/

#### 日本産蝶類和名学名便覧

- https://web.archive.org/web/20211017231224/https://binran.lepimages.jp/

#### 日本産アリ類の分類体系

- http://ant.miyakyo-u.ac.jp/J/Tables/SpList201201.html

#### 日本産トビケラの種リスト

- https://tobikera.eco.coocan.jp/names.htm

#### 日本産ハネカクシ科総目録

- https://doi.org/10.15017/26400

#### 日本産有剣膜翅類目録（2016 年版）

- https://web.archive.org/web/20220324223234/https://sc888fba2c6537423.jimcontent.com/download/version/1486475674/module/12561110890/name/Hym.list.%28Japan%292016.ver5.pdf

### ダニ類 (Acarids)

- https://sites.google.com/site/catalogueofacariofjapan/

### タナイス類

- https://sites.google.com/site/tnidjpn/tanaidacea/jpnlist

### ミミズ

- https://japanese-mimizu.jimdofree.com/

### ワラジムシ

- https://www.warajimushi.com/Species/List_species.html

### 維管束植物

- http://ylist.info/
- https://doi.org/10.57400/data.bnmnsbot.22696618

### コケ植物

- https://doi.org/10.18968/hattoria.7.0_9
- https://doi.org/10.18968/hattoria.9.0_53

### 地衣類

- https://lichenjapan.jp/checklist/

### 真菌

- https://www.mycology-jp.org/html/checklist_clist.html

### 海藻

- https://tonysharks.com/Seaweeds_list/Seaweed_list_top.html

## ファイルフォーマット

### 和名→学名テーブル

```
japname    sciname    rank    subrank
```

実際にはスペースではなくタブを区切りとして使用する。和名シノニムがある場合、scinameが同一でjapnameが異なる行が生じる。scinameにはシノニムは使用しない。

### 学名→和名テーブル

```
sciname    japname    rank    subrank
```

実際にはスペースではなくタブを区切りとして使用する。学名シノニムがある場合、japnameが同一でscinameが異なる行が生じる。japnameにはシノニムは使用しない。

### 和名読み→和名辞書

```
yomi    japname    pos
```

実際にはスペースではなくタブを区切りとして使用する。和名シノニムがある場合、和名シノニムの読みから有効名の和名を返す行と、和名シノニムの読みから和名シノニムを返す行も出力される。posはデフォルトでは常に`名詞`。`--for=mozc-user`のとき、`短縮読み`になる。

`--for=mozc-system`のとき、出力フォーマットは以下に変更される。

```
yomi    lid    rid    cost    japname
```

ただし、`id.def`のファイルパスを`--id-def`オプションで与える必要がある。costはデフォルトで20000だが、`--japcost`オプションで変更可能。lidとridは、種名・亜種名では「名詞,固有名詞,一般」の値、種より上位の分類群名では「名詞,固有名詞,組織」の値とします。

### 和名読み→学名辞書

```
yomi    sciname    pos
```

実際にはスペースではなくタブを区切りとして使用する。和名シノニムがある場合、和名シノニムの読みから有効名の学名を返す行も出力される。学名のシノニムは出力されない。posはデフォルトでは常に`名詞`。`--for=mozc-user`のとき、`短縮読み`になる。

`--for=mozc-system`のとき、出力フォーマットは以下に変更される。

```
yomi    lid    rid    cost    sciname
```

ただし、`id.def`のファイルパスを`--id-def`オプションで与える必要がある。costはデフォルトで30000だが、`--scicost`オプションで変更可能。lidとridは、種名・亜種名では「名詞,固有名詞,一般」の値、種より上位の分類群名では「名詞,固有名詞,組織」の値とします。
