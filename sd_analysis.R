# SD法による絵画印象評価データの集計・可視化
#
# 使い方（リポジトリのルートで実行）:
#   Rscript sd_analysis.R [データフォルダ] [出力フォルダ]
#   既定値は data/ と output/。data/ に sd_experiment.html が出力した CSV を置く。
#
# 出力:
#   1_radar_mean.png            絵画ごとの因子別得点（評定者間平均）のレーダーチャート
#   2_radar_all_raters.png      平均に全評定者のプロフィールの分布を重ねたもの
#   2_radar_raters/<ID>.png     平均と各評定者の比較、およびその評定者の (3b) の結果
#                               （作るかどうかは RATER_FIGURES で指定）
#   3a_factor_diff_mean.png     平均的に、絵画間の違いがどの因子に表れているか
#   3b_factor_diff_raters.png   評定者が、どの因子で絵画間の違いを表現しているかの分布
#   3b_factor_diff_raters_list.png  同じ内容を1人1行で示したもの（評定者が少ないときのみ）
#   0_excluded_raters.csv       除外した評定者とその理由
#   *.csv                       上の図の元になった集計値
#
# 必要なパッケージ: tidyverse, patchwork, ragg, jpeg

suppressPackageStartupMessages({
  library(tidyverse)
  library(patchwork)
  library(jpeg)
})

rm(list=ls())

args <- commandArgs(trailingOnly = TRUE)
data_dir <- if (length(args) >= 1) args[1] else "data"
out_dir  <- if (length(args) >= 2) args[2] else "output"

# 図の日本語フォント（環境に合わせて変更。Mac なら "Hiragino Sans" など）
FONT <- "Noto Sans CJK JP"

# 絵画の画像フォルダ（サムネイル用）。CSV の image 列のファイル名で探す
IMAGE_DIR <- "image"
# 絵画の情報（作家・作品名・所蔵館など）。図のラベルと出典表示に使う。なければ作品番号で表示
STIMULI_FILE <- file.path(IMAGE_DIR, "stimuli.csv")

# 評定者ごとの図（2_radar_raters/）を作る対象
#   "auto": 評定者が RATER_FIGURES_AUTO_MAX 人以下なら全員、それより多ければ作らない
#   "all" : 全員（1人あたり数秒かかる）
#   "none": 作らない
#   c("SAMPLE001", "SAMPLE002"): 指定した評定者だけ
RATER_FIGURES <- "auto"
RATER_FIGURES_AUTO_MAX <- 50
# 評定者ごとの図を並列に作るコア数（Windows では 1 になる）
N_CORES <- max(1, parallel::detectCores() - 1)

# 除外基準
#   全項目に同じ位置をつけた画像の割合がこの値以上なら除外
STRAIGHTLINE_MAX_PROP <- 0.5
#   1枚あたりの評定時間の中央値がこの秒数未満なら除外
#   （Qualtrics のデータは画像ごとの時間がないので、回答全体の時間 ÷ 絵画の枚数で判定する）
MIN_MEDIAN_RT_SEC <- 10
#   全部の絵画を評定していない評定者を除外するか
REQUIRE_ALL_PAINTINGS <- TRUE

# 評定者が少ないときだけ 1人1行の 3b を出す上限
LIST_PLOT_MAX <- 40

FACTOR_LABELS <- c(E = "評価性", A = "活動性", P = "力量性", S = "鋭さ")
SCORE_MIN <- -3
SCORE_MAX <- 3

# Qualtrics の書き出し（CSV、Use numeric values。zip のままでもよい）を読むときの設定
#   評定は Bipolar の Matrix table で、Recode values により pos 側の端を +3 にしてあるものとする
#   Loop & Merge の表（Field 1 = 画像 URL、Field 2 = 画像ファイル名）。列の URL から絵画を特定する
QUALTRICS_LOOP_MERGE <- "qualtrics/loop_merge.tsv"
#   学籍番号を尋ねた質問の列名
QUALTRICS_ID_COL <- "Q5"
#   プレビューの回答（DistributionChannel が preview）を除くか
# QUALTRICS_EXCLUDE_PREVIEW <- TRUE
QUALTRICS_EXCLUDE_PREVIEW <- FALSE
#   形容詞対（sd_experiment.html の SCALES と同じ）。Statements の「左:右」の文字列と照合する
QUALTRICS_SCALES <- tribble(
  ~id,         ~factor, ~pos,       ~neg,
  "good",      "E",     "良い",     "悪い",
  "like",      "E",     "好きな",   "嫌いな",
  "beautiful", "E",     "美しい",   "汚い",
  "dynamic",   "A",     "動的な",   "静的な",
  "showy",     "A",     "派手な",   "地味な",
  "noisy",     "A",     "騒がしい", "静かな",
  "strong",    "P",     "強い",     "弱い",
  "heavy",     "P",     "重い",     "軽い",
  "hard",      "P",     "硬い",     "柔らかい"
)

