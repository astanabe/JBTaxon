# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## リポジトリの現状

現時点でこのリポジトリに存在するのは `README.md`・`rank.def`・`yomi.tsv` と、実装済みの `fetch_data.pl` のみ。残る3スクリプト (`generate_tables.pl` / `generate_database.pl` / `generate_dictionary.pl`) は**まだ実装されていない**。README.md は実装すべき仕様書として読むこと。ビルド・lint・テストの仕組みは未整備で、検証は `perl -c` と `fetch_data.pl --list` / `--dry-run` および実取得で行っている。

実行環境は Perl (`/usr/bin/perl`, v5.38)。README で規定されている4つのスクリプトはすべて `.pl`。

## プロジェクトの根幹的な制約

情報源となる生物種名チェックリストの一部は改変・再配布が禁止されている。そのため **JBTaxon の成果物（DB や辞書ファイル）自体をリポジトリで配布することはできない**。配布するのは「各ユーザーがローカルで成果物を生成するためのスクリプト」だけ。生データや生成物をリポジトリにコミットする変更は、この制約に抵触するため行わないこと。

## パイプライン構造

4段階のパイプラインで、各段の入出力が次段の入力になる：

1. `fetch_data.pl` — 分類群ごとのディレクトリに生データファイルをダウンロード
2. `generate_tables.pl` — 各ディレクトリ内で生データから和名→学名 / 学名→和名テーブル TSV を生成
3. `generate_database.pl` — 全ディレクトリの TSV を集約し単一の `jbtaxon_VERSION_BUILDDATE.sqlite3` を生成
4. `generate_dictionary.pl` — 全ディレクトリの TSV から日本語入力IME用辞書 TSV を生成

3 と 4 は 2 の出力を共通の入力とする並列の枝であり、互いに依存しない。

### ディレクトリ構成

分類群ごとに1ディレクトリ（README の見出しの括弧内が英語ディレクトリ名: `Mammals`, `Reptiles_Amphibians`, `Fishes`, `Insects`, `Spiders`, `Nematodes`, `Tanaids`, `Earthworms`, `Isopods`, `VascularPlants`, `Bryophytes`, `Lichens`, `Fungi`, `Seaweeds` と全生物種を対象とする「全体」）。「全体」のディレクトリ名は **`AllTaxa`** とすることが決定済み。ステップ1・2はディレクトリ単位で完結し、ステップ3・4で横断的に統合される。

`Insects` はサブディレクトリを作らず**フラットに配置する**。NARO・List-MJ・ハネカクシ・有剣膜翅類・トビケラ・蝶類便覧・shigainsect が同一ディレクトリに同居するため、**`fetch_data.pl` が付けるファイル名がそのままソース識別子を兼ねる契約**になっている（`naro_insecta_pageNNN.html` / `ListMJ3-*.xlsx` / `staphylinidae_p069.pdf` / `aculeata_hym_list_2016_ver5.pdf` / `trichoptera_names.html` / `binran_*.html`）。`generate_tables.pl` はこのファイル名でパーサを振り分けるので、命名を安易に変えないこと。

ダニ類 (`Acarids`) は情報源の「データの無断転用・無断転載は固くお断りいたします」という記述の意味が不明瞭なため、**対象外**とすることが決定済み。README からも節が削除されている。再追加しないこと。

### 生データの形式が情報源ごとにばらばら

Excel (.xlsx)、CSV、タブ区切りテキスト、PDF、HTML ページそのもの、JSON (NARO 昆虫DB) が混在する。`generate_tables.pl` は情報源ごとに個別のパーサを持つ必要がある。

河川水辺の国勢調査は**令和元年度以降のみを使用する**と決定済み。平成年度の「全生物種」は `.lzh` 書庫で提供されているが、対象外なので LZH 展開は実装不要。

### 自動ダウンロードできない情報源

以下は `fetch_data.pl` の対象外で、ユーザーが手動でディレクトリに配置する前提：

- 哺乳類 (`Mammals`) — 利用規約への同意が必要。ゲート自体は Vue.js のクライアントサイド判定のみで技術的には取得可能だが、**規約遵守上の判断として手動配置とする**。規約は再配布と改変物の出版を禁止しているが、同意してダウンロードした本人が加工して自分で使うことは禁じておらず、加工プログラムしか含まない JBTaxon とは衝突しない。
- 昆虫 (`Insects`) のうち shigainsect のExcel — Google Sheets の export API では技術的に取得できてしまうが、`docs.google.com` の robots.txt が `User-agent: * / Disallow: /` のため**自動取得が禁止されている**。この理由で手動配置とする。
- コケ植物 (`Bryophytes`) の PDF — `www.jstage.jst.go.jp` の robots.txt が `Disallow: /*_pdf` で、取得先 `.../_pdf/-char/ja` が該当するため**自動取得が禁止されている**。この理由で手動配置とする。

