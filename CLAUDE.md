# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

絵画画像の印象を SD 法で評定する感性評価実験（jsPsych 版と Qualtrics 版）と、その R 分析スクリプト。使い方・設定変数・出力ファイルの詳細は `README.md` にまとまっているので、まずそちらを参照する。ドキュメントやコメントは日本語で書く。

## コマンド

すべてリポジトリのルート（`/home/imaru/git/kansei2026`）で実行する。

```
# 実験をローカルで動かす（?simulate を付けると DataPipe に送らず CSV をダウンロード）
python3 -m http.server   # → http://localhost:8000/sd_experiment.html?simulate

# 分析（既定は data/ → output/）
Rscript sd_analysis.R [データフォルダ] [出力フォルダ]
Rscript sd_analysis.R data_jspsych                     # 850 人分のサンプルで動作確認（約 45 秒）
Rscript sd_analysis.R data_jspsych <scratch の出力先>   # output/ を上書きしたくないとき
```

ビルド・lint・テストはない。変更の確認は、上記のサンプルデータで分析を通すことと、`?simulate` で実験を最後まで進めることで行う。

## 全体の構成

データは「実験 → CSV/zip → `sd_analysis.R`」の一方向に流れる。2 つの実験の実装が同じ分析スクリプトに入るため、次の対応関係を崩さないことが重要。

- **尺度の定義が 3 か所にある**: `sd_experiment.html` の `SCALES`（`id`・`pos`/`neg`・因子）、Qualtrics の Matrix の Statements（「左:右」の文字列）、`sd_analysis.R` の `QUALTRICS_SCALES`（その文字列 → 尺度 ID・因子）。形容詞対を変えるときは 3 つとも揃える。因子名は `FACTOR_LABELS`（R）と `FACTOR_NAMES`（JS）。
- **刺激の定義も複数か所にある**: `image/` の JPEG、`image/stimuli.csv`（図のラベル・並び順・出典）、`sd_experiment.html` の `STIMULI`（終了画面の出典）、`qualtrics/loop_merge.tsv`（Qualtrics の画像 URL ↔ ファイル名）、`qualtrics/end_message.html`。
- **共通のデータ形式は「1 行 = 評定者 × 絵画」**（jsPsych の CSV の形。`task == "sd"` の行、`pos_*`・`score_*`・`factor_*`・`rt`・`student_id`・`participant_id`・`start_time`）。`ResponseId` 列のあるファイルは Qualtrics の書き出しとみなし、`from_qualtrics()` でこの形に変換してから以降の処理を共通化している。Qualtrics 側で列や質問文を変えると、この変換（質問文中の画像 URL と「左:右」文字列の照合、学籍番号列 `QUALTRICS_ID_COL`）が壊れる。
- **得点の向き**: jsPsych 版は参加者ごとに半数の尺度の左右を入れ替えて提示し、`pos_*`（画面上の位置 1〜7）と `score_*`（`pos` 極 = +3 に変換済み）を両方記録する。分析は `factor_*` を使い、`pos_*` は全項目同一位置の判定にだけ使う。Qualtrics 版は Recode values で同じ向きにする。
- **因子の数は可変**: 分析スクリプトは `factor_*` 列から因子を自動判別する（3 因子なら三角図、4 因子ならヒストグラムに切り替わる）。因子数を前提にしたコードを書かない。

`sd_analysis.R` は上から順に、読み込み・二重送信の除去・除外基準 → レーダーチャート (1)(2) → 絵画間 SD と寄与率 (3a)(3b) → 評定者ごとの図（`parallel` で並列化、Windows では逐次）の順に進む。設定はすべて冒頭の大文字の変数にまとめている。

jsPsych は CDN を使わず `lib/jspsych/` のローカルコピーを読む（学校のネットワークで CDN が遮断されるため）。新しいプラグインを使うときも `lib/jspsych/` に置く。データ保存は extension-pipe で DataPipe に送る（`PIPE_EXPERIMENT_ID`）。

## 注意点

- `kansei_test.html` は初期の試作で、CDN 版 jsPsych を使う。本番の実験は `sd_experiment.html`。
- `output/`・`data_qualtrics/`・`data/*.zip`・`.RData` などは Git 管理外。Qualtrics の書き出し（実データ）はコミットしない。
- `QUALTRICS_EXCLUDE_PREVIEW` は動作確認のため現在 `FALSE`。本番前に `TRUE` に戻す。
- 画像は国立美術館のパブリックドメイン画像で、出典表示が利用条件。図や終了画面の出典表示を消さない。
