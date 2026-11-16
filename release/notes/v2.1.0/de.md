Crok Desktop 2.1.0 ist die native macOS-App dieses Forks. Sie bringt crok mit, die Agent-Laufzeit und die Terminal-Oberfläche `crok`, sodass nichts weiter zu installieren ist. Sie folgt auf 2.0.4, das Fotos und Dateien zu entfernten Prompts gebracht hat. 2.1.0 fügt die Meta Model API als siebten Anbieter mit ihren Muse-Modellen zum Terminal und zu Crok Desktop hinzu. Web und Telefon-Apps zeigen jetzt Modell und Denkstufe einer Sitzung zusammen, auch bei Sitzungen, die aus der Liste geöffnet wurden. Crok Desktop zeichnet sein Glas nur im aktiven Fenster und malt das Glas des Eingabefelds selbst, sodass ein inaktives Fenster hinter anderen Apps etwa so viel kostet wie ein normales Fenster und Mission Control flüssig bleibt. Ein gewählter Feedback-Daumen füllt sich, und der Statuspunkt von **Andere Computer** ist größer und online grün.

Dieses Release wird von GitHub Actions gebaut und veröffentlicht, sobald sein Pull Request gemergt wurde, wie es bei 2.0.4 der Fall war.

### Installation

1. Lade das Disk-Image herunter, das zu deiner macOS-Version passt, und öffne es. Welches das ist, sagt die Tabelle unter **Welches Disk-Image du herunterladen solltest**.
2. Ziehe **Crok Desktop** auf **Programme**.
3. Öffne Crok Desktop aus Programme. Dieser Build ist nicht notarisiert, daher meldet macOS beim ersten Mal, dass es die App nicht verifizieren kann. Schließe die Meldung, öffne **Systemeinstellungen › Datenschutz & Sicherheit**, klicke neben der Meldung zu Crok Desktop auf **Trotzdem öffnen** und bestätige. Das ist nur einmal nötig.
4. Melde dich unter **Einstellungen › Accounts** an: mit OpenRouter, OpenAI Codex, einem Anthropic-API-Schlüssel, einem DeepSeek-API-Schlüssel, einem Meta-Model-API-Schlüssel oder einem Schlüssel für den GLM Coding Plan.

Erfordert macOS 14 Sonoma oder neuer auf Apple Silicon (M1 oder neuer).

### Welches Disk-Image du herunterladen solltest

Beide Images sind Crok Desktop 2.1.0 und enthalten dieselben Funktionen. Sie unterscheiden sich nur im macOS-SDK, gegen das sie gebaut wurden, und das entscheidet, ob die Fensterumrandung Apples Liquid Glass nutzt:

| Disk-Image | Gebaut gegen | Verwende es auf | Titelleiste |
| --- | --- | --- | --- |
| `Crok-Desktop-2.1.0-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 und neuer | Liquid Glass |
| `Crok-Desktop-2.1.0-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 und 15 | Milchglasartige Unschärfe im Fenster |

Unter macOS 26 und neuer nimm für die Liquid-Glass-Titelleiste das Image mit dem macOS 26 SDK. Unter macOS 14 oder 15 nimm das Image mit dem macOS 15 SDK. Es läuft auch auf neueren Versionen, ist also die sichere Wahl, wenn du nicht weißt, welches macOS du hast. Das Eingabefeld wird in beiden Images gleich gezeichnet.

`crok-2.1.0-aarch64-apple-darwin.tar.gz` ist die Terminal-Oberfläche `crok` für sich allein, für einen Mac, auf dem du die App nicht haben möchtest: Entpacke das Archiv und lege `crok` in deinen `PATH`. Die Apps für Telefone sind unter **Telefon-Apps** beschrieben. `SHA256SUMS.txt` listet die SHA-256-Prüfsummen aller Downloads auf, und `SHA256SUMS.txt.sig` ist die Signatur dieser Liste, die die Aktualisierung prüft.

### Telefon-Apps

