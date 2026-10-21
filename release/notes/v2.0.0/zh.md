Crok Desktop 2.0.0 是本 fork 的原生 macOS 应用。它内置了 crok，也就是智能体运行时和 `crok` 终端界面，无需另外安装任何东西。此版本为远程控制提供了位于 https://crok.chenli.dev 的专属正式中继，并首次附带 iOS 和 Android 应用。网页和手机上的回复现在会以完整的 Markdown 呈现。更新会直接安装到你现有的应用中，关闭窗口后 Crok Desktop 也会继续运行。由于中继是新的，每台电脑和手机都要重新登录一次远程控制：做法见下文**远程控制**一节。

这也是第一个在拉取请求合并后随即由 GitHub Actions 构建并发布的版本。

### 安装

1. 下载与你的 macOS 版本相符的磁盘映像并打开。选哪一个，见**下载哪个磁盘映像**中的表格。
2. 把 **Crok Desktop** 拖到**应用程序**。
3. 从“应用程序”中打开 Crok Desktop。此构建未经公证，所以第一次打开时 macOS 会提示无法验证该应用：关闭该提示，打开**系统设置 › 隐私与安全性**，在 Crok Desktop 的提示旁点按**仍要打开**，然后确认。只需操作一次。
4. 在**设置 › 账号**中登录，可使用 OpenRouter、OpenAI Codex、Anthropic API 密钥、DeepSeek API 密钥或 GLM Coding Plan 密钥。

需要 macOS 14 Sonoma 或更高版本，以及搭载 Apple 芯片（M1 或更新）的 Mac。

### 下载哪个磁盘映像

两个映像都是 Crok Desktop 2.0.0，功能完全相同。区别只在于构建时所用的 macOS SDK，它决定窗口外观是否采用 Apple 的 Liquid Glass：

