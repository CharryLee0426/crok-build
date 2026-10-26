Crok Desktop 2.0.2 是本 fork 的原生 macOS 应用。它内置了 crok，也就是智能体运行时和 `crok` 终端界面，无需另外安装任何东西。它紧随 2.0.1 之后：那个版本以电脑、项目和话题重新设计了两个手机应用。在 2.0.2 中，浏览器工具直接使用你已经在用的 Chrome，并保持你的登录状态。每台设备都可以为会话选择其所在电脑的模型和思考级别，网页应用改用了手机应用的设计，终端也有了远程面板。轮次结束的消息现在约一秒内就会到达网页和手机。Agent Observability 可以追踪完整的轮次，发布流程也可以在发布前运行一套评测。

这个版本和 2.0.1 一样，在拉取请求合并后随即由 GitHub Actions 构建并发布。

### 安装

1. 下载与你的 macOS 版本相符的磁盘映像并打开。选哪一个，见**下载哪个磁盘映像**中的表格。
2. 把 **Crok Desktop** 拖到**应用程序**。
3. 从“应用程序”中打开 Crok Desktop。此构建未经公证，所以第一次打开时 macOS 会提示无法验证该应用：关闭该提示，打开**系统设置 › 隐私与安全性**，在 Crok Desktop 的提示旁点按**仍要打开**，然后确认。只需操作一次。
4. 在**设置 › 账号**中登录，可使用 OpenRouter、OpenAI Codex、Anthropic API 密钥、DeepSeek API 密钥或 GLM Coding Plan 密钥。

需要 macOS 14 Sonoma 或更高版本，以及搭载 Apple 芯片（M1 或更新）的 Mac。

### 下载哪个磁盘映像

两个映像都是 Crok Desktop 2.0.2，功能完全相同。区别只在于构建时所用的 macOS SDK，它决定窗口外观是否采用 Apple 的 Liquid Glass：

