import Foundation
import Combine

// MARK: - AppLanguage

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto
    case en
    case zhHans = "zh-Hans"
    case ja
    case es
    case fr
    case de

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .auto:   return L10n.t("language_system", "System")
        case .en:     return "English"
        case .zhHans: return "简体中文"
        case .ja:     return "日本語"
        case .es:     return "Español"
        case .fr:     return "Français"
        case .de:     return "Deutsch"
        }
    }

    /// The value written to `[ui].ui_language`; the terminal reads the same spelling.
    var configValue: String { self == .auto ? "auto" : rawValue }

    /// Parses a raw string from config.toml or the picker.
    /// nil / empty / "auto" → .auto; zh variants → .zhHans; otherwise matches rawValue.
    static func parse(_ raw: String?) -> AppLanguage {
        guard let raw, !raw.isEmpty, raw != "auto" else { return .auto }
        let lower = raw.lowercased()
        if lower == "zh" || lower.hasPrefix("zh-") || lower.hasPrefix("zh_") { return .zhHans }
        return AppLanguage(rawValue: raw) ?? .auto
    }
}

// MARK: - L10nState

/// The active language as something SwiftUI can observe. A view that shows `L10n.t` text adds
/// `@ObservedObject private var language = L10n.state` so it redraws when the language changes,
/// whether from Settings here or from the terminal through `config.toml`.
final class L10nState: ObservableObject {
    @Published fileprivate(set) var language: AppLanguage = .auto
    fileprivate init() {}
}

// MARK: - L10n

enum L10n {
    /// Observed by views; published on the main thread whenever the language changes.
    static let state = L10nState()

    /// Non-nil when the user has chosen a specific language (not .auto).
    private static var overrideCode: String? {
        get { overrideLock.lock(); defer { overrideLock.unlock() }; return storedOverride }
        set { overrideLock.lock(); storedOverride = newValue; overrideLock.unlock() }
    }
    /// The Chrome import words what it could not read on the thread that reads it, so the choice is
    /// read off the main thread too.
    private static let overrideLock = NSLock()
    private static var storedOverride: String?

    /// The chosen language (`.auto` follows this Mac).
    static var language: AppLanguage { state.language }

    /// Reads `[ui].ui_language` from a GrokConfig and primes the override.
    static func configure(fromConfig config: GrokConfig) {
        let lang = AppLanguage.parse(config.string("ui_language", in: "ui"))
        setLanguage(lang)
    }

    /// Sets the active override. `.auto` clears it so system detection takes over.
    /// Publishes to `state` (on the main thread) only when the choice actually changed.
    static func setLanguage(_ language: AppLanguage) {
        overrideCode = language == .auto ? nil : language.rawValue
        guard state.language != language else { return }
        if Thread.isMainThread {
            state.language = language
        } else {
            DispatchQueue.main.async { if state.language != language { state.language = language } }
        }
    }

    /// The BCP-47 code that will be used for lookups.
    static var resolvedCode: String {
        if let code = overrideCode { return code }
        // Map the system locale to a supported code, defaulting to English.
        let tag = Locale.preferredLanguages.first ?? Locale.current.identifier
        return mapLocale(tag)
    }