| 磁盘映像 | 构建所用 SDK | 适用系统 | 标题栏 |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.0-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 及更高版本 | Liquid Glass |
| `Crok-Desktop-2.0.0-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 和 15 | 窗口内的毛玻璃模糊 |

在 macOS 26 及更高版本上，建议选用 macOS 26 SDK 映像，以获得 Liquid Glass 标题栏。在 macOS 14 或 15 上，请选用 macOS 15 SDK 映像。它在更高版本上也能运行，所以如果不确定自己的 macOS 版本，选它最稳妥。

`crok-2.0.0-aarch64-apple-darwin.tar.gz` 是单独的 `crok` 终端界面，适合不想安装应用的 Mac：解压后把 `crok` 放到 `PATH` 中的某个目录即可。手机应用的介绍见**手机应用**一节。`SHA256SUMS.txt` 列出每个下载文件的 SHA-256，`SHA256SUMS.txt.sig` 是这份清单的签名，更新程序会校验它。

### 手机应用

适用于 iPhone 和 Android 的 Crok 应用会跟进你各台电脑上的会话，显示它们的回复和权限请求，并让你在任何地方开始或操控任务。此前你需要从仓库自行构建它；现在它随此版本一起提供。这三个文件都会登录到正式中继。

- **Android 8.0 或更高版本：** 在手机上下载 `Crok-Android-2.0.0.apk` 并打开，Android 询问时允许浏览器安装应用；也可以运行 `adb install -r Crok-Android-2.0.0.apk`。它使用以后的版本也会沿用的发布密钥签名，因此下一个 APK 可以直接覆盖安装。你自己构建的 Crok APK 使用另一个密钥签名，会导致安装被阻止：请先用 `adb uninstall dev.chenli.crok.mobile` 或在手机的设置中将其移除。
- **iPhone 和 iPad，iOS 17 或更高版本：** `Crok-iOS-2.0.0-unsigned.ipa` 没有签名，因为用于 iOS 设备的应用要用安装者本人的 Apple ID 签名。请用 AltStore 或 Sideloadly 等侧载工具安装它，这类工具会用你的 Apple ID 为它签名。使用免费 Apple ID 时，7 天后 iOS 将不再打开该应用，直到你重新安装。如果想改为自己构建，请使用 **Release** 配置：Xcode 的 Run 按钮构建的是 Debug，它会登录到测试中继。
- **iOS 模拟器：** `Crok-iOS-2.0.0-Simulator.zip` 解压后是 `Crok.app`，可在装有 Xcode 的 Mac 上用 `xcrun simctl install booted Crok.app` 安装。

要让手机登录，请点按**使用 GitHub 或 Google 继续**，在打开的 https://crok.chenli.dev 页面上登录，然后点按**批准**。接着关联每台电脑：在电脑上运行 `crok remote login`，然后在应用的**设置 › 关联电脑**中扫描它显示的二维码，或在随之打开的网页上批准这台电脑。

### 主要更新

- **远程控制有了正式中继。** 正式版本现在登录到自己的中继，其网页应用在 https://crok.chenli.dev 上。1.5.1 至 1.5.3 所用的中继（其网页应用在 https://crok-relay.vercel.app 上）现在只供测试构建使用。两者之间不会迁移任何内容，因此你需要重新登录一次。见下文**远程控制**。
- **手机应用随版本一起提供。** Android APK、未签名的 iOS 应用和 iOS 模拟器构建都在此版本的下载文件中，均为正式中继构建。见上文**手机应用**。
- **网页和手机上的回复以 Markdown 呈现。** 表格、标题、嵌套列表、任务列表、引用、链接和代码块都能正确显示。代码采用 GitHub 的配色高亮，并带有**复制**按钮。LaTeX 数学公式也能渲染：行内公式写作 `$…$` 或 `\(…\)`，独立成行的公式写作 `$$…$$` 或 `\[…\]`；像“$5 和 $10”这样的价格仍显示为文本。较宽的代码、表格和公式会在回复内横向滚动。图片绝不会被下载，而是显示为链接。
- **手机上的长回复会从末尾打开。** 如果会话的最后一条回复比屏幕还高，打开会话时会停在这条回复的末尾；在长回复中阅读时，会出现滚动到底部的按钮。在 Android 上，阅读时收到新消息不再把你拉到底部，但发送提示时仍会。在 iPhone 上，此功能需要 iOS 18。
- **更新会安装到你现有的应用中。** 从 2.0.0 起，**Crok Desktop › 检查更新…** 和 `crok upgrade` 会一步把新版本装进已安装的 `Crok Desktop.app`，因此它在程序坞和访达中的位置保持不变，废纸篓里也不会留下旧副本。安装前，它们会检查新版本是否由同一张证书签名，正是这一点让 macOS 授予 Crok Desktop 的权限（辅助功能、屏幕录制、麦克风）得以保留。以其他方式签名的版本会被拒绝，除非你运行 `crok upgrade --allow-new-signature`。
- **关闭窗口后 Crok Desktop 仍会运行。** 红色关闭按钮现在只是隐藏窗口，任务、侧边栏中的终端、浏览器页面和你的草稿都会在后台继续。按 **⌘Q** 退出。点按程序坞图标、在**窗口**菜单中选择该窗口，或使用**新建任务**等菜单命令，即可让窗口重新出现。
- **智能体以 Crok 自称。** 现在无论使用哪个提供商，系统提示词都以“You are Crok.”开头；以前即使模型是 Claude、DeepSeek 或 GLM，提示词中写的也是 Grok。`agent.system_prompt_label`、`model.<id>.system_prompt_label` 和 `CROK_SYSTEM_PROMPT_LABEL` 仍可设置其他名称。

### 远程控制

此版本中的每个 crok（终端界面、Crok Desktop 内置的那一个，以及单独的 tar 包）都登录到正式中继。`crok remote status` 会显示它的地址 `https://tacit-finch-29.convex.cloud`，`crok version --json` 则在 `remote` 下显示该地址。

- **在每台电脑上重新登录。** 运行 `crok remote login`（或在终端界面中输入 `/remote login`），或在 Crok Desktop 中使用**设置 › 远程控制 › 登录…**。随后会打开 https://crok.chenli.dev 上的一个页面：用 GitHub 或 Google 登录，然后点按**批准**。已登录的手机也可以改为由它来关联这台电脑：在**设置 › 关联电脑**中扫描二维码即可。
- **正式中继从零开始。** 你的账号、设备、置顶和归档的会话以及项目的排序都保存在中继上，因此第一次登录会在那里创建一个新账号，置顶和排序也会重新开始。
- **你在 1.5.x 中的登录会留给测试构建使用。** 2.0.0 第一次运行时，crok 会把它从 `~/.crok/remote/credentials.json` 移到 `~/.crok/remote/credentials-dev.json`，在你重新登录之前，这台电脑会显示为未登录。
- **更新每台电脑和手机。** 仍在使用 1.5.x 的电脑，或在此版本之前构建的手机应用，会继续使用测试中继，看不到已升级到 2.0.0 的电脑。

通过 `[remote] url` 或 `CROK_REMOTE_URL` 设置的自建中继，仍和以前一样可用。

### Agent Observability

与 1.5.3 一样，此版本中的每个 crok 都会把自己发出的每次模型调用上报到维护者 Grafana Cloud 堆栈上的 [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/)，其中包含提示、回复、工具调用、token 用量和耗时，并以这台电脑的名称作为标签。`crok version --json` 会在 `agentObservability` 下显示上报所到的主机。如要关闭，在 `~/.crok/config.toml` 的 `[features]` 下添加 `agent_observability = false`，或设置 `CROK_AGENT_OBSERVABILITY=0`。如要上报到你自己的堆栈，用仓库中的 `crates/codegen/xai-grok-agento11y/setup.sh` 写入 `~/.crok/agento11y.env`。

