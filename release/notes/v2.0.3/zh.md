Crok Desktop 2.0.3 是本 fork 的原生 macOS 应用。它内置了 crok，也就是智能体运行时和 `crok` 终端界面，无需另外安装任何东西。它紧随 2.0.2 之后：那个版本让浏览器工具用上了你自己的 Chrome，并把模型选择器带到了每台设备上。2.0.3 让每台设备上的会话列表保持最新：在一台电脑上新建、重命名或删除的会话，大约半分钟内就会同步到网页、手机和其他电脑。从网页或手机在某台电脑上开始的会话，现在也会出现在那台电脑上：在 Crok Desktop 中显示为一个任务，在终端中则出现在远程面板里。以选定模型开始的新会话一定会以该模型开始，crok 的 Claude 调用也不再在 Agent Observability 中被计算两次。

这个版本和 2.0.2 一样，在拉取请求合并后随即由 GitHub Actions 构建并发布。

### 安装

1. 下载与你的 macOS 版本相符的磁盘映像并打开。选哪一个，见**下载哪个磁盘映像**中的表格。
2. 把 **Crok Desktop** 拖到**应用程序**。
3. 从“应用程序”中打开 Crok Desktop。此构建未经公证，所以第一次打开时 macOS 会提示无法验证该应用：关闭该提示，打开**系统设置 › 隐私与安全性**，在 Crok Desktop 的提示旁点按**仍要打开**，然后确认。只需操作一次。
4. 在**设置 › 账号**中登录，可使用 OpenRouter、OpenAI Codex、Anthropic API 密钥、DeepSeek API 密钥或 GLM Coding Plan 密钥。

需要 macOS 14 Sonoma 或更高版本，以及搭载 Apple 芯片（M1 或更新）的 Mac。

### 下载哪个磁盘映像

两个映像都是 Crok Desktop 2.0.3，功能完全相同。区别只在于构建时所用的 macOS SDK，它决定窗口外观是否采用 Apple 的 Liquid Glass：

