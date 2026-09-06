# 真菌 (Fungi)

日本菌学会の日本産菌類チェックリストを使用する。

## 自動ダウンロードされるファイル

| ファイル | 形式 | 情報源 |
|---|---|---|
| `DB20200311.xlsx` | Excel | `https://www.mycology-jp.org/_userdata/DB20200311.xlsx` |

案内ページは https://www.mycology-jp.org/html/checklist_clist.html 。

## 手動で配置するファイル

なし。

## 補足

- ファイル名に日付が入り版が切られるが、`fetch_data.pl` は URL をハードコードしている。新しい版が出たときは `fetch_data.pl` 自体を更新して対応する。
- robots.txt に制限はなく、利用条件の記載もない。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