dir.create(file.path(out_dir, "2_radar_raters"), recursive = TRUE, showWarnings = FALSE)
theme_set(theme_minimal(base_family = FONT))

save_png <- function(plot, file, width, height) {
  ggsave(file.path(out_dir, file), plot, width = width, height = height,
         dpi = 150, device = ragg::agg_png, bg = "white")
}

# ---------------------------------------------------------------
# データ読み込み
# ---------------------------------------------------------------

files <- list.files(data_dir, pattern = "\\.(csv|zip)$", full.names = TRUE)
if (length(files) == 0) stop("CSV ファイルが見つかりません: ", data_dir)

# Qualtrics の書き出し（1行 = 1回答）を、jsPsych の CSV と同じ 1行 = 評定者 × 絵画 の形にする
from_qualtrics <- function(d) {
  # 2行目は質問文（「質問文 - 画像URL - 左:右」）、3行目は ImportId
  item_text <- unlist(d[1, ])
  d <- d[-(1:2), ] |> filter(Finished == "1")
  if (QUALTRICS_EXCLUDE_PREVIEW) d <- filter(d, DistributionChannel != "preview")

  loop_merge <- read_tsv(QUALTRICS_LOOP_MERGE, col_types = "cc", show_col_types = FALSE) |>
    set_names(c("url", "image"))
  scale_by_pair <- bind_rows(
    transmute(QUALTRICS_SCALES, id, factor, pair = paste0(pos, ":", neg), pos_left = TRUE),
    transmute(QUALTRICS_SCALES, id, factor, pair = paste0(neg, ":", pos), pos_left = FALSE))

  items <- tibble(col = names(item_text), text = item_text) |>
    filter(str_detect(col, "^\\d+_Q\\d+_\\d+$")) |>
    mutate(url = str_match(text, " - (https?://\\S+) - ")[, 2],
           pair = str_remove(text, "^.* - ")) |>
    left_join(loop_merge, by = "url") |>
    left_join(scale_by_pair, by = "pair")
  if (anyNA(items$image))
    stop("Loop & Merge の表にない画像 URL があります（", QUALTRICS_LOOP_MERGE, "）: ",
         paste(unique(items$url[is.na(items$image)]), collapse = ", "))
  if (anyNA(items$id))
    stop("QUALTRICS_SCALES にない形容詞対があります: ",
         paste(unique(items$pair[is.na(items$id)]), collapse = ", "))

  long <- d |>
    transmute(participant_id = ResponseId,
              student_id = .data[[QUALTRICS_ID_COL]],
              start_time = StartDate,
              duration_sec = as.numeric(`Duration (in seconds)`),
              across(all_of(items$col))) |>
    pivot_longer(all_of(items$col), names_to = "col", values_to = "score") |>
    filter(!is.na(score), score != "") |>
    left_join(select(items, col, image, id, factor, pos_left), by = "col") |>
    mutate(score = as.numeric(score),
           # 画面上の位置（左端 = 1）。左右の向きは全員共通
           pos = if_else(pos_left, 4 - score, 4 + score))
  if (any(abs(long$score) > 3))
    stop("Qualtrics の評定値が -3〜+3 の範囲外です。Recode values を確認してください")

  factor_means <- long |>
    group_by(participant_id, image, factor) |>
    summarise(value = mean(score), .groups = "drop") |>
    pivot_wider(names_from = factor, values_from = value, names_prefix = "factor_")
  long |>
    select(participant_id, student_id, start_time, duration_sec, image, id, pos, score) |>
    pivot_wider(names_from = id, values_from = c(pos, score)) |>
    left_join(factor_means, by = c("participant_id", "image")) |>
    # 画像ごとの時間はないので、回答全体の時間を絵画の枚数で割って rt（ミリ秒）とする
    group_by(participant_id) |>
    mutate(rt = duration_sec * 1000 / n(), task = "sd") |>
    ungroup() |>
    select(-duration_sec) |>
    mutate(across(everything(), as.character))
}

raw <- files |>
  map(\(f) {
    d <- read_csv(f, col_types = cols(.default = col_character()), show_col_types = FALSE)
    if ("ResponseId" %in% names(d)) d <- from_qualtrics(d)
    mutate(d, source_file = basename(f))
  }) |>
  list_rbind()
if (nrow(raw) == 0)
  stop("評定データがありません", if (QUALTRICS_EXCLUDE_PREVIEW)
    "（Qualtrics のプレビュー回答を使うときは QUALTRICS_EXCLUDE_PREVIEW を FALSE にする）")
raw <- filter(raw, task == "sd")

factor_cols <- intersect(paste0("factor_", names(FACTOR_LABELS)), names(raw))
factors <- str_remove(factor_cols, "^factor_")
factor_levels <- unname(FACTOR_LABELS[factors])
pos_cols <- str_subset(names(raw), "^pos_")