### 面向开发者

- 发布由 `.github/workflows/release.yml` 完成：一个提升了 `VERSION` 的拉取请求合并到 `main` 后，它会构建 TUI、两个磁盘映像和手机应用，对它们进行检查和签名，然后用 `release/notes/v2.0.0/` 中提交的说明发布 release。`release/ci-secrets.sh` 为它提供签名密钥。`release/README.md` 介绍了全部流程。
- `.github/workflows/ci.yml` 会针对每个合并到 `main` 的拉取请求，编译 TUI、两种 SDK 的 Crok Desktop、iOS 应用和 Android 应用；如果 `VERSION` 还没有对应的 release，还会检查它的说明。
- 中继有两个环境：`relay/environments/prod.env` 和 `relay/environments/dev.env`。`relay/scripts/deploy.sh prod` 或 `relay/scripts/deploy.sh test` 部署其中一个，`make clients-prod` 和 `make clients-test` 还会同时为它构建手机应用。crok 在构建时通过 `CROK_RELAY_ENV` 选定中继（除测试构建外均为 prod）。
- `desktop/macOS/scripts/build-app.sh` 使用 SwiftPM 的原生构建系统进行构建（可用 `SWIFT_BUILD_SYSTEM` 选择其他构建系统），这样在 Xcode 27 下 `SDKROOT` 和 SDK 版本标记也能保持正确。
- `mobile/scripts/build-apps.sh --ios-device` 会额外生成一个适用于设备的未签名 `.ipa`；Android 的 release 构建则使用 `CROK_ANDROID_KEYSTORE` 指定的密钥库签名。

### 签名

2.0.0 与 1.5.2 和 1.5.3 由同一张“Crok Code Signing”证书签名。macOS 把隐私权限与签名绑定，因此你为 1.5.3 允许的权限（屏幕录制、辅助功能、麦克风、语音识别）会延续到 2.0.0。如果从采用临时签名的 1.5.1 或更早版本升级，macOS 会再请求一次这些权限。如果系统设置中显示 Crok Desktop 已打开，而 Crok 却提示未被允许，请用 **−** 把它从列表中移除，再重新允许一次。此构建未经公证，所以新安装时需要做一次上面的**仍要打开**步骤。

Android 应用使用此版本新引入的发布密钥签名。iOS 应用没有签名，原因见**手机应用**一节。已签名的校验和清单是另一回事：它让更新程序能够校验下载的文件，并不改变 macOS 对待该应用的方式。

### 从 1.5.3 升级

使用 **Crok Desktop › 检查更新…**，或在退出 Crok Desktop 后在终端中运行 `crok upgrade`。这次更新仍由 1.5.3 自带的更新程序完成，它会替换整个应用，并把旧应用以 `Crok Desktop 1.5.3.app` 的名称移到废纸篓。更新后请清倒废纸篓：那个副本是另一个带有 Crok Desktop 标识符的应用。从 2.0.0 起，更新会就地安装到应用中。更新会选用与已安装应用构建时所用 SDK 相同的映像（macOS26-SDK 或 macOS15-SDK），绝不会选用另一个。

模型提供商的登录状态、设置和任务都会保留。远程控制的登录不会保留：请按上文**远程控制**一节所述重新登录，并安装此版本中的手机应用。

### 详细信息

- 内置 crok `{{CROK_VERSION}}`。
- 由 GitHub Actions 基于标签 `desktop-v2.0.0`（`main` 上的 `{{COMMIT}}`）构建。macOS 26 SDK 映像使用 Xcode {{XCODE26}} 针对 macOS {{SDK26}} SDK 构建，macOS 15 SDK 映像使用 Xcode {{XCODE15}} 针对 macOS {{SDK15}} SDK 构建，单独的 `crok` 则针对 macOS {{TUI_SDK}} SDK 构建。
- 两个映像均为 arm64，由 Crok Code Signing 证书签名且未经公证，均可在 macOS 14 Sonoma 或更高版本上运行。
- iOS 应用（`dev.chenli.crok.mobile`）是用 Xcode {{XCODE26}} 构建的 Release 版本；Android 应用是适用于 Android 8.0 或更高版本的 release 版本。
- SHA-256 校验和位于本说明末尾，也在 `SHA256SUMS.txt` 中，该文件现在也涵盖手机应用。仓库中的 `release/README.md` 说明了如何手动校验这份清单的签名。
