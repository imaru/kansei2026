// 評定ページ（Matrix table / Bipolar）の質問の JavaScript。
// 質問の左のメニュー（または歯車）> JavaScript を開き、中身をすべてこれに置き換える。
//
// 下の方の形容詞対までスクロールして画像が画面の上に外れたら、
// 画像の縮小版を画面の上端に固定して表示する（元の画像が見えている間は出さない）。
// position: sticky は Qualtrics のレイアウトによっては効かないので、
// 複製を body 直下に置いて position: fixed で表示している。

var SD_FLOATING_ID = "sd-floating-image";

Qualtrics.SurveyEngine.addOnReady(function () {
  // 前の絵画（Loop & Merge の前の回）のものが残っていれば消す
  var old = document.getElementById(SD_FLOATING_ID);
  if (old) old.parentNode.removeChild(old);

  var img = this.getQuestionContainer().querySelector("img");
  if (!img || !("IntersectionObserver" in window)) return;

  var box = document.createElement("div");
  box.id = SD_FLOATING_ID;
  box.style.cssText = "position:fixed; top:0; left:0; right:0; z-index:10000; display:none;" +
    "text-align:center; background:#fff; padding:6px 0;" +
    "box-shadow:0 2px 6px rgba(0,0,0,0.25);";
  var copy = document.createElement("img");
  copy.src = img.currentSrc || img.src;
  copy.alt = img.alt;
  // 固定表示する画像の高さ（画面の高さに対する割合）。大きくすると評定項目が隠れやすくなる
  copy.style.cssText = "max-height:30vh; max-width:95%; width:auto; height:auto;";
  box.appendChild(copy);
  document.body.appendChild(box);

  // 元の画像の半分以上が画面の上に隠れたら表示する
  var observer = new IntersectionObserver(function (entries) {
    var e = entries[0];
    var hidden = e.intersectionRatio < 0.5 && e.boundingClientRect.top < 0;
    box.style.display = hidden ? "block" : "none";
  }, { threshold: [0, 0.25, 0.5, 0.75, 1] });
  observer.observe(img);

  window.sdFloatingObserver = observer;
});

Qualtrics.SurveyEngine.addOnUnload(function () {
  if (window.sdFloatingObserver) window.sdFloatingObserver.disconnect();
  var box = document.getElementById(SD_FLOATING_ID);
  if (box) box.parentNode.removeChild(box);
});
