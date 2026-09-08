# RetroBASIC

1983年ごろのマイクロソフト系BASIC(N88-BASIC / MSX BASIC / GW-BASIC の雰囲気)を
気軽に楽しむための Mac 用アプリケーションです。厳密なPCエミュレーションではなく、
当時の標準的な命令セットを備えた行番号方式のBASICインタプリタ+80／40×25のテキストターミナルです。

詳しい操作方法と命令リファレンスは[ユーザーズマニュアル](USER_MANUAL.md)を参照してください。
印刷・配布向けの[PDF版](output/pdf/RetroBASIC_User_Manual.pdf)も用意しています。

## ビルドと起動

```bash
./build.sh          # RetroBASIC.app と retrobasic-cli を生成
open RetroBASIC.app
```

CLI版(ターミナル内で動く同じインタプリタ):

```bash
./retrobasic-cli                 # 対話モード
./retrobasic-cli samples/GUESS.bas   # ファイルをロードして即RUN
```

MIDIファイルからRetroBASIC用の3チャンネルMMLプログラムを作る補助アプリ:

```bash
cd MIDIToMML
./build.sh
open MIDIToMML.app
```

トラック／MIDIチャンネルをPSGのA・B・Cへ割り当て、量子化した行番号付きBASICを
コピーまたは`.bas`で保存できます。詳しくは[MIDIToMML/README.md](MIDIToMML/README.md)を
参照してください。

## 使い方

起動すると `Ok` プロンプトが出ます。行番号付きで入力するとプログラムとして記憶され、
行番号なしで入力すると即実行されます(イミディエイトモード)。

```
10 PRINT "HELLO"
20 GOTO 10
RUN
```

- **中断**: `Ctrl+C` または `Cmd+.`(`CONT` で再開可能)
- **入力ソース**: 起動時は英数入力へ自動的に切り替わります（起動後は通常どおりIMEへ戻せます）
- **スクリーン編集**: 入力待ち中に矢印キーで画面上を移動し、表示済みの行を直接修正できます
- **挿入/上書き**: `Control+I` またはEditメニューの「Insert Mode」で切り替えます
- **カナ／GRPH入力**: `Cmd+K` またはInputメニューの「Character Palette…」から選択します
- **貼り付け**: `Cmd+V` — 雑誌のプログラムリストなど複数行をまとめて流し込めます
- **画面コピー**: `Cmd+C`
- **画面の拡大／縮小**: `Cmd++` / `Cmd+-`(整数倍のみ。等倍で640×400)
- **CRT風表示**: Viewメニューの`CRT Effect`で、発光・走査線・ごく弱い周辺減光を切り替えます
- **SAVE/LOAD先**: `~/Documents/RetroBASIC/`(例: `SAVE "GAME"` → GAME.bas)

`samples/` にサンプルプログラムがあります。中身をコピーしてアプリに貼り付けて `RUN` してください。

### スクリーンエディタ

`LIST` などで表示されたプログラム行へ矢印キーでカーソルを移動し、文字を修正して
Returnを押すと、その画面行が再入力されます。80桁を超えて折り返した行も1つの行として
扱われます。

通常は上書きモードです。`Control+I` またはEditメニューの「Insert Mode」で挿入モードを
切り替えられます。挿入モードでは後続文字が右へ移動し、Backspace／Deleteで削除すると
後続文字が左へ詰まります。細い縦カーソルが挿入、ブロックカーソルが上書きを表します。

矢印キーが編集操作になるのはコマンドや `INPUT` の入力待ち中だけです。プログラム実行中は
従来どおり `INKEY$` に CHR$(28)〜CHR$(31) が渡されます。

### 文字と画面のドット

文字は8×8ドットのキャラクタです。80桁×25行はちょうど**640×200ドット**で、グラフィック
画面とまったく同じドット空間になります。テキストと図形はドット単位で重なり、拡大は
整数倍のみなので、ドットの大きさが不揃いになることはありません。

字形は1983年頃の国産8ビット機(N88-BASIC / PC-8801系)風のドットフォントを内蔵して
います。英数記号に加えて、PC-8001/8801系の文字パターンに合わせた**半角カタカナ**
(`ｱ`〜`ﾝ`、濁点・半濁点、`｢｣､･ｰ`)と56個の**GRPH文字**を文字ROM相当として持っています。

```basic
PRINT "ｺﾝﾆﾁﾊ ｾｶｲ"
```

`Command+K`で文字パレットを開き、KatakanaまたはGRPHの文字をクリックすると、パレット
下部の入力欄に文字が並びます。`←`で末尾の1文字を削除し、`GO`を押すとまとめてBASICの
カーソル位置へ挿入されます。濁音・半濁音は実機どおり、カナと濁点・半濁点の2文字です。

ひらがなや漢字は当時の8ビット機と同じく持っていません。表示はされますが、8×8ドットへ
機械的に縮小した粗い文字になります。