| 磁盘映像 | 构建所用 SDK | 适用系统 | 标题栏 |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.3-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 及更高版本 | Liquid Glass |
| `Crok-Desktop-2.0.3-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 和 15 | 窗口内的毛玻璃模糊 |

在 macOS 26 及更高版本上，建议选用 macOS 26 SDK 映像，以获得 Liquid Glass 标题栏。在 macOS 14 或 15 上，请选用 macOS 15 SDK 映像。它在更高版本上也能运行，所以如果不确定自己的 macOS 版本，选它最稳妥。

`crok-2.0.3-aarch64-apple-darwin.tar.gz` 是单独的 `crok` 终端界面，适合不想安装应用的 Mac：解压后把 `crok` 放到 `PATH` 中的某个目录即可。手机应用的介绍见**手机应用**一节。`SHA256SUMS.txt` 列出每个下载文件的 SHA-256，`SHA256SUMS.txt.sig` 是这份清单的签名，更新程序会校验它。

### 手机应用

适用于 iPhone 和 Android 的 Crok 应用会跟进你各台电脑上的会话，显示它们的回复和权限请求，并让你在任何地方开始或操控任务。它和 2.0.2 一样随此版本一起提供，功能也与 2.0.2 的手机应用相同：此版本的改动都在电脑和中继上，所以 2.0.2 和 2.0.1 的手机应用同样能用上这些改动。这三个文件都会登录到正式中继。

- **Android 8.0 或更高版本：** 在手机上下载 `Crok-Android-2.0.3.apk` 并打开，Android 询问时允许浏览器安装应用；也可以运行 `adb install -r Crok-Android-2.0.3.apk`。它使用以后的版本也会沿用的发布密钥签名，因此下一个 APK 可以直接覆盖安装。你自己构建的 Crok APK 使用另一个密钥签名，会导致安装被阻止：请先用 `adb uninstall dev.chenli.crok.mobile` 或在手机的设置中将其移除。
- **iPhone 和 iPad，iOS 17 或更高版本：** `Crok-iOS-2.0.3-unsigned.ipa` 没有签名，因为用于 iOS 设备的应用要用安装者本人的 Apple ID 签名。请用 AltStore 或 Sideloadly 等侧载工具安装它，这类工具会用你的 Apple ID 为它签名。使用免费 Apple ID 时，7 天后 iOS 将不再打开该应用，直到你重新安装。如果想改为自己构建，请使用 **Release** 配置：Xcode 的 Run 按钮构建的是 Debug，它会登录到测试中继。
- **iOS 模拟器：** `Crok-iOS-2.0.3-Simulator.zip` 解压后是 `Crok.app`，可在装有 Xcode 的 Mac 上用 `xcrun simctl install booted Crok.app` 安装。

要让手机登录，请点按**使用 GitHub 或 Google 继续**，在打开的 https://crok.chenli.dev 页面上登录，然后点按**批准**。接着关联每台电脑：在电脑上运行 `crok remote login`，然后在应用的**设置 › 关联电脑**中扫描它显示的二维码，或在随之打开的网页上批准这台电脑。

### 主要更新

- **每台设备上的会话列表都保持最新。** 只在电脑磁盘上发生变化的会话（由未登录中继的 crok 新建，或被重命名、删除），过去要等那台电脑下一次发送完整列表时才会同步到网页、手机和其他电脑；完整列表大约每 20 分钟才发送一次，而且发送它的 crok 一退出就会停止。现在这类变化大约半分钟内就会到达；第一个 crok 退出后，这台电脑上的另一个 crok 会立即接手列表。
- **从网页或手机开始的会话会出现在它所在的电脑上。** Crok Desktop 会把这样的会话作为一个未读任务加入它所属的项目，并在轮次运行时显示它正在工作。终端会说明是哪台设备开始了它，并在 `/remote` 的**这台电脑**下列出它。
- **新会话会以你选的模型开始。** 从网页或手机以选定的模型和思考级别开始的会话，过去可能会改用电脑的默认设置开始：如果那台电脑上较旧的 crok（比如更新之前就开着、一直没关的终端）先接下了它，就会这样。现在只有会应用这一选择的 crok 才能接下它。
- **其他电脑会立即列出。** Crok Desktop 的**其他电脑**每当与中继的连接建立时都会重新请求列表，并在得到回应之前每 5 秒请求一次，而不再最多等待 4 分钟。
- **Claude 调用只会向 Agent Observability 上报一次。** Claude Platform 自己的遥测导出过去会为 crok 上报的每次 Claude 调用再存一份副本。现在 crok 会请求 Anthropic 的 API 不要导出它自己上报的调用。详见下文的 **Agent Observability** 一节。

### 远程控制

此版本中的每个 crok 都和 2.0.2 一样登录位于 https://crok.chenli.dev 的正式中继，并沿用已有的登录。正式中继已经在运行此版本对中继的改动，所以下面关于选定模型的规则现在就已生效；其余改动要等每台电脑装上 crok 2.0.3 才会有。

- **会话列表。** 每台电脑上由一个 crok 负责这台电脑的列表：它每 30 秒查看一次磁盘上的会话，只发送有变化的部分，每 30 分钟再发送一次完整列表。当它退出或断开连接时，这台电脑上的其他所有 crok 都会被请求接手列表，由最先响应的那个接手。crok 重新启动的电脑会立即列出它的会话。仍在运行 crok 2.0.2 或更早版本的电脑继续自己发送完整列表，现在每 10 分钟一次，而不是大约每 20 分钟一次。
- **在别处开始的会话（Crok Desktop）。** 另一台设备在这台 Mac 上开始的会话，一经中继列出就会成为其所属项目中的一个任务；如果应用里还没有对应那个文件夹的项目，也会一并创建项目。这个任务是未读的，在你打开它之前沿用会话的标题；那边有轮次运行时显示为正在工作，轮次结束时显示为未读；打开方式和其他任务一样。每个这样的会话只添加一次，所以你移除过的任务或项目不会再回来。
- **在别处开始的会话（终端）。** 终端连接着中继时，会通告另一台设备在这台电脑上开始的每个会话，例如“iPhone 在 app 中开始了一个会话：… — 用 /resume 或 /remote 打开”。远程面板把这些会话列在最前面，位于**这台电脑**之下，每个都标出它来自哪台设备（“来自 iPhone”）。按回车会在这里打开会话；在这台电脑上按 `n`，则会引导你使用 `/new`。
- **选定的模型。** 带有模型或思考级别的新会话只会交给会应用它的 crok，也就是 crok 2.0.1 及更高版本。在只运行 crok 2.0.0 或更早版本的电脑上，开始这样的会话会失败并提示“Update crok on … to start a session there with a chosen model or thinking level”（意为：请更新 … 上的 crok，才能在那里以选定的模型或思考级别开始会话），而不会以默认设置开始。模型选为**默认**的会话仍然可以在任何 crok 上开始。重新打开一个未能开始的会话的提示或重试，也遵循同样的规则。
- **请更新电脑。** 与磁盘保持同步的列表，以及其他设备开始的会话出现在其所在电脑上，都需要那台电脑装有 crok 2.0.3。手机上没有变化。

### Agent Observability

和 2.0.2 一样，此版本中的每个 crok 都会把它发出的每次模型调用，连同轮次、工具运行、步骤和守卫检查，上报到维护者 Grafana Cloud 栈上的 [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/)，`crok version --json` 会在 `agentObservability` 下显示上报的主机。

- **Claude 调用不再有第二份副本。** Claude Platform 组织可以把每个 API 请求的追踪 span 导出到它的遥测目标，而 Agent Observability 过去会把其中每一个都当作一个单独的会话，以其追踪 ID 命名，归在智能体 `claude-platform` 之下。因此 crok 上报的每次 Claude 调用都会被存储两次。现在 crok 把它自己上报的调用发往 `api.anthropic.com` 时，会带上标记为未采样的追踪上下文，Anthropic 的 API 对此的处理是不为这些调用导出任何内容。crok 不上报的调用（压缩，以及关闭上报时的所有调用）仍会照常导出，发往其他提供商的调用也是如此。
- **如果你的组织导出了 Claude 遥测，** crok 上报到 Agent Observability 的 Claude 调用就不会再出现在那份导出中；如需让它们重新出现在那里，请关闭上报。
- **仪表盘用 crok 的记录代替 Claude Platform 的记录来统计 crok 的 Claude 调用。** 这类调用在 crok 中的 span 带有 `crok.unsampled = true`，并以 Claude Platform 的属性名记录其缓存读取和思考 token，所以 LLM Observability 仪表盘只会统计它一次。来自 crok 2.0.2 及更早版本的调用仍按 Claude Platform 的导出统计。
- **已存储的副本已做标记。** Agent Observability 无法删除已存储的内容，所以 crok 1.5.0 到 2.0.2 产生的 586 份副本，每一份都已被标为 crok 调用的副本，以便与只有 Claude Platform 看到的调用区分开。每台仍在使用 crok 2.0.2 或更早版本的电脑，在更新之前都会继续产生副本。

要关闭上报，在 `~/.crok/config.toml` 的 `[features]` 下加上 `agent_observability = false`，或设置 `CROK_AGENT_OBSERVABILITY=0`。要上报到你自己的栈，用仓库中的 `crates/codegen/xai-grok-agento11y/setup.sh` 写好 `~/.crok/agento11y.env`。

### 面向开发者

- 发布仍由 `.github/workflows/release.yml` 完成：一个修改了 `VERSION` 的拉取请求合并进 `main` 后，它会构建、检查并签名每个文件，运行评测门禁，然后带着 `release/notes/v2.0.3/` 中的说明发布。
- 中继为每台电脑保留一个目录持有者（catalog holder）：`bridge:catalogUpdate` 接收持有者自上次上传以来的变化（一旦由另一个进程持有，则返回 `EXPIRED`），目录被释放时会把 `catalogWanted` 放进那台电脑上每个 crok 的收件箱，`bridge:connect` 会列出 `catalog`。`sessions:create` 会保存 `startedFrom`（`{kind: phone | web | computer, name, at}`），查看器的 `x.ai/remote/sessions` 带有 `here`，即这台电脑上从别处开始的会话（最新的 100 个）。`relay/DESIGN.md` §2–§5 对此有说明。
- 带有模型或思考级别的 `create` 只会提供给 `features` 中列有 `setup`（crok 2.0.3 会列出它）或 `git`（crok 2.0.1 和 2.0.2）的主机。
- `relay/scripts/sessions-live-e2e.mjs` 用一个本地中继检查两台电脑和一部手机：正在运行的会话立即列出、在磁盘上新建和删除会话、持有者退出、手机开始的会话到达电脑自己的前端。`commands-e2e` 和 `bridge-e2e` 现在还会检查带选定模型的会话在哪里开始，以及它的第一个轮次实际在什么模型上运行。
- 手机应用的 Debug 构建在**个人资料**右侧多了第三个标签页 **o11y**：由中继把所有者的 Grafana Cloud 仪表盘、评测和 Agent Observability 做成手机页面（`o11y:page`、`o11y:refresh`；`mobile/DESIGN.md` 中的“o11y”一节，`relay/DESIGN.md` §3）。Release 构建（包括此版本的）没有这个标签页，正式中继也关闭了它。`relay/scripts/o11y-setup.sh` 用于创建只读服务账号和部署的变量，`o11y-preview.mjs` 无需中继即可构建这些页面，`o11y-demo.mjs` 用于生成手机的演示页面。
- `observability/agento11y/stack.py duplicates [--label]` 按响应 ID 匹配 Claude Platform 对 crok 调用的副本，并逐一加上标记；`gcx_api` 现在会向 gcx 请求纯 JSON，所以 `backfill` 不再跳过长会话。

### 签名

2.0.3 与 2.0.2、2.0.1、2.0.0、1.5.2 和 1.5.3 由同一张“Crok Code Signing”证书签名。macOS 把隐私权限与签名绑定，因此你为 2.0.2 允许的权限（屏幕录制、辅助功能、麦克风、语音识别）会延续到 2.0.3。此构建未经公证，所以新安装时需要做一次上面的**仍要打开**步骤。

Android 应用使用 2.0.0 引入的发布密钥签名。iOS 应用没有签名，原因见**手机应用**一节。已签名的校验和清单是另一回事：它让更新程序能够校验下载的文件，并不改变 macOS 对待该应用的方式。

### 从 2.0.2 升级

使用 **Crok Desktop › 检查更新…**，或在退出 Crok Desktop 后于终端中运行 `crok upgrade`。这次更新是就地安装到已安装的 `Crok Desktop.app` 中，因此它在程序坞和访达中的位置保持不变，废纸篓里也不会留下旧副本。更新会选用与已安装应用构建时所用 SDK 相同的映像（macOS26-SDK 或 macOS15-SDK），绝不会选用另一个。

模型提供商的登录状态、设置、任务和远程控制的登录状态都会保留：2.0.3 与 2.0.2 连接的是同一个正式中继。请更新你通过中继使用的每台电脑，让它的会话在各处都保持最新。手机应用无需更新，如上文**手机应用**一节所述。

### 详细信息

- 内置 crok `{{CROK_VERSION}}`。
- 由 GitHub Actions 基于标签 `desktop-v2.0.3`（`main` 上的 `{{COMMIT}}`）构建。macOS 26 SDK 映像使用 Xcode {{XCODE26}} 针对 macOS {{SDK26}} SDK 构建，macOS 15 SDK 映像使用 Xcode {{XCODE15}} 针对 macOS {{SDK15}} SDK 构建，单独的 `crok` 则针对 macOS {{TUI_SDK}} SDK 构建。
- 两个映像均为 arm64，由 Crok Code Signing 证书签名且未经公证，均可在 macOS 14 Sonoma 或更高版本上运行。
- iOS 应用（`dev.chenli.crok.mobile`）是用 Xcode {{XCODE26}} 构建的 Release 版本；Android 应用是适用于 Android 8.0 或更高版本的 release 版本。
- SHA-256 校验和位于本说明末尾，也在 `SHA256SUMS.txt` 中，该文件也涵盖手机应用。仓库中的 `release/README.md` 说明了如何手动校验这份清单的签名。