# 評定者ID: 学籍番号があればそれを、なければ実験側のランダムIDを使う
raw <- raw |>
  mutate(rater = coalesce(na_if(str_trim(student_id), ""), participant_id),
         painting = tools::file_path_sans_ext(basename(image)),
         start_time = if ("start_time" %in% names(raw)) start_time else NA_character_)
n_paintings_all <- n_distinct(raw$painting)

# 同じ評定者の二重送信は、最初の回答（start_time が最も早いもの。なければファイル名順）だけを使う
submissions <- raw |>
  group_by(rater, participant_id) |>
  summarise(start_time = min(start_time), source_file = min(source_file), .groups = "drop") |>
  arrange(rater, start_time, source_file) |>
  group_by(rater) |>
  mutate(keep = row_number() == 1) |>
  ungroup()
n_dup <- sum(!submissions$keep)
raw <- semi_join(raw, filter(submissions, keep), by = c("rater", "participant_id"))

# 除外基準のチェック
straight <- raw |>
  select(rater, painting, all_of(pos_cols)) |>
  pivot_longer(all_of(pos_cols), values_to = "pos") |>
  group_by(rater, painting) |>
  summarise(same = n_distinct(pos) == 1, .groups = "drop") |>
  group_by(rater) |>
  summarise(straight_prop = mean(same))

screen <- raw |>
  group_by(rater) |>
  summarise(n_paintings = n_distinct(painting),
            median_rt_sec = median(as.numeric(rt)) / 1000) |>
  left_join(straight, by = "rater") |>
  mutate(reason = case_when(
    straight_prop >= STRAIGHTLINE_MAX_PROP ~ "全項目に同じ位置",
    median_rt_sec < MIN_MEDIAN_RT_SEC ~ "評定時間が短すぎる",
    REQUIRE_ALL_PAINTINGS & n_paintings < n_paintings_all ~ "未評定の絵画がある",
    .default = NA_character_))

excluded <- filter(screen, !is.na(reason))
write_csv(excluded, file.path(out_dir, "0_excluded_raters.csv"))

scores <- raw |>
  anti_join(excluded, by = "rater") |>
  select(rater, painting, all_of(factor_cols)) |>
  pivot_longer(all_of(factor_cols), names_to = "factor", values_to = "score",
               names_prefix = "factor_") |>
  mutate(score = as.numeric(score),
         factor = factor(FACTOR_LABELS[factor], levels = factor_levels)) |>
  # 同じ評定者が同じ絵画を複数回評定していれば平均する
  group_by(rater, painting, factor) |>
  summarise(score = mean(score), .groups = "drop")

raters <- sort(unique(scores$rater))
message(sprintf("ファイル %d 個 → 二重送信 %d 件を除き %d 名。除外 %d 名%s",
                length(files), n_dup, nrow(screen), nrow(excluded),
                if (nrow(excluded) > 0)
                  paste0("（", paste(names(table(excluded$reason)), table(excluded$reason),
                                     sep = " ", collapse = "、"), "）") else ""))
message(sprintf("分析対象: 評定者 %d 名, 絵画 %d 枚, 因子 %d 個 (%s)",
                length(raters), n_distinct(scores$painting),
                length(factors), paste(factor_levels, collapse = "・")))

mean_scores <- scores |>
  group_by(painting, factor) |>
  summarise(sd = sd(score), score = mean(score), n = n(), .groups = "drop")


# ---------------------------------------------------------------
# レーダーチャート（ggplot2 上で直交座標に変換して描く）
# ---------------------------------------------------------------

n_axes <- length(factor_levels)
axis_angle <- pi / 2 - 2 * pi * (seq_len(n_axes) - 1) / n_axes
names(axis_angle) <- factor_levels

# 得点 -3 を中心、+3 を外周とする
to_xy <- function(df) {
  r <- (df$score - SCORE_MIN) / (SCORE_MAX - SCORE_MIN)
  a <- axis_angle[as.character(df$factor)]
  mutate(df, x = r * cos(a), y = r * sin(a))
}