1ドットは実機同様に横1×縦2の比率で表示されます。等倍が640×400ピクセル、2倍が
1280×800ピクセルで、起動時は画面に収まる最大の倍率が選ばれます。

Viewメニューの`CRT Effect`を有効にすると、柔らかな発光、走査線、ごく弱い周辺減光を加えた
CRT風表示になります。効果は静的で、文字やグラフィックの元データ、表示倍率には影響しません。
設定は次回起動時にも引き継がれます。初期状態はオフです。

### 画面の桁数

`WIDTH 80` と `WIDTH 40` で、25行のまま画面の桁数を切り替えられます。切り替えると
画面はクリアされます。40桁モードではウィンドウの大きさを変えず、文字を横方向に2倍で
表示します。起動時は80桁です。

### 画面の色

`COLOR 前景色,背景色` で文字色と背景色を変更できます。色番号は0〜7で、順に
黒・青・赤・紫・緑・水色・黄・白です。背景色を省略した `COLOR 前景色` は、
現在の背景色を維持したまま文字色だけを変更します。起動時の背景色は黒です。

```basic
COLOR 7,1
PRINT "WHITE ON BLUE"
COLOR 0,7
PRINT "BLACK ON WHITE"
```

### PC-8801スタイルのグラフィック

GUI版は、テキスト画面の背面に8色のグラフィック画面を持ちます。解像度は`WIDTH`と
連動し、`WIDTH 40`では **320×200**、`WIDTH 80`では **640×200** になります。

```basic
WIDTH 80
CLS 3
LINE (80,30)-(560,170),1,B
CIRCLE (320,100),150,6
PAINT (320,100),2,6
PSET (320,100),7
```

SHARP X1 Hu-BASIC互換の8×nドット・8色タイルパターンも使えます。各行は青・赤・緑の
3バイトで表し、`HEXCHR$`で16進文字列からタイル文字列へ変換します。

```basic
T$=HEXCHR$("AA CC 33")
LINE (80,40)-(240,120),T$,BF
PAINT (320,100),T$,6
```

`CLS 1`はテキスト、`CLS 2`はグラフィック、`CLS 3`または引数なしの`CLS`は
両方を消去します。座標は左上が`(0,0)`、右下は40桁時が`(319,199)`、
80桁時が`(639,199)`です。`WIDTH`を切り替えると両画面が消去されます。

| ファイル | 内容 |
|---|---|
| HELLO.bas | COLOR/TAB/STRING$ のデモ |
| GUESS.bas | 数当てゲーム(INPUT/RND/IF) |
| STARS.bas | LOCATE/COLOR による画面デモ |
| CATCH.bas | INKEY$ を使ったリアルタイムゲーム(左右矢印キー) |
| GRAPHICS.bas | WIDTH 80／640×200・8色グラフィックのデモ |
| TILE_PAINT.bas | X1 Hu-BASIC互換の8色タイルペイント |
| 3D_MAZE_SAMPLE.bas | WIDTH 40／ランダム生成3D迷路ゲーム |
| MYSTERY_ROOM.bas | コマンド入力とタイルペイントを使う脱出ゲーム |
| MUSIC.bas | AY-3-8910風3チャンネルMML演奏 |

## 対応命令セット

**コマンド**: RUN / LIST / RENUM / AUTO / NEW / CONT / CLEAR / SAVE / LOAD / MERGE / FILES / KILL / TRON / TROFF

**ステートメント**:
LET / PRINT (`?`, `;`, `,`, TAB, SPC, USING) / INPUT / LINE INPUT /
IF〜THEN〜ELSE / FOR〜NEXT〜STEP / WHILE〜WEND / GOTO / GOSUB〜RETURN /
ON〜GOTO / ON〜GOSUB / DIM / READ / DATA / RESTORE / DEF FN / REM (`'`) /
END / STOP / CLS / LOCATE x,y / COLOR fg[,bg] / BEEP / PLAY / SWAP / RANDOMIZE /
POKE / ERASE / WIDTH 40 / WIDTH 80 / PSET / PRESET / LINE /
CIRCLE / PAINT

**関数**:
ABS INT FIX SGN SQR SIN COS TAN ATN LOG EXP RND CINT CSNG CDBL PEEK FRE POS CSRLIN /
LEN ASC VAL CHR$ STR$ LEFT$ RIGHT$ MID$ INSTR STRING$ SPACE$ HEX$ HEXCHR$ OCT$ /
SCRN$ INKEY$ INPUT$ TIME$ DATE$ POINT PLAY(n)

**演算子**: `^  * /  \(整数除算)  MOD  + -  = <> < > <= >=  NOT AND OR XOR`
(論理演算はMS BASIC同様ビット演算、真=-1)

## MML演奏

