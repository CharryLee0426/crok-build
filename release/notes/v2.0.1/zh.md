Crok Desktop 2.0.1 是本 fork 的原生 macOS 应用。它内置了 crok，也就是智能体运行时和 `crok` 终端界面，无需另外安装任何东西。它紧随 2.0.0 之后：那个版本让远程控制有了自己的正式中继，位于 https://crok.chenli.dev 的网页应用，并首次附带 iOS 和 Android 应用。2.0.1 承接的正是其后的工作。两个手机应用都以电脑、项目和话题重新设计；另一台电脑上的会话会在 Crok Desktop 中显示其分支和 token 数据，其 Git Graph 也会读取那台电脑的仓库；远程会话可以在创建时选择模型和思考级别；Agent Observability 还会为 Codex、GLM 和 DeepSeek 的调用计价。

这个版本和 2.0.0 一样，在拉取请求合并后随即由 GitHub Actions 构建并发布。

### 安装

1. 下载与你的 macOS 版本相符的磁盘映像并打开。选哪一个，见**下载哪个磁盘映像**中的表格。
2. 把 **Crok Desktop** 拖到**应用程序**。
3. 从“应用程序”中打开 Crok Desktop。此构建未经公证，所以第一次打开时 macOS 会提示无法验证该应用：关闭该提示，打开**系统设置 › 隐私与安全性**，在 Crok Desktop 的提示旁点按**仍要打开**，然后确认。只需操作一次。
4. 在**设置 › 账号**中登录，可使用 OpenRouter、OpenAI Codex、Anthropic API 密钥、DeepSeek API 密钥或 GLM Coding Plan 密钥。

需要 macOS 14 Sonoma 或更高版本，以及搭载 Apple 芯片（M1 或更新）的 Mac。

### 下载哪个磁盘映像

两个映像都是 Crok Desktop 2.0.1，功能完全相同。区别只在于构建时所用的 macOS SDK，它决定窗口外观是否采用 Apple 的 Liquid Glass：

