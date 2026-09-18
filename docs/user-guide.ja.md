# QuotaTempoの導入と使い方

このガイドは、Developer ID署名とAppleのnotarizationが完了し、公式GitHub Releasesから配布されるQuotaTempo Public Betaを対象にしています。Public Beta版に利用期限はなく、開発は今後も継続します。正式版や今後の追加機能の提供形態・価格は未定です。

## 動作条件

- macOS 14以降
- Apple silicon
- ログイン済みの対応providerが最低1つ：公式CodexアプリまたはCLI、Claude Desktop、Claude Code

CodexBarは必要ありません。QuotaTempo自身がproviderへログインすることも、token、cookie、API keyの入力を求めることもありません。

## 確認してインストールする

1. QuotaTempoのZIPと公開SHA-256を、同じ公式releaseページからダウンロードします。
2. Terminalでarchiveのhashを計算します。

   ```bash
   shasum -a 256 QuotaTempo-<version>-macOS.zip
   ```

3. 値全体が、そのreleaseで公開されたSHA-256と完全に一致することを確認します。
4. FinderでZIPをダブルクリックして展開し、Finder上で`QuotaTempo.app`を`/Applications`またはユーザーの`Applications`フォルダへドラッグします。macOSがユーザーによる移動として記録し、App Translocationから起動しないよう、展開と移動の両方をFinderで行ってください。
5. ApplicationsからQuotaTempoを開きます。初回案内ウインドウが前面に表示され、起動したこととメニューバー表示の選び方を確認できます。QuotaTempoはDockには表示されません。

公開版はApple Developer IDで署名し、Appleのnotarizationを通した状態で提供します。macOSに「開発元を確認できない」「アプリが壊れている」などと表示された場合は、そこで停止してください。Gatekeeperを迂回せず、公式配布元とSHA-256を再確認し、QuotaTempoのversionとmacOSの正確な表示内容を公開support窓口へ伝えてください。

## メニューバー表示の読み方

両方を有効にした場合、Full表示は次の形式で比較します。

```text
[Codex glyph] W34/P48 ↓14 · [Claude glyph] W60/P48 ↑12
```

- `W`はproviderが示した週間残量です。
- `W?`は最新の更新を待っている、最後に確認した週間残量です。現在の`P`との差を計算しないでください。
- `P`は週間resetから7日間均等に使う前提で計算した、その時点での理想残量です。
- `↑`は計画より余裕がある量です。
- `↓`は計画を下回っている量です。

差はpercentage pointです。QuotaTempoは数字を比較しますが、どちらを使うべきかは推薦しません。

メニューを開くと、次のreset基準checkpoint、checkpointでの目標残量、そこまで使える量、取得元、鮮度、取得時刻、取得状態を確認できます。5時間枠は、直近の制約になる場合だけ表示します。

## 表示量を選ぶ

混み合ったメニューバーやノッチのあるMacで隠れにくいよう、初期設定は**Icon only**です。初回案内ウインドウ、または後から**メニューバー表示**で三つの表示から選びます。

- **Full**：中立的なprovider識別glyph、週間残量、現在の計画、差
- **Compact**：中立的なprovider識別glyph、週間残量、差
- **Icon only**：中立的なmetronome glyphのみ。値は開いて確認

1回分のリセット推定を使う場合、コンパクト表示でも推定記号を計画側へ付け、`[Claude glyph] 75↑25 P≈`と表示します。

選択内容はQuotaTempo自身のmacOS設定へ保存します。CodexやClaudeの設定は変更しません。観測済みのリセット時刻がすでに過ぎている場合、古い週間残量は表示せず、現在の観測が届くまで**新しい利用枠を待機中**と表示します。

## 初回ガイドとログイン時起動

初回ガイドでは、provider選択、`W`、`P`、`P≈`、矢印の意味を説明します。Full、Compact、Icon onlyの見本も実際の表示に近い形で示し、その場で切り替えられます。表示言語が英語の場合は**Got It**、日本語の場合は**わかりました**を押すと通常の比較画面へ進みます。後から**表示の見方**で開き直せます。

