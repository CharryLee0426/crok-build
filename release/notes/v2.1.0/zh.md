Crok Desktop 2.1.0 是本 fork 的原生 macOS 应用。它内置了 crok，也就是智能体运行时和 `crok` 终端界面，无需另外安装任何东西。它紧随 2.0.4 之后：那个版本让远程提示可以附带照片和文件。2.1.0 为终端和 Crok Desktop 增加了第七个模型提供商 Meta Model API 及其 Muse 模型。网页和手机应用现在会把会话的模型和思考级别一起显示，包括从列表中打开的会话。Crok Desktop 只在活动窗口中绘制它的玻璃效果，并自行绘制输入区的玻璃，所以放在其他应用后面的闲置窗口开销与普通窗口相当，调度中心也保持流畅。已选中的反馈赞或踩现在会实心填充，**其他电脑**的状态圆点也更大，在线时为绿色。

这个版本和 2.0.4 一样，在拉取请求合并后随即由 GitHub Actions 构建并发布。

### 安装

1. 下载与你的 macOS 版本相符的磁盘映像并打开。选哪一个，见**下载哪个磁盘映像**中的表格。
2. 把 **Crok Desktop** 拖到**应用程序**。
3. 从“应用程序”中打开 Crok Desktop。此构建未经公证，所以第一次打开时 macOS 会提示无法验证该应用：关闭该提示，打开**系统设置 › 隐私与安全性**，在 Crok Desktop 的提示旁点按**仍要打开**，然后确认。只需操作一次。
4. 在**设置 › 账号**中登录，可使用 OpenRouter、OpenAI Codex、Anthropic API 密钥、DeepSeek API 密钥、Meta Model API 密钥或 GLM Coding Plan 密钥。

需要 macOS 14 Sonoma 或更高版本，以及搭载 Apple 芯片（M1 或更新）的 Mac。

### 下载哪个磁盘映像

两个映像都是 Crok Desktop 2.1.0，功能完全相同。区别只在于构建时所用的 macOS SDK，它决定窗口外观是否采用 Apple 的 Liquid Glass：

| 磁盘映像 | 构建所用 SDK | 适用系统 | 标题栏 |
| --- | --- | --- | --- |
| `Crok-Desktop-2.1.0-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 及更高版本 | Liquid Glass |
| `Crok-Desktop-2.1.0-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 和 15 | 窗口内的毛玻璃模糊 |

在 macOS 26 及更高版本上，建议选用 macOS 26 SDK 映像，以获得 Liquid Glass 标题栏。在 macOS 14 或 15 上，请选用 macOS 15 SDK 映像。它在更高版本上也能运行，所以如果不确定自己的 macOS 版本，选它最稳妥。两个映像中的输入区绘制方式相同。

`crok-2.1.0-aarch64-apple-darwin.tar.gz` 是单独的 `crok` 终端界面，适合不想安装应用的 Mac：解压后把 `crok` 放到 `PATH` 中的某个目录即可。手机应用的介绍见**手机应用**一节。`SHA256SUMS.txt` 列出每个下载文件的 SHA-256，`SHA256SUMS.txt.sig` 是这份清单的签名，更新程序会校验它。

### 手机应用

适用于 iPhone 和 Android 的 Crok 应用会跟进你各台电脑上的会话，显示它们的回复和权限请求，并让你在任何地方开始或操控任务。此版本的手机应用是新的：打开的会话会把模型和思考级别一起显示，即使电脑较旧、按提供商的方式命名模型，也能在列表中找到它。把它们覆盖安装到 2.0.4 的手机应用上，就能用上这些。2.0.4 及更早版本的手机应用仍会照常工作。这三个文件都会登录到正式中继。