| 磁盘映像 | 构建所用 SDK | 适用系统 | 标题栏 |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.1-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 及更高版本 | Liquid Glass |
| `Crok-Desktop-2.0.1-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 和 15 | 窗口内的毛玻璃模糊 |

在 macOS 26 及更高版本上，建议选用 macOS 26 SDK 映像，以获得 Liquid Glass 标题栏。在 macOS 14 或 15 上，请选用 macOS 15 SDK 映像。它在更高版本上也能运行，所以如果不确定自己的 macOS 版本，选它最稳妥。

`crok-2.0.1-aarch64-apple-darwin.tar.gz` 是单独的 `crok` 终端界面，适合不想安装应用的 Mac：解压后把 `crok` 放到 `PATH` 中的某个目录即可。手机应用的介绍见**手机应用**一节。`SHA256SUMS.txt` 列出每个下载文件的 SHA-256，`SHA256SUMS.txt.sig` 是这份清单的签名，更新程序会校验它。

### 手机应用

适用于 iPhone 和 Android 的 Crok 应用会跟进你各台电脑上的会话，显示它们的回复和权限请求，并让你在任何地方开始或操控任务。它和 2.0.0 一样随此版本一起提供。这三个文件都会登录到正式中继。

- **Android 8.0 或更高版本：** 在手机上下载 `Crok-Android-2.0.1.apk` 并打开，Android 询问时允许浏览器安装应用；也可以运行 `adb install -r Crok-Android-2.0.1.apk`。它使用以后的版本也会沿用的发布密钥签名，因此下一个 APK 可以直接覆盖安装。你自己构建的 Crok APK 使用另一个密钥签名，会导致安装被阻止：请先用 `adb uninstall dev.chenli.crok.mobile` 或在手机的设置中将其移除。
- **iPhone 和 iPad，iOS 17 或更高版本：** `Crok-iOS-2.0.1-unsigned.ipa` 没有签名，因为用于 iOS 设备的应用要用安装者本人的 Apple ID 签名。请用 AltStore 或 Sideloadly 等侧载工具安装它，这类工具会用你的 Apple ID 为它签名。使用免费 Apple ID 时，7 天后 iOS 将不再打开该应用，直到你重新安装。如果想改为自己构建，请使用 **Release** 配置：Xcode 的 Run 按钮构建的是 Debug，它会登录到测试中继。
- **iOS 模拟器：** `Crok-iOS-2.0.1-Simulator.zip` 解压后是 `Crok.app`，可在装有 Xcode 的 Mac 上用 `xcrun simctl install booted Crok.app` 安装。

要让手机登录，请点按**使用 GitHub 或 Google 继续**，在打开的 https://crok.chenli.dev 页面上登录，然后点按**批准**。接着关联每台电脑：在电脑上运行 `crok remote login`，然后在应用的**设置 › 关联电脑**中扫描它显示的二维码，或在随之打开的网页上批准这台电脑。

**手机应用经过重新设计。** 一台已关联的电脑是一个账号，一个项目是一个带话题的群组，一个会话则是其中的一个话题。**会话**标签页显示所选电脑的项目，并可进入这些项目的话题；**个人资料**取代了**设置**；**已归档的会话**有了独立页面；**外观**提供 Telegram 的聊天主题或照片。下一节介绍两个应用共用的设计。

### 手机：电脑、项目与话题

两个手机应用现在都沿用同一套设计，取自 Telegram，取代了 2.0.0 随附的会话列表。iOS 和 Android 上的设计完全相同。

- **两个标签页：会话和个人资料。** 个人资料标签页的图标是中继账号的头像，其角标统计其他电脑上的未读会话。长按**会话**会提供**全部标为已读**；长按**个人资料**会打开电脑切换器，点按会话页标题也会打开它。
- **会话标签页一次显示一台电脑。** 所选电脑的项目以论坛行的形式出现：圆角方形头像、最新的几个话题标题、它是否正在工作、需要批准或最后一条回复的预览，以及未读总数。选择会记在手机上；新手机从最近活跃的电脑开始。
- **项目是带话题的群组。** 打开项目后，它的会话以话题行列出，每一行都有彩色的话题图标、标题、时间、文件夹、预览和未读角标。项目页面有搜索、**全部标为已读**、**重新排序**、**按最近活动排序**和一个新建按钮；在话题上滑动可以置顶或归档，长按则提供置顶、停止、标为已读、归档、上移和下移。
- **已归档的会话。** 会话标签页顶部的一行会打开所选电脑的归档。在会话上向左滑动即可归档；在归档页面上用同样的方式取消归档。
- **个人资料是账号页面。** 它显示账号的头像、名称和邮箱，然后列出每台电脑及其未读角标和所选电脑上的对勾，接着是**关联电脑**、**设备**、**外观**、**语言**、**版本**、开发者的 GitHub 和 X 链接，以及**退出登录**。
- **外观提供 Telegram 的聊天主题。** 一个预览和一排卡片提供**无主题**、**经典**以及九个 emoji 主题（家、小鸭、雪人、钻石、老师、郁金香、紫心、圣诞树和电子游戏），每个都有浅色和深色两种样式；也可以选择图库中的照片并开启**模糊**。主题会设置会话背景和用户自己的气泡；智能体气泡保持原样。**颜色模式**仍是跟随系统、浅色或深色。
- **两个应用都支持六种语言。** 每个新页面和字符串都提供英语、简体中文、日语、西班牙语、法语和德语版本。

### 主要更新

- **手机应用经过重新设计。** 一台电脑是一个账号，一个项目是一个带话题的群组，一个会话是一个话题。会话标签页显示所选电脑，个人资料取代了设置，会话还可以使用 Telegram 的聊天主题。见上文**手机：电脑、项目与话题**。
- **另一台电脑的分支和 token 数据会出现在输入框下方。** 在从**其他电脑**打开的任务中，Crok Desktop 会显示那台电脑最近报告的分支、输入和输出 token、缓存命中率和输出速度；那台电脑上一轮结束时就会刷新。
- **Git Graph 和分支选择器可以直接操作那台电脑的仓库。** 它们通过中继读取仓库，切换或创建分支会在那台电脑上执行，并把该分支更新到所有设备看到的位置。拥有该会话的电脑需要 crok 2.0.1 才能使用这一功能。
- **远程会话可以在创建时选择模型。** 网页应用的新会话页面会在输入框上方列出目标电脑自己的模型和思考级别；那台电脑的 crok 会在第一条提示之前应用它们。**默认**会保留那台电脑自己的选择。
- **Agent Observability 为所有提供商的调用计价。** 现在每次调用的 span 都带有以美元计的费用、费用的来源、后端，以及你是否取消了这次调用，因此 Codex、GLM 和 DeepSeek 的调用也会显示花费。仪表盘新增 **Codex、GLM 和 DeepSeek** 视图、14 天历史和逐周对比。
- **Crok Desktop 和 crok 的一些小修复。** 会话的首次标题现在使用它当前运行的模型，包括在第一条提示之前切换过模型的情况；任务仍在连接时开始一轮，会报告这一状态，而不再打开第二个连接。
- **更新会安装到你现有的应用中。** 从 2.0.0 起，**Crok Desktop › 检查更新…** 和 `crok upgrade` 会一步把新版本装进已安装的 `Crok Desktop.app`，因此它在程序坞和访达中的位置保持不变，废纸篓里也不会留下旧副本。安装前，它们会检查新版本是否由同一张证书签名，正是这一点让 macOS 授予 Crok Desktop 的权限（辅助功能、屏幕录制、麦克风）得以保留。以其他方式签名的版本会被拒绝，除非你运行 `crok upgrade --allow-new-signature`。
- **智能体以 Crok 自称。** 现在无论使用哪个提供商，系统提示词都以“You are Crok.”开头；以前即使模型是 Claude、DeepSeek 或 GLM，提示词中写的也是 Grok。`agent.system_prompt_label`、`model.<id>.system_prompt_label` 和 `CROK_SYSTEM_PROMPT_LABEL` 仍可设置其他名称。

### 远程控制

此版本中的每个 crok（终端界面、Crok Desktop 内置的那一个，以及单独的 tar 包）都登录到正式中继。`crok remote status` 会显示它的地址 `https://tacit-finch-29.convex.cloud` 而 `crok version --json` 则在 `remote` 下显示该地址。