Die Crok-App für iPhone und Android verfolgt die Sitzungen deiner Computer, zeigt ihre Antworten und Berechtigungsanfragen und startet oder steuert Aufgaben von überall aus. Die Telefon-Apps dieses Releases sind neu: Eine geöffnete Sitzung zeigt Modell und Denkstufe zusammen, und ein Modell, das ein älterer Computer nach Art des Anbieters benennt, wird trotzdem in der Liste gefunden. Installiere sie über die Apps von 2.0.4, um das zu bekommen. Telefon-Apps von 2.0.4 und älter funktionieren weiter wie bisher. Alle drei Dateien melden sich beim Produktions-Relay an.

- **Android 8.0 oder neuer:** Lade `Crok-Android-2.1.0.apk` auf dem Telefon herunter und öffne sie, wobei du deinem Browser erlaubst, Apps zu installieren, wenn Android danach fragt, oder führe `adb install -r Crok-Android-2.1.0.apk` aus. Sie ist mit dem Release-Schlüssel signiert, den 2.0.0 eingeführt hat, und installiert sich daher über die APK einer früheren Version. Eine selbst gebaute Crok-APK ist mit einem anderen Schlüssel signiert und blockiert die Installation: Entferne sie vorher mit `adb uninstall dev.chenli.crok.mobile` oder in den Einstellungen des Telefons.
- **iPhone und iPad, iOS 17 oder neuer:** `Crok-iOS-2.1.0-unsigned.ipa` ist nicht signiert, weil eine App für iOS-Geräte mit der Apple ID der Person signiert wird, die sie installiert. Installiere sie mit einem Sideloading-Werkzeug wie AltStore oder Sideloadly, das sie mit deiner Apple ID signiert. Mit einer kostenlosen Apple ID öffnet iOS die App nach 7 Tagen nicht mehr, bis du sie erneut installierst. Wenn du sie selbst bauen möchtest, nutze die **Release**-Konfiguration: Die Run-Schaltfläche von Xcode baut Debug, und das meldet sich beim Test-Relay an.
- **iOS-Simulator:** `Crok-iOS-2.1.0-Simulator.zip` entpackt sich zu `Crok.app`, für `xcrun simctl install booted Crok.app` auf einem Mac mit Xcode.

Um das Telefon anzumelden, tippe auf **Weiter mit GitHub oder Google**, melde dich auf der Seite an, die sich unter https://crok.chenli.dev öffnet, und tippe auf **Genehmigen**. Verknüpfe dann jeden Computer: Führe dort `crok remote login` aus und scanne den angezeigten QR-Code in der App unter **Einstellungen › Computer verknüpfen**, oder genehmige den Computer auf der Webseite, die sich öffnet.

### Highlights

