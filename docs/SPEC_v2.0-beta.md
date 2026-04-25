# GyLogSync Direct v2.0-beta 仕様書

**作成日**：2026-04-25
**作成者**：Shinichi Maruyama / NagiLab
**法人**：Kumo, INC.
**ライセンス**：GPLv3（Gyroflow 準拠）
**配布**：GitHub Releases / kumoinc.com 直接ダウンロード（β期間中はフリー）

---

## 0. このバージョンで何が新規か

v1.0-beta.11 → v2.0-beta の差分は **Rolling Shutter 値の設定機能の追加**。
タイミング同期・IMU orientation 自動検出・`.gyroflow` 出力など、それ以外の主要機能はすべて β11 までに実装済み。

---

## 1. NagiLab 製品ラインナップ

| アプリ | プラットフォーム | 役割 | 法人 | ブランド |
|---|---|---|---|---|
| GyLog | iOS | 動画撮影中に gcsv データを収録 | Kumo, INC. | NagiLab |
| GyLogSync | Mac デスクトップ | gcsv を各動画クリップに合わせてカット | Kumo, INC. | NagiLab |
| **GyLogSync Direct** | Mac デスクトップ | gcsv カット＋全自動処理で `.gyroflow` 直接生成 | Kumo, INC. | NagiLab |

**ブランド構造**：
- 法人（Apple Developer 登録、販売契約）= **Kumo, INC.**
- 公開ブランド（YouTube / X / Instagram / SNS）= **NagiLab**
- 製品名（アプリ表示名）= GyLog / GyLogSync / GyLogSync Direct（変更なし）

---

## 2. プロダクト概要

### 2.1 目的

GyLog で収録した gcsv データと映像ファイルから、**Gyroflow Desktop を経由せず**、DaVinci Resolve の Gyroflow OFX プラグインで直接使用できる `.gyroflow` プロジェクトファイルをバッチ生成する。

### 2.2 GyLogSync との違い

| 機能 | GyLogSync | GyLogSync Direct |
|---|---|---|
| gcsv カット | ✅ | ✅ |
| gcsv ファイル出力 | ✅ | ✅ |
| タイミング同期（per-clip optical flow） | ❌ | ✅ |
| IMU orientation auto-detect（per-batch） | ❌ | ✅ |
| Rolling Shutter 値設定 | ❌ | ✅（v2.0 新規） |
| `.gyroflow` ファイル出力 | ❌ | ✅ |
| レンズプロファイル埋め込み | ❌ | ✅ |
| Gyroflow Desktop 不要 | ❌ | ✅ |

---

## 3. 処理フロー

```
[1] 映像ファイル選択（複数可・バッチ対応）
      ↓
[2] gcsv 選択
      ↓
[3] レンズプロファイル選択（任意）
      ↓
[4] RS 値選択（DB値 / 保存実測値 / 直接入力）  ← v2.0 新規
      ↓
[5] バッチ処理開始
      ├─ 解像度・fps 混在チェック → 警告ダイアログ
      ├─ クリップ 1：
      │    ├─ gcsv カット
      │    ├─ IMU orientation 自動検出（gyroflow-core::guess_imu_orientation, ~90s）
      │    ├─ optical flow 同期検出
      │    ├─ レンズプロファイル + RS値 + sync offset 埋め込み
      │    └─ `.gyroflow` 書き出し
      └─ クリップ 2〜N：
           ├─ gcsv カット
           ├─ IMU orientation = クリップ1の検出結果を再利用（~4s）
           ├─ optical flow 同期検出（クリップごと）
           ├─ レンズプロファイル + RS値 + sync offset 埋め込み
           └─ `.gyroflow` 書き出し
      ↓
[6] DaVinci Resolve の Gyroflow OFX プラグインで直接使用
```

**重要：1バッチ = 1カメラ = 1モード（解像度・fps）= 1レンズ = 1リグ取付**
gcsv ログの構造上、スマホを取り付け直すと IMU orientation が変わるため、この単位は自然に成立する。混在検出時は警告ダイアログ（「解像度／fps が混在しています。別バッチに分けることを推奨します。続行しますか？」）。