- **在创建远程会话时选择模型和思考级别。** 在网页上，新会话页面会在输入框上方列出目标电脑的模型和思考级别，那台电脑会在第一条提示之前应用它们。**默认**会保留它自己的选择。
- **另一台电脑上的任务会显示它的数据。** 输入框下方显示该会话的分支、输入和输出 token、缓存命中率和输出速度，这些是那台电脑在上一轮结束时报告的数字。
- **读取并切换另一台电脑的仓库。** 在 Crok Desktop 中，**其他电脑**里任务的 **Git Graph** 和分支选择器会通过中继读取那台电脑的仓库；切换或创建分支会在那里执行，命令检出的分支会更新到所有设备看到的会话行。拥有该会话的电脑需要 crok 2.0.1；旧版 crok 会回答需要更新。
- **你的登录状态从 2.0.0 延续下来。** 2.0.0 上的电脑已经登录到正式中继，2.0.1 直接沿用同一个登录状态：不必再次登录，也没有文件需要迁移。1.5.x 的登录信息已由 2.0.0 从 `~/.crok/remote/credentials.json` 移到了 `~/.crok/remote/credentials-dev.json`，那次迁移只做过一次；2.0.1 让两个文件都留在原处。
- **正式中继还在原来的地方。** 你的账号、设备、置顶和归档的会话以及项目的排序都保存在中继上，2.0.1 从同一处读取它们，因此更新时不会迁移任何东西。
- **请更新每台电脑和手机。** 仍在使用 1.5.x 的电脑，或 2.0.0 之前构建的手机应用，会继续使用测试中继，看不到 2.0.0 或更高版本的电脑。

通过 `[remote] url` 或 `CROK_REMOTE_URL` 设置的自建中继，仍和以前一样可用。

### Agent Observability

与 2.0.0 一样，此版本中的每个 crok 都会把自己发出的每次模型调用上报到维护者 Grafana Cloud 堆栈上的 [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) 中，其中包含提示、回复、工具调用、token 用量和耗时，并以这台电脑的名称作为标签。`crok version --json` 会在 `agentObservability` 下显示上报所到的主机。如要关闭，在 `~/.crok/config.toml` 的 `[features]` 下添加 `agent_observability = false`，或设置 `CROK_AGENT_OBSERVABILITY=0`。如要上报到你自己的堆栈，用仓库中的 `crates/codegen/xai-grok-agento11y/setup.sh` 写入 `~/.crok/agento11y.env`。

现在每次调用的 span 还会带有 `crok.cost.usd`、`crok.cost.source`、`crok.backend`，以及在你中断调用时的 `crok.cancelled`。费用优先使用提供商自己报告的数字，否则按该次调用 token 的模型标准 API 价格计算。因此，即使 Codex、GLM 和 DeepSeek 不导出自己的 trace，它们的调用也会有价格。仪表盘包含 **Codex、GLM 和 DeepSeek** 视图，保留 14 天历史，并将每周与前一周对比。

### 面向开发者

