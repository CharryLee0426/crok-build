import Foundation

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
        case .auto:   return "System"
        case .en:     return "English"
        case .zhHans: return "简体中文"
        case .ja:     return "日本語"
        case .es:     return "Español"
        case .fr:     return "Français"
        case .de:     return "Deutsch"
        }
    }

    /// Parses a raw string from config.toml or the picker.
    /// nil / empty / "auto" → .auto; zh variants → .zhHans; otherwise matches rawValue.
    static func parse(_ raw: String?) -> AppLanguage {
        guard let raw, !raw.isEmpty, raw != "auto" else { return .auto }
        let lower = raw.lowercased()
        if lower == "zh" || lower.hasPrefix("zh-") || lower.hasPrefix("zh_") { return .zhHans }
        return AppLanguage(rawValue: raw) ?? .auto
    }
}

// MARK: - L10n

enum L10n {
    /// Non-nil when the user has chosen a specific language (not .auto).
    private static var overrideCode: String?

    /// Reads `[ui].ui_language` from a GrokConfig and primes the override.
    static func configure(fromConfig config: GrokConfig) {
        let lang = AppLanguage.parse(config.string("ui_language", in: "ui"))
        setLanguage(lang)
    }

    /// Sets the active override. `.auto` clears it so system detection takes over.
    static func setLanguage(_ language: AppLanguage) {
        overrideCode = language == .auto ? nil : language.rawValue
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

    // MARK: - Translation tables

    private static let tables: [String: [String: String]] = [
        "en": english,
        "zh-Hans": chineseSimplified,
        "ja": japanese,
        "es": spanish,
        "fr": french,
        "de": german,
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
        "new_task": "新任务",
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
    ]
}
