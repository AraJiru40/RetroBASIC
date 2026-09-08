# MIDI to RetroBASIC MML

Standard MIDI FileをRetroBASICのAY-3-8910向け3チャンネルMMLプログラムへ変換する
macOSアプリです。

## 主な機能

- MIDI Format 0 / 1、テンポ変更、ランニングステータスに対応
- MIDIトラック×チャンネル単位のパートをPSG A・B・Cへ割り当て
- 1/8、1/16、1/32音符への量子化
- 和音を最高音優先でPSG用の単音へ整理
- MIDIチャンネル10のドラムをAYノイズ（`@1`）へ変換
- ベロシティをMML音量（`V1`〜`V15`）へ変換
- フォアグラウンド（`MF`）／バックグラウンド（`MB`）演奏を選択
- 行番号付きBASICをクリップボードへコピー、または`.bas`で保存

## 使い方

1. `OPEN MIDI`を押すか、`.mid`／`.midi`をウインドウへドロップします。
2. MIDIパートをPSGチャンネルA、B、Cへ割り当てます。
3. 量子化、バックグラウンド演奏、ベロシティ変換を選びます。
4. `COPY BASIC`でコピーするか、`SAVE .BAS`で保存します。
5. 生成されたプログラムをRetroBASICで`LOAD`／貼り付けして`RUN`します。

長さが10分を超える曲、SMPTE時間形式、MIDI Format 2には対応していません。

## ビルドとテスト

```bash
./test.sh
./build.sh
open MIDIToMML.app
```

macOS 13以降に対応します。