- **Meta Model API, ein siebter Anbieter.** Terminal und Crok Desktop melden sich bei Metas eigener Model API an, die pro Token über ein Meta-Konto abgerechnet wird, mit einem Schlüssel von dev.meta.ai. `crok login meta` fragt den Schlüssel ab, ohne ihn anzuzeigen, und prüft ihn bei Meta, bevor er gespeichert wird; ein abgelehnter Schlüssel wird nicht gespeichert. `meta-code` und `muse` sind Aliase, `META_API_KEY` und `MODEL_API_KEY` melden sich genauso an, und `crok logout meta` entfernt den gespeicherten Schlüssel. **Einstellungen › Accounts** in Crok Desktop und das Erststartmenü des Terminals listen den Anbieter auf.
- **Die Muse-Modelle.** Beim Anmelden wird die Modellliste deines Kontos geladen, die danach stündlich aktualisiert wird. Die eingebaute Liste umfasst Muse Wonder, Muse Spark 1.3, 1.2 und 1.1, deren Contributor-Modus-Varianten und Muse Ember; ein Modell, das Meta später veröffentlicht, funktioniert sofort mit seiner ID `meta/<model>`. Die Modelle lesen Text, Bilder, PDFs, Audio und Video. Sie denken immer nach: `/effort` bietet `minimal`, `low`, `medium`, `high`, `xhigh` und `max`, mit `max` als Standard bei Muse Wonder und Muse Ember und `high` bei Muse Spark. `none` wird nicht angeboten, weil Meta es ablehnt, und die Contributor-Varianten enden bei `xhigh`.
- **Modell und Denkstufe einer Sitzung, immer zusammen.** Beim Öffnen einer Sitzung im Web, auf iOS oder Android erschien manchmal nur die nackte Modell-ID ohne Denkstufen-Pille. crok benennt das Modell einer Sitzung jetzt mit der ID seiner Modellliste, sodass die Geräte das Modell und seine Stufen finden. Eine Sitzung von einem älteren crok, das das Modell nach Art des Anbieters benennt, wird trotzdem über die ID ohne ihren Anbieter und dann über den Namen gefunden. Die Denkstufen-Pille zeigt die Stufe der Sitzung, während die Liste lädt, und nennt eine Stufe, die in der Liste des Modells fehlt, statt **Standard** zu sagen. Sie entfällt nur bei einem Modell, dessen Liste sagt, dass es keine Stufen hat, oder wenn weder die Liste noch die Sitzung eine Stufe nennt.
- **Glas, das weniger zum Zeichnen kostet.** Nur das Glas des aktiven Fensters ist lebendig, wie bei den Seitenleisten des Systems: Ein Fenster hinter anderen Apps malt Volltonfarben, und die Karten der Willkommensseite rollen nicht mehr. Das Wischen in Mission Control ruckelt nicht mehr, erst recht nicht mit einem externen Display. Auf einem M1 mit 4K-Display ging Mission Control mit Crok hinter dem Finder von 14,1 auf 8,9 mittlere GPU-Auslastung zurück (p90 von 46 auf 31).
- **Das Eingabefeld, gezeichnet statt Liquid Glass.** Der Fensterserver zeichnet Liquid Glass erneut, sobald sich in seinem Fenster etwas ändert, auch ein blinkender Cursor. Die Oberfläche des Eingabefelds wird jetzt aus einem mattierten Material und einem einzigen Canvas gezeichnet, der Schatten, Füllung, beleuchtete Kante, Glühen und Haarlinie enthält, und trifft das Aussehen des Systems bis auf wenige Stufen von 255. Auf demselben M1 und 4K-Display ging die GPU-Auslastung von Crok im Vordergrund im Leerlauf von etwa 25 auf 10,6 zurück, und die von Mission Control mit Crok im Vordergrund von 18,8 auf 13,0.
- **Kleinere Details.** Ein Daumen hoch oder runter füllt sich, wenn er gewählt ist, sodass das Urteil auf einen Blick zu erkennen ist. Der Online-Punkt von **Andere Computer** ist 10 Punkt groß, grün und von einem Halo umgeben, und der Offline-Punkt ist gleich groß in Grau.

### Fernsteuerung

Jedes crok in diesem Release meldet sich beim Produktions-Relay unter https://crok.chenli.dev an, wie 2.0.4, und behält die vorhandene Anmeldung. Das Produktions-Relay liefert die Web-Änderungen dieses Releases aus, wenn es veröffentlicht wird; was auf einem Computer passiert, kommt mit crok 2.1.0 dorthin.