radar_grid <- function() {
  rings <- expand_grid(score = SCORE_MIN:SCORE_MAX,
                       factor = factor(factor_levels, levels = factor_levels)) |>
    to_xy()
  spokes <- tibble(factor = factor(factor_levels, levels = factor_levels),
                   score = SCORE_MAX) |> to_xy()
  labels <- tibble(factor = factor(factor_levels, levels = factor_levels),
                   score = SCORE_MAX + 1.1) |> to_xy()
  ticks <- tibble(score = c(SCORE_MIN + 0.001, 0, SCORE_MAX),
                  factor = factor(factor_levels[1], levels = factor_levels)) |>
    to_xy()
  list(
    geom_polygon(data = filter(rings, score != 0), aes(x, y, group = score),
                 inherit.aes = FALSE, fill = NA, colour = "grey80", linewidth = 0.25),
    geom_polygon(data = filter(rings, score == 0), aes(x, y),
                 inherit.aes = FALSE, fill = NA, colour = "grey60", linewidth = 0.5),
    geom_segment(data = spokes, aes(x = 0, y = 0, xend = x, yend = y),
                 inherit.aes = FALSE, colour = "grey80", linewidth = 0.25),
    geom_text(data = labels, aes(x, y, label = factor), inherit.aes = FALSE,
              family = FONT, size = 3.3),
    geom_text(data = ticks, aes(x, y, label = ifelse(round(score) == 0, "0", sprintf("%+d", round(score)))),
              inherit.aes = FALSE, family = FONT, size = 2.3, colour = "grey50",
              hjust = -0.2, vjust = 1.2),
    coord_equal(xlim = c(-1.3, 1.3), ylim = c(-1.3, 1.3), clip = "off"),
    theme_void(base_family = FONT),
    theme(legend.position = "bottom",
          plot.margin = margin(2, 12, 6, 12))
  )
}

image_files <- raw |>
  distinct(painting = tools::file_path_sans_ext(basename(image)), file = basename(image)) |>
  mutate(path = file.path(IMAGE_DIR, file))
image_path <- setNames(image_files$path, image_files$painting)

# 絵画のラベルと出典。stimuli.csv があればその順に並べる
paintings <- sort(unique(scores$painting))
painting_label <- setNames(paintings, paintings)
painting_short <- painting_label
credit_text <- NULL
if (file.exists(STIMULI_FILE)) {
  stimuli <- read_csv(STIMULI_FILE, show_col_types = FALSE) |>
    mutate(painting = tools::file_path_sans_ext(file),
           artist_short = str_remove(artist, "、.*$"))
  unknown <- setdiff(paintings, stimuli$painting)
  if (length(unknown) > 0) warning("stimuli.csv にない絵画: ", paste(unknown, collapse = ", "))
  stimuli <- filter(stimuli, painting %in% paintings)
  paintings <- c(stimuli$painting, unknown)
  painting_label[stimuli$painting] <- sprintf("%s\n「%s」", stimuli$artist_short, stimuli$title)
  painting_short[stimuli$painting] <- stimuli$artist_short
  credit_text <- sprintf(
    "画像出典：国立美術館所蔵作品総合目録検索システム（https://search.artmuseums.go.jp/）。%s所蔵。サムネイルは縮小して使用。",
    paste(unique(stimuli$museum), collapse = "・"))
}
mean_scores <- mean_scores |> mutate(label = str_replace(painting_label[painting], "\n", ""))
write_csv(mean_scores, file.path(out_dir, "1_mean_scores.csv"))

facet_cols <- min(5, length(paintings))
facet_rows <- ceiling(length(paintings) / facet_cols)
radar_w <- 3 * facet_cols
radar_h <- 4.6 * facet_rows + 1

title_theme <- theme(plot.title = element_text(family = FONT, size = 14),
                     plot.subtitle = element_text(family = FONT, size = 10, colour = "grey30"),
                     plot.caption = element_text(family = FONT, size = 8, colour = "grey40", hjust = 0))

# 絵画のサムネイル（画像が見つからなければ名前だけ）
thumbnail <- function(painting) {
  p <- ggplot() + theme_void(base_family = FONT) +
    labs(title = painting_label[painting]) +
    theme(plot.title = element_text(size = 10, hjust = 0.5, lineheight = 1.1, margin = margin(b = 3)),
          plot.margin = margin(6, 6, 0, 6))
  path <- image_path[painting]
  if (is.na(path) || !file.exists(path)) {
    warning("画像が見つかりません: ", painting)
    return(p)
  }
  img <- readJPEG(path)
  h <- dim(img)[1]
  w <- dim(img)[2]
  p + annotation_raster(as.raster(img), 0, w, 0, h, interpolate = TRUE) +
    coord_fixed(xlim = c(0, w), ylim = c(0, h), expand = FALSE)
}

# 絵画ごとに「サムネイル＋レーダー」を作って並べる
# layers: 絵画名を受け取り、そのレーダーに重ねる ggplot レイヤーのリストを返す関数
radar_figure <- function(layers) {
  paintings |>
    map(\(pt) thumbnail(pt) / (ggplot(mapping = aes(x, y)) + radar_grid() + layers(pt)) +
          plot_layout(heights = c(1, 1.6))) |>
    wrap_plots(ncol = facet_cols) +
    plot_layout(guides = "collect") &
    theme(legend.position = "bottom")
}

