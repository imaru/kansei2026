# SD法による絵画印象評価データの集計・可視化
#
# 使い方（リポジトリのルートで実行）:
#   Rscript sd_analysis.R [データフォルダ] [出力フォルダ]
#   既定値は data/ と output/。data/ に sd_experiment.html が出力した CSV を置く。
#
# 出力:
#   1_radar_mean.png            絵画ごとの因子別得点（評定者間平均）のレーダーチャート
#   2_radar_all_raters.png      平均に全評定者のプロフィールを重ねたもの
#   2_radar_raters/<ID>.png     平均と各評定者の比較、およびその評定者の (3b) の結果
#   3a_factor_diff_mean.png     平均的に、絵画間の違いがどの因子に表れているか
#   3b_factor_diff_raters.png   各評定者が、どの因子で絵画間の違いを表現しているか
#   *.csv                       上の図の元になった集計値
#
# 必要なパッケージ: tidyverse, patchwork, ragg, jpeg

suppressPackageStartupMessages({
  library(tidyverse)
  library(patchwork)
  library(jpeg)
})

args <- commandArgs(trailingOnly = TRUE)
data_dir <- if (length(args) >= 1) args[1] else "data"
out_dir  <- if (length(args) >= 2) args[2] else "output"

# 図の日本語フォント（環境に合わせて変更。Mac なら "Hiragino Sans" など）
FONT <- "Noto Sans CJK JP"

# 絵画の画像フォルダ（サムネイル用）。CSV の image 列のファイル名で探す
IMAGE_DIR <- "image"

FACTOR_LABELS <- c(E = "評価性", A = "活動性", P = "力量性", S = "鋭さ")
SCORE_MIN <- -3
SCORE_MAX <- 3

dir.create(file.path(out_dir, "2_radar_raters"), recursive = TRUE, showWarnings = FALSE)
theme_set(theme_minimal(base_family = FONT))

save_png <- function(plot, file, width, height) {
  ggsave(file.path(out_dir, file), plot, width = width, height = height,
         dpi = 150, device = ragg::agg_png, bg = "white")
}

# ---------------------------------------------------------------
# データ読み込み
# ---------------------------------------------------------------

files <- list.files(data_dir, pattern = "\\.csv$", full.names = TRUE)
if (length(files) == 0) stop("CSV ファイルが見つかりません: ", data_dir)

raw <- files |>
  map(\(f) read_csv(f, col_types = cols(.default = col_character()),
                    show_col_types = FALSE) |>
        mutate(source_file = basename(f))) |>
  list_rbind() |>
  filter(task == "sd")

factor_cols <- intersect(paste0("factor_", names(FACTOR_LABELS)), names(raw))
factors <- str_remove(factor_cols, "^factor_")
factor_levels <- unname(FACTOR_LABELS[factors])

# 評定者ID: 学籍番号があればそれを、なければ実験側のランダムIDを使う
scores <- raw |>
  mutate(rater = coalesce(na_if(student_id, ""), participant_id),
         painting = tools::file_path_sans_ext(basename(image))) |>
  select(rater, painting, all_of(factor_cols)) |>
  pivot_longer(all_of(factor_cols), names_to = "factor", values_to = "score",
               names_prefix = "factor_") |>
  mutate(score = as.numeric(score),
         factor = factor(FACTOR_LABELS[factor], levels = factor_levels)) |>
  # 同じ評定者が同じ絵画を複数回評定していれば平均する
  group_by(rater, painting, factor) |>
  summarise(score = mean(score), .groups = "drop")

raters <- sort(unique(scores$rater))
message(sprintf("評定者 %d 名, 絵画 %d 枚, 因子 %d 個 (%s)",
                length(raters), n_distinct(scores$painting),
                length(factors), paste(factor_levels, collapse = "・")))

mean_scores <- scores |>
  group_by(painting, factor) |>
  summarise(sd = sd(score), score = mean(score), n = n(), .groups = "drop")

write_csv(mean_scores, file.path(out_dir, "1_mean_scores.csv"))

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

paintings <- sort(unique(scores$painting))
image_files <- raw |>
  distinct(painting = tools::file_path_sans_ext(basename(image)), file = basename(image)) |>
  mutate(path = file.path(IMAGE_DIR, file))
image_path <- setNames(image_files$path, image_files$painting)