`PLAY`はAY-3-8910を想定した3チャンネルPSG音源でMMLを演奏します。各チャンネルは
矩形波、4ビット相当の音量を持ち、音程は1.789773MHzクロック／12ビット周期へ量子化
されます。既定の`MF`では演奏終了まで待機し、`Ctrl+C`または`Cmd+.`で中断できます。
`MB`を指定すると、演奏を続けながら直後のBASIC文へ進みます。
MSX BASIC互換の`PLAY(n)`関数で演奏状態を調べられます。`PLAY(0)`は全チャンネル、
`PLAY(1)`〜`PLAY(3)`はA〜Cを表し、演奏中は`-1`、終了後は`0`を返します。

`BEEP`も同じPSG音源を使用し、MSX1 BIOSの標準音（チャンネルA、E6相当の約1316Hz、
音量7、40ms）を再現します。実行時はバックグラウンドの`PLAY`を停止してBEEPを優先します。

```basic
PLAY "MFT150O4L8V13 CDEFGAB>C"  ' 終了まで待つ
PLAY "MBT150O4L8V13 CDEFGAB>C"  ' バックグラウンドで演奏
IF PLAY(0) THEN PRINT "MUSIC IS PLAYING"
PLAY ""                         ' 演奏を停止
```

使用できる主な記号は、音名`C`〜`B`、休符`R`、テンポ`T32`〜`T255`、
オクターブ`O1`〜`O8`、標準音長`L1`〜`L64`、音量`V0`〜`V15`、
ゲート長`Q1`〜`Q8`、音番号`N0`〜`N96`、付点`.`、タイ`&`、
半音上げ`+`/`#`、半音下げ`-`、オクターブ移動`>`/`<`です。
RetroBASIC拡張の`@0`はトーン、`@1`はノイズ、`@2`はトーン＋ノイズを選びます。
`MF`／`MB`のモードは次の`PLAY`にも引き継がれ、新しい`PLAY`は演奏中の曲を置き換えます。

## 実行速度について

インタプリタは1983年級のマシン相当(既定 **4000文/秒**)に調速されています。
これにより `FOR W=1 TO 300: NEXT W` のような当時定番の空ループウェイトが
本来の意図どおりの「待ち時間」として機能します。
`LIST` のスクロール速度とグラフィック命令の描画速度も同じ設定に連動します。
既定値では約30画面行/秒、グラフィックは約4000ドット/秒で途中経過を表示します。

- `SPEED 0` … 実行・LIST表示・グラフィック描画とも調速解除(最高速)
- `SPEED 4000` … 既定値に戻す(数値は文/秒、および概ね描画ドット/秒)

※ SPEED は本アプリ独自の拡張命令です。

## 当時の仕様を再現している点

- 小文字入力は文字列以外自動的に大文字化(`print` → `PRINT`)
- 数値表示: 正数は先頭に空白、`.5` `-.25` 形式、`PRINT` のカンマは14桁ゾーン
- PRINT USING は数値書式(`#`, `.`, `,`, `+`, `-`, `**`, `$$`, `**$`, `^^^^`)と
  文字列書式(`!`, `&`, `\   \`)に対応
- FOR ループは本体を必ず1回実行(NEXT で判定)
- 変数はサフィックスで型指定(`A$` 文字列 / `A%` 整数 / `A` 実数)
- 配列は未宣言でも添字10まで自動確保
- `?Redo from start` / `Break in 100` / `Ok` などのメッセージ
- 文字は8×8ドット。80×25=640×200で、グラフィック画面とドットが一致する
- 半角カタカナと56個のGRPH文字をPC-8001/8801系文字ROM相当として内蔵
- LOCATE は N88-BASIC 流の `LOCATE X,Y`(0起点・列が先)
- 矢印キーは INKEY$ で CHR$(28)〜CHR$(31)(右・左・上・下)

## 非対応(意図的な割り切り)

- EDIT
- PC-8001式2×4セミグラフィック
- 640×400モノクロ、グラフィックVRAMのページ切り替え、実VRAMへの直接アクセス
- 数値はすべて倍精度で計算(当時の単精度誤差は再現しません)

## 構成

```
Sources/Interpreter.swift    … BASICインタプリタ本体(UI非依存)
Sources/RetroCharset.swift   … 1バイト文字コードとUnicodeの相互変換
Sources/Console.swift        … 入出力プロトコル + CLI用コンソール
Sources/PSG.swift            … MMLパーサー + AY-3-8910風3チャンネル音源
Sources/RetroFont.swift      … 8×8ドットフォント(英数記号)
Sources/RetroFontKana.swift  … 8×8ドットフォント(半角カタカナ)
Sources/RetroFontGraph.swift … 8×8ドットフォント(GRPH文字)
Sources/Terminal.swift       … 80×25ターミナル画面 (AppKit)
Sources/CharacterPalette.swift … カナ／GRPH入力パレット
Sources/App.swift            … アプリ本体・メニュー
Sources/CLIMain.swift        … CLI版エントリポイント
MIDIToMML/                   … MIDI→3チャンネルMML変換Macアプリ
```