# (1) 評定者間平均
mean_xy <- to_xy(mean_scores)
p1 <- radar_figure(\(pt) list(
  geom_polygon(data = filter(mean_xy, painting == pt),
               fill = "#3B6FB6", alpha = 0.25, colour = "#3B6FB6", linewidth = 0.8),
  geom_point(data = filter(mean_xy, painting == pt), colour = "#3B6FB6", size = 1.6)
)) +
  plot_annotation(title = sprintf("絵画ごとの因子得点（評定者 %d 名の平均）", length(raters)),
                  caption = credit_text, theme = title_theme)
save_png(p1, "1_radar_mean.png", radar_w, radar_h)

# (2) 平均に全評定者の分布を重ねたもの
# 分布を帯（10〜90 / 25〜75パーセンタイル）で示す。評定者が少なければ各評定者も細線で描く
LINES_MAX <- 100
rater_xy <- to_xy(scores)
band_ring <- function(lo_p, hi_p, band) {
  scores |>
    group_by(painting, factor) |>
    summarise(outer = quantile(score, hi_p), inner = quantile(score, lo_p), .groups = "drop") |>
    pivot_longer(c(outer, inner), names_to = "ring", values_to = "score") |>
    # 外周を先、穴（内周）を後にする
    mutate(ring = factor(ring, levels = c("outer", "inner")), band = band) |>
    arrange(painting, ring, factor) |>
    to_xy()
}
band_xy <- bind_rows(band_ring(0.10, 0.90, "10〜90%"), band_ring(0.25, 0.75, "25〜75%"))
show_lines <- length(raters) <= LINES_MAX

p2_all <- radar_figure(\(pt) list(
  if (show_lines)
    geom_polygon(data = filter(rater_xy, painting == pt), aes(group = rater),
                 fill = NA, colour = scales::alpha("#D1495B", 0.35), linewidth = 0.3),
  geom_polygon(data = filter(band_xy, painting == pt),
               aes(group = band, subgroup = ring, fill = band), colour = NA),
  geom_polygon(data = filter(mean_xy, painting == pt),
               fill = NA, colour = "black", linewidth = 1.1),
  scale_fill_manual(values = c("10〜90%" = scales::alpha("#3B6FB6", 0.2),
                               "25〜75%" = scales::alpha("#3B6FB6", 0.45)),
                    limits = c("10〜90%", "25〜75%"), name = "評定者の分布")
)) +
  plot_annotation(
    title = sprintf("評定者のプロフィールの分布（評定者 %d 名）", length(raters)),
    caption = credit_text,
    subtitle = paste0("黒線: 平均　帯: 評定者の得点の範囲（パーセンタイル）",
                      if (show_lines) "　赤い細線: 各評定者" else ""),
    theme = title_theme)
save_png(p2_all, "2_radar_all_raters.png", radar_w, radar_h + 0.5)

# ---------------------------------------------------------------
# (3) 絵画間の違いがどの因子に表れているか
#
# ある因子で絵画同士の得点が大きく異なるほど、その因子で絵画を「区別」している。
# そこで因子ごとに、絵画間の得点の標準偏差（SD）を求め、
# 全因子の分散の合計に占める割合を「その因子の寄与率」とする。
#   - 平均: 評定者間平均の得点について計算（3a）
#   - 個人: 評定者ごとの得点について計算（3b）
# ---------------------------------------------------------------

between_painting <- function(df) {
  df |>
    group_by(factor) |>
    summarise(sd = sd(score), .groups = "drop") |>
    mutate(share = if (sum(sd^2) > 0) sd^2 / sum(sd^2) else NA_real_)
}

diff_mean <- mean_scores |> between_painting() |> mutate(rater = "全体平均")
diff_rater <- scores |>
  group_by(rater) |>
  group_modify(\(d, k) between_painting(d)) |>
  ungroup()

# 絵画間にまったく差をつけなかった評定者は寄与率を計算できないので 3b から外す
no_diff <- diff_rater |> group_by(rater) |> filter(all(is.na(share))) |> distinct(rater)
if (nrow(no_diff) > 0)
  message(sprintf("絵画間に差をつけなかった %d 名は寄与率を計算できないため 3b から除外", nrow(no_diff)))
diff_rater <- anti_join(diff_rater, no_diff, by = "rater")

# 評定者ごとの要約: 最も寄与率の大きい因子（タイプ）と、全因子をまとめた絵画間SD
rater_summary <- diff_rater |>
  group_by(rater) |>
  summarise(type = factor[which.max(share)], total_sd = sqrt(sum(sd^2)), .groups = "drop")

write_csv(bind_rows(diff_mean, diff_rater) |> relocate(rater),
          file.path(out_dir, "3_between_painting_sd.csv"))

factor_colours <- setNames(c("#3B6FB6", "#E08E2B", "#4E9A5B", "#8E5BA8")[seq_along(factor_levels)],
                           factor_levels)