- **Modellnamen.** Eine Sitzung speichert ihr Modell so, wie der Anbieter es nennt (`claude-sonnet-5-5`, `deepseek-flash`, OpenRouters `deepseek/deepseek-v4.1-flash`), während die von crok veröffentlichte Liste es nach Katalogsschlüssel benennt (`anthropic/claude-sonnet-5-5`, `deepseek/deepseek-flash`, `openrouter/deepseek/deepseek-v4.1-flash`). crok 2.1.0 sendet die ID der Liste, sodass Web und Telefone das Modell und seine Denkstufen finden. Ein Modell, das der Computer nicht mehr anbietet, behält seinen Namen.
- **Älteres crok.** Ein Computer, auf dem nur crok 2.0.4 oder älter läuft, benennt das Modell weiterhin nach Art des Anbieters. Web und die Telefon-Apps dieses Releases finden es über die ID ohne ihren Anbieter, sodass Modell und Stufe trotzdem erscheinen; die nackte ID erscheint nur, wenn keine der beiden Formen passt.
- **Beide Pillen.** Web, iOS und Android zeigen Modell und Denkstufe der Sitzung zusammen. Während die Liste des Computers unterwegs ist, wird das Modell benannt und die Denkstufen-Pille zeigt die Stufe der Sitzung; ohne Liste von einem älteren crok sind beide gedimmt, und ein Tippen erklärt, dass dieser Computer noch keine Modellauswahl anbietet. Eine Stufe, die in der Liste des Modells fehlt, erscheint mit ihrem Stufennamen.
- **Aktualisiere die Computer.** Die Meta Model API und die genauen Modellnamen kommen mit crok 2.1.0 auf jedem Computer. Installiere die Telefon-Apps dieses Releases, wie oben unter **Telefon-Apps** beschrieben, für die beiden Pillen.

### Feedback und Agent Observability

Die Meldung ist gegenüber 2.0.4 unverändert: Jedes crok meldet jeden Modellaufruf, den es macht, mit seinen Turns, Werkzeugausführungen, Schritten und Guard-Prüfungen an [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) auf dem Grafana-Cloud-Stack des Maintainers, und `crok version --json` zeigt den Host unter `agentObservability`. Ein Daumen hoch oder runter aus Crok Desktop oder dem Terminal wird an der Konversation dieses Turns und als Gauge `crok_feedback_rating` erfasst; das Zurücknehmen wird als neutral erfasst.

Um die Meldung abzuschalten, füge `agent_observability = false` unter `[features]` in `~/.crok/config.toml` hinzu oder setze `CROK_AGENT_OBSERVABILITY=0`. Um an deinen eigenen Stack zu melden, schreibe `~/.crok/agento11y.env` mit `crates/codegen/xai-grok-agento11y/setup.sh` aus dem Repository.

### Für Entwickler

- Meta ist ein `ApiBackend` (`meta`) mit einem eigenen Chat-Completions-Dialekt. `GET /v1/models` wird beim Anmelden und danach stündlich abgerufen und in `~/.crok/meta-models.json` zwischengespeichert; bis zum ersten Abruf gilt die eingebaute Liste. `provider_compat.rs` sendet `none` und `minimal` als `minimal`, hebt jedes `max_tokens` unter 4.096 an, weil das Reasoning aus demselben Budget kommt, bittet mit `tool_choice: "auto"` in Worten um einen erzwungenen Werkzeugaufruf, behält native JSON-Schemas, entfernt `reasoning_content` aus erneut gesendeten Turns und entfernt `frequency_penalty` und `presence_penalty`.
- Ein Modellwechsel zwischen Familien komprimiert vorher, wie bei Anthropic. Standardkosten werden aus Metas veröffentlichten Preisen geschätzt, einschließlich der Langkontext-Stufe von Muse Ember ab 200.000 Eingabe-Tokens und der Contributor-Preise.
- Remote: `bridge:upsertSession` (nur wenn sich das Modell geändert hat), `bridge:catalogBatch` und `catalogUpdate` benennen das Modell einer Sitzung mit dem Katalogsschlüssel, den `selectable_catalog_key_for_persisted` auflöst, so wie das Modell einer fortgesetzten Sitzung aufgelöst wird. Ein Modell, das die Liste nicht enthält, behält seinen Namen. `relay/DESIGN.md` und `mobile/DESIGN.md` beschreiben den Vertrag.
- Web, iOS und Android finden das Modell einer Sitzung über die ID, dann über die ID ohne ihren Anbieter und dann über den Namen, und zeigen die Denkstufen-Pille, sobald die Sitzung eine Stufe nennt. Die Web-Vorschau hat die neuen Fälle (`session-provider-model`, `session-models-loading`, `session-unknown-model`).
- Desktop: `GlassBackdrop` nutzt die Volltonfarben, solange ein Fenster inaktiv ist, und tönt über den Hintergrund eines anderen Bereichs, statt den Schreibtisch erneut zu verwischen; `GlassSurface` zeichnet sein `FrostedGlass`-Aussehen in einem einzigen Canvas. Tests prüfen, dass keine Liquid-Glass-Ebenen übrig bleiben und inaktive Fenster Volltonfarben malen.
- Releases macht weiterhin `.github/workflows/release.yml`: Wenn ein Pull Request, der `VERSION` erhöht, in `main` gemergt wird, baut, prüft und signiert es jede Datei, führt das Eval-Gate aus und veröffentlicht das Release mit den Hinweisen in `release/notes/v2.1.0/`.