---

## 4. Rolling Shutter 値の設定（v2.0 新規機能）

### 4.1 設計方針：手動入力ファースト

ローリングシャッター補正に必要な Frame Readout Time（ms）は、カメラ機種・解像度・fps の組み合わせごとに異なる。さらに、データベースの理論値と実映像で最適な値が一致しないケースがある（例：Sony A7R II 4K 24p で DB 値 31ms に対し、実写では 20ms 前後が最適になる場合がある）。

差の原因は現時点では完全には解明されていないため、**DB を内蔵せず、ユーザーが調べた値を手で入力する設計** とする。理由：

- DB 内蔵 + ドロップダウン UI は表記揺れ・古いデータ・カメラ未対応など複雑性とメンテ負荷が大きい
- 実用上「DB 値で揺れる → 実測値で再試行」のサイクルになるなら、最初から実測値ベースで運用したほうが早い
- ユーザー側で **「ちょっとずれていたら数値を少しずつ変える」** イテレーションが直感的

### 4.2 UI

Advanced Options に1個のテキストフィールドを追加：

```
Rolling Shutter (ms): [ 20.0 ]   e.g. 31.0 for A7R II 4K 24p

Empty = use lens profile value (if any). Look up your camera at
horshack-dpreview.github.io/RollingShutter, or fine-tune in
Gyroflow Desktop's Frame Readout Time slider. When set, .gyroflow
files go into RS_{value}ms/ subfolder so you can compare different
values without overwriting.
```

- 空欄：レンズプロファイルに `frame_readout_time` があればそれを使う、無ければ RS 補正なし
- 値あり（正の数）：レンズプロファイルの値を上書きして、すべてのクリップに適用
- 値は **アプリ再起動後も保持**（`UserDefaults` `@AppStorage("rollingShutterMs")`）

### 4.3 値の調べ方（README / アプリ内ヘルプで案内）

- **horshack-dpreview Rolling Shutter Database**：https://horshack-dpreview.github.io/RollingShutter/
  - 機種＋解像度／fps を検索 → 値をコピー
  - GPL-3.0、商用利用可、出典明記推奨
- **Gyroflow Desktop で実測**（DB 値で揺れる場合）：
  1. 1本のクリップを Gyroflow Desktop で開く
  2. gcsv をロード
  3. Auto sync 実行
  4. `Stabilization → Frame Readout Time` スライダーを動かし、揺れが最小になる値を探す
  5. その値を GyLogSync Direct のフィールドに入れる
- **カメラのレビュー記事・スペックシート**

### 4.4 将来の拡張余地

ユーザーフィードバックで「カメラ別プリセットが欲しい」と要望が来たら、以下の順で拡張可能：

- (v2.1) よく使う値を複数保存できるドロップダウン
- (v2.2) horshack DB バンドル + ドロップダウンから選ぶ UI
- (v2.3) 動画メタデータからカメラ・解像度・fps 自動判別

ただし手動入力で十分という結論なら、それ以上の追加はしない。

### 4.5 既知の制約：iPhone-on-mirrorless（未検証）

Connector side セレクタは Sony A7R II + Xperia (Android) 標準マウントで実機検証済み。**iPhone をミラーレスに取り付けた場合（install_angle あり）も同じ ZYx / zYX マッピングを適用する** が、iPhone と Android で IMU 軸の細部が一致するかは未検証。理論上 X=右 / Y=上 / Z=画面外 で一致するはずだが、iOS の `CMMotionManager` が "device coordinate system" と "screen coordinate system" を使い分ける可能性があり、軸が想定通りにならないケースがありうる。

万一 iPhone-on-mirrorless で補正がおかしい場合：
1. Advanced Options の "IMU orientation override" に Gyroflow Desktop で確認した値を入力
2. または β フィードバックで報告 → 別プリセットを追加検討