- **Android 8.0 或更高版本：** 在手机上下载 `Crok-Android-2.1.0.apk` 并打开，Android 询问时允许浏览器安装应用；也可以运行 `adb install -r Crok-Android-2.1.0.apk`。它使用 2.0.0 引入的发布密钥签名，因此可以直接覆盖安装之前版本的 APK。你自己构建的 Crok APK 使用另一个密钥签名，会导致安装被阻止：请先用 `adb uninstall dev.chenli.crok.mobile` 或在手机的设置中将其移除。
- **iPhone 和 iPad，iOS 17 或更高版本：** `Crok-iOS-2.1.0-unsigned.ipa` 没有签名，因为用于 iOS 设备的应用要用安装者本人的 Apple ID 签名。请用 AltStore 或 Sideloadly 等侧载工具安装它，这类工具会用你的 Apple ID 为它签名。使用免费 Apple ID 时，7 天后 iOS 将不再打开该应用，直到你重新安装。如果想改为自己构建，请使用 **Release** 配置：Xcode 的 Run 按钮构建的是 Debug，它会登录到测试中继。
- **iOS 模拟器：** `Crok-iOS-2.1.0-Simulator.zip` 解压后是 `Crok.app`，可在装有 Xcode 的 Mac 上用 `xcrun simctl install booted Crok.app` 安装。

要让手机登录，请点按**使用 GitHub 或 Google 继续**，在打开的 https://crok.chenli.dev 页面上登录，然后点按**批准**。接着关联每台电脑：在电脑上运行 `crok remote login`，然后在应用的**设置 › 关联电脑**中扫描它显示的二维码，或在随之打开的网页上批准这台电脑。

### 主要更新

- **Meta Model API，第七个提供商。** 终端和 Crok Desktop 可以登录 Meta 自己的 Model API，费用按 token 记在 Meta 账号上，密钥来自 dev.meta.ai。`crok login meta` 会要求输入密钥且不显示内容，并在保存前向 Meta 校验；被拒绝的密钥不会保存。`meta-code` 和 `muse` 是别名，`META_API_KEY` 和 `MODEL_API_KEY` 也能以同样的方式登录，`crok logout meta` 会移除已保存的密钥。Crok Desktop 的**设置 › 账号**和终端的首次运行菜单都会列出这个提供商。
- **Muse 模型。** 登录时会获取你账号的模型列表，之后每小时刷新一次。内置列表包括 Muse Wonder、Muse Spark 1.3、1.2 和 1.1、它们的 Contributor 模式变体，以及 Muse Ember；Meta 以后发布的模型可以用 `meta/<model>` 形式的 ID 立即使用。这些模型可以读取文本、图片、PDF、音频和视频。它们总会推理：`/effort` 提供 `minimal`、`low`、`medium`、`high`、`xhigh` 和 `max`，Muse Wonder 和 Muse Ember 默认使用 `max`，Muse Spark 默认使用 `high`。由于 Meta 拒绝，`none` 不在选项中；Contributor 变体最高只到 `xhigh`。
- **会话的模型和思考级别始终一起显示。** 在网页、iOS 或 Android 上打开会话时，过去可能只显示模型 ID 本身，没有思考级别标签。crok 现在按模型列表中的 ID 给会话的模型命名，因此各设备能找到该模型及其思考级别。来自较旧 crok 的会话会按提供商的方式命名模型，此时仍可先按去掉提供商前缀的 ID、再按名称找到它。列表加载期间，思考级别标签会显示会话自己的级别；模型列表中没有的级别会按其级别名称显示，而不会写成**默认**。只有当列表说明该模型没有思考级别，或列表和会话都没有给出级别时，这个标签才会省略。
- **开销更低的玻璃效果。** 只有活动窗口的玻璃效果是实时的，和系统自带的边栏一样：放在其他应用后面的窗口会绘制纯色，欢迎页的卡片也不再滚动。滑入调度中心时不再卡顿，使用外接显示器时更明显。在一台连接 4K 显示器的 M1 上，Crok 位于访达后面时，调度中心的 GPU 占用均值从 14.1 降到 8.9（p90 从 46 降到 31）。
- **输入区改为绘制，不再使用 Liquid Glass。** 只要窗口中有任何变化（包括光标闪烁），窗口服务器就会重新渲染 Liquid Glass。输入区的表面现在由一层毛玻璃材质和一个 Canvas 绘制，后者包含阴影、填充、受光边缘、辉光和细线，外观与系统效果相差不超过 255 级中的几级。在同一台 M1 和 4K 显示器上，Crok 在最前面闲置时的 GPU 占用从约 25 降到 10.6，Crok 在最前面时的调度中心从 18.8 降到 13.0。
- **小幅改进。** 选择赞或踩后，图标会变成实心，评价一眼可见。**其他电脑**的在线圆点为 10 点大小，绿色并带光晕；离线圆点大小相同，为灰色。