### Signatur

2.1.0 ist mit demselben Zertifikat „Crok Code Signing“ signiert wie 2.0.4, 2.0.3, 2.0.2, 2.0.1, 2.0.0, 1.5.2 und 1.5.3. macOS knüpft Datenschutzberechtigungen an die Signatur, sodass das, was du für 2.0.4 erlaubt hast (Bildschirmaufnahme, Bedienungshilfen, Mikrofon, Spracherkennung), für 2.1.0 übernommen wird. Der Build ist nicht notarisiert, daher ist bei einer neuen Installation der Schritt **Trotzdem öffnen** oben einmal nötig.

Die Android-App ist mit dem Release-Schlüssel signiert, den 2.0.0 eingeführt hat. Die iOS-App ist nicht signiert, wie unter **Telefon-Apps** erklärt. Die signierte Prüfsummenliste ist etwas anderes: Mit ihr kann die Aktualisierung einen Download prüfen; wie macOS die App behandelt, ändert sie nicht.

### Upgrade von 2.0.4

Verwende **Crok Desktop › Nach Updates suchen…** oder `crok upgrade` im Terminal bei beendeter Crok Desktop App. Dieses Update wird an Ort und Stelle in die installierte `Crok Desktop.app` gemacht, sodass sie ihren Platz im Dock und im Finder behält und keine alte Kopie im Papierkorb zurückbleibt. Es nimmt das Image, das mit demselben SDK gebaut wurde wie die installierte App (macOS26-SDK oder macOS15-SDK), niemals das andere.

Die Anmeldung bei deinen Modellanbietern, deine Einstellungen, deine Aufgaben und das Relay bleiben erhalten: 2.1.0 spricht mit demselben Produktions-Relay wie 2.0.4. Aktualisiere jeden Computer, den du mit dem Relay nutzt, auf crok 2.1.0 für die Meta Model API und die genauen Modellnamen, und installiere die Telefon-Apps dieses Releases, wie oben unter **Telefon-Apps** steht.

### Details

- Bringt crok `{{CROK_VERSION}}` mit.
- Von GitHub Actions gebaut aus dem Tag `desktop-v2.1.0` bei `{{COMMIT}}` auf `main`. Das Image mit dem macOS 26 SDK wurde mit Xcode {{XCODE26}} und dem macOS {{SDK26}} SDK gebaut, das Image mit dem macOS 15 SDK mit Xcode {{XCODE15}} und dem macOS {{SDK15}} SDK und das eigenständige `crok` mit dem macOS {{TUI_SDK}} SDK.
- Beide Images sind arm64, mit dem Zertifikat Crok Code Signing signiert und nicht notarisiert, und beide laufen auf macOS 14 Sonoma oder neuer.
- Die iOS-App (`dev.chenli.crok.mobile`) ist ein Release-Build mit Xcode {{XCODE26}}; die Android-App ist ein Release-Build für Android 8.0 oder neuer.
- Die SHA-256-Prüfsummen stehen am Ende dieser Hinweise und in der Datei `SHA256SUMS.txt`, die auch die Telefon-Apps umfasst. Die Datei `release/README.md` im Repository zeigt, wie sich die Signatur der Liste von Hand prüfen lässt.
