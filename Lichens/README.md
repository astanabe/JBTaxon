# 地衣類 (Lichens)

地衣類研究会 (Lichenological Society of Japan) の2つのページを使用する。いずれも HTML ページ自体がデータファイル。

## 自動ダウンロードされるファイル

| ファイル | 形式 | 情報源 |
|---|---|---|
| `checklist.html` | HTML (UTF-8, 約3MB) | https://lichenjapan.jp/checklist/ |
| `systematics.html` | HTML (UTF-8, 約190KB) | https://lichenjapan.jp/systematics/ |

- `checklist.html` は Checklist of Lichens and Allied Fungi of Japan。属の見出し (`<h2>`)、有効名 (`<p class="entry">`)、シノニム (`<p class="entry syn">`) からなる。
- `systematics.html` は Classification of higher taxonomic groups of lichens and allied fungi in Japan。**罫線文字 (`｜` `－`) と全角空白で木構造を描いたページ**で、門から属までの高次分類群 714 行を持つ。字下げの深さは使わず、和名の接尾辞 (門/綱/亜綱/目/科/属) で rank を決める。学名の後ろの `*` は日本産の種を含むことを示す印なので取り除く。

## 手動で配置するファイル

なし。

## 補足

- ライセンスは **CC BY 4.0**。**出典明記が求められる情報源**なので、成果物に出典・引用表記を含めること。
- 引用形式はページ本文に明記されている。`Ohmura, Y., Miyazawa, K., Tadome, K. and Kashiwadani, H. (eds.) 2026. Checklist of Lichens and Allied Fungi of Japan.` / `Lichenological Society of Japan. 2026. Classification of higher taxonomic groups of lichens and allied fungi in Japan.`

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
