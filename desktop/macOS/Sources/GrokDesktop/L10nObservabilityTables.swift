import Foundation

// The strings for Settings › Agent Observability: the switch that reports each model call to the
// user's Grafana stack, where reports go, and the banner a change shows. Agent Observability is
// Grafana's product name and stays as it is in every language, as the terminal's settings row has it.
extension L10n {
    // MARK: English

    static let englishObservability: [String: String] = [
        "observability_settings_title": "Agent Observability",
        "observability_report": "Report model calls",
        "observability_detail": "Sends each model call (prompt, reply, tool calls, tokens, timing) from Crok Desktop and the terminal to your Grafana Agent Observability stack. Applies right away, to open tasks too.",
        "observability_destination": "Destination",
        "observability_destination_host": "{host}, set in {file}.",
        "observability_destination_disabled": "{host}, but {file} turns sending off (AGENTO11Y_ENABLED=false).",
        "observability_destination_missing": "Not set up: nothing is sent until {file} holds your Grafana stack's endpoint and token. The agento11y setup.sh in the crok repository writes it.",
        "observability_open_log": "Open Log",
        "observability_banner": "✓ Agent Observability: {state}",
        "observability_banner_reporting": "✓ Agent Observability: {state} · reporting to {host}",
        "observability_banner_not_set_up": "✓ Agent Observability: {state} · nothing is sent until {file} is set up",
    ]

    // MARK: Simplified Chinese

    static let chineseSimplifiedObservability: [String: String] = [
        "observability_settings_title": "Agent Observability",
        "observability_report": "上报模型调用",
        "observability_detail": "将 Crok Desktop 和终端中的每次模型调用（提示、回复、工具调用、token、耗时）发送到你的 Grafana Agent Observability 栈。立即生效，已打开的任务也一样。",
        "observability_destination": "目标位置",
        "observability_destination_host": "{host}，在 {file} 中设置。",
        "observability_destination_disabled": "{host}，但 {file} 关闭了发送（AGENTO11Y_ENABLED=false）。",
        "observability_destination_missing": "尚未设置：在 {file} 写入你的 Grafana 栈的端点和令牌之前，不会发送任何内容。crok 仓库中的 agento11y setup.sh 可以写入该文件。",
        "observability_open_log": "打开日志",
        "observability_banner": "✓ Agent Observability：{state}",
        "observability_banner_reporting": "✓ Agent Observability：{state} · 上报到 {host}",
        "observability_banner_not_set_up": "✓ Agent Observability：{state} · 在设置好 {file} 之前不会发送任何内容",
    ]

    // MARK: Japanese

    static let japaneseObservability: [String: String] = [
        "observability_settings_title": "Agent Observability",
        "observability_report": "モデル呼び出しを送信",
        "observability_detail": "Crok Desktop とターミナルからの各モデル呼び出し（プロンプト、応答、ツール呼び出し、トークン、所要時間）を、あなたの Grafana Agent Observability スタックに送信します。すぐに反映され、開いているタスクにも適用されます。",
        "observability_destination": "送信先",
        "observability_destination_host": "{host}（{file} で設定）。",
        "observability_destination_disabled": "{host}。ただし {file} で送信がオフになっています（AGENTO11Y_ENABLED=false）。",
        "observability_destination_missing": "未設定: {file} に Grafana スタックのエンドポイントとトークンが書かれるまで、何も送信されません。crok リポジトリの agento11y setup.sh で書き込めます。",
        "observability_open_log": "ログを開く",
        "observability_banner": "✓ Agent Observability: {state}",
        "observability_banner_reporting": "✓ Agent Observability: {state} · {host} に送信します",
        "observability_banner_not_set_up": "✓ Agent Observability: {state} · {file} を設定するまで何も送信されません",
    ]

    // MARK: Spanish

    static let spanishObservability: [String: String] = [
        "observability_settings_title": "Agent Observability",
        "observability_report": "Enviar las llamadas al modelo",
        "observability_detail": "Envía cada llamada al modelo (prompt, respuesta, llamadas a herramientas, tokens, tiempos) desde Crok Desktop y el terminal a tu pila de Grafana Agent Observability. Se aplica al instante, también a las tareas abiertas.",
        "observability_destination": "Destino",
        "observability_destination_host": "{host}, configurado en {file}.",
        "observability_destination_disabled": "{host}, pero {file} desactiva el envío (AGENTO11Y_ENABLED=false).",
        "observability_destination_missing": "Sin configurar: no se envía nada hasta que {file} contenga el endpoint y el token de tu pila de Grafana. El setup.sh de agento11y del repositorio de crok lo escribe.",
        "observability_open_log": "Abrir registro",
        "observability_banner": "✓ Agent Observability: {state}",
        "observability_banner_reporting": "✓ Agent Observability: {state} · enviando a {host}",
        "observability_banner_not_set_up": "✓ Agent Observability: {state} · no se envía nada hasta configurar {file}",
    ]

    // MARK: French

    static let frenchObservability: [String: String] = [
        "observability_settings_title": "Agent Observability",
        "observability_report": "Envoyer les appels au modèle",
        "observability_detail": "Envoie chaque appel au modèle (prompt, réponse, appels d'outils, tokens, durées) depuis Crok Desktop et le terminal vers votre stack Grafana Agent Observability. S'applique immédiatement, y compris aux tâches ouvertes.",
        "observability_destination": "Destination",
        "observability_destination_host": "{host}, défini dans {file}.",
        "observability_destination_disabled": "{host}, mais {file} désactive l'envoi (AGENTO11Y_ENABLED=false).",
        "observability_destination_missing": "Non configuré : rien n'est envoyé tant que {file} ne contient pas l'endpoint et le jeton de votre stack Grafana. Le setup.sh d'agento11y du dépôt crok l'écrit.",
        "observability_open_log": "Ouvrir le journal",
        "observability_banner": "✓ Agent Observability : {state}",
        "observability_banner_reporting": "✓ Agent Observability : {state} · envoi vers {host}",
        "observability_banner_not_set_up": "✓ Agent Observability : {state} · rien n'est envoyé tant que {file} n'est pas configuré",
    ]

    // MARK: German

    static let germanObservability: [String: String] = [
        "observability_settings_title": "Agent Observability",
        "observability_report": "Modellaufrufe melden",
        "observability_detail": "Sendet jeden Modellaufruf (Prompt, Antwort, Tool-Aufrufe, Tokens, Zeiten) aus Crok Desktop und dem Terminal an deinen Grafana-Agent-Observability-Stack. Gilt sofort, auch für offene Aufgaben.",
        "observability_destination": "Ziel",
        "observability_destination_host": "{host}, festgelegt in {file}.",
        "observability_destination_disabled": "{host}, aber {file} schaltet das Senden aus (AGENTO11Y_ENABLED=false).",
        "observability_destination_missing": "Nicht eingerichtet: Es wird nichts gesendet, bis {file} den Endpunkt und das Token deines Grafana-Stacks enthält. Das agento11y-setup.sh im crok-Repository schreibt die Datei.",
        "observability_open_log": "Protokoll öffnen",
        "observability_banner": "✓ Agent Observability: {state}",
        "observability_banner_reporting": "✓ Agent Observability: {state} · sendet an {host}",
        "observability_banner_not_set_up": "✓ Agent Observability: {state} · es wird nichts gesendet, bis {file} eingerichtet ist",
    ]
}