    private static func mapLocale(_ tag: String) -> String {
        let lower = tag.lowercased()
        if lower == "zh" || lower.hasPrefix("zh-") || lower.hasPrefix("zh_") { return "zh-Hans" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("es") { return "es" }
        if lower.hasPrefix("fr") { return "fr" }
        if lower.hasPrefix("de") { return "de" }
        return "en"
    }

    /// Returns the localised string for `key`, falling back to the English table, then to `en`.
    static func t(_ key: String, _ en: String) -> String {
        let code = resolvedCode
        if let value = tables[code]?[key] { return value }
        if let value = tables["en"]?[key] { return value }
        return en
    }

    /// `t` for a string with one `%d`, such as "Show %d more".
    static func t(_ key: String, _ en: String, count: Int) -> String {
        String(format: t(key, en), locale: nil, count)
    }

    /// `t` for a string with named `{placeholders}`, such as "Sign in to {name}". Each language puts
    /// them where its word order needs them.
    static func t(_ key: String, _ en: String, _ values: [String: String]) -> String {
        fill(t(key, en), values)
    }

    /// Replaces each `{name}` in `template` in one pass, so a value that itself contains braces is left alone.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        guard template.contains("{") else { return template }
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            rest = rest[open...]
            guard let close = rest.firstIndex(of: "}") else { break }
            let name = String(rest[rest.index(after: open)..<close])
            result += values[name] ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// The text around one `{name}` placeholder, for a view that puts a control (a link, a styled word) in its place.
    static func split(_ template: String, around name: String) -> (before: String, after: String) {
        guard let range = template.range(of: "{\(name)}") else { return (template, "") }
        return (String(template[..<range.lowerBound]), String(template[range.upperBound...]))
    }

    /// The keys one language's table holds. Tests compare the languages with it.
    static func keys(for code: String) -> Set<String> { Set(tables[code]?.keys.map { $0 } ?? []) }

    /// One language's own text for `key`, with no fallback to English.
    static func text(_ key: String, in code: String) -> String? { tables[code]?[key] }

    static let languageCodes = ["en", "zh-Hans", "ja", "es", "fr", "de"]

    /// The thinking level's name for a harness id (`low`, `high`, `xhigh`, …); the harness's own
    /// English name when the id is not a standard level.
    static func reasoningName(id: String, fallback: String) -> String {
        guard let en = reasoningNames[id] else { return fallback }
        return t("effort_\(id)", en)
    }

    /// "on" or "off", as a confirmation says what a switch is now.
    static func onOff(_ on: Bool) -> String { on ? L10n.t("state_on", "on") : L10n.t("state_off", "off") }

    /// A language's name in the interface language, as this Mac names it ("西班牙语", "Espagnol"); `fallback` is its English name.
    static func languageName(code: String, fallback: String) -> String {
        let interface = resolvedCode
        guard interface != "en", let name = Locale(identifier: interface).localizedString(forLanguageCode: code), !name.isEmpty else { return fallback }
        // Spanish and French write language names in lower case inside a sentence; a list entry starts with a capital.
        return name.prefix(1).capitalized + name.dropFirst()
    }

    private static let reasoningNames = [
        "none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium",
        "high": "High", "xhigh": "Extra high", "max": "Max",
    ]

    // MARK: - Translation tables

    /// Each language's strings: the tables below, with the ones for Settings and the side panel
    /// (`L10nPanelTables.swift`) added to them.
    private static let tables: [String: [String: String]] = [
        "en": english.merging(englishPanels) { own, _ in own },
        "zh-Hans": chineseSimplified.merging(chineseSimplifiedPanels) { own, _ in own },
        "ja": japanese.merging(japanesePanels) { own, _ in own },
        "es": spanish.merging(spanishPanels) { own, _ in own },
        "fr": french.merging(frenchPanels) { own, _ in own },
        "de": german.merging(germanPanels) { own, _ in own },
    ]

    // MARK: English

    private static let english: [String: String] = [
        "settings": "Settings",
        "done": "Done",
        "cancel": "Cancel",
        "save": "Save",
        "accounts": "Accounts",
        "behavior": "Behavior",
        "appearance": "Appearance",
        "theme": "Theme",
        "transparency": "Transparency",
        "permissions": "Permissions",
        "multiline_input": "Multiline input",
        "dictation_language": "Dictation language",
        "dictation_shortcut": "Dictation shortcut",
        "dictation_model": "Dictation model",
        "while_working": "While Crok is working",
        "connected": "Connected",
        "open_a_project": "Open a project",
        "your_workspace": "Your workspace",
        "new_task": "New Task",
        "open_project": "Open Project…",
        "search_tasks": "Search Tasks",
        "commands": "Commands…",
        "close": "Close",
        "plan_mode": "Plan Mode",
        "stop": "Stop",
        "side_panel": "Side Panel",
        "files": "Files",
        "terminal": "Terminal",
        "browser": "Browser",
        "tutorial": "Tutorial",
        "keyboard_shortcuts": "Keyboard Shortcuts",
        "settings_ellipsis": "Settings…",
        "check_for_updates": "Check for Updates…",
        "software_update": "Software Update",
        "update_checking": "Checking for updates…",
        "update_up_to_date": "Crok Desktop {version} is the latest version.",
        "update_available": "Crok Desktop {latest} is available. You have {current}.",
        "update_detail": "The new app and its crok command download from GitHub, are checked against the release signature, and replace this copy. Crok Desktop quits and opens again.",
        "install_and_relaunch": "Install and Relaunch",
        "update_downloading": "Downloading…",
        "update_quit_to_install": "The update is ready. Crok Desktop installs it when it quits.",
        "update_quit_detail": "Quit when your tasks are done; the new version opens by itself.",
        "quit_and_install": "Quit and Install",
        "release_notes": "Release Notes",
        "check_again": "Check Again",
        "update_unavailable_dev": "Updates come with the installed Crok Desktop app.",
        "update_failed_title": "The update did not finish.",
        "last_checked": "Last checked {time}",
        "interface_language": "Interface language",
        "interface_language_detail": "Shared with the Crok terminal. System follows this Mac's language.",
        "good_morning": "Good morning",
        "good_afternoon": "Good afternoon",
        "good_evening": "Good evening",
        "most_settings_shared": "Most settings are shared with the Crok CLI. Tasks stay on this Mac.",
        "automatic": "Automatic",
        "multiline_on_detail": "Return inserts a new line; ⌘Return sends.",
        "multiline_off_detail": "Return sends; ⇧Return inserts a new line.",
        "dictation_language_detail": "Automatic follows your Mac's language.",
        // Sidebar
        "new_task_row": "New task",
        "search": "Search",
        "commands_row": "Commands",
        "skills_tools": "Skills & tools",
        "projects": "Projects",
        "pinned": "Pinned",
        "recents": "Recents",
        "archived": "Archived",
        "back_to_projects": "Back to projects",
        "search_all_tasks": "Search all tasks",
        "search_archived_tasks": "Search archived tasks",
        "no_tasks_yet": "No tasks yet",
        "tasks_appear_here": "Your tasks will appear here.",
        "archived_appear_here": "Archived tasks will appear here.",
        "results": "Results",
        "archived_results": "Archived results",
        "no_matching_tasks": "No matching tasks.",
        "show_less": "Show less",
        "show_n_more": "Show %d more",
        "open_first_project": "Open your first project",
        "engine_unavailable": "Crok engine unavailable",
        "time_now": "now",
        "time_minutes": "%dm",
        "time_hours": "%dh",
        "time_days": "%dd",
        "time_weeks": "%dw",
        "time_months": "%dmo",
        "time_years": "%dy",
        // Welcome
        "good_night": "Good night",
        "starter_explore": "Explore the codebase",
        "starter_build": "Build something",
        "starter_review": "Review changes",
        "open_another_folder": "Open Another Folder…",
        // Composer
        "placeholder_new": "Ask Crok to build, fix, or explore anything…",
        "placeholder_continue": "Continue the conversation…",
        "placeholder_steer": "Steer Crok while it works…",
        "placeholder_queue": "Queue a follow-up…",
        "thinking": "Thinking",
        "thinking_level": "Thinking level",
        "model": "Model",
        "choose_model": "Choose model",
        "conversation_settings": "Conversation settings",
        "tools_commands": "Tools & commands",
        "add_photos_files": "Add photos & files",
        "add_folder": "Add folder",
        "plan_mode_row": "Plan mode",
        "goal": "Goal",
        "no_repository": "No repository",
        "effort_none": "None",
        "effort_minimal": "Minimal",
        "effort_low": "Low",
        "effort_medium": "Medium",
        "effort_high": "High",
        "effort_xhigh": "Extra high",
        "effort_max": "Max",
        "effort_default": "Default",
        "effort_not_supported": "Not supported",
        // Permission and follow-up modes
        "mode_default": "Default",
        "mode_ask": "Ask",
        "mode_auto": "Auto",
        "mode_always_approve": "Always approve",
        "mode_default_detail": "Use the agent's default (currently Ask).",
        "mode_ask_detail": "Ask before tool actions.",
        "mode_auto_detail": "A classifier approves safe tools; risky actions still ask.",
        "mode_always_approve_detail": "Every tool action runs without asking.",
        "toast_always_approve_on": "⚠ Always-approve ON: all tool actions auto-run",
        "toast_always_approve_plan": "⚠ Always-approve ON: plan mode still blocks file edits until you exit plan mode",
        "toast_mode_auto": "✓ Permission mode: Auto (classifier)",
        "toast_mode_ask": "✓ Permission mode: Ask",
        "toast_mode_default": "✓ Permission mode: Default",
        "followup_queue": "Queue",
        "followup_steer": "Steer",
        "followup_queue_detail": "Send it after Crok finishes.",
        "followup_steer_detail": "Add it to the running turn.",
    ]

    // MARK: Chinese Simplified

    private static let chineseSimplified: [String: String] = [
        "settings": "设置",
        "done": "完成",
        "cancel": "取消",
        "save": "保存",
        "accounts": "账号",
        "behavior": "行为",
        "appearance": "外观",
        "theme": "主题",
        "transparency": "透明度",
        "permissions": "权限",
        "multiline_input": "多行输入",
        "dictation_language": "听写语言",
        "dictation_shortcut": "听写快捷键",
        "dictation_model": "听写模型",
        "while_working": "Crok 工作时",
        "connected": "已连接",
        "open_a_project": "打开项目",
        "your_workspace": "您的工作区",
        "new_task": "新建任务",
        "open_project": "打开项目…",
        "search_tasks": "搜索任务",
        "commands": "命令…",
        "close": "关闭",
        "plan_mode": "计划模式",
        "stop": "停止",
        "side_panel": "侧边栏",
        "files": "文件",
        "terminal": "终端",
        "browser": "浏览器",
        "tutorial": "教程",
        "keyboard_shortcuts": "键盘快捷键",
        "settings_ellipsis": "设置…",
        "check_for_updates": "检查更新…",
        "software_update": "软件更新",
        "update_checking": "正在检查更新…",
        "update_up_to_date": "Crok Desktop {version} 已是最新版本。",
        "update_available": "Crok Desktop {latest} 已发布。当前版本为 {current}。",
        "update_detail": "新版应用及其 crok 命令将从 GitHub 下载，经发布签名校验后替换当前副本。Crok Desktop 会退出并重新打开。",
        "install_and_relaunch": "安装并重新启动",
        "update_downloading": "正在下载…",
        "update_quit_to_install": "更新已就绪。Crok Desktop 退出时将完成安装。",
        "update_quit_detail": "任务完成后退出即可；新版本会自动打开。",
        "quit_and_install": "退出并安装",
        "release_notes": "发行说明",
        "check_again": "重新检查",
        "update_unavailable_dev": "更新随已安装的 Crok Desktop 应用提供。",
        "update_failed_title": "更新未完成。",
        "last_checked": "上次检查：{time}",
        "interface_language": "界面语言",
        "interface_language_detail": "与 Crok 终端共享。系统选项遵循本 Mac 的语言设置。",
        "good_morning": "早上好",
        "good_afternoon": "下午好",
        "good_evening": "晚上好",
        "most_settings_shared": "大多数设置与 Crok CLI 共享。任务保留在此 Mac 上。",
        "automatic": "自动",
        "multiline_on_detail": "回车键插入新行；⌘回车键发送。",
        "multiline_off_detail": "回车键发送；⇧回车键插入新行。",
        "dictation_language_detail": "自动选项遵循您 Mac 的语言设置。",
        // Sidebar
        "new_task_row": "新建任务",
        "search": "搜索",
        "commands_row": "命令",
        "skills_tools": "技能与工具",
        "projects": "项目",
        "pinned": "已置顶",
        "recents": "最近",
        "archived": "已归档",
        "back_to_projects": "返回项目",
        "search_all_tasks": "搜索所有任务",
        "search_archived_tasks": "搜索已归档任务",
        "no_tasks_yet": "暂无任务",
        "tasks_appear_here": "你的任务会显示在这里。",
        "archived_appear_here": "已归档的任务会显示在这里。",
        "results": "结果",
        "archived_results": "已归档结果",
        "no_matching_tasks": "没有匹配的任务。",
        "show_less": "收起",
        "show_n_more": "再显示 %d 个",
        "open_first_project": "打开你的第一个项目",
        "engine_unavailable": "Crok 引擎不可用",
        "time_now": "刚刚",
        "time_minutes": "%d分钟",
        "time_hours": "%d小时",
        "time_days": "%d天",
        "time_weeks": "%d周",
        "time_months": "%d个月",
        "time_years": "%d年",
        // Welcome
        "good_night": "晚安",
        "starter_explore": "探索代码库",
        "starter_build": "动手构建",
        "starter_review": "审查更改",
        "open_another_folder": "打开其他文件夹…",
        // Composer
        "placeholder_new": "让 Crok 构建、修复或探索任何内容…",
        "placeholder_continue": "继续对话…",
        "placeholder_steer": "在 Crok 工作时引导它…",
        "placeholder_queue": "排队一条后续消息…",
        "thinking": "思考",
        "thinking_level": "思考级别",
        "model": "模型",
        "choose_model": "选择模型",
        "conversation_settings": "对话设置",
        "tools_commands": "工具与命令",
        "add_photos_files": "添加照片和文件",
        "add_folder": "添加文件夹",
        "plan_mode_row": "计划模式",
        "goal": "目标",
        "no_repository": "无仓库",
        "effort_none": "无",
        "effort_minimal": "最少",
        "effort_low": "低",
        "effort_medium": "中",
        "effort_high": "高",
        "effort_xhigh": "超高",
        "effort_max": "最高",
        "effort_default": "默认",
        "effort_not_supported": "不支持",
        // Permission and follow-up modes
        "mode_default": "默认",
        "mode_ask": "询问",
        "mode_auto": "自动",
        "mode_always_approve": "始终批准",
        "mode_default_detail": "使用代理的默认设置（当前为“询问”）。",
        "mode_ask_detail": "执行工具操作前先询问。",
        "mode_auto_detail": "分类器自动批准安全的工具操作；高风险操作仍会询问。",
        "mode_always_approve_detail": "所有工具操作无需询问即可运行。",
        "toast_always_approve_on": "⚠ 始终批准已开启：所有工具操作将自动运行",
        "toast_always_approve_plan": "⚠ 始终批准已开启：退出计划模式前仍会阻止文件编辑",
        "toast_mode_auto": "✓ 权限模式：自动（分类器）",
        "toast_mode_ask": "✓ 权限模式：询问",
        "toast_mode_default": "✓ 权限模式：默认",
        "followup_queue": "排队",
        "followup_steer": "引导",
        "followup_queue_detail": "Crok 完成后再发送。",
        "followup_steer_detail": "加入正在进行的回合。",
    ]

    // MARK: Japanese

    private static let japanese: [String: String] = [
        "settings": "設定",
        "done": "完了",
        "cancel": "キャンセル",
        "save": "保存",
        "accounts": "アカウント",
        "behavior": "動作",
        "appearance": "外観",
        "theme": "テーマ",
        "transparency": "透明度",
        "permissions": "権限",
        "multiline_input": "複数行入力",
        "dictation_language": "ディクテーション言語",
        "dictation_shortcut": "ディクテーションショートカット",
        "dictation_model": "ディクテーションモデル",
        "while_working": "Crokの作業中",
        "connected": "接続済み",
        "open_a_project": "プロジェクトを開く",
        "your_workspace": "ワークスペース",
        "new_task": "新規タスク",
        "open_project": "プロジェクトを開く…",
        "search_tasks": "タスクを検索",
        "commands": "コマンド…",
        "close": "閉じる",
        "plan_mode": "プランモード",
        "stop": "停止",
        "side_panel": "サイドパネル",
        "files": "ファイル",
        "terminal": "ターミナル",
        "browser": "ブラウザ",
        "tutorial": "チュートリアル",
        "keyboard_shortcuts": "キーボードショートカット",
        "settings_ellipsis": "設定…",
        "check_for_updates": "アップデートを確認…",
        "software_update": "ソフトウェア・アップデート",
        "update_checking": "アップデートを確認しています…",
        "update_up_to_date": "Crok Desktop {version} は最新バージョンです。",
        "update_available": "Crok Desktop {latest} が利用できます。現在のバージョンは {current} です。",
        "update_detail": "新しいアプリとその crok コマンドを GitHub からダウンロードし、リリース署名を検証してからこのコピーを置き換えます。Crok Desktop は終了して再び開きます。",
        "install_and_relaunch": "インストールして再起動",
        "update_downloading": "ダウンロードしています…",
        "update_quit_to_install": "アップデートの準備ができました。Crok Desktop は終了時にインストールします。",
        "update_quit_detail": "タスクが終わったら終了してください。新しいバージョンが自動的に開きます。",
        "quit_and_install": "終了してインストール",
        "release_notes": "リリースノート",
        "check_again": "再確認",
        "update_unavailable_dev": "アップデートはインストール済みの Crok Desktop アプリで利用できます。",
        "update_failed_title": "アップデートを完了できませんでした。",
        "last_checked": "最終確認: {time}",
        "interface_language": "インターフェース言語",
        "interface_language_detail": "Crokターミナルと共有されます。システムはこのMacの言語に従います。",
        "good_morning": "おはようございます",
        "good_afternoon": "こんにちは",
        "good_evening": "こんばんは",
        "most_settings_shared": "ほとんどの設定はCrok CLIと共有されます。タスクはこのMacに保存されます。",
        "automatic": "自動",
        "multiline_on_detail": "Returnで改行、⌘Returnで送信します。",
        "multiline_off_detail": "Returnで送信、⇧Returnで改行します。",
        "dictation_language_detail": "自動はMacの言語設定に従います。",
        // Sidebar
        "new_task_row": "新規タスク",
        "search": "検索",
        "commands_row": "コマンド",
        "skills_tools": "スキルとツール",
        "projects": "プロジェクト",
        "pinned": "ピン留め",
        "recents": "最近",
        "archived": "アーカイブ済み",
        "back_to_projects": "プロジェクトに戻る",
        "search_all_tasks": "すべてのタスクを検索",
        "search_archived_tasks": "アーカイブ済みタスクを検索",
        "no_tasks_yet": "タスクはまだありません",
        "tasks_appear_here": "タスクはここに表示されます。",
        "archived_appear_here": "アーカイブ済みのタスクはここに表示されます。",
        "results": "結果",
        "archived_results": "アーカイブ済みの結果",
        "no_matching_tasks": "一致するタスクはありません。",
        "show_less": "少なく表示",
        "show_n_more": "さらに%d件表示",
        "open_first_project": "最初のプロジェクトを開く",
        "engine_unavailable": "Crokエンジンを利用できません",
        "time_now": "今",
        "time_minutes": "%d分",
        "time_hours": "%d時間",
        "time_days": "%d日",
        "time_weeks": "%d週",
        "time_months": "%dか月",
        "time_years": "%d年",
        // Welcome
        "good_night": "おやすみなさい",
        "starter_explore": "コードベースを探索",
        "starter_build": "何かを作る",
        "starter_review": "変更をレビュー",
        "open_another_folder": "別のフォルダを開く…",
        // Composer
        "placeholder_new": "Crokに構築・修正・探索を頼む…",
        "placeholder_continue": "会話を続ける…",
        "placeholder_steer": "作業中のCrokを誘導…",
        "placeholder_queue": "フォローアップをキューに追加…",
        "thinking": "思考",
        "thinking_level": "思考レベル",
        "model": "モデル",
        "choose_model": "モデルを選択",
        "conversation_settings": "会話設定",
        "tools_commands": "ツールとコマンド",
        "add_photos_files": "写真とファイルを追加",
        "add_folder": "フォルダを追加",
        "plan_mode_row": "プランモード",
        "goal": "ゴール",
        "no_repository": "リポジトリなし",
        "effort_none": "なし",
        "effort_minimal": "最小",
        "effort_low": "低",
        "effort_medium": "中",
        "effort_high": "高",
        "effort_xhigh": "超高",
        "effort_max": "最大",
        "effort_default": "既定",
        "effort_not_supported": "非対応",
        // Permission and follow-up modes
        "mode_default": "既定",
        "mode_ask": "確認",
        "mode_auto": "自動",
        "mode_always_approve": "常に承認",
        "mode_default_detail": "エージェントの既定（現在は「確認」）を使います。",
        "mode_ask_detail": "ツール操作の前に確認します。",
        "mode_auto_detail": "分類器が安全なツールを自動承認し、リスクのある操作は確認します。",
        "mode_always_approve_detail": "すべてのツール操作を確認なしで実行します。",
        "toast_always_approve_on": "⚠ 常に承認 ON：すべてのツール操作が自動実行されます",
        "toast_always_approve_plan": "⚠ 常に承認 ON：プランモードを終了するまでファイル編集はブロックされます",
        "toast_mode_auto": "✓ 権限モード：自動（分類器）",
        "toast_mode_ask": "✓ 権限モード：確認",
        "toast_mode_default": "✓ 権限モード：既定",
        "followup_queue": "キュー",
        "followup_steer": "誘導",
        "followup_queue_detail": "Crokの完了後に送信します。",
        "followup_steer_detail": "実行中のターンに追加します。",
    ]

    // MARK: Spanish

    private static let spanish: [String: String] = [
        "settings": "Ajustes",
        "done": "Listo",
        "cancel": "Cancelar",
        "save": "Guardar",
        "accounts": "Cuentas",
        "behavior": "Comportamiento",
        "appearance": "Apariencia",
        "theme": "Tema",
        "transparency": "Transparencia",
        "permissions": "Permisos",
        "multiline_input": "Entrada multilínea",
        "dictation_language": "Idioma de dictado",
        "dictation_shortcut": "Atajo de dictado",
        "dictation_model": "Modelo de dictado",
        "while_working": "Mientras Crok trabaja",
        "connected": "Conectado",
        "open_a_project": "Abrir un proyecto",
        "your_workspace": "Tu espacio de trabajo",
        "new_task": "Nueva tarea",
        "open_project": "Abrir proyecto…",
        "search_tasks": "Buscar tareas",
        "commands": "Comandos…",
        "close": "Cerrar",
        "plan_mode": "Modo plan",
        "stop": "Detener",
        "side_panel": "Panel lateral",
        "files": "Archivos",
        "terminal": "Terminal",
        "browser": "Navegador",
        "tutorial": "Tutorial",
        "keyboard_shortcuts": "Atajos de teclado",
        "settings_ellipsis": "Ajustes…",
        "check_for_updates": "Buscar actualizaciones…",
        "software_update": "Actualización de software",
        "update_checking": "Buscando actualizaciones…",
        "update_up_to_date": "Crok Desktop {version} es la versión más reciente.",
        "update_available": "Crok Desktop {latest} está disponible. Tienes la {current}.",
        "update_detail": "La nueva app y su comando crok se descargan de GitHub, se comprueban con la firma de la versión y sustituyen esta copia. Crok Desktop se cierra y vuelve a abrirse.",
        "install_and_relaunch": "Instalar y reabrir",
        "update_downloading": "Descargando…",
        "update_quit_to_install": "La actualización está lista. Crok Desktop la instala al cerrarse.",
        "update_quit_detail": "Cierra la app cuando terminen tus tareas; la nueva versión se abre sola.",
        "quit_and_install": "Salir e instalar",
        "release_notes": "Notas de la versión",
        "check_again": "Buscar de nuevo",
        "update_unavailable_dev": "Las actualizaciones llegan con la app Crok Desktop instalada.",
        "update_failed_title": "La actualización no terminó.",
        "last_checked": "Última comprobación: {time}",
        "interface_language": "Idioma de interfaz",
        "interface_language_detail": "Compartido con el terminal de Crok. Sistema sigue el idioma de este Mac.",
        "good_morning": "Buenos días",
        "good_afternoon": "Buenas tardes",
        "good_evening": "Buenas noches",
        "most_settings_shared": "La mayoría de los ajustes se comparten con Crok CLI. Las tareas permanecen en este Mac.",
        "automatic": "Automático",
        "multiline_on_detail": "Intro inserta una nueva línea; ⌘Intro envía.",
        "multiline_off_detail": "Intro envía; ⇧Intro inserta una nueva línea.",
        "dictation_language_detail": "Automático sigue el idioma de tu Mac.",
        // Sidebar
        "new_task_row": "Nueva tarea",
        "search": "Buscar",
        "commands_row": "Comandos",
        "skills_tools": "Habilidades y herramientas",
        "projects": "Proyectos",
        "pinned": "Fijadas",
        "recents": "Recientes",
        "archived": "Archivadas",
        "back_to_projects": "Volver a proyectos",
        "search_all_tasks": "Buscar en todas las tareas",
        "search_archived_tasks": "Buscar tareas archivadas",
        "no_tasks_yet": "Aún no hay tareas",
        "tasks_appear_here": "Tus tareas aparecerán aquí.",
        "archived_appear_here": "Las tareas archivadas aparecerán aquí.",
        "results": "Resultados",
        "archived_results": "Resultados archivados",
        "no_matching_tasks": "No hay tareas que coincidan.",
        "show_less": "Mostrar menos",
        "show_n_more": "Mostrar %d más",
        "open_first_project": "Abre tu primer proyecto",
        "engine_unavailable": "Motor de Crok no disponible",
        "time_now": "ahora",
        "time_minutes": "%d min",
        "time_hours": "%d h",
        "time_days": "%d d",
        "time_weeks": "%d sem",
        "time_months": "%d mes",
        "time_years": "%d a",
        // Welcome
        "good_night": "Buenas noches",
        "starter_explore": "Explorar el código",
        "starter_build": "Construir algo",
        "starter_review": "Revisar cambios",
        "open_another_folder": "Abrir otra carpeta…",
        // Composer
        "placeholder_new": "Pide a Crok que construya, corrija o explore lo que sea…",
        "placeholder_continue": "Continúa la conversación…",
        "placeholder_steer": "Dirige a Crok mientras trabaja…",
        "placeholder_queue": "Encola un seguimiento…",
        "thinking": "Razonamiento",
        "thinking_level": "Nivel de razonamiento",
        "model": "Modelo",
        "choose_model": "Elegir modelo",
        "conversation_settings": "Ajustes de la conversación",
        "tools_commands": "Herramientas y comandos",
        "add_photos_files": "Añadir fotos y archivos",
        "add_folder": "Añadir carpeta",
        "plan_mode_row": "Modo plan",
        "goal": "Objetivo",
        "no_repository": "Sin repositorio",
        "effort_none": "Ninguno",
        "effort_minimal": "Mínimo",
        "effort_low": "Bajo",
        "effort_medium": "Medio",
        "effort_high": "Alto",
        "effort_xhigh": "Muy alto",
        "effort_max": "Máximo",
        "effort_default": "Predeterminado",
        "effort_not_supported": "No compatible",
        // Permission and follow-up modes
        "mode_default": "Predeterminado",
        "mode_ask": "Preguntar",
        "mode_auto": "Auto",
        "mode_always_approve": "Aprobar siempre",
        "mode_default_detail": "Usa el valor predeterminado del agente (actualmente Preguntar).",
        "mode_ask_detail": "Pregunta antes de cada acción de herramienta.",
        "mode_auto_detail": "Un clasificador aprueba las herramientas seguras; las acciones arriesgadas siguen preguntando.",
        "mode_always_approve_detail": "Toda acción de herramienta se ejecuta sin preguntar.",
        "toast_always_approve_on": "⚠ Aprobar siempre ACTIVADO: todas las acciones de herramientas se ejecutan solas",
        "toast_always_approve_plan": "⚠ Aprobar siempre ACTIVADO: el modo plan sigue bloqueando las ediciones de archivos hasta que salgas",
        "toast_mode_auto": "✓ Modo de permisos: Auto (clasificador)",
        "toast_mode_ask": "✓ Modo de permisos: Preguntar",
        "toast_mode_default": "✓ Modo de permisos: Predeterminado",
        "followup_queue": "Encolar",
        "followup_steer": "Dirigir",
        "followup_queue_detail": "Se envía cuando Crok termine.",
        "followup_steer_detail": "Se añade al turno en curso.",
    ]

    // MARK: French

    private static let french: [String: String] = [
        "settings": "Réglages",
        "done": "Terminé",
        "cancel": "Annuler",
        "save": "Enregistrer",
        "accounts": "Comptes",
        "behavior": "Comportement",
        "appearance": "Apparence",
        "theme": "Thème",
        "transparency": "Transparence",
        "permissions": "Permissions",
        "multiline_input": "Saisie multiligne",
        "dictation_language": "Langue de dictée",
        "dictation_shortcut": "Raccourci de dictée",
        "dictation_model": "Modèle de dictée",
        "while_working": "Pendant que Crok travaille",
        "connected": "Connecté",
        "open_a_project": "Ouvrir un projet",
        "your_workspace": "Votre espace de travail",
        "new_task": "Nouvelle tâche",
        "open_project": "Ouvrir un projet…",
        "search_tasks": "Rechercher des tâches",
        "commands": "Commandes…",
        "close": "Fermer",
        "plan_mode": "Mode plan",
        "stop": "Arrêter",
        "side_panel": "Panneau latéral",
        "files": "Fichiers",
        "terminal": "Terminal",
        "browser": "Navigateur",
        "tutorial": "Tutoriel",
        "keyboard_shortcuts": "Raccourcis clavier",
        "settings_ellipsis": "Réglages…",
        "check_for_updates": "Rechercher des mises à jour…",
        "software_update": "Mise à jour logicielle",
        "update_checking": "Recherche de mises à jour…",
        "update_up_to_date": "Crok Desktop {version} est la version la plus récente.",
        "update_available": "Crok Desktop {latest} est disponible. Vous avez la {current}.",
        "update_detail": "La nouvelle app et sa commande crok sont téléchargées depuis GitHub, vérifiées avec la signature de la version, puis remplacent cette copie. Crok Desktop quitte et se rouvre.",
        "install_and_relaunch": "Installer et relancer",
        "update_downloading": "Téléchargement…",
        "update_quit_to_install": "La mise à jour est prête. Crok Desktop l'installe en quittant.",
        "update_quit_detail": "Quittez quand vos tâches sont terminées ; la nouvelle version s'ouvre d'elle-même.",
        "quit_and_install": "Quitter et installer",
        "release_notes": "Notes de version",
        "check_again": "Vérifier à nouveau",
        "update_unavailable_dev": "Les mises à jour arrivent avec l'app Crok Desktop installée.",
        "update_failed_title": "La mise à jour n'a pas abouti.",
        "last_checked": "Dernière vérification : {time}",
        "interface_language": "Langue de l'interface",
        "interface_language_detail": "Partagé avec le terminal Crok. Système suit la langue de ce Mac.",
        "good_morning": "Bonjour",
        "good_afternoon": "Bon après-midi",
        "good_evening": "Bonsoir",
        "most_settings_shared": "La plupart des réglages sont partagés avec Crok CLI. Les tâches restent sur ce Mac.",
        "automatic": "Automatique",
        "multiline_on_detail": "Entrée insère une nouvelle ligne ; ⌘Entrée envoie.",
        "multiline_off_detail": "Entrée envoie ; ⇧Entrée insère une nouvelle ligne.",
        "dictation_language_detail": "Automatique suit la langue de votre Mac.",
        // Sidebar
        "new_task_row": "Nouvelle tâche",
        "search": "Rechercher",
        "commands_row": "Commandes",
        "skills_tools": "Compétences et outils",
        "projects": "Projets",
        "pinned": "Épinglées",
        "recents": "Récentes",
        "archived": "Archivées",
        "back_to_projects": "Retour aux projets",
        "search_all_tasks": "Rechercher dans toutes les tâches",
        "search_archived_tasks": "Rechercher les tâches archivées",
        "no_tasks_yet": "Pas encore de tâche",
        "tasks_appear_here": "Vos tâches apparaîtront ici.",
        "archived_appear_here": "Les tâches archivées apparaîtront ici.",
        "results": "Résultats",
        "archived_results": "Résultats archivés",
        "no_matching_tasks": "Aucune tâche ne correspond.",
        "show_less": "Afficher moins",
        "show_n_more": "Afficher %d de plus",
        "open_first_project": "Ouvrez votre premier projet",
        "engine_unavailable": "Moteur Crok indisponible",
        "time_now": "maintenant",
        "time_minutes": "%d min",
        "time_hours": "%d h",
        "time_days": "%d j",
        "time_weeks": "%d sem",
        "time_months": "%d mois",
        "time_years": "%d a",
        // Welcome
        "good_night": "Bonne nuit",
        "starter_explore": "Explorer le code",
        "starter_build": "Construire quelque chose",
        "starter_review": "Relire les modifications",
        "open_another_folder": "Ouvrir un autre dossier…",
        // Composer
        "placeholder_new": "Demandez à Crok de construire, corriger ou explorer…",
        "placeholder_continue": "Poursuivez la conversation…",
        "placeholder_steer": "Orientez Crok pendant qu'il travaille…",
        "placeholder_queue": "Mettez un suivi en file…",
        "thinking": "Réflexion",
        "thinking_level": "Niveau de réflexion",
        "model": "Modèle",
        "choose_model": "Choisir un modèle",
        "conversation_settings": "Réglages de la conversation",
        "tools_commands": "Outils et commandes",
        "add_photos_files": "Ajouter des photos et fichiers",
        "add_folder": "Ajouter un dossier",
        "plan_mode_row": "Mode plan",
        "goal": "Objectif",
        "no_repository": "Aucun dépôt",
        "effort_none": "Aucun",
        "effort_minimal": "Minimal",
        "effort_low": "Faible",
        "effort_medium": "Moyen",
        "effort_high": "Élevé",
        "effort_xhigh": "Très élevé",
        "effort_max": "Maximum",
        "effort_default": "Par défaut",
        "effort_not_supported": "Non pris en charge",
        // Permission and follow-up modes
        "mode_default": "Par défaut",
        "mode_ask": "Demander",
        "mode_auto": "Auto",
        "mode_always_approve": "Toujours approuver",
        "mode_default_detail": "Utilise le réglage par défaut de l'agent (actuellement Demander).",
        "mode_ask_detail": "Demande avant chaque action d'outil.",
        "mode_auto_detail": "Un classifieur approuve les outils sûrs ; les actions risquées demandent encore.",
        "mode_always_approve_detail": "Chaque action d'outil s'exécute sans demander.",
        "toast_always_approve_on": "⚠ Toujours approuver ACTIVÉ : toutes les actions d'outils s'exécutent seules",
        "toast_always_approve_plan": "⚠ Toujours approuver ACTIVÉ : le mode plan bloque encore les modifications de fichiers jusqu'à sa sortie",
        "toast_mode_auto": "✓ Mode de permissions : Auto (classifieur)",
        "toast_mode_ask": "✓ Mode de permissions : Demander",
        "toast_mode_default": "✓ Mode de permissions : Par défaut",
        "followup_queue": "File",
        "followup_steer": "Orienter",
        "followup_queue_detail": "Envoyé quand Crok a terminé.",
        "followup_steer_detail": "Ajouté au tour en cours.",
    ]

    // MARK: German

    private static let german: [String: String] = [
        "settings": "Einstellungen",
        "done": "Fertig",
        "cancel": "Abbrechen",
        "save": "Sichern",
        "accounts": "Accounts",
        "behavior": "Verhalten",
        "appearance": "Darstellung",
        "theme": "Design",
        "transparency": "Transparenz",
        "permissions": "Berechtigungen",
        "multiline_input": "Mehrzeilige Eingabe",
        "dictation_language": "Diktiersprache",
        "dictation_shortcut": "Diktat-Kürzel",
        "dictation_model": "Diktiermodell",
        "while_working": "Während Crok arbeitet",
        "connected": "Verbunden",
        "open_a_project": "Projekt öffnen",
        "your_workspace": "Dein Arbeitsbereich",
        "new_task": "Neue Aufgabe",
        "open_project": "Projekt öffnen…",
        "search_tasks": "Aufgaben suchen",
        "commands": "Befehle…",
        "close": "Schließen",
        "plan_mode": "Planungsmodus",
        "stop": "Stopp",
        "side_panel": "Seitenleiste",
        "files": "Dateien",
        "terminal": "Terminal",
        "browser": "Browser",
        "tutorial": "Tutorial",
        "keyboard_shortcuts": "Tastaturkürzel",
        "settings_ellipsis": "Einstellungen…",
        "check_for_updates": "Nach Updates suchen…",
        "software_update": "Softwareupdate",
        "update_checking": "Nach Updates wird gesucht…",
        "update_up_to_date": "Crok Desktop {version} ist die neueste Version.",
        "update_available": "Crok Desktop {latest} ist verfügbar. Sie haben {current}.",
        "update_detail": "Die neue App und ihr crok-Befehl werden von GitHub geladen, gegen die Release-Signatur geprüft und ersetzen diese Kopie. Crok Desktop wird beendet und erneut geöffnet.",
        "install_and_relaunch": "Installieren und neu starten",
        "update_downloading": "Wird heruntergeladen…",
        "update_quit_to_install": "Das Update ist bereit. Crok Desktop installiert es beim Beenden.",
        "update_quit_detail": "Beenden Sie die App, wenn Ihre Aufgaben erledigt sind; die neue Version öffnet sich von selbst.",
        "quit_and_install": "Beenden und installieren",
        "release_notes": "Versionshinweise",
        "check_again": "Erneut suchen",
        "update_unavailable_dev": "Updates kommen mit der installierten Crok Desktop-App.",
        "update_failed_title": "Das Update wurde nicht abgeschlossen.",
        "last_checked": "Zuletzt geprüft: {time}",
        "interface_language": "Oberflächensprache",
        "interface_language_detail": "Gemeinsam mit dem Crok-Terminal. System folgt der Sprache dieses Macs.",
        "good_morning": "Guten Morgen",
        "good_afternoon": "Guten Tag",
        "good_evening": "Guten Abend",
        "most_settings_shared": "Die meisten Einstellungen werden mit Crok CLI geteilt. Aufgaben bleiben auf diesem Mac.",
        "automatic": "Automatisch",
        "multiline_on_detail": "Return fügt eine neue Zeile ein; ⌘Return sendet.",
        "multiline_off_detail": "Return sendet; ⇧Return fügt eine neue Zeile ein.",
        "dictation_language_detail": "Automatisch folgt der Sprache deines Macs.",
        // Sidebar
        "new_task_row": "Neue Aufgabe",
        "search": "Suchen",
        "commands_row": "Befehle",
        "skills_tools": "Fähigkeiten und Werkzeuge",
        "projects": "Projekte",
        "pinned": "Angeheftet",
        "recents": "Zuletzt",
        "archived": "Archiviert",
        "back_to_projects": "Zurück zu den Projekten",
        "search_all_tasks": "Alle Aufgaben durchsuchen",
        "search_archived_tasks": "Archivierte Aufgaben durchsuchen",
        "no_tasks_yet": "Noch keine Aufgaben",
        "tasks_appear_here": "Deine Aufgaben erscheinen hier.",
        "archived_appear_here": "Archivierte Aufgaben erscheinen hier.",
        "results": "Ergebnisse",
        "archived_results": "Archivierte Ergebnisse",
        "no_matching_tasks": "Keine passenden Aufgaben.",
        "show_less": "Weniger anzeigen",
        "show_n_more": "%d weitere anzeigen",
        "open_first_project": "Öffne dein erstes Projekt",
        "engine_unavailable": "Crok-Engine nicht verfügbar",
        "time_now": "jetzt",
        "time_minutes": "%d Min",
        "time_hours": "%d Std",
        "time_days": "%d T",
        "time_weeks": "%d W",
        "time_months": "%d Mon",
        "time_years": "%d J",
        // Welcome
        "good_night": "Gute Nacht",
        "starter_explore": "Codebasis erkunden",
        "starter_build": "Etwas bauen",
        "starter_review": "Änderungen prüfen",
        "open_another_folder": "Anderen Ordner öffnen…",
        // Composer
        "placeholder_new": "Bitte Crok, etwas zu bauen, zu beheben oder zu erkunden…",
        "placeholder_continue": "Unterhaltung fortsetzen…",
        "placeholder_steer": "Crok während der Arbeit steuern…",
        "placeholder_queue": "Nachfrage in die Warteschlange…",
        "thinking": "Denken",
        "thinking_level": "Denkstufe",
        "model": "Modell",
        "choose_model": "Modell wählen",
        "conversation_settings": "Unterhaltungseinstellungen",
        "tools_commands": "Werkzeuge und Befehle",
        "add_photos_files": "Fotos und Dateien hinzufügen",
        "add_folder": "Ordner hinzufügen",
        "plan_mode_row": "Planungsmodus",
        "goal": "Ziel",
        "no_repository": "Kein Repository",
        "effort_none": "Keins",
        "effort_minimal": "Minimal",
        "effort_low": "Niedrig",
        "effort_medium": "Mittel",
        "effort_high": "Hoch",
        "effort_xhigh": "Sehr hoch",
        "effort_max": "Maximal",
        "effort_default": "Standard",
        "effort_not_supported": "Nicht unterstützt",
        // Permission and follow-up modes
        "mode_default": "Standard",
        "mode_ask": "Fragen",
        "mode_auto": "Auto",
        "mode_always_approve": "Immer genehmigen",
        "mode_default_detail": "Verwendet die Vorgabe des Agenten (derzeit Fragen).",
        "mode_ask_detail": "Fragt vor jeder Werkzeugaktion.",
        "mode_auto_detail": "Ein Klassifizierer genehmigt sichere Werkzeuge; riskante Aktionen fragen weiterhin.",
        "mode_always_approve_detail": "Jede Werkzeugaktion läuft ohne Nachfrage.",
        "toast_always_approve_on": "⚠ Immer genehmigen AN: alle Werkzeugaktionen laufen automatisch",
        "toast_always_approve_plan": "⚠ Immer genehmigen AN: der Planungsmodus blockiert Dateiänderungen, bis du ihn verlässt",
        "toast_mode_auto": "✓ Berechtigungsmodus: Auto (Klassifizierer)",
        "toast_mode_ask": "✓ Berechtigungsmodus: Fragen",
        "toast_mode_default": "✓ Berechtigungsmodus: Standard",
        "followup_queue": "Warteschlange",
        "followup_steer": "Steuern",
        "followup_queue_detail": "Wird gesendet, wenn Crok fertig ist.",
        "followup_steer_detail": "Wird dem laufenden Zug hinzugefügt.",
    ]
}