| 磁盘映像 | 构建所用 SDK | 适用系统 | 标题栏 |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.2-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 及更高版本 | Liquid Glass |
| `Crok-Desktop-2.0.2-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 和 15 | 窗口内的毛玻璃模糊 |

在 macOS 26 及更高版本上，建议选用 macOS 26 SDK 映像，以获得 Liquid Glass 标题栏。在 macOS 14 或 15 上，请选用 macOS 15 SDK 映像。它在更高版本上也能运行，所以如果不确定自己的 macOS 版本，选它最稳妥。

`crok-2.0.2-aarch64-apple-darwin.tar.gz` 是单独的 `crok` 终端界面，适合不想安装应用的 Mac：解压后把 `crok` 放到 `PATH` 中的某个目录即可。手机应用的介绍见**手机应用**一节。`SHA256SUMS.txt` 列出每个下载文件的 SHA-256，`SHA256SUMS.txt.sig` 是这份清单的签名，更新程序会校验它。

### 手机应用

适用于 iPhone 和 Android 的 Crok 应用会跟进你各台电脑上的会话，显示它们的回复和权限请求，并让你在任何地方开始或操控任务。它和 2.0.1 一样随此版本一起提供。这三个文件都会登录到正式中继。

- **Android 8.0 或更高版本：** 在手机上下载 `Crok-Android-2.0.2.apk` 并打开，Android 询问时允许浏览器安装应用；也可以运行 `adb install -r Crok-Android-2.0.2.apk`。它使用以后的版本也会沿用的发布密钥签名，因此下一个 APK 可以直接覆盖安装。你自己构建的 Crok APK 使用另一个密钥签名，会导致安装被阻止：请先用 `adb uninstall dev.chenli.crok.mobile` 或在手机的设置中将其移除。
- **iPhone 和 iPad，iOS 17 或更高版本：** `Crok-iOS-2.0.2-unsigned.ipa` 没有签名，因为用于 iOS 设备的应用要用安装者本人的 Apple ID 签名。请用 AltStore 或 Sideloadly 等侧载工具安装它，这类工具会用你的 Apple ID 为它签名。使用免费 Apple ID 时，7 天后 iOS 将不再打开该应用，直到你重新安装。如果想改为自己构建，请使用 **Release** 配置：Xcode 的 Run 按钮构建的是 Debug，它会登录到测试中继。
- **iOS 模拟器：** `Crok-iOS-2.0.2-Simulator.zip` 解压后是 `Crok.app`，可在装有 Xcode 的 Mac 上用 `xcrun simctl install booted Crok.app` 安装。

要让手机登录，请点按**使用 GitHub 或 Google 继续**，在打开的 https://crok.chenli.dev 页面上登录，然后点按**批准**。接着关联每台电脑：在电脑上运行 `crok remote login`，然后在应用的**设置 › 关联电脑**中扫描它显示的二维码，或在随之打开的网页上批准这台电脑。

### 主要更新

- **浏览器工具使用你自己的 Chrome。** 它会在你正在运行的浏览器里打开一个窗口，使用你上次用的配置文件，所以你已登录的网站都保持登录。需要在 Chrome 中做一次设置，并由你点按 **Allow**，详见下文的**你自己的浏览器**一节。
- **在每台设备上为会话选择模型和思考级别。** iPhone、Android 和网页在新会话和已打开的会话中，都会在输入框上方显示两个胶囊按钮：一个是模型，点开后是可搜索、按提供方分组的模型面板；另一个是思考级别。在 Crok Desktop 的**其他电脑**中新建任务时，也可以在开始前做同样的选择。
- **有数百个模型的电脑会提供全部模型。** 登录了 OpenRouter 的电脑大约列出 480 个模型。中继过去会拒绝超过 200 个的列表，于是这类电脑根本提供不了选择；现在它最多保留 1,000 个。
- **网页应用改用手机应用的设计。** 它的布局类似 Telegram Web：左边是所选电脑的项目及其话题，中间是带主题的会话，右边是会话信息。
- **终端里的远程面板。** `/remote` 像 Crok Desktop 的**其他电脑**一样显示其他电脑、它们的项目和会话；按 `n` 可以在那里用你选的模型开始一个会话。
- **轮次结束会立即到达网页和手机。** 过去在一个繁忙的轮次之后，电脑早已完成，它们却还会显示会话在工作，持续数秒，有时长达数分钟。现在结束的消息约一秒内就会到达。
- **长会话在手机上打开得很快。** 手机应用以小块的实时片段加载会话记录，新会话的第一条提示始终可见，思考和工具调用也像 Crok Desktop 一样只显示状态。
- **OpenRouter 的 100 万 token 模型在超过 10.5 万 token 后仍可使用。** crok 过去请求的输出额度没给提示留出空间，对话变长后 OpenRouter 就会拒绝；现在它请求的输出不会超过提示之外剩下的空间。
- **Agent Observability 追踪完整的轮次。** 每个轮次是一条追踪，包含它的模型调用和工具运行；维护者的栈会给真实流量打分，并检查可能改变状态的工具调用。详见下文的 **Agent Observability** 一节。

### 你自己的浏览器

浏览器工具过去会启动一个自己的浏览器，使用 Crok 专用的配置文件。现在它会在你正在运行的 Chrome 里打开一个窗口，使用你上次用的配置文件，所以你已登录的每个网站都保持登录。模型也会被告知，这个窗口可能以你的身份登录。

- **开启一次远程调试。** 这需要 Chrome 144 或更高版本。在 Chrome 中打开 `chrome://inspect/#remote-debugging`，开启 **Allow remote debugging for this browser instance**。Chrome 不接受从其他应用传来的 `chrome://` 地址，所以 Crok Desktop 的**设置 › 浏览器与电脑使用**中有一个**拷贝地址**按钮。
- **每个任务允许一次。** 任务第一次使用浏览器时，Chrome 会询问 **Allow remote debugging?**，点按 **Allow** 即可。Crok 会等待两分钟，并在远程调试未开启或请求被拒绝时告诉你该怎么做。
- **你的浏览器仍然归你。** Crok 从不退出它，也不接管它启动时的标签页，下载内容也会存到你的 Chrome 设置所指定的位置。
- **Crok 专用的配置文件仍然可用。** 在 Crok Desktop 的**设置 › 浏览器与电脑使用 › 浏览器配置文件**中选择 **Crok 专用配置文件**，或者在 `~/.crok/config.toml` 的 `[toolset.browser]` 下设置 `profile = "crok"`。默认值是 `profile = "user"`。

目前已在 macOS 上的 Chrome 中测试过。Edge、Brave 和 Chromium 尚未测试。

### 远程控制

此版本中的每个 crok 都和 2.0.1 一样登录位于 https://crok.chenli.dev 的正式中继，并沿用已有的登录。

