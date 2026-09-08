# X1 Tile Pattern Maker

SHARP X1 Hu-BASIC形式の8×nドット・デジタルRGBタイルをマウスで編集し、
RetroBASICへそのまま貼り付けられる`HEXCHR$("...")`を生成するmacOSアプリです。

## 使い方

1. 右側の8色パレットから色を選びます。
2. 左側のセルをクリック、またはドラッグして塗ります。
3. 必要なら`ROWS`のステッパーで高さを1〜16行に変更します。
4. `ACTUAL SIZE PREVIEW`で640×200（1×2ドット）と320×200（2×2ドット）の見え方を確認します。
5. `COPY HEXCHR$`を押すと式全体がクリップボードへコピーされます。

生成した式は次のように使用できます。

```basic
T$=HEXCHR$("FF5500FFAA00")
LINE (20,20)-(180,100),T$,BF
PAINT (200,100),T$,7
```

## ビルドとテスト

```bash
./test.sh
./build.sh
```

ビルド結果は`TilePatternMaker.app`です。macOS 13以降に対応します。
