# 昆虫 (Insects)

昆虫の情報源は数が多く、**サブディレクトリを作らずこのディレクトリ直下にフラットに配置する**。そのため `generate_tables.pl` はファイル名でソースを判別する。**下表のファイル名はソース識別子を兼ねる契約**なので、安易に変更しないこと。

## 自動ダウンロードされるファイル

| ファイル | 数 | 形式 | 情報源 |
|---|---:|---|---|
| `naro_insecta_page001.html` 〜 `naro_insecta_page365.html` | 365 | HTML | NARO 昆虫インベントリーDB `search/basic` (category=`BB00000004`) |
| `ListMJ3-210603DL.xlsx` | 1 | Excel | List-MJ 日本産蛾類総目録 `http://listmj.mothprog.com/dl/ListMJ3-210603DL.xlsx` |
| `staphylinidae_p069.pdf` | 1 | PDF | 日本産ハネカクシ科総目録 (九州大学リポジトリ `opac_download_md/26400/p069.pdf`) |
| `aculeata_hym_list_2016_ver5.pdf` | 1 | PDF | 日本産有剣膜翅類目録 2016年版 (Web Archive) |
| `trichoptera_names.html` | 1 | HTML | 日本産トビケラの種リスト https://tobikera.eco.coocan.jp/names.htm |
| `butterfly_Hesperiidae.html` ほか4件 | 5 | HTML | 日本産蝶類の学名リスト 科別ページ https://japanesebutterfly.wixsite.com/butterfly-list |

計 406 ファイル。

### NARO 昆虫DB について

- README に記載の `https://insect-web.rad.naro.go.jp/flame/tree` は 809 バイトのフレームセットでデータを含まない。実データは `search/basic`（30件/ページ）と `search/tree.json` の2系統がある。
- **`fetch_data.pl` は `search/basic` のみを使用する**（計 10,931 件 → 365ページ）。門/綱/目/科/属/種の列に配置されるので **rank が明示的に得られ**、セル内の `└` 記号が中間階層（上科・亜綱など）を表して **subrank にそのまま対応する**。`tree.json` 巡回は約4,700リクエスト必要で採らない。
- 和名に表記揺れがある（和名欄に学名が入る `Setodes (Setodes属)`、全角スペース混入 `Eubasilissa (ムラサキトビケラ 属)`、末尾の余分なスペース）。
- NARO のトビケラ目は14ノードしかなく、専用ソース (`trichoptera_names.html`) の方が遥かに充実している。「より狭い分類群のソースを優先」が効く場面。

### 日本産蝶類の学名リスト について

科ごとに1ページ、計5ページ（セセリチョウ科・アゲハチョウ科・シロチョウ科・シジミチョウ科・タテハチョウ科）。ページ名が日本語なので `fetch_data.pl` はパーセントエンコードした URL を持ち、`butterfly_<科の学名>.html` として保存する。

Wix のサイトだが本文はサーバ側で描画されているので HTML から読める。1レコードが1つの `<p class="font_N">` で、**学名だけが `font-style:italic` の span に入っている**。

```
Family Hesperiidae セセリチョウ科
Subfamily Coeliadinae アオバセセリ亜科
Tribe Zerynthiini タイスアゲハ族
Genus <i>Luehdorfia</i> Cruger, 1878 ギフチョウ属
<i>Luehdorfia japonica</i> Leech, 1889 ギフチョウ Japanese luehdorfia
ssp. <i>yessoensis</i> Rothschild, 1918 北海道亜種
```

- **亜種の行は種小名しか書かれていない**ので直前の種の学名に連結し、和名も直前の種の和名に修飾語を付けて組み立てる（「ヒメギフチョウ 北海道亜種」）。修飾語がない亜種は種の和名をそのまま使う。
- 種の行の「`Papilio (Menelaides) polytes`」のような**亜属名は二名法の学名からは外す**（他の情報源と照合できなくなるため）。
- **「`Genue Troides`」のように綴りを誤った見出しがある**ので、キーワードで決まらないときは和名の接尾辞でも rank を判定する。
- 和名のない見出し（`Tribe Astictopterini`、`Subgenus Menelaides` など）は出力に寄与しない。
- 旧情報源は「日本産蝶類和名学名便覧」（Web Archive 経由、CC BY 3.0）だったが、2026年に新サイトが公開されたので差し替えた。

### トビケラ について

- 文字コードは **UTF-8**（`.html` の見た目から Shift_JIS を想定すると化ける）。
- **属名が頭文字省略形**（`C. aira`）で書かれており、直前の属名行を保持して展開する必要がある。

## 手動で配置するファイル

**shigainsect（滋賀県昆虫目録2025）の目別 Excel 28ファイル。**

| ファイル | 取得先 |
|---|---|
| `アザミウマ目2025.xlsx`, `アミメカゲロウ目2025.xlsx`, `イシノミ目2025.xlsx`, `カゲロウ目2025.xlsx`, `カジリムシ目2025.xlsx`, `カマキリ目2025.xlsx`, `カメムシ目2025.xlsx`, `カワゲラ目2025.xlsx`, `ガロアムシ目2025.xlsx`, `コウチュウ目2025.xlsx`, `コムシ目2025.xlsx`, `ゴキブリ目2025.xlsx`, `シミ目2025.xlsx`, `シリアゲムシ目2025.xlsx`, `チョウ目（ガ類）2025.xlsx`, `チョウ目（チョウ類）2025.xlsx`, `トビケラ目2025.xlsx`, `トビムシ目2025.xlsx`, `トンボ目2025.xlsx`, `ナナフシ目2025.xlsx`, `ネジレバネ目2025.xlsx`, `ノミ目2025.xlsx`, `ハエ目2025.xlsx`, `ハサミムシ目2025.xlsx`, `ハチ目2025.xlsx`, `バッタ目2025.xlsx`, `ヘビトンボ目2025.xlsx`, `ラクダムシ目2025.xlsx` | https://sites.google.com/view/shigainsect/ |

**一括ダウンロードの zip ファイルでも、上記のように目ごとの xlsx ファイルでも、どちらでも構わない（zip は自動的に展開される）。**

Google Sheets の export API を使えば技術的には取得できてしまうが、`docs.google.com` の robots.txt が `User-agent: * / Disallow: /` のため**自動取得が禁止されている**。この理由で手動配置とする。

## 補足

- List-MJ と FernGreenList は CC0。
- List-MJ の robots.txt は HTTP 500 を返す。RFC 9309 の厳密な解釈では 5xx は全面 disallow だが、サイト本体は正常稼働し、データは CC0、`about.html` に明示的なダウンロードリンクがある。実質は robots.txt 未設置のサーバエラーと見られる。
- ハネカクシの九大リポジトリは `Disallow: /` だが `Allow: /opac_download_md/` があり、取得先は明示的に許可されている。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