また、リンク切れに備えて Web Archive の URL を情報源としているものがあり（日本産蝶類和名学名便覧、日本産有剣膜翅類目録）、README には「リンク切れの際は古いファイルに遡って取得する」旨の要求がある。

なお `insect-web.rad.naro.go.jp/flame/tree` は昆虫・クモ類・線形動物の3ディレクトリで共通の情報源になっている。

### fetch_data.pl の実装契約

実装済み。Perl 5 のコアモジュールのみを使う（CPAN 依存なし）。以下は変更してはならない約束事：

- **全ての http(s) 取得は `curl` で行い、ダウンロードとダウンロードの間に必ず5秒空ける。** この規則は `fetch()` に集約してあるので、`fetch()` 以外の場所で `curl` を呼んではならない。ミミズの `Crawl-Delay: 5` もこの全体規則で自動的に満たされる。5秒は要件なので定数 (`$SLEEP_SECONDS`) とし、`--sleep` オプションは設けない。
- 既存ファイルはスキップし、`--force` で再取得する。**スキップ時は sleep しない**（ネットワークアクセスが発生していないため。中断後の再開が数秒で済む）。
- `.part` に落として成功時のみ `rename` する。中断で切り詰められたファイルが残り、スキップ判定で「取得済み」と誤認される事故を防ぐため。スキップ方式を採る以上これは必須。
- 巡回系（NARO・蝶類便覧・海藻）は、**レスポンスではなくディスク上のファイルを読んで**次に辿る URL を決める。再開時にスキップされたページの内容はレスポンスとして手元に来ないため。
- 失敗しても即座に中断せず最後まで走り切り、失敗一覧を末尾に再掲する（約510件・45分の処理で1件の失敗のために全体をやり直すのは非現実的なため）。ダウンロード失敗が1件でもあれば exit 1、手動未配置は警告のみで exit 0。
- ソース定義は `@SOURCES` の1テーブルに宣言的にまとめてある。URL 固定方針の保守がこのテーブルの編集だけで完結するのが狙い。`type` は `file` / `naro` / `binran` / `seaweed` / `manual` の5種。
- CLI: `--dir` / `--only`（複数指定可）/ `--force` / `--list` / `--dry-run` / `--help`。`--list` と `--dry-run` は通信しない。
- 全件取得は約510ダウンロード・約45分。

### ダウンロードURLは固定する（追従自動化しない）

日付入りファイル名で版が切られる情報源（魚類・List-MJ・真菌・YList・ミミズなど）でも、**ページを解析して最新版を探す処理は書かない**。現行の最新版を URL として `fetch_data.pl` にハードコードし、新しい版が出たときは `fetch_data.pl` 自体を更新して対応する。

理由: 版が変わるとファイルフォーマット自体が変化している可能性があり、ダウンロードだけ自動追従しても `generate_tables.pl` が対応できず壊れるため。`fetch_data.pl` が更新されない限り新しい版は使わない、というのが意図した挙動。

この方針により DOI 解決や Figshare API 呼び出しも不要で、解決後の実 URL を直接指定してよい。

### 取得方法の実測結果（README の記述と異なる点）

全情報源の到達性を実地に検証済み。README が「以下のURLのHTML自体がデータファイルです」と書いていても、実際にはトップが入口ページに過ぎず巡回が必要なものがある：

- **NARO 昆虫DB**（昆虫・クモ類・線形動物）— `flame/tree` は 809 バイトのフレームセットで、データを含まない。実データは2系統:
  - `search/tree.json?add=1&category=<ID>&lang=ja` — jsTree 用 JSON。`text` は高次分類群が `学名 (和名)`、種・亜種が `種小名 (和名)` で、**学名と和名は揃っている**（和名がないノードは括弧ごと省略）。学名は祖先ノードの連結で復元する。ただし rank は取れず、**深さは階層と一致しない**（同じ深さに亜科と属が混在する）。
  - `search/basic?category=<ID>&mon=1&kou=1&moku=1&ka=1&kazoku=1&zoku=1&syu=1&amon=1&akou=1&amoku=1&aka=1&azoku=1&asyu=1&lang=ja` — 30件/ページの一覧。門/綱/目/科/属/種の列に配置されるので **rank が明示的に得られる**。セル内の `└` 記号が中間階層（上科・亜綱など）を表し、**JBTaxon の subrank にそのまま対応する**。
  - カテゴリID: Insecta=`BB00000004`(10,931件) / Araneae=`BB00006378`(255件) / Nematoda=`BB00011689`(633件)。`search/basic` なら計約400ページ、ツリー巡回なら約4,700リクエスト。robots.txt は全面許可。
  - **`fetch_data.pl` は `search/basic` のみを使用することが決定済み**（計396ページ・約33分。`tree.json` 巡回は約4,700リクエスト＝5秒間隔では約7時間かかるため採らない）。rank が列位置から明示的に取れる利点もある。
  - 和名の表記揺れがある: 和名欄に学名が入る (`Setodes (Setodes属)`)、全角スペース混入 (`Eubasilissa (ムラサキトビケラ 属)`)、末尾の余分なスペース。
  - NARO のトビケラ目は14ノードしかなく、専用ソース (tobikera.eco.coocan.jp) の方が遥かに充実している。「より狭い分類群のソースを優先」が効く場面。
