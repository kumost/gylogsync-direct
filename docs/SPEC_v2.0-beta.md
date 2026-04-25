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

### 4.1 背景

ローリングシャッター補正に必要な Frame Readout Time（ms）は、カメラ機種・解像度・fps の組み合わせごとに異なる。さらに、データベースの理論値と実映像で最適な値が一致しないケースがある（例：Sony A7R II 4K 24p で DB 値 31ms に対し、実写では 20ms 前後が最適になる場合がある）。

差の原因は現時点では完全には解明されていないが、同期タイミングの微小なズレが影響している可能性がある。β 期間中はユーザーフィードバックを集め、必要なら追加調査する。

そのため、**DB 値・実測値・直接入力の3択を1画面で選べる設計**とする。

### 4.2 UI（Mode A/B 等の階層なし、1画面で完結）

```
┌──────────────────────────────────────────────────────────────┐
│  Rolling Shutter 設定                                        │
│                                                              │
│  カメラ機種:   [Sony A7R II                          ▼]    │
│  解像度/fps:   [4K 24p (3840x2160)                   ▼]    │
│                                                              │
│  RS 値:                                                      │
│    ● データベース値:           31.08 ms                     │
│    ○ 保存済み実測値:           20.00 ms  [削除]             │
│    ○ 直接入力:                 [        ] ms  [この値を保存]│
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

- カメラ機種を選ぶと、その機種でデータが存在する解像度/fps だけを 2 段目に表示
- DB 値は horshack-dpreview Rolling Shutter Database から取得（バンドル）
- 「保存済み実測値」はそのカメラ＋モードで以前 Mode B で保存したものがあれば表示、なければラジオごと非表示
- 「直接入力」で `[この値を保存]` を押すと「保存済み実測値」枠に登録される
- 同じカメラ＋モードに新しい実測値を保存したら上書き

### 4.3 horshack DB の取り込み

- データソース：[horshack-dpreview/RollingShutter](https://github.com/horshack-dpreview/RollingShutter)
- ライセンス：GPL-3.0（本アプリと同一）
- 配置：`Resources/rolling_shutter_db.json`（アプリビルド時にバンドル）
- 更新：horshack 側に新カメラが追加された場合は、本アプリのアップデートで取り込む
- ユーザー報告：README に新カメラ報告用メールアドレスを記載
- 表記揺れ対応：カメラ機種名の正規化辞書（"ILCE-7RM2" → "Sony A7R II" 等）を別 JSON で同梱

### 4.4 RS 値調整の推奨手順（アプリ内ヘルプ）

**ステップ 1：まずデータベース値で試す**
DB 値を選んでバッチ生成し、DaVinci Resolve で映像を確認する。

**ステップ 2：揺れが残る場合**
Gyroflow Desktop で1本のクリップだけ実測：
1. gcsv と映像を読み込む
2. Auto sync を実行し、同期ポイントが揃っているか確認
3. `Stabilization → Frame Readout Time` スライダーを動かし、最も揺れが少ない値を探す
4. その値をメモ

参考：[horshack RS Database](https://horshack-dpreview.github.io/RollingShutter/)

**ステップ 3：実測値を GyLogSync Direct に登録**
「直接入力」に値を入れて `[この値を保存]` を押す。以降のバッチ処理ではこの「保存済み実測値」を選べるようになる。

**注意**：保存した実測値は、その時の sync 状態を前提とした最適値です。アプリのアップデートで sync アルゴリズムが変わると、再測定が必要になる場合があります。

---

## 5. 出力仕様

### 5.1 ファイル構成

```
{出力先フォルダ}/
  CLIP_001.gcsv                                  ← gcsv は1セットのみ（RS 非依存）
  CLIP_002.gcsv
  CLIP_003.gcsv
  ...
  RS_31.0ms/                                     ← DB 値で生成した結果
    CLIP_001_RS31.0ms.gyroflow
    CLIP_002_RS31.0ms.gyroflow
    CLIP_003_RS31.0ms.gyroflow
    ...
  RS_20.0ms/                                     ← 別 RS 値で再生成した結果
    CLIP_001_RS20.0ms.gyroflow
    CLIP_002_RS20.0ms.gyroflow
    ...
```

### 5.2 ルール

- gcsv は出力フォルダ直下に1セット（RS 値に依存しないため）
- `.gyroflow` は `RS_{値}ms/` サブフォルダ内に配置
- `.gyroflow` ファイル名は `{クリップ名}_RS{値}ms.gyroflow`
- `.gyroflow` 内の `gyro_source.filepath` は親フォルダの gcsv への **相対パス**（`../{クリップ名}.gcsv`）
- 同じ RS 値で再実行 → サブフォルダ内で **黙って上書き**（同じ RS = 同じ結果想定なので情報損失ゼロ）

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
| RS 値データベース（horshack） | GPL-3.0 | LICENSE-horshack 同梱、`THIRD_PARTY_LICENSES.md` に追記 |
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
