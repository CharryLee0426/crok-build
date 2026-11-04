Crok Desktop 2.0.4 是本 fork 的原生 macOS 应用。它内置了 crok，也就是智能体运行时和 `crok` 终端界面，无需另外安装任何东西。它紧随 2.0.3 之后：那个版本让每台设备上的会话列表保持最新。2.0.4 让来自网页、手机或另一台电脑的提示可以附带照片和文件，并在每台设备的会话记录中显示它们。每个会话列表都新增了**刷新**按钮，可以让每台在线电脑立即重新列出它的会话。Crok Desktop 在每条回复下方加上了拷贝以及赞和踩按钮，终端会在一个轮次结束后问一个简短的问题，OpenRouter 上更多的推理模型现在也能为会话生成标题了。

这个版本和 2.0.3 一样，在拉取请求合并后随即由 GitHub Actions 构建并发布。

### 安装

1. 下载与你的 macOS 版本相符的磁盘映像并打开。选哪一个，见**下载哪个磁盘映像**中的表格。
2. 把 **Crok Desktop** 拖到**应用程序**。
3. 从“应用程序”中打开 Crok Desktop。此构建未经公证，所以第一次打开时 macOS 会提示无法验证该应用：关闭该提示，打开**系统设置 › 隐私与安全性**，在 Crok Desktop 的提示旁点按**仍要打开**，然后确认。只需操作一次。
4. 在**设置 › 账号**中登录，可使用 OpenRouter、OpenAI Codex、Anthropic API 密钥、DeepSeek API 密钥或 GLM Coding Plan 密钥。

需要 macOS 14 Sonoma 或更高版本，以及搭载 Apple 芯片（M1 或更新）的 Mac。

### 下载哪个磁盘映像

两个映像都是 Crok Desktop 2.0.4，功能完全相同。区别只在于构建时所用的 macOS SDK，它决定窗口外观是否采用 Apple 的 Liquid Glass：