# (3a) 平均: 左に絵画ごとの平均得点の散らばり、右に絵画間SDと寄与率
p3a_dots <- ggplot(mean_scores, aes(score, fct_rev(factor), colour = factor)) +
  geom_vline(xintercept = 0, colour = "grey70") +
  geom_point(size = 3, alpha = 0.8) +
  geom_text(aes(label = painting_short[painting]), size = 2.6, vjust = -1, family = FONT,
            check_overlap = TRUE, show.legend = FALSE) +
  scale_colour_manual(values = factor_colours, guide = "none") +
  scale_x_continuous(limits = c(SCORE_MIN, SCORE_MAX), breaks = SCORE_MIN:SCORE_MAX) +
  labs(x = "評定者間平均の得点", y = NULL, subtitle = "各点が1枚の絵画")

p3a_bar <- ggplot(diff_mean, aes(sd, fct_rev(factor), fill = factor)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = sprintf("%.2f（%.0f%%）", sd, share * 100)),
            hjust = -0.1, size = 3.3, family = FONT) +
  scale_fill_manual(values = factor_colours, guide = "none") +
  scale_x_continuous(expand = expansion(mult = c(0, 0.45))) +
  labs(x = "絵画間の標準偏差（括弧内は分散の寄与率）", y = NULL,
       subtitle = "大きいほど、その因子で絵画が区別されている")

p3a <- (p3a_dots | p3a_bar) +
  plot_annotation(title = "絵画間の違いはどの因子に表れているか（評定者間平均）",
                  theme = title_theme)
save_png(p3a, "3a_factor_diff_mean.png", 11, 1.2 * length(factor_levels) + 2)

# (3b) 個人
diff_all <- bind_rows(diff_mean, diff_rater)
sd_limits <- c(0, max(diff_all$sd))
mean_total_sd <- sqrt(sum(diff_mean$sd^2))

# 先頭の行（全体平均）の下に区切り線を引く
diff_share_plot <- function(d, rows, y_title = "評定者") {
  d <- mutate(d, rater = factor(rater, levels = rev(rows)))
  ggplot(d, aes(share, rater, fill = factor)) +
    geom_col(width = 0.75, position = position_stack(reverse = TRUE)) +
    geom_text(aes(label = ifelse(share >= 0.08, sprintf("%.0f%%", share * 100), "")),
              position = position_stack(vjust = 0.5, reverse = TRUE),
              size = 2.8, colour = "white", family = FONT) +
    geom_hline(yintercept = length(rows) - 0.5, colour = "grey30") +
    scale_fill_manual(values = factor_colours, name = NULL) +
    scale_x_continuous(labels = scales::percent, expand = c(0, 0)) +
    labs(x = "絵画間の分散に占める各因子の割合", y = y_title,
         subtitle = "どの因子で絵画を区別しているか（相対）") +
    theme(legend.position = "top", panel.grid.major.y = element_blank())
}

diff_sd_plot <- function(d, rows) {
  d <- mutate(d, rater = factor(rater, levels = rev(rows)))
  ggplot(d, aes(factor, rater, fill = sd)) +
    geom_tile(colour = "white") +
    geom_text(aes(label = sprintf("%.2f", sd)), size = 2.8, family = FONT) +
    geom_hline(yintercept = length(rows) - 0.5, colour = "grey30") +
    scale_fill_gradient(low = "white", high = "#3B6FB6", name = "SD", limits = sd_limits) +
    labs(x = NULL, y = NULL, subtitle = "絵画間の標準偏差（絶対量）") +
    theme(panel.grid = element_blank(), axis.text.y = element_blank())
}

# 三角図（3因子のときのみ）: 寄与率の組 (a, b, c) を正三角形内の1点で表す
# 頂点はレーダーチャートと同じ配置（第1因子が上、第2因子が右下、第3因子が左下）
to_ternary <- function(d) {
  d |>
    select(rater, factor, share) |>
    pivot_wider(names_from = factor, values_from = share) |>
    mutate(tx = .data[[factor_levels[2]]] + .data[[factor_levels[1]]] / 2,
           ty = .data[[factor_levels[1]]] * sqrt(3) / 2)
}

ternary_base <- function() {
  h <- sqrt(3) / 2
  corners <- tibble(x = c(0.5, 1, 0), y = c(h, 0, 0), label = factor_levels)
  ticks <- seq(0.2, 0.8, by = 0.2)
  # 各因子の割合が一定の線（20% 刻み）
  grid <- bind_rows(
    tibble(x = ticks / 2, y = ticks * h, xend = 1 - ticks / 2, yend = ticks * h),
    tibble(x = ticks, y = 0, xend = (1 + ticks) / 2, yend = (1 - ticks) * h),
    tibble(x = 1 - ticks, y = 0, xend = (1 - ticks) / 2, yend = (1 - ticks) * h))
  # 最も大きい因子が切り替わる境界（重心から各辺の中点へ）
  centre <- c(0.5, h / 3)
  borders <- tibble(x = centre[1], y = centre[2],
                    xend = c(0.75, 0.25, 0.5), yend = c(h / 2, h / 2, 0))
  list(
    geom_polygon(data = corners, aes(x, y), fill = NA, colour = "grey40",
                 inherit.aes = FALSE),
    geom_segment(data = grid, aes(x, y, xend = xend, yend = yend),
                 colour = "grey88", linewidth = 0.3, inherit.aes = FALSE),
    geom_segment(data = borders, aes(x, y, xend = xend, yend = yend),
                 colour = "grey60", linetype = "dashed", linewidth = 0.4, inherit.aes = FALSE),
    geom_text(data = corners, aes(x, y, label = label), family = FONT, size = 3.6,
              vjust = c(-0.8, 1.6, 1.6), inherit.aes = FALSE),
    coord_equal(xlim = c(-0.05, 1.05), ylim = c(-0.08, h + 0.08), clip = "off"),
    theme_void(base_family = FONT)
  )
}

