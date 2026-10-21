# kansei2026

絵画画像の印象を SD 法（セマンティック・ディファレンシャル法）で評定する感性評価実験と、その分析スクリプト。

## ファイル構成

| パス | 内容 |
|---|---|
| `sd_experiment.html` | 実験プログラム（jsPsych 8） |
| `qualtrics/` | Qualtrics で同じ実験を作るときに貼り付ける HTML と、Loop & Merge の表（`loop_merge.tsv`） |
| `image/` | 評定対象の絵画画像と、その情報（`stimuli.csv`） |
| `lib/jspsych/` | jsPsych 本体・プラグイン・extension-pipe（CDN を使わずに動かすためのローカル配置） |
| `sd_analysis.R` | 集計・可視化スクリプト（R） |
| `data/` | 分析スクリプトが読む評定データ（CSV または Qualtrics の zip）。Qualtrics の書き出し（zip）は Git 管理外 |
| `data_jspsych/` | jsPsych 版の動作確認用サンプルデータ 850 人分（絵画 10 枚・9 項目。学籍番号 `SAMPLE001`〜`850`。全項目に同じ位置をつけた回答 10 人、学籍番号なし 8 人、二重送信 5 件を含む） |
| `data_qualtrics/` | Qualtrics の書き出しの保管場所（Git 管理外） |
| `output/` | 分析結果の出力先（Git 管理外） |

## 実験

### 実行方法

`sd_experiment.html` をブラウザで開く。`image/` と `lib/` を同じフォルダに置いておくこと。jsPsych は `lib/jspsych/` から読み込むため、外部への通信は DataPipe への保存だけになる（学校のネットワークで CDN が遮断されても動く）。

ファイルを直接開くか、リポジトリのルートで簡易サーバーを立てて開く。

```
python3 -m http.server
# → http://localhost:8000/sd_experiment.html
```

### 流れ

1. 画像の読み込み
2. 学籍番号の入力
3. 全画面表示
4. 教示
5. 画像ごとの評定（10 枚。提示順は参加者ごとにランダム）。画像の横に 7 段階の形容詞対尺度が 9 項目並び、全項目に回答すると次へ進む
6. データ保存・終了（終了画面に画像の出典を表示）

### 設定（`sd_experiment.html` 冒頭）

