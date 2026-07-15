# rmd

`rmd` は、macOS 標準のリマインダーを EventKit 経由で読み書きする
Swift 製の小さなコマンドラインツールです。

## 対象範囲

最初のバージョンでは Reminders のみを扱います。Calendar 連携は対象外です。
通常は人間が読みやすい形式で表示し、スクリプト向けには `--json` を使えます。

## コマンド

リマインダーを一覧表示します。

```sh
rmd list
rmd list --list "仕事"
rmd list --list "仕事" --list "買い物"
rmd list --yesterday
rmd list --today
rmd list --tomorrow
rmd list --overdue
rmd list --next 7
rmd list --due-from "2026-06-18"
rmd list --due-to "2026-06-30"
rmd list --due-from "2026-06-18" --due-to "2026-06-30"
rmd list --completed
rmd list --completed --yesterday
rmd list --completed --today
rmd list --completed-from "2026-06-01" --completed-to "2026-06-18"
rmd list --limit 10
rmd list --json
```

1 件のリマインダーを詳細表示します。メモもここで確認できます。

```sh
rmd show <reminder-id>
rmd show <reminder-id> --json
```

リマインダーを作成・編集します。

```sh
rmd add "牛乳を買う"
rmd add "牛乳を買う" --due "2026-06-18 18:00" --list "買い物" --note "低脂肪"
rmd add "牛乳を買う" --verbose

rmd edit <reminder-id> --title "牛乳と卵を買う"
rmd edit <reminder-id> --due "2026-06-19 09:00"
rmd edit <reminder-id> --clear-due
```

リマインダーを削除、完了、または未完了に戻します。

```sh
rmd delete <reminder-id>
rmd delete <reminder-id> <reminder-id>
rmd delete <reminder-id> --verbose

rmd done <reminder-id>
rmd done <reminder-id> --verbose
rmd undone <reminder-id>
```

リストを表示します。

```sh
rmd lists
rmd lists --json
```

## ID

リマインダー ID には、EventKit のフル ID か、一意に決まる短い prefix を使えます。
通常の表形式では先頭 8 文字だけを表示します。`edit`、`done`、`undone`、
`show` などの ID 指定コマンドでは、4 文字以上の prefix が 1 件にだけ一致すれば
そのリマインダーを対象にします。

## 出力

`add`、`edit`、`done`、`undone` は、成功時には何も表示しません。確認メッセージが
必要な場合は `-v` または `--verbose` を指定してください。変更後のリマインダーを
JSON で受け取りたい場合は `--json` を使います。

`delete` は 1 件以上の ID を受け取り、削除前に 1 件ずつ確認します。
`y` または `yes` と入力した場合だけ削除し、それ以外の入力ではスキップします。

## 日付

日付は `yyyy-MM-dd`、`yyyy-MM-dd HH:mm`、`yyyy年M月d日`、
`yyyy年M月d日 HH:mm`、`令和y年M月d日`、`令和y年M月d日 HH:mm` で指定できます。
日本の暦で扱える `平成` や `昭和` などの年号も使えます。

`--due-to "2026-06-30"` や `--completed-to "2026-06-30"` のように日付だけを
上限に指定した場合、その日全体を含みます。`--due-to "令和8年6月30日"` の
ような和暦の日付だけの指定でも同じです。

`--yesterday`、`--today`、`--tomorrow` のような相対日付指定は、通常は期限に
対して効きます。`--completed --today` のように完了済み表示と組み合わせると、
期限ではなく完了日時に対して絞り込みます。

`--limit 件数` を指定すると、絞り込みと並び替えの後、先頭の件数だけを表示します。

`rmd list` は、`--list` を指定しない場合は全リストを対象にします。複数のリストに
絞り込む場合は、`--list リスト名` を繰り返し指定します。

## デフォルトリスト

`rmd add` で `--list` を省略した場合、`RMD_DEFAULT_LIST` で保存先リストを
指定できます。

```sh
export RMD_DEFAULT_LIST="買い物"
rmd add "牛乳を買う"
```

`RMD_DEFAULT_LIST` が未設定または空の場合は、macOS のデフォルト Reminders
リストを使います。

## 権限

Reminders に初めてアクセスするコマンドを実行すると、macOS が Reminders への
フルアクセス許可を求めます。拒否した場合は、システム設定の
「プライバシーとセキュリティ」>「リマインダー」から許可してください。

SSH などの非 GUI セッションでは初回の権限ダイアログを操作しづらいため、
最初は Mac の GUI セッションで `rmd lists` などを実行して許可しておくのが安全です。

## ビルド

```sh
make
```

最適化したバイナリをビルドして、`PATH` の通った場所へコピーします。

```sh
make release
make install
```

個人用のコマンドを `~/bin` などに置いている場合は、コピー先を
`~/bin/rmd` などに変更してください。

```sh
make install PREFIX="$HOME"
```

SwiftPM を直接実行することもできます。

```sh
swift build
swift build -c release
```

開発中に実行する例:

```sh
make run
```

## ライセンス

MIT License です。詳細は [LICENSE](LICENSE) を参照してください。
