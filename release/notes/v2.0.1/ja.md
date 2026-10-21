Crok Desktop 2.0.1 は、このフォークのネイティブ macOS アプリです。エージェントのランタイムと `crok` ターミナル UI である crok を同梱しているので、ほかにインストールするものはありません。これは 2.0.0 に続くリリースです。2.0.0 では、リモートコントロールに専用の本番リレー https://crok.chenli.dev が用意され、初めて iOS と Android のアプリも含めたリリースとなりました。2.0.1 はその後の作業のリリースで、2.0.0 に加えて行われた修正と改善が入っています。**ハイライト** のリストは、その作業の進行に合わせて増えていきます。

このリリースも 2.0.0 と同様に、プルリクエストがマージされるとすぐに GitHub Actions がビルドして公開します。

### インストール

1. お使いの macOS のバージョンに合ったディスクイメージをダウンロードして開きます。どちらを選ぶかは**どのディスクイメージをダウンロードするか**の表をご覧ください。
2. **Crok Desktop** を**アプリケーション**にドラッグします。
3. アプリケーションから Crok Desktop を開きます。このビルドは公証されていないため、初回は macOS がアプリを検証できないと表示します。メッセージを閉じ、**システム設定 › プライバシーとセキュリティ**を開いて、Crok Desktop のメッセージの横にある**このまま開く**をクリックし、確認してください。この操作は一度だけです。
4. **設定 › アカウント**で、OpenRouter、OpenAI Codex、Anthropic API キー、DeepSeek API キー、または GLM Coding Plan のキーでサインインします。

Apple シリコン（M1 以降）を搭載した Mac と、macOS 14 Sonoma 以降が必要です。

### どのディスクイメージをダウンロードするか

どちらのイメージも Crok Desktop 2.0.1 で、機能は同じです。違いはビルドに使った macOS SDK だけで、これによってウインドウの外観に Apple の Liquid Glass が使われるかどうかが決まります。