- **海藻** — `Seaweed_list_top.html` は更新履歴のポータル。実データは `Brown/*.html`, `Red/*.html`, `Green/*.html` の分類群別ページに分散。
- **日本産蝶類和名学名便覧** — トップは科一覧のみ。科・亜科・族・属それぞれの学名／和名対応を得るには階層を辿る必要がある。「詳細」が1つ下の階層へのリンク:

  ```
  /                                  科（学名・和名）
    /taxa/family/<F>/subfamily       亜科  ← トップの「詳細」
      /taxa/subfamily/<S>/tribe      族    ← 亜科ページの「詳細」
        /taxa/tribe/<T>/genus        属
        /taxa/tribe/<T>/species      種
      /taxa/subfamily/<S>/genus      属
      /taxa/subfamily/<S>/species    種
    /taxa/family/<F>/genus           属    ← 「属一覧」
    /taxa/family/<F>/species         種    ← 「種一覧」
  ```

  族ページに「詳細」はなく、そこが最下層。`/taxa/family/<F>` のような中間パスは Web Archive に取得されていないので、上記の正確なパスを使うこと。
- **List-MJ** — トップはフレームセット。Excel は `about.html` 内にリンクがある（`dl/ListMJ3-*.xlsx`）。

その他の注意:

- **文字コード**: トビケラは UTF-8（`.html` の見た目から Shift_JIS を想定すると化ける）。河川水辺の国勢調査のページ自体は cp932。
- **トビケラは属名が頭文字省略形**（`C. aira`）で書かれており、直前の属名行を保持して展開する必要がある。
- **YList** は Excel 版 (`20210514YList_download.xlsx`) が正本。同じ内容のタブ区切りテキスト (`_tab.txt`) も配布されているが**使用しない**。
- **FernGreenList** の CSV は `Japanese name 和名` と `Synonym of Japanese name 和名異名` の列を持ち、和名シノニムをそのまま利用できる。
- ライセンスが明確なもの: List-MJ と FernGreenList は **CC0**、日本産蝶類和名学名便覧は **CC BY 3.0**、地衣類は **CC BY 4.0**。

### robots.txt と利用規約（全ソース検証済み）

自動取得を追加・変更するときは必ずここを確認すること。

**robots.txt により自動取得が禁止されているもの**（いずれも手動配置で対応済み。自動化しないこと）:

- **コケ植物 (Hattoria / J-STAGE)** — `www.jstage.jst.go.jp/robots.txt` が `User-agent: * / Disallow: /*_pdf`。取得先 `.../7_9/_pdf/-char/ja` が該当する。
- **昆虫 shigainsect** — `docs.google.com/robots.txt` が `Disallow: /`。

**規約により対象外としたもの:**

- **日本産アリ類の分類体系 (JAnt)** — 利用規定が「営利を伴わない学術研究、教育普及および報道を目的とした利用の場合は無料。ただし、利用者は**あらかじめ著作権者の許可を得**」と定め、リンクを張る場合も事前許可を求めているため、**ソースから除外することが決定済み**。README からも節が削除されている。ダニ類と同じく再追加しないこと。

**判断が分かれるもの:**

- **List-MJ** — `robots.txt` が HTTP 500 を返す。RFC 9309 の厳密な解釈では 5xx は全面 disallow として扱う。ただしサイト本体は正常稼働し、データは CC0、`about.html` に明示的なダウンロードリンクがある。実質は robots.txt 未設置のサーバエラーと見られる。

**条件付きで問題ないもの:**

- **ミミズ** — 「当サイト内に記載された文章、写真、絵画などの無断転載を禁じます」。ただし xlsx は明示的な「ダウンロード」ボタンで提供され、robots.txt も `Disallow: /app/` に対し `Allow: /app/download/` と明示的に許可している。ダウンロードして各自が加工する行為は転載に当たらず、データを再配布しない JBTaxon とは衝突しない。**`Crawl-Delay: 5` があるのでアクセス間隔を5秒以上空けること。**
- **ハネカクシ (九大リポジトリ)** — `Disallow: /` だが `Allow: /opac_download_md/` があり、取得先 `/opac_download_md/26400/p069.pdf` は明示的に許可されている。

**制限なしを確認したもの:**