![Full、Compact、Icon onlyの見本を含む初回案内](assets/fixture-onboarding-ja.png)

小さい画面やmacOSの「文字を拡大」設定では、パネル自体が画面外へはみ出さない高さに自動調整されます。その場合は表示されるスクロール位置を使って、最下段の操作と**法的情報**まで確認できます。

メニューバー項目がノッチやほかの項目に隠れた場合は、ApplicationsからQuotaTempoをもう一度開いてください。起動中のQuotaTempoがアプリケーションウインドウを前面へ出し、同じ比較、設定、更新、終了操作を利用できます。初回案内の完了後、任意で有効にしたログイン時起動はウインドウを出さず静かに開始します。

各providerの詳細にある**週間リセット**は、providerの7日間枠が終了する日時です。**次の区切り**は、そのリセットから24時間単位で逆算した次の計画境界であり、別のリセットではありません。詳細日時には曜日も表示します。Claudeで最後に確認したリセットを安全に1週間だけ進めた場合は、**週間リセット（推定）**と表示します。日時が未取得・期限切れ・安全に使えない場合は`—`のままです。

## Codexのbanked resetを使った場合

OpenAIは、一度だけ使える[banked Codex reset](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work)を提供することがあります。full resetを適用すると、Codexの5時間枠と週間枠が更新され、週間リセット日も変わります。QuotaTempoは、reset特典の有無を探したり、resetを適用したり、有効期限を管理したりしません。

resetを適用した後は、Codexの設定 › 使用状況で新しい枠を確認し、QuotaTempoの**更新**を押してください。取得に成功すると、以前のprovider観測値を新しい枠で置き換え、`W`、`P`、区切りの予定を再計算します。自動またはglobal resetは、banked resetとして表示されず直接適用される場合があります。QuotaTempoはCodexから報告された枠に追従しますが、枠が変わった理由までは推測・表示しません。

QuotaTempoがLogin Itemsへ自動登録されることはありません。`/Applications`またはユーザーの`Applications`フォルダへ移動してから、**ログイン時に起動**を有効にしてください。ダウンロード、App Translocation、一時ディレクトリ、検証用コピーからはログイン項目を変更できません。macOS側の許可が必要な場合、その要求はまだ有効ではありません。表示に従ってシステム設定 › 一般 › ログイン項目で許可してください。アプリの移動、置換、アンインストール前にはこの設定をOFFにしてください。

## Providerを選ぶ

**表示するprovider**で、Codex、Claude、または両方を有効にできます。最低1つは有効のままです。無効にしたproviderはpopoverとメニューバーから消え、更新対象にもなりません。最後の正規化済み観測値はローカルに保持されるため、再び有効にしても履歴を破棄しません。取得失敗だけを理由に、QuotaTempoがproviderを自動で無効化することはありません。

初回起動時は、有効な観測値を確認できたproviderを選びます。どちらも検出できない場合は両方を表示し、利用者が明示的に選べる状態を保ちます。この設定はQuotaTempoの表示と取得だけを変え、providerのログアウトや設定変更は行いません。

## 更新と鮮度

QuotaTempoは起動時、起動中の15分ごと、Macのスリープ復帰時に、有効なproviderだけを範囲限定で取得します。Claudeのローカル観測は、起動中に約1分ごとにも確認します。メニューを開いたときの更新にはprovider別の再試行間隔（Codexは5分、Claudeは55秒）を適用します。自動更新とメニュー表示時の更新は、同じproviderの取得中に二重実行しません。**更新**を押すと、有効なproviderをすぐに再取得します。取得中は**更新中…**と表示し、buttonを無効化します。

