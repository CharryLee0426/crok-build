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
    ]
}