- 河川水辺の国勢調査 — `/lab/fbg/` は Disallow 対象外。ページに利用条件の記載なし
- NARO 昆虫DB — `Disallow:`（空）で全面許可
- 爬虫両生類 — robots.txt なし。サイトの著作権ポリシーは会誌掲載論文に関するもので、標準和名リストの利用制限ではない
- 魚類 — robots.txt なし。「利用は自由ですが，できればご一報ください」＋引用要請
- 日本産蝶類和名学名便覧 — CC BY 3.0。web.archive.org に robots.txt なし
- 地衣類 — CC BY 4.0
- FernGreenList — CC0。`ndownloader.figshare.com` に robots.txt なし
- YList — robots.txt なし。「右クリックで保存してお使い下さい」と明示。引用形式の指定あり
- タナイス類・トビケラ・ワラジムシ・海藻・真菌 — robots.txt に制限なし、利用条件の記載もなし

**出典明記が求められるソース**: 魚類、YList、地衣類 (CC BY)、日本産蝶類和名学名便覧 (CC BY)、哺乳類。成果物に出典・引用表記を含める仕組みが必要。

### 情報源が衝突した場合の優先順位

1. より狭い分類群を対象とするソースを優先
2. 同条件なら、より新しいソースを優先

**ただし有効名／シノニムの判定（`japvalid` / `scivalid` の値）だけは例外で、分類群の狭さを考慮せず「より新しいソースか」のみで決める。** つまり衝突解決は2系統に分かれる:

- どの名前を採用するか（行の選択・対応付け） → 狭さ優先、次いで新しさ
- 採用した名前が有効名かシノニムか → 新しさのみ

狭いソースが古く広いソースが新しい場合、「狭いソース由来の名前に、新しい広いソース由来の valid フラグが付く」組み合わせが正しく起こりうる。実装ではこの2つの判定を混同しないこと。

## rank / subrank

**`rank.def` が rank 値の唯一の正**。README にも階層の一覧が記載されているが、README 側には rank 0 (`no rank`, `clade`) が含まれておらず、README 自身が「rank の値は変更されることがある」と述べている。実装では README の一覧をハードコードせず `rank.def` を読むこと。

`rank.def` の形式はタブ区切りの `rank番号<TAB>階層名`。同一の rank 番号に複数の階層名が対応する（例: 31 に `subspecies`/`morph`/`subvariety`/`pathogroup`/`serogroup`）。

`subrank` は通常 1。`rank.def` に定義のない中間階層を表現するために使う。例えば family (19) と superfamily (18) の間の階層は rank=18, subrank=2 とする。中間階層が複数ある場合は subrank を 3, 4, 5… と増やす。

種より上位（科・門など）・下位（亜種・品種など）の分類群も、生データに含まれていれば出力対象とする。

## 出力ファイルフォーマット

すべてタブ区切り。ヘッダ行なしの列順で表現する。

### 中間テーブル（ステップ2の出力）

- `japname2sciname.tsv` — `japname / sciname / japvalid / rank / subrank`。和名シノニムがある場合、同一 sciname に対し japname が異なる行が複数生じる。sciname 側にシノニムは使わない。
- `sciname2japname.tsv` — `sciname / japname / scivalid / rank / subrank`。学名シノニムがある場合、同一 japname に対し sciname が異なる行が複数生じる。japname 側にシノニムは使わない。

`japvalid` / `scivalid` は1列目の名前が有効名かどうかのフラグ（0 = invalid, 1 = valid）で、シノニムなら 0。**2列目の名前側にはシノニムが現れない設計なので、このフラグは常に1列目に対応する**。位置は rank/subrank の手前（3列目）。

### IME辞書（ステップ4の出力）

- `yomi2japname.tsv` — `yomi / japname / pos`。和名シノニムがある場合、「シノニムの読み→有効名の和名」と「シノニムの読み→シノニム」の両方の行を出力する。
- `yomi2sciname.tsv` — `yomi / sciname / pos`。和名シノニムがある場合、「シノニムの読み→有効名の学名」の行を出力する。学名シノニムは出力しない。

`pos` はデフォルト `名詞`、`--for=mozc-user` のとき `短縮読み`。

`--for=mozc-system` のときのみフォーマットが変わり `yomi / lid / rid / cost / japname`（または `sciname`）になる。このモードでは `--id-def` で Mozc の `id.def` のパスを与える必要がある。lid/rid は種名・亜種名なら「名詞,固有名詞,一般」、種より上位の分類群名なら「名詞,固有名詞,組織」に対応する ID を `id.def` から引く。cost は和名がデフォルト 20000 (`--japcost` で変更可)、学名がデフォルト 30000 (`--scicost` で変更可)。

## ドキュメントの言語

README.md は日本語で記述されている。ドキュメントを追記・更新する際は日本語で書くこと。