- **最新**または**最近**の値は、計画と比較できます。
- **更新待ち**では、最後に観測した週間残量を`W?`として残します。リセットがまだ有効なら、`P`とリセットから求める区切りも表示しますが、目標差と利用可能量は最新の残量が届くまで表示しません。
- `P≈`は、最後に確認した週間resetを1期間だけ進めて現在の計画を推定している状態です。詳細画面にも根拠を表示します。新しいresetを取得すると自動で正確な値へ戻り、推定値から次の推定値を連鎖させません。
- **リセット時刻未取得**は、週間残量は有効でも計画計算に必要なreset日時がproviderから得られなかった状態です。`W`は残し、`P`と差を`—`で表示します。
- **利用不可**は、必要な情報が欠けている、無効、期限切れ、またはprovider側で形式が変わった状態です。
- **アクセス制限中**は、通常利用できないとproviderが明示した状態です。QuotaTempoはpercentageから利用可能だと推測せず、値を隠します。

更新に失敗しても、古い観測値を新しい値として扱いません。有効なローカル残量を保持したままreset取得だけが失敗した場合は、残量と失敗した試行を分けて表示します。取得状態と観測時刻も別々です。

## Providerが利用不可の場合

1. 公式providerアプリまたはCLIがインストール済みで、ログインできていることを確認します。
2. provider自身のusage画面が通常どおり確認できることを確かめます。
3. QuotaTempoへ戻り、**更新**を1回押します。
4. 利用不可が続く場合は、**診断情報をコピー**を押し、その内容とproviderアプリまたはCLIのversionをsupportへ伝えます。

Codexの詳細画面では、未インストール、起動失敗、既知の旧version、上流protocol変更、timeout、出力安全上限、一時的な失敗を区別します。表示された対処を行ってから再度更新してください。QuotaTempoは署名を検証できた公式デスクトップ版を優先し、範囲を限定して代替候補も試すため、古いHomebrew版だけで正常なデスクトップ版が隠れることはありません。

コピーされる診断情報は、QuotaTempoとmacOSのversion、有効なprovider、正規化した取得元、Codex実行元の分類と正規化済みsemantic version（取得できた場合）、鮮度、取得状態だけです。percentage、reset日時、local path、raw version出力、credential、session内容は含みません。raw provider file、prompt、transcript、cookie、token、credential、private URLは送らないでください。上流のinterfaceが変化した場合、QuotaTempoは欠けた値を推測せず安全側で停止します。

## 更新する

最初のSparkle対応版は、公式releaseページまたは下記のHomebrewコマンドからインストールします。この版が、以後のアプリ内更新を有効にするbridge releaseです。

bridge releaseの導入後は、QuotaTempoの**アップデートを確認...**からいつでも確認できます。macOSの確認画面で自動チェックを有効にした場合、Sparkleは最大1日1回確認し、インストール前に更新内容を表示します。QuotaTempoが無断で強制更新することはありません。

Homebrewでは第三者Caskへの明示的なtrustが必要です。次の1行はQuotaTempoのCaskだけをtrustし、公開repoを配布元として登録して、同じnotarized releaseをインストールします。

```bash
brew trust --cask ishikawa-hidekazu/quotatempo/quotatempo && brew tap ishikawa-hidekazu/quotatempo https://github.com/Ishikawa-Hidekazu/quota-tempo.git && brew install --cask ishikawa-hidekazu/quotatempo/quotatempo
```

以後のコマンド更新には`brew upgrade --cask ishikawa-hidekazu/quotatempo/quotatempo`を使います。

この確認が通るまでは、直前の検証済みarchiveをrollback元として保持してください。

正規化済みの観測値は、別途削除しない限りQuotaTempoのApplication Support directoryへ残ります。

## アンインストールと観測値の削除

1. **ログイン時に起動**が有効ならOFFにします。
2. **QuotaTempoを終了**を選びます。
3. `QuotaTempo.app`をゴミ箱へ移します。
4. QuotaTempoが保持する正規化済みの観測値も消す場合は、次を削除します。

   ```text
   ~/Library/Application Support/QuotaTempo/
   ```

5. 表示形式、provider選択、初回ガイドの設定も消す場合は、[Privacy](../PRIVACY.md)に記載した`co.ishikawa.QuotaTempo` preference domainを削除します。

QuotaTempoを削除しても、CodexやClaudeの認証は変更されません。アプリ内の**規約・情報**から、bundle内のライセンス、プライバシー、更新方針、第三者表記、サポートを開けます。技術上の境界は[Security](../SECURITY.md)を確認してください。