| ディスクイメージ | ビルドに使った SDK | 対象 | タイトルバー |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.1-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 以降 | Liquid Glass |
| `Crok-Desktop-2.0.1-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 と 15 | ウインドウ内のすりガラス風のぼかし |

macOS 26 以降では、タイトルバーが Liquid Glass になる macOS 26 SDK のイメージをおすすめします。macOS 14 または 15 では、macOS 15 SDK のイメージを使ってください。こちらはそれ以降のバージョンでも動くので、macOS のバージョンがわからない場合はこちらが安全です。

`crok-2.0.1-aarch64-apple-darwin.tar.gz` は `crok` ターミナル UI 単体で、アプリを入れたくない Mac 向けです。展開して `crok` を `PATH` の通った場所に置いてください。スマートフォンアプリについては、**スマートフォンアプリ**で説明しています。`SHA256SUMS.txt` はすべてのダウンロードファイルの SHA-256 の一覧、`SHA256SUMS.txt.sig` はその一覧の署名で、アップデート機能がこれを検証します。

### スマートフォンアプリ

iPhone と Android 向けの Crok アプリは、お使いのコンピューターのセッションを追いかけ、その応答と権限の要求を表示し、どこからでもタスクを開始したり操作したりできます。2.0.0 と同様に、このリリースに含まれます。3 つのファイルはいずれも本番リレーにサインインします。

- **Android 8.0 以降**：スマートフォンで `Crok-Android-2.0.1.apk` をダウンロードして開きます。Android に求められたら、ブラウザにアプリのインストールを許可してください。または `adb install -r Crok-Android-2.0.1.apk` を実行します。この APK は今後のリリースでも使い続けるリリース用の鍵で署名されているため、次の APK はこの上にそのままインストールできます。自分でビルドした Crok の APK は別の鍵で署名されていて、インストールを妨げます。先に `adb uninstall dev.chenli.crok.mobile` を実行するか、スマートフォンの設定から削除してください。
- **iPhone と iPad、iOS 17 以降**：`Crok-iOS-2.0.1-unsigned.ipa` は署名されていません。iOS デバイス向けのアプリは、インストールする人の Apple ID で署名されるためです。AltStore や Sideloadly などのサイドロードツールでインストールしてください。これらのツールがお使いの Apple ID で署名します。無料の Apple ID の場合、7 日たつと、もう一度インストールするまで iOS はアプリを開かなくなります。代わりに自分でビルドする場合は、**Release** 構成を使ってください。Xcode の Run ボタンは Debug をビルドし、そちらはテスト用リレーにサインインします。
- **iOS シミュレータ**：`Crok-iOS-2.0.1-Simulator.zip` を展開すると `Crok.app` になります。Xcode のある Mac で `xcrun simctl install booted Crok.app` を実行するためのものです。

スマートフォンをサインインさせるには、**GitHub または Google で続ける**をタップし、開いた https://crok.chenli.dev のページでサインインして、**承認**をタップします。続いて、各コンピューターをリンクします。そのコンピューターで `crok remote login` を実行し、表示された QR コードをアプリの**設定 › コンピュータをリンク**から読み取るか、開いた Web ページでそのコンピューターを承認してください。

### ハイライト

- **2.0.1 は、2.0.0 の後の作業のリリースです。** 2.0.0 以降、`charlie/dev` ブランチで行われた修正と改善を備えており、このリストはその作業の進行に合わせて増えていきます。
- **リリースのしくみは 2.0.0 が導入したものです。** 2.0.1 も、同じ GitHub Actions のパイプラインでビルド、検証、署名、公開され、これらのノートは `release/notes/v2.0.1/` にコミットされています。
- **リレーとスマートフォンアプリは、これまでどおり動きます。** 2.0.1 も同じ本番リレー https://crok.chenli.dev にサインインし、スマートフォンアプリは 2.0.0 と同じ挙動を保ちます。下の **リモートコントロール** をご覧ください。
- **アップデートがお使いのアプリにそのままインストールされるようになりました。** 2.0.0 以降、**Crok Desktop › アップデートを確認…** と `crok upgrade` は、インストール済みの `Crok Desktop.app` に新しいバージョンを一度に入れます。そのため Dock や Finder での位置はそのままで、古いコピーがゴミ箱に残ることもありません。インストールの前には、新しいバージョンが同じ証明書で署名されていることを確認します。macOS が Crok Desktop に与えた権限（「アクセシビリティ」、「画面収録」、マイク）が保たれるのは、このためです。別の署名のリリースは、`crok upgrade --allow-new-signature` を実行しない限り拒否されます。
- **エージェントが Crok と名乗るようになりました。** システムプロンプトは、どのプロバイダでも「You are Crok.」で始まるようになりました。以前は、モデルが Claude、DeepSeek、GLM の場合でも Grok という名前になっていました。`agent.system_prompt_label`、`model.<id>.system_prompt_label`、`CROK_SYSTEM_PROMPT_LABEL` では、これまでどおり別の名前を設定できます。

### リモートコントロール

このリリースのすべての crok（ターミナル UI、Crok Desktop に含まれるもの、単体の tarball）は、本番リレーにサインインします。そのアドレス `https://tacit-finch-29.convex.cloud` は `crok remote status` で表示され、`crok version --json` では `remote` の下に表示されます。

- **サインインは 2.0.0 のものがそのまま引き継がれます。** 2.0.0 のコンピューターはすでに本番リレーにサインインしていて、2.0.1 も同じサインインを使います。もう一度サインインする必要はなく、移すファイルもありません。1.5.x のサインインは、2.0.0 が一度だけ `~/.crok/remote/credentials.json` から `~/.crok/remote/credentials-dev.json` に移しました。2.0.1 は両方のファイルをそのままにしておきます。
- **本番リレーは以前と同じ場所にあります。** アカウント、デバイス、ピン留めやアーカイブをしたセッション、プロジェクトの並び順はリレー上に保存されており、2.0.1 も同じ場所から読み込むので、アップデートによって何かが移動することはありません。
- **すべてのコンピューターとスマートフォンをアップデートしてください。** 1.5.x のコンピューターや、2.0.0 より前にビルドしたスマートフォンアプリはテスト用リレーに残り、2.0.0 以降のコンピューターが見えません。

`[remote] url` または `CROK_REMOTE_URL` で指定した自分のリレーは、これまでどおり使えます。

### Agent Observability

2.0.0 と同じく、このリリースのすべての crok は、自身が行う各モデル呼び出しを、メンテナーの Grafana Cloud スタック上の [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) に報告します。報告にはプロンプト、応答、ツール呼び出し、トークン使用量、タイミング情報が含まれ、コンピューターの名前がタグとして付きます。報告先のホストは、`crok version --json` の `agentObservability` の下に表示されます。オフにするには、`~/.crok/config.toml` の `[features]` の下に `agent_observability = false` を追加するか、`CROK_AGENT_OBSERVABILITY=0` を設定します。自分のスタックに報告するには、リポジトリの `crates/codegen/xai-grok-agento11y/setup.sh` で `~/.crok/agento11y.env` を書き出します。