### 远程控制

此版本中的每个 crok 都和 2.0.4 一样登录位于 https://crok.chenli.dev 的正式中继，并沿用已有的登录。正式中继会在此版本发布时用上此版本对网页的改动；电脑上的那部分改动，要等那台电脑装上 crok 2.1.0 才会有。

- **模型名称。** 会话按提供商的方式保存模型（`claude-sonnet-5-5`、`deepseek-flash`、OpenRouter 的 `deepseek/deepseek-v4.1-flash`），而 crok 发布的列表按目录键命名（`anthropic/claude-sonnet-5-5`、`deepseek/deepseek-flash`、`openrouter/deepseek/deepseek-v4.1-flash`）。crok 2.1.0 会发送列表中的 ID，因此网页和手机能找到该模型及其思考级别。电脑不再提供的模型会保留原来的名字。
- **较旧的 crok。** 运行 crok 2.0.4 或更早版本的电脑仍会按提供商的方式命名模型。网页和此版本的手机应用会按去掉提供商前缀的 ID 找到它，所以模型和级别仍能显示；只有当两种形式都不匹配时，才会直接显示模型 ID。
- **两个标签。** 网页、iOS 和 Android 会把会话的模型和思考级别一起显示。电脑的列表还在传输时，模型照常显示，思考级别标签显示会话的级别；如果较旧的 crok 没有提供列表，两个标签都会变暗，点按后会提示该电脑还不能提供模型选择。模型列表中没有的级别会按其级别名称显示。
- **请更新电脑。** Meta Model API 和准确的模型名称需要每台电脑装有 crok 2.1.0。按上文**手机应用**一节所述安装此版本的手机应用，才能用上这两个标签。

### 反馈与 Agent Observability

上报与 2.0.4 相同：此版本中的每个 crok 都会把它发出的每次模型调用，连同轮次、工具运行、步骤和守卫检查，上报到维护者 Grafana Cloud 栈上的 [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/)，`crok version --json` 会在 `agentObservability` 下显示上报的主机。来自 Crok Desktop 或终端的赞或踩，会记录在该轮次所属的会话上，同时记为 `crok_feedback_rating` 这个 gauge 指标；撤回评价会被记为中性。

要关闭上报，在 `~/.crok/config.toml` 的 `[features]` 下加上 `agent_observability = false`，或设置 `CROK_AGENT_OBSERVABILITY=0`。要上报到你自己的栈，用仓库中的 `crates/codegen/xai-grok-agento11y/setup.sh` 写好 `~/.crok/agento11y.env`。

### 面向开发者