facet_cols <- min(4, length(paintings))
facet_rows <- ceiling(length(paintings) / facet_cols)
radar_w <- 3 * facet_cols
radar_h <- 4.6 * facet_rows + 1

title_theme <- theme(plot.title = element_text(family = FONT, size = 14),
                     plot.subtitle = element_text(family = FONT, size = 10, colour = "grey30"))

# 絵画のサムネイル（画像が見つからなければ名前だけ）
thumbnail <- function(painting) {
  p <- ggplot() + theme_void(base_family = FONT) +
    labs(title = painting) +
    theme(plot.title = element_text(size = 11, hjust = 0.5, margin = margin(b = 3)),
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
                  theme = title_theme)
save_png(p1, "1_radar_mean.png", radar_w, radar_h)

# (2) 平均に全評定者を重ねたもの
rater_xy <- to_xy(scores)
p2_all <- radar_figure(\(pt) list(
  geom_polygon(data = filter(rater_xy, painting == pt), aes(group = rater, colour = rater),
               fill = NA, linewidth = 0.4, alpha = 0.7),
  geom_polygon(data = filter(mean_xy, painting == pt),
               fill = NA, colour = "black", linewidth = 1.1),
  scale_colour_discrete(name = "評定者", limits = raters)
)) +
  plot_annotation(title = "各評定者のプロフィール（黒線が平均）", theme = title_theme)
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
    mutate(share = sd^2 / sum(sd^2))
}

diff_mean <- mean_scores |> between_painting() |> mutate(rater = "全体平均")
diff_rater <- scores |>
  group_by(rater) |>
  group_modify(\(d, k) between_painting(d)) |>
  ungroup()

write_csv(bind_rows(diff_mean, diff_rater) |> relocate(rater),
          file.path(out_dir, "3_between_painting_sd.csv"))

factor_colours <- setNames(c("#3B6FB6", "#E08E2B", "#4E9A5B", "#8E5BA8")[seq_along(factor_levels)],
                           factor_levels)

# (3a) 平均: 左に絵画ごとの平均得点の散らばり、右に絵画間SDと寄与率
p3a_dots <- ggplot(mean_scores, aes(score, fct_rev(factor), colour = factor)) +
  geom_vline(xintercept = 0, colour = "grey70") +
  geom_point(size = 3, alpha = 0.8) +
  geom_text(aes(label = painting), size = 2.6, vjust = -1, family = FONT,
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

# (3b) 個人: 寄与率の積み上げ棒と、絵画間SDのヒートマップ
# 評定者は最も寄与率の大きい因子ごとにまとめ、その中で寄与率の大きい順に並べる
rater_order <- diff_rater |>
  group_by(rater) |>
  slice_max(share, n = 1, with_ties = FALSE) |>
  arrange(factor, desc(share)) |>
  pull(rater)

diff_all <- bind_rows(diff_mean, diff_rater)
sd_limits <- c(0, max(diff_all$sd))

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

rows_all <- c("全体平均", rater_order)
p3b <- (diff_share_plot(diff_all, rows_all) | diff_sd_plot(diff_all, rows_all)) +
  plot_layout(widths = c(3, 1.4)) +
  plot_annotation(title = "各評定者はどの因子で絵画間の違いを表現していたか",
                  theme = title_theme)
save_png(p3b, "3b_factor_diff_raters.png", 11, 0.32 * length(rows_all) + 2.5)

# ---------------------------------------------------------------
# (2) 評定者ごとのファイル: 平均との比較レーダー＋その評定者の (3b)
# ---------------------------------------------------------------

for (rt in raters) {
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
  diff_part <- (diff_share_plot(d, rows, y_title = NULL) | diff_sd_plot(d, rows)) +
    plot_layout(widths = c(3, 1.4))

  p2 <- wrap_elements(radar) / wrap_elements(diff_part) +
    plot_layout(heights = c(radar_h, 2.4)) +
    plot_annotation(
      title = sprintf("評定者 %s と平均の比較", rt),
      subtitle = "上: 絵画ごとの因子得点　下: 絵画間の違いをどの因子で表現しているか（全体平均との比較）",
      theme = title_theme)
  save_png(p2, file.path("2_radar_raters", paste0(rt, ".png")), max(radar_w, 10), radar_h + 3)
}

message("出力先: ", normalizePath(out_dir))