| 変数 | 内容 |
|---|---|
| `STIMULI` | 評定する画像と出典（終了画面に表示）。`image/stimuli.csv` と対応させる |
| `SCALES` | 形容詞対（評価性・活動性・力量性 × 3 項目）。`pos` が +3 側、`neg` が −3 側 |
| `RANDOMIZE_SCALE_ORDER_PER_IMAGE` | `true` で尺度の順序を画像ごとにランダム化（既定は参加者内で固定） |
| `PIPE_EXPERIMENT_ID` | [DataPipe](https://pipe.jspsych.org/) の experiment ID。空ならブラウザから CSV をダウンロード |

尺度は大山らの SD 法研究の 3 因子構成を参考にした例。実際に使う形容詞対は原典を確認して調整すること。

反応の偏りを防ぐため、参加者ごとに半数の尺度で左右の極を入れ替えて提示する（入れ替えた尺度は `flipped_scales` 列に記録）。

### データの保存

`PIPE_EXPERIMENT_ID` を設定すると、[extension-pipe](https://www.npmjs.com/package/@jspsych/extension-pipe) で DataPipe に保存する。

- 実験の最後に、評定の試行だけを `sd_<ランダムID>.csv` として送る。送信中は「保存しています。閉じないでください」、完了後は「保存が完了しました」と表示する。
- 1 試行ごとにもデータを送っているため、途中でページを閉じた参加者のデータは DataPipe 側で `.partial.json` として回収される（分析スクリプトは `.csv` だけを読むので、自動では含まれない）。この送信は DataPipe 経由で Google の Firebase にもつながる。ネットワークで遮断された場合は、最後にまとめて送る動作に切り替わる。
- 最後の送信に失敗したときは「保存できませんでした。係の人に知らせてください」と表示する。
- URL の末尾に `?simulate` を付けて開くと DataPipe に送らず、CSV をダウンロードする（動作確認で DataPipe のセッションを消費しないため）。

### 出力データ

`sd_<ランダムID>.csv`。1 行が 1 画像の評定。

| 列 | 内容 |
|---|---|
| `student_id`, `participant_id` | 学籍番号、実験側で発行したランダム ID |
| `start_time` | 実験開始時刻（UTC）。二重送信のとき最初の回答を選ぶのに使う |
| `image` | 画像ファイル |
| `pos_<尺度>` | 画面上で選んだ位置（左 = 1 〜 右 = 7） |
| `score_<尺度>` | 得点（`pos` 極 = +3 〜 `neg` 極 = −3。左右の入れ替えは変換済み） |
| `factor_E/A/P` | 因子ごとの平均得点（評価性・活動性・力量性） |
| `scale_order`, `flipped_scales` | 尺度の提示順、左右を入れ替えた尺度 |
| `rt` | 1 画像の評定にかかった時間（ms） |

## Qualtrics 版

jsPsych の代わりに Qualtrics でも同じ評定を実施できる。`qualtrics/` のファイルを使って次のように作る。

| ファイル | 貼り付け先 |
|---|---|
| `instructions.html` | 説明ページ（Text / Graphic 質問）。Rich Content Editor の「<>」(Source) |
| `sd_question.html` | 評定ページ（Matrix table / Bipolar）の質問文。同上 |
| `end_message.html` | 終了メッセージ（Survey options > End of survey > Custom message）。画像の出典を表示する |
| `loop_merge.tsv` | 評定ページのブロックの Loop & Merge の表。Field 1 = 画像の URL（Qualtrics のライブラリにアップロードした画像）、Field 2 = 画像ファイル名 |

- 学籍番号は Text entry 質問で尋ねる（分析スクリプトは列名 `Q5` を読む）。
- 評定は Bipolar の Matrix table で、Statements に形容詞対を「左:右」（例 `良い:悪い`）で入れる。形容詞対は `sd_experiment.html` の `SCALES` と同じ。
- Recode values で、各尺度の `pos` 側の端が +3、反対の端が −3 になるようにする。
- jsPsych 版と違い、左右の入れ替えは参加者ごとには行わない（向きは全員共通）。画像ごとの評定時間も記録されない。
- 画像はアップロードしやすいように、`image/` の JPEG を画質を落として再保存してある（大きさは元と同じ）。画像を差し替えたら `loop_merge.tsv` の URL も更新する。

データは Data & Analysis > Export で、CSV・**Use numeric values** を選んで書き出す。ダウンロードした zip は展開せずにそのまま `data/` に置いてよい。

## 分析

### 準備

R と次のパッケージが必要。

```r
install.packages(c("tidyverse", "patchwork", "ragg", "jpeg"))
```

図のフォントはスクリプト冒頭の `FONT` で指定する（既定は `"Noto Sans CJK JP"`。Mac では `"Hiragino Sans"` など）。

### 実行方法

実験で得た CSV（jsPsych 版）または Qualtrics の書き出し（CSV か zip）を `data/` に置き、リポジトリのルートで実行する。両方を混ぜて置いてもよい。

```
Rscript sd_analysis.R [データフォルダ] [出力フォルダ]
```

フォルダを省略すると `data/` と `output/` を使う。jsPsych 版のサンプルデータで試すときは `Rscript sd_analysis.R data_jspsych` とする。RStudio では `kansei2026.Rproj` を開いて `sd_analysis.R` を Source する。

- 因子は CSV の `factor_*` 列から自動判別する（4 因子のデータにも対応）。
- `ResponseId` 列のあるファイルは Qualtrics の書き出しとみなし、jsPsych 版と同じ「1 行 = 評定者 × 絵画」の形に変換する。質問文に含まれる画像 URL を `loop_merge.tsv` と照合して絵画を、「左:右」の文字列を `QUALTRICS_SCALES` と照合して尺度を特定する。最後まで回答した（`Finished` が 1）回答だけを使い、評定者は学籍番号（空なら `ResponseId`）で識別する。
- 評定者は学籍番号で識別する（空なら実験側のランダム ID）。同じ評定者の二重送信は、最初の回答（`start_time` が最も早いもの）だけを使う。
- サムネイルは `IMAGE_DIR`（既定は `image`）から CSV の `image` 列のファイル名で探す。見つからない絵画は名前だけを表示し、警告を出す。
- `image/stimuli.csv` があれば、図の絵画ラベルを「作家名＋作品名」にし、絵画を同ファイルの順に並べ、サムネイルを含む図に出典を注記する。

850 人分のサンプルデータで約 45 秒（評定者ごとの図を作らない場合）。

### 設定（`sd_analysis.R` 冒頭）

| 変数 | 内容 |
|---|---|
| `FONT` | 図の日本語フォント |
| `IMAGE_DIR` | サムネイルに使う画像のフォルダ |
| `STIMULI_FILE` | 絵画の情報のファイル（既定は `image/stimuli.csv`） |
| `RATER_FIGURES` | 評定者ごとの図を作る対象。`"auto"`（`RATER_FIGURES_AUTO_MAX` 人以下なら全員、多ければ作らない）、`"all"`、`"none"`、または `c("SAMPLE001", "SAMPLE002")` のような ID の指定 |
| `N_CORES` | 評定者ごとの図を並列に作るコア数（Windows では並列化しない）。1 人あたり約 5 秒なので、850 人分は 7 コアで 10 分程度 |
| `STRAIGHTLINE_MAX_PROP` | 全項目に同じ位置をつけた画像の割合がこの値以上の評定者を除外（既定 0.5） |
| `MIN_MEDIAN_RT_SEC` | 1 枚あたりの評定時間の中央値がこの秒数未満の評定者を除外（既定 10 秒）。Qualtrics のデータは回答全体の時間 ÷ 絵画の枚数で判定する |
| `REQUIRE_ALL_PAINTINGS` | 全部の絵画を評定していない評定者を除外するか |
| `QUALTRICS_LOOP_MERGE` | Loop & Merge の表のファイル（既定は `qualtrics/loop_merge.tsv`） |
| `QUALTRICS_ID_COL` | 学籍番号を尋ねた質問の列名（既定 `Q5`） |
| `QUALTRICS_EXCLUDE_PREVIEW` | プレビューの回答（`DistributionChannel` が `preview`）を除くか（既定 `TRUE`）。プレビューで動作確認するときは `FALSE` にする |
| `QUALTRICS_SCALES` | Qualtrics の形容詞対と尺度 ID・因子の対応 |
| `LIST_PLOT_MAX` | 評定者がこの人数以下のときだけ、1 人 1 行の `3b_factor_diff_raters_list.png` を出す |

除外した評定者と理由は `0_excluded_raters.csv` に出力され、人数は実行時のメッセージにも表示される。

### 出力

| ファイル | 内容 |
|---|---|
| `1_radar_mean.png` | 絵画ごとの因子得点（評定者間平均）のレーダーチャート。サムネイル付き |
| `2_radar_all_raters.png` | 評定者のプロフィールの分布。平均（黒線）と、10〜90%・25〜75% パーセンタイルの帯。評定者が 100 人以下なら各評定者も細線で描く |
| `2_radar_raters/<ID>.png` | 評定者ごとの比較（`RATER_FIGURES` で指定）。上段は平均と当該評定者のレーダーチャート、下段は当該評定者の寄与率・絵画間 SD と、三角図上の位置（3 因子のとき） |
| `3a_factor_diff_mean.png` | 絵画間の違いが、平均的にはどの因子に表れているか |
| `3b_factor_diff_raters.png` | 評定者がどの因子で絵画間の違いを表現しているかの分布。3 因子なら寄与率の三角図（1 点が 1 人）、4 因子なら因子ごとの寄与率のヒストグラム。あわせて、最も寄与率の大きい因子ごとの人数と、絵画間 SD の分布 |
| `3b_factor_diff_raters_list.png` | 同じ内容を 1 人 1 行で示したもの（評定者が少ないときのみ） |
| `0_excluded_raters.csv` | 除外した評定者と理由 |
| `1_mean_scores.csv` | 絵画 × 因子の平均・SD・人数 |
| `3_between_painting_sd.csv` | 評定者（と全体平均）× 因子の絵画間 SD と寄与率 |
| `3_rater_types.csv` | 評定者ごとの、最も寄与率の大きい因子（タイプ）と全因子をまとめた絵画間 SD |

### (3) の指標について

ある因子で絵画同士の得点が大きく違うほど、その因子で絵画を区別しているとみなす。因子ごとに絵画間の得点の標準偏差（SD）を求め、全因子の分散の合計に占める割合を「寄与率」とする。

- **寄与率**：どの因子に重きを置いて絵画の違いを表しているか（相対的な使い方）
- **SD**：そもそも絵画の違いを大きくつけるか（絶対量）

解釈上の注意:

- 「全体平均」は評定者間で平均した得点から計算しているため、個人の寄与率の平均とは一致しない（平均すると個人の癖が打ち消され、傾向がはっきり見えやすい）。三角図の ◇ が点の集まりの中心からずれるのはこのため。
- 絵画間にまったく差をつけなかった評定者は寄与率を計算できないため、(3b) から外す（除外基準で外れていなければ、評定者ごとの図の下段にその旨を表示する）。
- 絵画の枚数が少ないと個人の SD は不安定になる。
- 因子得点は実験で決めた形容詞対のまとまりを平均したもので、データから因子分析で確かめたものではない。評定者が集まったら `score_*` 列で因子構造を確認するとよい。

## 画像の出典

画像は[国立美術館所蔵作品総合目録検索システム](https://search.artmuseums.go.jp/)のパブリックドメイン画像（Rights Statement「No Copyright – Contractual Restrictions」）で、いずれも国立西洋美術館所蔵。作家・作品名・制作年・作品ページの URL などは `image/stimuli.csv` にまとめている。

[利用規約](https://search.artmuseums.go.jp/terms.html)により、利用時は出典（同システムのコンテンツであること、可能な範囲で URL）を明示し、改変した場合はその旨を明示する。実験では終了画面に、分析の図では注記として出典を表示している（サムネイルは縮小して使用）。講演のスライドや配布物でも出典を表示すること。