- 发布由 `.github/workflows/release.yml` 完成：一个提升了 `VERSION` 的拉取请求合并到 `main` 后，它会构建 TUI、两个磁盘映像和手机应用，对它们进行检查和签名，然后用 `release/notes/v2.0.1/` 中提交的说明发布 release。`release/ci-secrets.sh` 为它提供签名密钥。`release/README.md` 介绍了全部流程。
- 发布运行器会把导入的签名钥匙串加入用户的钥匙串搜索列表，然后在任何构建之前对 `/usr/bin/true` 的临时副本签名：当 `codesign` 无法使用该钥匙串时，`.github/scripts/release/import-codesign.sh` 会在导入步骤就让任务失败，而不是等到 46 分钟的构建之后。
- `.github/workflows/ci.yml` 会针对每个合并到 `main` 的拉取请求，编译 TUI、两种 SDK 的 Crok Desktop、iOS 应用和 Android 应用；如果 `VERSION` 还没有对应的 release，还会检查它的说明。
- 两个手机应用都实现 `mobile/DESIGN.md` 中的约定：电脑作为账号、项目作为带话题的群组、个人资料和会话主题。它取代了 `relay/DESIGN.md` 第 5 节的手机部分；网页应用仍沿用那一节。
- 中继有两个环境：`relay/environments/prod.env` 和 `relay/environments/dev.env`。`relay/scripts/deploy.sh prod` 或 `relay/scripts/deploy.sh test` 部署其中一个，`make clients-prod` 和 `make clients-test` 还会同时为它构建手机应用。crok 在构建时通过 `CROK_RELAY_ENV` 选定中继（除测试构建外均为 prod）。
- 中继的 `git` 命令类型通过 `commands:git`（`{op: "graph"|"branches"|"files"|"diff"|"workspace"|"workspace_diff"|"signature"|"switch"|"create", …}`）把请求交给该会话电脑上任何声明支持 `git` 的 crok，`bridge:setBranch` 记录命令检出的分支。会话行现在带有 `gitBranch` 和 `usage`，其中包括 `outputTokensPerSecond`。
- Agent Observability 桥接会把 `crok.cost.usd`、`crok.cost.source`、`crok.backend` 和 `crok.cancelled` 写到每个 span 上。`observability/grafana-llm/build_dashboards.py` 生成 **Codex、GLM 和 DeepSeek** 仪表盘和 64 条历史规则，`prices.json` 保存标准 API 价格。
- `desktop/macOS/scripts/build-app.sh` 使用 SwiftPM 的原生构建系统进行构建（可用 `SWIFT_BUILD_SYSTEM` 选择其他构建系统），这样在 Xcode 27 下 `SDKROOT` 和 SDK 版本标记也能保持正确。
- `mobile/scripts/build-apps.sh --ios-device` 会额外生成一个适用于设备的未签名 `.ipa`；Android 的 release 构建则使用 `CROK_ANDROID_KEYSTORE` 指定的密钥库签名。两个应用的调试构建使用黄色图标，发布构建使用蓝色图标。

### 签名

2.0.1 与 2.0.0、1.5.2 和 1.5.3 由同一张“Crok Code Signing”证书签名。macOS 把隐私权限与签名绑定，因此你为 2.0.0 允许的权限（屏幕录制、辅助功能、麦克风、语音识别）会延续到 2.0.1。此构建未经公证，所以新安装时需要做一次上面的**仍要打开**步骤。

Android 应用使用 2.0.0 引入的发布密钥签名。iOS 应用没有签名，原因见**手机应用**一节。已签名的校验和清单是另一回事：它让更新程序能够校验下载的文件，并不改变 macOS 对待该应用的方式。

### 从 2.0.0 升级

使用 **Crok Desktop › 检查更新…**，或在退出 Crok Desktop 后于终端中运行 `crok upgrade`。这次更新是就地安装到已安装的 `Crok Desktop.app` 中，因此它在程序坞和访达中的位置保持不变，废纸篓里也不会留下旧副本。更新会选用与已安装应用构建时所用 SDK 相同的映像（macOS26-SDK 或 macOS15-SDK），绝不会选用另一个。

模型提供商的登录状态、设置、任务和远程控制的登录状态都会保留：2.0.1 与 2.0.0 连接的是同一个正式中继。手机应用则按上文**手机应用**一节所述，从此版本的文件安装。

### 详细信息

- 内置 crok `{{CROK_VERSION}}`。
- 由 GitHub Actions 基于标签 `desktop-v2.0.1`（`main` 上的 `{{COMMIT}}`）构建。macOS 26 SDK 映像使用 Xcode {{XCODE26}} 针对 macOS {{SDK26}} SDK 构建，macOS 15 SDK 映像使用 Xcode {{XCODE15}} 针对 macOS {{SDK15}} SDK 构建，单独的 `crok` 则针对 macOS {{TUI_SDK}} SDK 构建。
- 两个映像均为 arm64，由 Crok Code Signing 证书签名且未经公证，均可在 macOS 14 Sonoma 或更高版本上运行。
- iOS 应用（`dev.chenli.crok.mobile`）是用 Xcode {{XCODE26}} 构建的 Release 版本；Android 应用是适用于 Android 8.0 或更高版本的 release 版本。
- SHA-256 校验和位于本说明末尾，也在 `SHA256SUMS.txt` 中，该文件现在也涵盖手机应用。仓库中的 `release/README.md` 说明了如何手动校验这份清单的签名。