type_counts <- rater_summary |>
  count(type, .drop = FALSE) |>
  mutate(prop = n / sum(n))

p3b_types <- ggplot(type_counts, aes(prop, fct_rev(type), fill = type)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = sprintf("%d名（%.0f%%）", n, prop * 100)),
            hjust = -0.1, size = 3.2, family = FONT) +
  scale_fill_manual(values = factor_colours, guide = "none") +
  scale_x_continuous(labels = scales::percent, expand = expansion(mult = c(0, 0.5))) +
  labs(x = NULL, y = NULL, subtitle = "最も寄与率の大きい因子ごとの人数")

p3b_total <- ggplot(rater_summary, aes(total_sd)) +
  geom_histogram(bins = 30, fill = "grey60", colour = "white") +
  geom_vline(xintercept = mean_total_sd, colour = "black", linewidth = 0.8) +
  annotate("text", x = mean_total_sd, y = Inf, label = " 全体平均", hjust = 0, vjust = 1.5,
           family = FONT, size = 3) +
  labs(x = "絵画間の標準偏差（全因子をまとめたもの）", y = "人数",
       subtitle = "絵画の違いをどれだけ大きくつけているか（絶対量）")

if (length(factor_levels) == 3) {
  tern <- to_ternary(diff_rater) |> left_join(rater_summary, by = "rater")
  tern_mean <- to_ternary(diff_mean)
  p3b_main <- ggplot() +
    ternary_base() +
    geom_point(data = tern, aes(tx, ty, colour = type),
               alpha = min(0.8, 40 / nrow(tern)) + 0.15, size = 1.6) +
    geom_point(data = tern_mean, aes(tx, ty), shape = 23, size = 4,
               fill = "white", colour = "black", stroke = 1.2) +
    scale_colour_manual(values = factor_colours, guide = "none") +
    labs(subtitle = "1点が1人。頂点に近いほどその因子で絵画を区別している",
         caption = "◇: 全体平均（評定者間で平均した得点から計算。平均すると個人の癖が打ち消されるため、点の集まりの中心とは一致しない）")
} else {
  # 4因子: 因子ごとに寄与率のヒストグラム
  p3b_main <- ggplot(diff_rater, aes(share, fill = factor)) +
    geom_histogram(bins = 20, boundary = 0, colour = "white") +
    geom_vline(data = diff_mean, aes(xintercept = share), linewidth = 0.8) +
    facet_wrap(~factor, ncol = 2) +
    scale_fill_manual(values = factor_colours, guide = "none") +
    scale_x_continuous(labels = scales::percent, limits = c(0, 1)) +
    labs(x = "絵画間の分散に占める割合", y = "人数",
         subtitle = "各因子の寄与率の分布（縦線は全体平均）")
}

p3b <- (p3b_main | (p3b_types / p3b_total)) +
  plot_layout(widths = c(1.3, 1)) +
  plot_annotation(
    title = sprintf("評定者はどの因子で絵画間の違いを表現していたか（評定者 %d 名）",
                    nrow(rater_summary)),
    theme = title_theme)
save_png(p3b, "3b_factor_diff_raters.png", 12, 6.5)

write_csv(rater_summary, file.path(out_dir, "3_rater_types.csv"))

# 評定者が少なければ 1人1行の一覧も出す
# 評定者は最も寄与率の大きい因子ごとにまとめ、その中で寄与率の大きい順に並べる
rater_order <- diff_rater |>
  group_by(rater) |>
  slice_max(share, n = 1, with_ties = FALSE) |>
  arrange(factor, desc(share)) |>
  pull(rater)
rows_all <- c("全体平均", rater_order)

if (length(rater_order) <= LIST_PLOT_MAX) {
  p3b_list <- (diff_share_plot(diff_all, rows_all) | diff_sd_plot(diff_all, rows_all)) +
    plot_layout(widths = c(3, 1.4)) +
    plot_annotation(title = "各評定者はどの因子で絵画間の違いを表現していたか",
                    theme = title_theme)
  save_png(p3b_list, "3b_factor_diff_raters_list.png", 11, 0.32 * length(rows_all) + 2.5)
}