---

## 5. 出力仕様

### 5.1 ファイル構成（フラット出力）

```
{動画フォルダ}/
  CLIP_001.mov                                   ← 元動画
  CLIP_001.gcsv                                  ← カット済み gcsv
  CLIP_001.gyroflow                              ← RS 値未設定の場合
  CLIP_001_RS20ms.gyroflow                       ← RS=20ms で生成
  CLIP_001_RS31ms.gyroflow                       ← RS=31ms で生成（共存）
  CLIP_002.mov
  CLIP_002.gcsv
  CLIP_002_RS20ms.gyroflow
  ...
```

### 5.2 ルール

- 動画と同じフォルダにすべて出力（サブフォルダ作らない）
- gcsv ファイル名：`{クリップ名}.gcsv`（RS 非依存・上書き）
- `.gyroflow` ファイル名：
  - RS 値**未設定**：`{クリップ名}.gyroflow`（毎回上書き）
  - RS 値**設定**（例 20ms）：`{クリップ名}_RS20ms.gyroflow`（異なる RS 値で共存）

### 5.3 DaVinci OFX 自動ロードの仕組みと運用上の注意

Gyroflow OFX プラグインは動画ファイルと同じフォルダ内で `.gyroflow` を自動検索する（[gyroflow-plugins/common/src/lib.rs::get_project_path](https://github.com/gyroflow/gyroflow-plugins) 参照）：

1. まず動画と同名の `{クリップ名}.gyroflow` を探す
2. 無ければ「動画名で始まり `.gyroflow` で終わる」ファイルを同フォルダで探す
3. **サブフォルダは見ない**

そのため `.gyroflow` を動画と同じフォルダに置く設計とした。

**複数の RS 値で生成して共存させた場合**、OFX は「ディレクトリ内の最初に見つけたもの」を読み込む（非決定的）。意図した RS 値で読み込ませたい場合は、不要な variant を削除または別フォルダに退避する。

### 5.4 推奨運用フロー

1. **horshack DB 値でまず試す** → 全クリップを bulk 処理 → DaVinci で確認
2. **揺れが残るなら 1 クリップだけ Gyroflow Desktop で実測** → 最適な RS 値を見つける
3. その値を GyLogSync Direct の Rolling Shutter フィールドに入力 → bulk 再処理
4. 古い variant の `.gyroflow` は削除して clean な状態にする

### 5.3 出力先

```
出力先:  [ ] 元の映像ファイルと同じフォルダ
         [ ] 指定フォルダ
```

---

## 6. 既存機能（v1.0-beta.11 で実装済み、v2.0 では変更なし）

### 6.1 タイミング同期

- 各クリップで個別に optical flow ベースの sync を実行
- 結果（offset）を `.gyroflow` の `gyro_source.offsets` に埋め込み
- DaVinci OFX プラグインは Auto sync 機能を持たないため、Mac 側での sync が必須

### 6.2 IMU orientation 自動検出

- バッチ最適化：クリップ 1 で `gyroflow-core::guess_imu_orientation` を実行（~90s）
- 結果を文字列で取得し、クリップ 2〜N にはその値を直接渡す（~4s）
- 物理的な取付は1バッチ内で固定なので、これで安全
- iPhone vs Android は gcsv の `id` フィールドから自動判別
  - `iPhone_Motion_Logger` → `XYZ`
  - `Android_Motion_Logger` → header の `orientation` 値（標準的には `ZYx`）
- ユーザーが手動で 3 文字の orientation 値（例：`ZYx`, `XyZ`）を Advanced Options から指定することも可能

### 6.3 レンズプロファイル

- ファイルピッカーで任意の `.json` を指定（オプション）
- 指定した場合、`.gyroflow` の `calibration_data` に埋め込み
- DaVinci OFX 側で何もせずレンズ補正がかかる
- 理由：DaVinci OFX の "Load lens profile" ボタンが gyroflow-plugins v2.1.1 で壊れているため、埋め込み方式が必要
- レンズプロファイル自体は Gyroflow Desktop の Calibrator で別途作成（一生もの・1レンズ1回）

---

## 7. ライセンス・法的事項

| コンポーネント | ライセンス | 対応 |
|---|---|---|
| Gyroflow / gyroflow_core | GPLv3 | ソースコード GitHub 公開 |
| RS 値データベース（horshack） | GPL-3.0 | バンドルしないため特別対応不要。README で出典 URL を案内 |
| GyLogSync Direct 本体 | GPLv3 | github.com/kumost/gylogsync-direct で公開 |

---

## 8. 配布

### 8.1 配布形態

- **GitHub Releases**：github.com/kumost/gylogsync-direct/releases
- **公式サイト**：kumoinc.com からの直接ダウンロード
- **Mac App Store は使用しない**（GPLv3 と App Store 利用規約は DRM 条項等で衝突するため、原則として GPLv3 ソフトウェアの配布経路として使用できない）

### 8.2 価格モデル

- **β 期間中はフリー**：v2.0-beta はフィードバック収集を目的として無料配布
- **正式版（v2.0）以降の有料化を検討中**：β 期間のフィードバックと利用状況を見て決定

### 8.3 コードサイニング

- Apple Developer ID（Kumo, INC.）で署名
- Apple Notarization 取得済み
- ユーザーは macOS Gatekeeper の警告なしでインストール可能（初回のみ「インターネットからダウンロードされました」の確認ダイアログ）

### 8.4 動作環境

- macOS 13 (Ventura) 以降
- Apple Silicon 推奨（Rust bridge を arm64 + x86_64 でビルド）

---

## 9. 参考リンク

- Gyroflow GitHub: https://github.com/gyroflow/gyroflow
- Gyroflow ライセンス: GPLv3
- gyroflow-plugins (DaVinci OFX): https://github.com/gyroflow/gyroflow-plugins
- Rolling Shutter Database: https://horshack-dpreview.github.io/RollingShutter/
- GCSV 形式仕様: https://docs.gyroflow.xyz/app/technical-details/gcsv-format
- 本リポジトリ: https://github.com/kumost/gylogsync-direct

---

## 10. 仕様レビュー履歴

- 2026-04-25：v2.1 ドラフト → v2.0-beta として再構成（全 11 項目をレビュー）
  - スコープ修正：v2.1 で追加と書かれていた機能のうち、Rolling Shutter 値設定以外は β11 までに実装済みであることを明確化
  - 命名修正：仕様書ドラフトの "GyroSync Direct / NagiLab" を、製品名は現行の "GyLogSync Direct"、法人は "Kumo, INC."、SNS ブランドは "NagiLab" の三層に整理
  - UI 改修：Mode A / Mode B の階層を廃止し、1画面で「DB 値 / 保存実測値 / 直接入力」の3択ラジオに簡素化
  - 出力仕様変更：ファイル名サフィックス案を、フォルダ分け（gcsv は親フォルダに1セット、`.gyroflow` は `RS_{値}ms/` サブフォルダ）に変更
  - ライセンス記述修正：誤った App Store Exception 記述を削除し、Mac App Store を使用しない旨を明記
- 2026-04-25：実装着手時に再簡素化
  - **DB バンドル＋ドロップダウン UI を廃止し、テキストフィールド1個での手動入力に切り替え**。理由：DB 値と実測値が乖離する既知の問題があり、結局ユーザーが手で調整する運用になるため。「自分で調べた数値を入れて、ずれてたら少しずつ変える」のほうがシンプルで誤解が少ない
  - 実装スコープが大幅縮小：horshack DB 取得・正規化辞書・カメラ自動判別・ドロップダウン UI・カスタム値永続化は全て不要に。最小実装は ~1〜2 時間の作業で完結
  - 値は `UserDefaults` (`@AppStorage`) でアプリ再起動後も保持
  - 将来的なドロップダウン UI 化は v2.1 以降の拡張余地として残す