### 開発者向け

- リリースは `.github/workflows/release.yml` で作られます。`VERSION` を上げるプルリクエストが `main` にマージされると、TUI、両方のディスクイメージ、スマートフォンアプリをビルドし、検証と署名を行ったうえで、`release/notes/v2.0.1/` にコミットされたノートを付けてリリースを公開します。署名用の鍵は `release/ci-secrets.sh` がこのワークフローに渡します。全体の説明は `release/README.md` にあります。
- `.github/workflows/ci.yml` は、`main` へのすべてのプルリクエストで、TUI、両方の SDK 向けの Crok Desktop、iOS アプリ、Android アプリをコンパイルし、まだリリースのない `VERSION` のノートを検証します。
- リレーには `relay/environments/prod.env` と `relay/environments/dev.env` の 2 つの環境があります。`relay/scripts/deploy.sh prod` または `relay/scripts/deploy.sh test` でどちらかをデプロイし、`make clients-prod` と `make clients-test` はその環境向けのスマートフォンアプリもビルドします。crok は、ビルド時に `CROK_RELAY_ENV` で使うリレーを決めます（テストビルドでなければ prod）。
- `desktop/macOS/scripts/build-app.sh` は SwiftPM のネイティブビルドシステムでビルドします（別のものは `SWIFT_BUILD_SYSTEM` で選べます）。これにより、Xcode 27 でも `SDKROOT` と SDK のスタンプが正しく保たれます。
- `mobile/scripts/build-apps.sh --ios-device` はデバイス向けの署名されていない `.ipa` を追加で作ります。Android のリリースビルドは、`CROK_ANDROID_KEYSTORE` が指すキーストアで署名されます。

### 署名

2.0.1 は、2.0.0、1.5.2、1.5.3 と同じ "Crok Code Signing" 証明書で署名されています。macOS はプライバシー権限を署名に結び付けているため、2.0.0 に許可したもの（「画面収録」、「アクセシビリティ」、マイク、音声認識）は 2.0.1 に引き継がれます。このビルドは公証されていないので、新しくインストールする場合は上記の**このまま開く**の手順が一度必要です。

Android アプリは、2.0.0 で導入されたリリース用の鍵で署名されています。iOS アプリは、**スマートフォンアプリ**で説明しているとおり署名されていません。署名付きのチェックサム一覧は、これとは別のものです。アップデート機能がダウンロードしたファイルを検証するためのもので、macOS によるアプリの扱いは変わりません。

### 2.0.0 からのアップグレード

**Crok Desktop › アップデートを確認…** を使うか、Crok Desktop を終了してからターミナルで `crok upgrade` を実行します。今回のアップデートは、インストール済みの `Crok Desktop.app` にそのまま行われます。そのため Dock や Finder での位置はそのままで、古いコピーがゴミ箱に残ることもありません。アップデートは、インストール済みのアプリと同じ SDK でビルドされたイメージ（macOS26-SDK または macOS15-SDK）を取得し、もう一方になることはありません。

モデルプロバイダへのサインイン、設定、タスク、リレーはいずれも引き継がれます。2.0.1 は 2.0.0 と同じ本番リレーと通信します。スマートフォンアプリは、上の**スマートフォンアプリ**の説明どおり、このリリースのファイルからインストールします。

### 詳細

- crok `{{CROK_VERSION}}` を同梱しています。
- GitHub Actions が、`main` のタグ `desktop-v2.0.1`（`{{COMMIT}}`）からビルドしました。macOS 26 SDK のイメージは Xcode {{XCODE26}} と macOS {{SDK26}} SDK、macOS 15 SDK のイメージは Xcode {{XCODE15}} と macOS {{SDK15}} SDK、単体の `crok` は macOS {{TUI_SDK}} SDK でビルドしています。
- どちらのイメージも arm64 で、Crok Code Signing 証明書による署名あり、公証なしです。どちらも macOS 14 Sonoma 以降で動作します。
- iOS アプリ（`dev.chenli.crok.mobile`）は Xcode {{XCODE26}} で作った Release ビルド、Android アプリは Android 8.0 以降向けのリリースビルドです。
- SHA-256 チェックサムは、このノートの末尾と `SHA256SUMS.txt` にあります。`SHA256SUMS.txt` には、スマートフォンアプリも含まれます。一覧の署名を手作業で確認する方法は、リポジトリの `release/README.md` にあります。