# ---------------------------------------------------------------
# (2) 評定者ごとのファイル: 平均との比較レーダー＋その評定者の (3b)
# ---------------------------------------------------------------

figure_raters <- if (identical(RATER_FIGURES, "auto")) {
  if (length(raters) <= RATER_FIGURES_AUTO_MAX) raters else character(0)
} else if (identical(RATER_FIGURES, "all")) {
  raters
} else if (identical(RATER_FIGURES, "none")) {
  character(0)
} else {
  missing <- setdiff(RATER_FIGURES, raters)
  if (length(missing) > 0)
    warning("分析対象にいない評定者: ", paste(missing, collapse = ", "))
  intersect(RATER_FIGURES, raters)
}

rater_figure <- function(rt) {
  this <- filter(rater_xy, rater == rt)
  radar <- radar_figure(\(pt) list(
    geom_polygon(data = filter(mean_xy, painting == pt), aes(fill = "平均", colour = "平均"),
                 alpha = 0.25, linewidth = 0.6),
    geom_polygon(data = filter(this, painting == pt),
                 aes(fill = "この評定者", colour = "この評定者"), alpha = 0, linewidth = 1),
    geom_point(data = filter(this, painting == pt), colour = "#D1495B", size = 1.6),
    scale_colour_manual(values = c("平均" = "grey40", "この評定者" = "#D1495B"),
                        limits = c("平均", "この評定者"), name = NULL),
    scale_fill_manual(values = c("平均" = "grey60", "この評定者" = NA),
                      limits = c("平均", "この評定者"), name = NULL)
  ))

  rows <- c("全体平均", rt)
  d <- filter(diff_all, rater %in% rows)
  if (all(is.na(d$share[d$rater == rt]))) {
    diff_part <- wrap_elements(grid::textGrob("絵画間に差がないため、寄与率は計算できません",
                                              gp = grid::gpar(fontfamily = FONT)))
  } else {
    diff_part <- (diff_share_plot(d, rows, y_title = NULL) | diff_sd_plot(d, rows))
    if (length(factor_levels) == 3) {
      this_tern <- filter(tern, rater == rt)
      p_tern <- ggplot() +
        ternary_base() +
        geom_point(data = tern, aes(tx, ty), colour = "grey75",
                   alpha = min(0.8, 40 / nrow(tern)) + 0.1, size = 0.9) +
        geom_point(data = tern_mean, aes(tx, ty), shape = 23, size = 3,
                   fill = "white", colour = "black", stroke = 1) +
        geom_point(data = this_tern, aes(tx, ty), colour = "#D1495B", size = 3.5) +
        labs(subtitle = "赤: この評定者　◇: 全体平均　灰: 他の評定者")
      diff_part <- diff_part | p_tern
      diff_part <- diff_part + plot_layout(widths = c(3, 1.4, 2.2))
    } else {
      diff_part <- diff_part + plot_layout(widths = c(3, 1.4))
    }
  }

  p2 <- wrap_elements(radar) / wrap_elements(diff_part) +
    plot_layout(heights = c(radar_h, 3.2)) +
    plot_annotation(
      title = sprintf("評定者 %s と平均の比較", rt),
      caption = credit_text,
      subtitle = "上: 絵画ごとの因子得点　下: 絵画間の違いをどの因子で表現しているか（全体平均との比較）",
      theme = title_theme)
  save_png(p2, file.path("2_radar_raters", paste0(rt, ".png")), max(radar_w, 12), radar_h + 4)
  invisible(NULL)
}

if (length(figure_raters) > 0) {
  message(sprintf("評定者ごとの図を %d 名分作成します（%d コア）", length(figure_raters), N_CORES))
  # 寄与率を計算できない評定者も図は作る（下段にメッセージを出す）
  diff_all <- bind_rows(diff_all,
                        filter(scores, rater %in% no_diff$rater) |>
                          group_by(rater) |> group_modify(\(d, k) between_painting(d)) |> ungroup())
  if (.Platform$OS.type == "windows" || N_CORES <= 1) {
    walk(figure_raters, rater_figure)
  } else {
    res <- parallel::mclapply(figure_raters, \(rt) tryCatch(rater_figure(rt), error = \(e) conditionMessage(e)),
                              mc.cores = N_CORES)
    errs <- keep(res, is.character)
    if (length(errs) > 0) warning("評定者ごとの図でエラー: ", errs[[1]])
  }
} else if (length(raters) > RATER_FIGURES_AUTO_MAX && identical(RATER_FIGURES, "auto")) {
  message(sprintf("評定者が %d 名と多いため、評定者ごとの図は作りません（RATER_FIGURES で指定可）",
                  length(raters)))
}

message("出力先: ", normalizePath(out_dir))