- Meta 是一个 `ApiBackend`（`meta`），有自己的一套 Chat Completions 方言。登录时会获取 `GET /v1/models`，之后每小时获取一次，并缓存在 `~/.crok/meta-models.json`；在首次获取之前使用内置列表。`provider_compat.rs` 会把 `none` 和 `minimal` 都作为 `minimal` 发送；由于推理占用同一份输出额度，它会把低于 4,096 的 `max_tokens` 提高；它用文字要求强制工具调用，并发送 `tool_choice: "auto"`；它保留原生 JSON schema；它会从重放的轮次中移除 `reasoning_content`，并移除 `frequency_penalty` 和 `presence_penalty`。
- 在不同模型家族之间切换时会先压缩，和 Anthropic 一样。标准费用根据 Meta 公布的价格估算，包括 Muse Ember 的 20 万输入 token 长上下文档位和 Contributor 价格。
- 远程控制：`bridge:upsertSession`（仅在模型变化时）、`bridge:catalogBatch` 和 `catalogUpdate` 会按 `selectable_catalog_key_for_persisted` 解析出的目录键来命名会话的模型，这与恢复会话时解析模型的方式相同。列表中缺少的模型会保留原名。`relay/DESIGN.md` 和 `mobile/DESIGN.md` 说明了这一约定。
- 网页、iOS 和 Android 会先按 ID、再按去掉提供商前缀的 ID、最后按名称查找会话的模型，并在会话给出级别时显示思考级别标签。网页预览新增了这些场景（`session-provider-model`、`session-models-loading`、`session-unknown-model`）。
- 桌面端：`GlassBackdrop` 在窗口不活动时使用纯色，并在另一区域的背景上叠加色调，而不再重新模糊桌面；`GlassSurface` 用一个 Canvas 绘制它的 `FrostedGlass` 外观。测试会检查窗口中不再有 Liquid Glass 图层，以及不活动的窗口绘制纯色。
- 发布仍由 `.github/workflows/release.yml` 完成：一个修改了 `VERSION` 的拉取请求合并进 `main` 后，它会构建、检查并签名每个文件，运行评测门禁，然后带着 `release/notes/v2.1.0/` 中的说明发布。

### 签名

2.1.0 与 2.0.4、2.0.3、2.0.2、2.0.1、2.0.0、1.5.2 和 1.5.3 由同一张“Crok Code Signing”证书签名。macOS 把隐私权限与签名绑定，因此你为 2.0.4 允许的权限（屏幕录制、辅助功能、麦克风、语音识别）会延续到 2.1.0。此构建未经公证，所以新安装时需要做一次上面的**仍要打开**步骤。

Android 应用使用 2.0.0 引入的发布密钥签名。iOS 应用没有签名，原因见**手机应用**一节。已签名的校验和清单是另一回事：它让更新程序能够校验下载的文件，并不改变 macOS 对待该应用的方式。

### 从 2.0.4 升级

使用 **Crok Desktop › 检查更新…**，或在退出 Crok Desktop 后于终端中运行 `crok upgrade`。这次更新是就地安装到已安装的 `Crok Desktop.app` 中，因此它在程序坞和访达中的位置保持不变，废纸篓里也不会留下旧副本。更新会选用与已安装应用构建时所用 SDK 相同的映像（macOS26-SDK 或 macOS15-SDK），绝不会选用另一个。

模型提供商的登录状态、设置、任务和远程控制的登录状态都会保留：2.1.0 与 2.0.4 连接的是同一个正式中继。请把你通过中继使用的每台电脑都更新到 crok 2.1.0，才能使用 Meta Model API 和准确的模型名称；同时按上文**手机应用**一节所述，安装此版本的手机应用。

### 详细信息

- 内置 crok `{{CROK_VERSION}}`。
- 由 GitHub Actions 基于标签 `desktop-v2.1.0`（`main` 上的 `{{COMMIT}}`）构建。macOS 26 SDK 映像使用 Xcode {{XCODE26}} 针对 macOS {{SDK26}} SDK 构建，macOS 15 SDK 映像使用 Xcode {{XCODE15}} 针对 macOS {{SDK15}} SDK 构建，单独的 `crok` 则针对 macOS {{TUI_SDK}} SDK 构建。
- 两个映像均为 arm64，由 Crok Code Signing 证书签名且未经公证，均可在 macOS 14 Sonoma 或更高版本上运行。
- iOS 应用（`dev.chenli.crok.mobile`）是用 Xcode {{XCODE26}} 构建的 Release 版本；Android 应用是适用于 Android 8.0 或更高版本的 release 版本。
- SHA-256 校验和位于本说明末尾，也在 `SHA256SUMS.txt` 中，该文件也涵盖手机应用。仓库中的 `release/README.md` 说明了如何手动校验这份清单的签名。