| 磁盘映像 | 构建所用 SDK | 适用系统 | 标题栏 |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.4-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 及更高版本 | Liquid Glass |
| `Crok-Desktop-2.0.4-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 和 15 | 窗口内的毛玻璃模糊 |

在 macOS 26 及更高版本上，建议选用 macOS 26 SDK 映像，以获得 Liquid Glass 标题栏。在 macOS 14 或 15 上，请选用 macOS 15 SDK 映像。它在更高版本上也能运行，所以如果不确定自己的 macOS 版本，选它最稳妥。

`crok-2.0.4-aarch64-apple-darwin.tar.gz` 是单独的 `crok` 终端界面，适合不想安装应用的 Mac：解压后把 `crok` 放到 `PATH` 中的某个目录即可。手机应用的介绍见**手机应用**一节。`SHA256SUMS.txt` 列出每个下载文件的 SHA-256，`SHA256SUMS.txt.sig` 是这份清单的签名，更新程序会校验它。

### 手机应用

适用于 iPhone 和 Android 的 Crok 应用会跟进你各台电脑上的会话，显示它们的回复和权限请求，并让你在任何地方开始或操控任务。此版本的手机应用是新的：它们可以随提示发送照片和文件，在会话记录中显示它们，并且有了**刷新**。把它们覆盖安装到 2.0.3 的手机应用上，就能同时用上这两项。2.0.3 及更早版本的手机应用仍会照常工作，只是没有这些功能。这三个文件都会登录到正式中继。

- **Android 8.0 或更高版本：** 在手机上下载 `Crok-Android-2.0.4.apk` 并打开，Android 询问时允许浏览器安装应用；也可以运行 `adb install -r Crok-Android-2.0.4.apk`。它使用 2.0.0 引入的发布密钥签名，因此可以直接覆盖安装之前版本的 APK。你自己构建的 Crok APK 使用另一个密钥签名，会导致安装被阻止：请先用 `adb uninstall dev.chenli.crok.mobile` 或在手机的设置中将其移除。
- **iPhone 和 iPad，iOS 17 或更高版本：** `Crok-iOS-2.0.4-unsigned.ipa` 没有签名，因为用于 iOS 设备的应用要用安装者本人的 Apple ID 签名。请用 AltStore 或 Sideloadly 等侧载工具安装它，这类工具会用你的 Apple ID 为它签名。使用免费 Apple ID 时，7 天后 iOS 将不再打开该应用，直到你重新安装。如果想改为自己构建，请使用 **Release** 配置：Xcode 的 Run 按钮构建的是 Debug，它会登录到测试中继。
- **iOS 模拟器：** `Crok-iOS-2.0.4-Simulator.zip` 解压后是 `Crok.app`，可在装有 Xcode 的 Mac 上用 `xcrun simctl install booted Crok.app` 安装。

要让手机登录，请点按**使用 GitHub 或 Google 继续**，在打开的 https://crok.chenli.dev 页面上登录，然后点按**批准**。接着关联每台电脑：在电脑上运行 `crok remote login`，然后在应用的**设置 › 关联电脑**中扫描它显示的二维码，或在随之打开的网页上批准这台电脑。

### 主要更新

- **任何设备上的提示都能附带照片和文件。** 在网页和手机应用中，输入框旁的回形针按钮可以为提示添加照片和文件：手机上可选“照片”“相机”和“文件”，网页上还可以把它们粘贴或拖放到会话中。一条消息最多附带 10 个，每个不超过 20 MB，一条消息也可以只有照片。电脑会把图片作为图片交给模型，其他文件则保存到专门的文件夹中供模型读取。照片会显示在每台设备的会话记录中，点按即可全屏打开（手机上还可以分享和保存：iPhone 上是**共享**和**存储到照片**，Android 上是**分享**和**保存**）；直接在电脑上输入的提示中的图片，也会显示在手机和网页上。
- **刷新每个会话列表。** 网页、手机应用、Crok Desktop 的**其他电脑**和终端的远程面板都有刷新控件（↻，或在 `/remote` 中按 `r`）。它会请求每台在线电脑立即重新列出全部会话，而不是等到下一次检查，并会一直转动，直到每台电脑都列完为止。在手机上，下拉列表也有同样的效果。
- **对回复给出反馈。** Crok Desktop 会在每条已完成的回复下方显示**拷贝**按钮以及赞和踩按钮。拷贝得到的是回复原本的 Markdown，再次点按已选的那个按钮则会撤回评价。终端会在已完成的轮次下方问一次“这次回复怎么样？”，可以用 `/good`、`/not-so-well` 或 `/dont-show-again` 回答。
- **更多 OpenRouter 模型能生成会话标题。** 拒绝强制工具调用的推理模型（Muse Spark 1.3），以及把简短回答的额度耗在推理上的推理模型（Muse Glimmer、GLM 5.3 Flash、Aion 2.0），过去从来得不到生成的标题，所以它们的会话都以提示开头的几个词命名。现在它们会像其他任何模型一样得到标题。

### 远程控制

此版本中的每个 crok 都和 2.0.3 一样登录位于 https://crok.chenli.dev 的正式中继，并沿用已有的登录。正式中继会在此版本发布时用上此版本对中继的改动；电脑上的那部分改动，要等那台电脑装上 crok 2.0.4 才会有。

- **照片和文件（电脑上）。** 在运行这样的提示之前，crok 会先下载其中的照片和文件。图片作为图像输入交给模型。其他文件保存在 `~/.crok/remote/attachments/` 下（每个会话和每条消息各一个文件夹），并在提示中给出链接，方式与 Crok Desktop 附加文件相同。在已经打开的另一台电脑的任务中，Crok Desktop 和终端会随提示一起上传其中的图片和文件；在另一台电脑上新建的任务仍然只能以文字开始。
- **照片和文件（中继上）。** 网页和手机发送的照片会摆正方向，长边不超过 2048 像素，去掉元数据，并附带一张小预览图。没有任何消息认领的上传会在一天后删除；会话的文件会随会话一起删除，或在会话闲置 30 天后随会话记录一起删除。
- **较旧的 crok。** 只运行 crok 2.0.3 或更早版本的电脑无法接收照片或文件：向那里发送时会提示“Update crok on … to send photos and files there.”（意为：请更新 … 上的 crok，才能把照片和文件发送到那里）。文字提示照常可用。
- **刷新。** 持有一台电脑会话列表的 crok，一旦有人按下刷新，就会立即重新列出磁盘上的每个会话，之后像以前一样每 30 秒只发送有变化的部分。每台在线电脑都响应后，或者 15 秒后，旋转图标就会停下。只运行较旧 crok 的电脑可能要到下一次定期列出时才会响应。离线的电脑无法列出它们的会话：这些会话保持上次列出时的样子；没有电脑在线时，手机和网页会显示“没有在线的电脑。列表显示的是它们上次列出的会话。”
- **请更新电脑。** 提示中的照片和文件，以及对刷新的即时响应，都需要每台电脑装有 crok 2.0.4。

### 反馈与 Agent Observability

和 2.0.3 一样，此版本中的每个 crok 都会把它发出的每次模型调用，连同轮次、工具运行、步骤和守卫检查，上报到维护者 Grafana Cloud 栈上的 [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/)，`crok version --json` 会在 `agentObservability` 下显示上报的主机。

- **赞和踩记录在哪里。** 来自 Crok Desktop 或终端的赞或踩，会记录在 Agent Observability 中该轮次所属的会话上，同时记为 `crok_feedback_rating` 这个 gauge 指标。撤回评价会被记为中性，因此不再计入。关闭上报时不会发送任何内容。
- **终端里的问题。** 它会在已完成的轮次下方出现一次；轮次被取消或失败后、极简模式下，以及终端很矮时，都不会出现。`/dont-show-again` 会在 `~/.crok/config.toml` 的 `[features]` 下写入 `feedback_prompt = false` 来关闭它；把它改回 `true` 即可再次看到这个问题。
- **维护者的评估。** 新的 **crok Feedback** 仪表盘显示有反馈的轮次中赞所占的比例，这一比例在一天内低于 80% 时会告警，并设有 30 天的目标。一个时间范围内至少有 20 条评价时，它才会生效。

要关闭上报，在 `~/.crok/config.toml` 的 `[features]` 下加上 `agent_observability = false`，或设置 `CROK_AGENT_OBSERVABILITY=0`。要上报到你自己的栈，用仓库中的 `crates/codegen/xai-grok-agento11y/setup.sh` 写好 `~/.crok/agento11y.env`。

### 面向开发者

- 发布仍由 `.github/workflows/release.yml` 完成：一个修改了 `VERSION` 的拉取请求合并进 `main` 后，它会构建、检查并签名每个文件，运行评测门禁，然后带着 `release/notes/v2.0.4/` 中的说明发布。
- 照片和文件：设备上传到 `files:uploadUrl`，并在 `commands:sendPrompt` 和 `sessions:create` 中指明这些上传（`attachments`）；中继把它们保存在 `files` 表中（所有者、会话、SHA-256、预览图），并在电脑的收件箱和每次会话记录查询中给出它们的下载 URL。只有 `features` 中列有 `attachments` 的 crok 才会收到这类提示，`bridge:connect` 会以中继自己的 `features` 作答。`relay/DESIGN.md` §2–§5 中的“Photos and files”一节是其契约；`relay/scripts/attachments-e2e.mjs` 和 `attachments-bridge-e2e.mjs` 对此进行检查。
- 刷新：`sessions:refresh`（返回 `{asked, offline, at}`）会在每台在线电脑的目录上记下 `refreshAt`；只要它晚于上一次上传的开始时间，那台电脑上的每个 crok 都会看到 `catalogWanted`，`bridge:beginCatalog` 也会立即批准最先请求的那个 crok，持有者也不例外。`sessions:refreshState({since})` 给出仍在列出会话的电脑。查看器的 `x.ai/remote/refresh` 为 Crok Desktop 和终端完成这两步。`relay/scripts/refresh-e2e.mjs` 用真实的 crok 进程对此进行检查。
- 反馈：前端会为一个轮次发送 `x.ai/feedback/rating`（`1`、`-1`，撤回时为 `0`）。`[features] feedback_prompt`（默认 `true`，环境变量 `CROK_FEEDBACK_PROMPT`）控制终端里的那个问题。评估由 `crok Feedback` 仪表盘、`crok-feedback-good-rate-low` 告警和 `crok feedback is mostly positive` SLO 组成。
- 在 OpenRouter 上，采样器改为用文字要求强制工具调用，并使用 `tool_choice: "auto"`；除非调用本身指定了推理强度，否则它会以目录中列出的最轻推理强度给推理模型至少 4,096 个输出 token。`SamplerConfig` 的两个字段记录目录中的推理支持情况和最轻推理强度。
- **LLM Overview** 仪表盘的缓存命中率现在涵盖 Claude Platform、OpenRouter 和 crok 自己上报的调用，每个来源单独查询，所以在所选时间范围内没有调用的来源不会影响结果。

### 签名

2.0.4 与 2.0.3、2.0.2、2.0.1、2.0.0、1.5.2 和 1.5.3 由同一张“Crok Code Signing”证书签名。macOS 把隐私权限与签名绑定，因此你为 2.0.3 允许的权限（屏幕录制、辅助功能、麦克风、语音识别）会延续到 2.0.4。此构建未经公证，所以新安装时需要做一次上面的**仍要打开**步骤。

Android 应用使用 2.0.0 引入的发布密钥签名。iOS 应用没有签名，原因见**手机应用**一节。已签名的校验和清单是另一回事：它让更新程序能够校验下载的文件，并不改变 macOS 对待该应用的方式。

### 从 2.0.3 升级

使用 **Crok Desktop › 检查更新…**，或在退出 Crok Desktop 后于终端中运行 `crok upgrade`。这次更新是就地安装到已安装的 `Crok Desktop.app` 中，因此它在程序坞和访达中的位置保持不变，废纸篓里也不会留下旧副本。更新会选用与已安装应用构建时所用 SDK 相同的映像（macOS26-SDK 或 macOS15-SDK），绝不会选用另一个。

模型提供商的登录状态、设置、任务和远程控制的登录状态都会保留：2.0.4 与 2.0.3 连接的是同一个正式中继。请更新你通过中继使用的每台电脑，让它能接收照片和文件并立即响应刷新；同时按上文**手机应用**一节所述，安装此版本的手机应用。

### 详细信息

- 内置 crok `{{CROK_VERSION}}`。
- 由 GitHub Actions 基于标签 `desktop-v2.0.4`（`main` 上的 `{{COMMIT}}`）构建。macOS 26 SDK 映像使用 Xcode {{XCODE26}} 针对 macOS {{SDK26}} SDK 构建，macOS 15 SDK 映像使用 Xcode {{XCODE15}} 针对 macOS {{SDK15}} SDK 构建，单独的 `crok` 则针对 macOS {{TUI_SDK}} SDK 构建。
- 两个映像均为 arm64，由 Crok Code Signing 证书签名且未经公证，均可在 macOS 14 Sonoma 或更高版本上运行。
- iOS 应用（`dev.chenli.crok.mobile`）是用 Xcode {{XCODE26}} 构建的 Release 版本；Android 应用是适用于 Android 8.0 或更高版本的 release 版本。
- SHA-256 校验和位于本说明末尾，也在 `SHA256SUMS.txt` 中，该文件也涵盖手机应用。仓库中的 `release/README.md` 说明了如何手动校验这份清单的签名。