- **模型和思考级别。** 新会话中的胶囊按钮在你选择之前显示 **Default**，会话会以你的选择开始。在已打开的会话中，修改会发送到它所在的电脑，胶囊按钮会一直转动，直到那台电脑应用了修改；如果它拒绝，会恢复原来的值并说明原因。会话信息中也有同样的两行，手机上的 `/model` 和 `/think` 命令读取的也是同一份列表。
- **网页应用。** 左栏是一叠页面：所选电脑的会话及其项目、一个项目的话题、已归档的会话以及个人资料。话题支持悬停操作和右键菜单，可以置顶、停止、标记为已读、归档和调整顺序。会话主题和颜色模式保存在浏览器中。窗口宽度小于 1024 像素时，一次只显示一栏。
- **终端的远程面板。** `/remote` 和 `/remote open` 会先显示账号、这台电脑和连接状态，然后是一棵树：其他电脑（在线或最后在线时间，以及未读数）、它们的项目和每个项目的会话。按回车会像 `/resume` 一样打开会话，按 `n` 会开始一个会话并询问那台电脑的模型和思考级别，直接输入可以过滤这棵树。`/remote status` 会输出原来的文字。另一台电脑上的会话会在状态栏显示它的分支和 token 数据，在那里使用 `/model` 也不再修改这台电脑的默认模型。
- **轮次结束会立即到达。** 与中继的连接现在会把每次写入之前排队的更新合并成一次，所以繁忙的轮次不会再积压出拖延结束消息的队列。即使排队的提示没有运行就离开了队列，结束的轮次也会显示为已结束，之后从手机发送的提示也会运行。
- **手机分段加载长会话。** 手机应用打开会话记录时先显示最新的 40 条，向上滚动时每次再加载 60 条更早的内容，所以镜像了数周的会话在慢速网络上也能很快打开。新会话的第一条提示会保持在输入框上方。思考显示为进行中再变为已完成，工具调用显示为运行中、已完成、失败或已停止。中继不再把思考的文字或工具的输出发送到手机。
- **请更新电脑和手机。** 模型列表和更快的轮次结束来自会话所在电脑上的 crok 2.0.2，胶囊按钮和会话记录窗口则来自 2.0.2 的手机应用。2.0.1 的手机应用仍可与中继配合使用。

### Agent Observability

和 2.0.1 一样，此版本中的每个 crok 都会把它发出的每次模型调用上报到维护者 Grafana Cloud 栈上的 [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/)，`crok version --json` 会在 `agentObservability` 下显示上报的主机。2.0.2 还会上报两次调用之间发生的事情：

- **轮次和工具运行。** 一个轮次是一条追踪，它的根 span 包含该轮次的模型调用和工具运行，并记录轮次如何结束、有多少次调用和工具错误。工具运行记录其结果、类型、退出码和输出大小，但不记录参数和输出内容。子智能体的轮次位于启动它的那个轮次之下。
- **步骤、判定和评分。** 权限决策、PreToolUse 钩子结果、压缩和 MCP 服务器启动会作为步骤显示在会话上。crok 自己的目标评估器、偷懒分类器、重复调用守卫和轮次上限会上报分数，你给出的评分除了发给 xAI，也会发到这里。
- **标签。** 调用带有 `origin`（`local`；`headless` 表示 `crok -p`；`relay` 表示来自网页和手机的提示；`eval` 表示实验），以及 `repo`、`branch` 和 `user`（电脑的登录名）。
- **守卫检查，警告模式。** 在可能改变状态的工具调用运行之前，以及工具结果返回给模型之前，crok 会把它们发送给栈上的守卫，检查改写历史的 git 命令、破坏性的 shell 命令和正式密钥。crok 从不等待结果，也从不阻止调用；匹配到的内容会作为警告记录在会话上。`CROK_AGENTO11Y_GUARDS=off` 会停止这些检查。
- **指标。** `crok_turns_total`、`crok_tool_runs_total`、`crok_workflow_steps_total` 和 `crok_guard_checks_total`，以及轮次和工具的耗时，为栈上的 Harness 仪表盘、告警和 SLO 提供数据。

要关闭上报，在 `~/.crok/config.toml` 的 `[features]` 下加上 `agent_observability = false`，或设置 `CROK_AGENT_OBSERVABILITY=0`。要上报到你自己的栈，用仓库中的 `crates/codegen/xai-grok-agento11y/setup.sh` 写好 `~/.crok/agento11y.env`。

### 面向开发者

