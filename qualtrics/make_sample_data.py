# Qualtrics のプレビュー書き出しの列構成をそのまま使って、N 人分のダミー回答を作る
#   絵画ごとの平均は data_jspsych の尺度ごとの平均から取る
#   除外基準の確認用に、全項目同一位置 3%・回答が速すぎる 3%・未完了 2%・二重送信 2% を混ぜる
#
# リポジトリのルートで実行する:
#   python3 qualtrics/make_sample_data.py <プレビューの書き出し（CSV か zip）> <出力 CSV> [人数（既定 850）]
#   python3 qualtrics/make_sample_data.py data_qualtrics/感性2026_*.zip data_qualtrics/sample_qualtrics_850.csv
#   Rscript sd_analysis.R data_qualtrics <出力先>
import csv, glob, io, random, re, statistics, collections, datetime, string, sys, zipfile

src, out = sys.argv[1:3]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 850
repo = "."
random.seed(2026)

# data_jspsych の (絵画, 尺度) ごとの平均
acc = collections.defaultdict(list)
for f in glob.glob(f"{repo}/data_jspsych/*.csv"):
    for r in csv.DictReader(open(f, encoding="utf-8")):
        if r.get("task") == "sd":
            for k, v in r.items():
                if k.startswith("score_") and v:
                    acc[(r["image"].removeprefix("image/"), k[6:])].append(float(v))
means = {k: statistics.mean(v) for k, v in acc.items()}

url2img = {}
with open(f"{repo}/qualtrics/loop_merge.tsv", encoding="utf-8") as f:
    next(f)
    for line in f:
        u, i = line.rstrip("\n").split("\t")
        url2img[u] = i
pair2id = {"良い:悪い": "good", "好きな:嫌いな": "like", "美しい:汚い": "beautiful",
           "動的な:静的な": "dynamic", "派手な:地味な": "showy", "騒がしい:静かな": "noisy",
           "強い:弱い": "strong", "重い:軽い": "heavy", "硬い:柔らかい": "hard"}

if src.endswith(".zip"):
    with zipfile.ZipFile(src) as z:
        text = z.read(next(n for n in z.namelist() if n.endswith(".csv"))).decode("utf-8-sig")
else:
    text = open(src, encoding="utf-8-sig").read()
rows = list(csv.reader(io.StringIO(text)))
header, label, importid, template = rows[0], rows[1], rows[2], rows[3]
items = {}  # 列番号 -> (絵画, 尺度 ID)
for i, (c, t) in enumerate(zip(header, label)):
    if re.fullmatch(r"\d+_Q\d+_\d+", c):
        _, url, pair = t.split(" - ")
        items[i] = (url2img[url], pair2id[pair])
col = {c: i for i, c in enumerate(header)}

def rid():
    return "R_" + "".join(random.choices(string.ascii_letters + string.digits, k=15))

def clip(x):
    return max(-3, min(3, round(x)))

n_straight, n_fast, n_unfin, n_dup = round(N * .03), round(N * .03), round(N * .02), round(N * .02)
kinds = (["straight"] * n_straight + ["fast"] * n_fast + ["unfinished"] * n_unfin)
kinds += ["normal"] * (N - len(kinds))

start0 = datetime.datetime(2026, 10, 22, 9, 0, 0)
out_rows = []
for n in range(N):
    kind = kinds[n]
    sid = f"{2426001 + n}"
    bias = random.gauss(0, 0.4)          # 評定者ごとの全体的な偏り
    gain = random.uniform(0.6, 1.6)      # 評定者ごとの尺度の使い方の幅
    start = start0 + datetime.timedelta(minutes=random.uniform(0, 600))
    dur = int(random.uniform(15, 40) * 10) if kind != "fast" else int(random.uniform(3, 7) * 10)
    r = list(template)
    for i, (img, sc) in items.items():
        if kind == "straight":
            r[i] = "0"
        else:
            r[i] = str(clip(gain * means[(img, sc)] + bias + random.gauss(0, 1.0)))
    if kind == "unfinished":
        stop = random.randint(20, 80)   # 途中の絵画で離脱
        for i in items:
            if i >= stop: r[i] = ""
        r[col["Finished"]], r[col["Progress"]] = "0", str(int(100 * (stop - 20) / 90))
    else:
        r[col["Finished"]], r[col["Progress"]] = "1", "100"
    end = start + datetime.timedelta(seconds=dur)
    rec = end + datetime.timedelta(seconds=random.randint(1, 5))
    r[col["StartDate"]] = start.strftime("%Y-%m-%d %H:%M:%S")
    r[col["EndDate"]] = end.strftime("%Y-%m-%d %H:%M:%S")
    r[col["RecordedDate"]] = rec.strftime("%Y-%m-%d %H:%M:%S")
    r[col["Duration (in seconds)"]] = str(dur)
    r[col["Status"]] = "0"
    r[col["DistributionChannel"]] = "anonymous"
    r[col["ResponseId"]] = rid()
    r[col["LocationLatitude"]], r[col["LocationLongitude"]] = "", ""
    r[col["Q5"]] = sid
    out_rows.append(r)

# 二重送信: 普通の回答者の一部がもう一度回答した（後の回答は分析で捨てられるはず）
normal_rows = [r for r, k in zip(out_rows, kinds) if k == "normal"]
for src_row in random.sample(normal_rows, n_dup):
    r = list(src_row)
    r[col["ResponseId"]] = rid()
    t = datetime.datetime.strptime(r[col["StartDate"]], "%Y-%m-%d %H:%M:%S") + datetime.timedelta(hours=1)
    r[col["StartDate"]] = t.strftime("%Y-%m-%d %H:%M:%S")
    for i in items:
        r[i] = str(clip(int(r[i]) + random.choice([-1, 0, 1])))
    out_rows.append(r)

out_rows.sort(key=lambda r: r[col["StartDate"]])
with open(out, "w", encoding="utf-8-sig", newline="") as f:
    w = csv.writer(f, quoting=csv.QUOTE_ALL)
    w.writerows([header, label, importid] + out_rows)
print(len(out_rows), "rows ->", out)