- 发布仍由 `.github/workflows/release.yml` 完成：一个修改了 `VERSION` 的拉取请求合并进 `main` 后，它会构建、检查并签名每个文件，然后带着 `release/notes/v2.0.2/` 中的说明发布。
- 发布工作流新增了一个 `eval` 作业，`publish` 会等待它完成。它对发布构建把 `evals/run.py` 的七个冒烟用例各运行两次；当 pass@1 比 `evals/baselines/smoke.json` 低 0.20 以上，或者一个一直通过的安全用例失败时，作业失败。release 环境中没有 `CROK_EVAL_OPENROUTER_API_KEY` 这个 secret 时，它会给出警告并通过。
- `evals/run.py` 以无头模式在小型夹具仓库上运行 crok，分为三个套件（`s1` 回归、`s2` 工具使用、`s3` 安全，共 22 个用例），并按模型和构建报告通过率、成本和行为。`evals/README.md` 介绍了这些用例和检查。
- `observability/agento11y/stack.json` 保存栈上的评测器、规则和守卫；`observability/agento11y/stack.py` 通过 Agent Observability 插件 API 应用它们，给规则建立之前存储的会话打分，并安装告警和 SLO。
- 采样器通过 `crates/codegen/xai-grok-sampler/src/observe_harness.rs` 上报每个轮次、工具运行、步骤、判定、评分和守卫检查，桥接程序在 `crates/codegen/xai-grok-agento11y/bridge/src/harness.ts` 中记录它们。
- 中继的 `sessions:transcript` 按从新到旧的顺序返回会话某一范围内的条目，不含思考和工具输出的文字，供手机的会话记录窗口使用（`relay/DESIGN.md` §3）。`bridge:setModels` 最多保留 1,000 个模型，`devices:models` 是客户端读取的列表，crok 的查看器用 `x.ai/remote/models` 获取它。
- 与中继的连接会把一个会话排队中的更新合并成一次写入（`fold_backlog`），`relay/scripts/status-e2e.mjs` 用来测量在慢速中继下手机多快能看到轮次结束。
- OpenRouter 请求会把 `max_tokens` 调整为上下文窗口减去估算的提示长度。

### 签名

2.0.2 与 2.0.1、2.0.0、1.5.2 和 1.5.3 由同一张“Crok Code Signing”证书签名。macOS 把隐私权限与签名绑定，因此你为 2.0.1 允许的权限（屏幕录制、辅助功能、麦克风、语音识别）会延续到 2.0.2。此构建未经公证，所以新安装时需要做一次上面的**仍要打开**步骤。

Android 应用使用 2.0.0 引入的发布密钥签名。iOS 应用没有签名，原因见**手机应用**一节。已签名的校验和清单是另一回事：它让更新程序能够校验下载的文件，并不改变 macOS 对待该应用的方式。

### 从 2.0.1 升级

使用 **Crok Desktop › 检查更新…**，或在退出 Crok Desktop 后于终端中运行 `crok upgrade`。这次更新是就地安装到已安装的 `Crok Desktop.app` 中，因此它在程序坞和访达中的位置保持不变，废纸篓里也不会留下旧副本。更新会选用与已安装应用构建时所用 SDK 相同的映像（macOS26-SDK 或 macOS15-SDK），绝不会选用另一个。

模型提供商的登录状态、设置、任务和远程控制的登录状态都会保留：2.0.2 与 2.0.1 连接的是同一个正式中继。手机应用则按上文**手机应用**一节所述，从此版本的文件安装。

### 详细信息

- 内置 crok `{{CROK_VERSION}}`。
- 由 GitHub Actions 基于标签 `desktop-v2.0.2`（`main` 上的 `{{COMMIT}}`）构建。macOS 26 SDK 映像使用 Xcode {{XCODE26}} 针对 macOS {{SDK26}} SDK 构建，macOS 15 SDK 映像使用 Xcode {{XCODE15}} 针对 macOS {{SDK15}} SDK 构建，单独的 `crok` 则针对 macOS {{TUI_SDK}} SDK 构建。
- 两个映像均为 arm64，由 Crok Code Signing 证书签名且未经公证，均可在 macOS 14 Sonoma 或更高版本上运行。
- iOS 应用（`dev.chenli.crok.mobile`）是用 Xcode {{XCODE26}} 构建的 Release 版本；Android 应用是适用于 Android 8.0 或更高版本的 release 版本。
- SHA-256 校验和位于本说明末尾，也在 `SHA256SUMS.txt` 中，该文件现在也涵盖手机应用。仓库中的 `release/README.md` 说明了如何手动校验这份清单的签名。
