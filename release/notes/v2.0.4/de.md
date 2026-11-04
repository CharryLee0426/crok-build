Crok Desktop 2.0.4 ist die native macOS-App dieses Forks. Sie bringt crok mit, die Agent-Laufzeit und die Terminal-Oberfläche `crok`, sodass nichts weiter zu installieren ist. Sie folgt auf 2.0.3, das die Sitzungsliste jedes Geräts aktuell gehalten hat. Mit 2.0.4 kann ein Prompt aus dem Web, von einem Telefon oder von einem anderen Computer Fotos und Dateien mitbringen, und sie erscheinen auf jedem Gerät im Transkript. Jede Sitzungsliste bekommt eine Schaltfläche **Aktualisieren**, mit der jeder Computer, der online ist, seine Sitzungen sofort neu auflistet. Crok Desktop zeigt unter jeder Antwort Kopieren sowie Daumen hoch und Daumen runter, das Terminal stellt nach einem Turn eine kurze Frage, und mehr Reasoning-Modelle auf OpenRouter benennen ihre Sitzungen jetzt.

Dieses Release wird von GitHub Actions gebaut und veröffentlicht, sobald sein Pull Request gemergt wurde, wie es bei 2.0.3 der Fall war.

### Installation

1. Lade das Disk-Image herunter, das zu deiner macOS-Version passt, und öffne es. Welches das ist, zeigt die Tabelle unter **Welches Disk-Image laden**.
2. Ziehe **Crok Desktop** auf **Programme**.
3. Öffne Crok Desktop aus dem Ordner „Programme“. Dieser Build ist nicht notarisiert, also nicht von Apple beglaubigt. Beim ersten Start meldet macOS deshalb, dass es die App nicht überprüfen kann: Klicke auf **Fertig**, öffne **Systemeinstellungen › Datenschutz & Sicherheit**, klicke neben der Meldung zu Crok Desktop auf **Dennoch öffnen** und bestätige. Das ist nur einmal nötig.
4. Melde dich unter **Einstellungen › Accounts** an: mit OpenRouter, OpenAI Codex, einem Anthropic-API-Schlüssel, einem DeepSeek-API-Schlüssel oder einem Schlüssel für den GLM Coding Plan.

Erfordert macOS 14 Sonoma oder neuer auf einem Mac mit Apple Chip (M1 oder neuer).

### Welches Disk-Image laden

Beide Images sind Crok Desktop 2.0.4 und enthalten dieselben Funktionen. Sie unterscheiden sich nur im macOS-SDK, mit dem sie gebaut wurden. Es entscheidet, ob der Fensterrahmen Apples Liquid Glass verwendet:

| Disk-Image | Gebaut mit | Geeignet für | Titelleiste |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.4-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 und neuer | Liquid Glass |
| `Crok-Desktop-2.0.4-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 und 15 | Milchglas-Unschärfe innerhalb des Fensters |

Nimm unter macOS 26 und neuer das Image mit dem macOS 26 SDK, um die Titelleiste in Liquid Glass zu bekommen. Nimm unter macOS 14 oder 15 das Image mit dem macOS 15 SDK. Es läuft auch auf neueren Versionen und ist deshalb die sichere Wahl, wenn du nicht weißt, welches macOS du hast.

`crok-2.0.4-aarch64-apple-darwin.tar.gz` ist die Terminal-Oberfläche `crok` für sich allein, für einen Mac, auf dem du die App nicht haben möchtest: Entpacke das Archiv und lege `crok` in deinen `PATH`. Die Apps für Telefone sind unter **Telefon-Apps** beschrieben. `SHA256SUMS.txt` listet die SHA-256-Prüfsummen aller Downloads auf, und `SHA256SUMS.txt.sig` ist die Signatur dieser Liste, die die Aktualisierung prüft.

### Telefon-Apps

Die Crok-App für iPhone und Android verfolgt die Sitzungen deiner Computer, zeigt ihre Antworten und Berechtigungsanfragen und startet oder steuert Aufgaben von überall aus. Die Telefon-Apps dieses Releases sind neu: Sie senden Fotos und Dateien mit einem Prompt, zeigen sie im Transkript und haben **Aktualisieren**. Installiere sie über die Apps von 2.0.3, um beides zu bekommen. Telefon-Apps von 2.0.3 und älter funktionieren weiter wie bisher, nur ohne diese Neuerungen. Alle drei Dateien melden sich beim Produktions-Relay an.

- **Android 8.0 oder neuer:** Lade `Crok-Android-2.0.4.apk` auf dem Telefon herunter und öffne es (erlaube deinem Browser, Apps zu installieren, wenn Android danach fragt), oder führe `adb install -r Crok-Android-2.0.4.apk` aus. Das APK ist mit dem Release-Schlüssel signiert, den 2.0.0 eingeführt hat, sodass es sich über das APK eines früheren Releases installieren lässt. Ein Crok-APK, das du selbst gebaut hast, ist mit einem anderen Schlüssel signiert und verhindert die Installation: Entferne es zuerst mit `adb uninstall dev.chenli.crok.mobile` oder in den Einstellungen des Telefons.
- **iPhone und iPad, iOS 17 oder neuer:** `Crok-iOS-2.0.4-unsigned.ipa` ist nicht signiert, weil eine App für iOS-Geräte mit der Apple-ID derjenigen Person signiert wird, die sie installiert. Installiere sie mit einem Sideloading-Tool wie AltStore oder Sideloadly, das sie mit deiner Apple-ID signiert. Mit einer kostenlosen Apple-ID öffnet iOS die App nach 7 Tagen nicht mehr, bis du sie erneut installierst. Um sie stattdessen selbst zu bauen, verwende die Konfiguration **Release**: Der Run-Button in Xcode baut Debug, und ein Debug-Build meldet sich beim Test-Relay an.
- **iOS-Simulator:** `Crok-iOS-2.0.4-Simulator.zip` ergibt entpackt `Crok.app`, zur Installation mit `xcrun simctl install booted Crok.app` auf einem Mac mit Xcode.

Um das Telefon anzumelden, tippe auf **Weiter mit GitHub oder Google**, melde dich auf der Seite an, die sich unter https://crok.chenli.dev öffnet, und tippe auf **Genehmigen**. Verknüpfe dann jeden Computer: Führe dort `crok remote login` aus und scanne den angezeigten QR-Code in der App unter **Einstellungen › Computer verknüpfen**, oder genehmige den Computer auf der Webseite, die sich öffnet.

### Neuerungen

- **Fotos und Dateien in Prompts, von jedem Gerät aus.** Im Web und in den Telefon-Apps fügt die Büroklammer neben dem Eingabefeld einem Prompt Fotos und Dateien hinzu: auf den Telefonen über Fotos, Kamera und Dateien, im Web außerdem durch Einfügen oder durch Ablegen auf der Sitzung. Eine Nachricht nimmt bis zu 10 davon mit, jeweils höchstens 20 MB, und darf auch nur aus Fotos bestehen. Der Computer gibt Bilder als Bilder an das Modell weiter und legt andere Dateien in einem eigenen Ordner ab, aus dem das Modell sie lesen kann. Fotos erscheinen auf jedem Gerät im Transkript und öffnen sich per Tippen im Vollbild (auf den Telefonen mit **Teilen** und **Speichern**, auf dem iPhone heißt es **In Fotos sichern**), und die Bilder eines Prompts, der direkt am Computer eingegeben wurde, erscheinen ebenfalls auf den Telefonen und im Web.
- **Jede Sitzungsliste aktualisieren.** Das Web, die Telefon-Apps, **Andere Computer** in Crok Desktop und das Remote-Panel des Terminals haben ein Bedienelement zum Aktualisieren (↻, oder `r` in `/remote`). Es bittet jeden Computer, der online ist, alle seine Sitzungen sofort neu aufzulisten, statt erst bei seiner nächsten Prüfung, und dreht sich, bis jeder das getan hat. Auf den Telefonen bewirkt das Herunterziehen der Liste dasselbe.
- **Feedback zu Antworten.** Crok Desktop zeigt unter jeder fertigen Antwort eine Schaltfläche zum Kopieren sowie Daumen hoch und Daumen runter. Kopieren übernimmt das Markdown der Antwort so, wie es geschrieben wurde, und ein erneuter Klick auf den gewählten Daumen nimmt das Urteil zurück. Das Terminal fragt unter einem fertigen Turn einmal „Wie war diese Antwort?“; beantwortet wird mit `/good`, `/not-so-well` oder `/dont-show-again`.
- **Sitzungstitel auf mehr OpenRouter-Modellen.** Reasoning-Modelle, die einen erzwungenen Werkzeugaufruf ablehnen (Muse Spark 1.3) oder das knappe Budget einer kurzen Antwort für ihr Reasoning verbrauchen (Muse Glimmer, GLM 5.3 Flash, Aion 2.0), bekamen nie einen generierten Titel, sodass ihre Sitzungen nach den ersten Wörtern des Prompts benannt wurden. Jetzt bekommen sie Titel wie jedes andere Modell.

### Fernsteuerung

Jedes crok dieses Releases meldet sich wie 2.0.3 beim Produktions-Relay unter https://crok.chenli.dev an und behält die Anmeldung, die es schon hat. Das Produktions-Relay übernimmt die Relay-Änderungen dieses Releases, wenn dieses Release veröffentlicht wird; was auf einem Computer geschieht, kommt dort mit crok 2.0.4.

- **Fotos und Dateien auf dem Computer.** Bevor crok einen solchen Prompt ausführt, lädt es dessen Fotos und Dateien herunter. Bilder gehen als Bildeingabe an das Modell. Andere Dateien werden unter `~/.crok/remote/attachments/` gespeichert (ein Ordner pro Sitzung und Nachricht) und im Prompt verlinkt, so wie Crok Desktop Dateien anhängt. In einer bereits offenen Aufgabe eines anderen Computers laden Crok Desktop und das Terminal die Bilder und Dateien eines Prompts mit ihm hoch; eine neue Aufgabe auf einem anderen Computer startet weiterhin nur mit Text.
- **Fotos und Dateien auf dem Relay.** Web und Telefone senden Fotos aufrecht, mit höchstens 2048 Pixeln an der langen Seite und ohne ihre Metadaten, zusammen mit einer kleinen Vorschau. Ein Upload, den keine Nachricht beansprucht, wird nach einem Tag gelöscht; die Dateien einer Sitzung werden mit der Sitzung gelöscht oder mit ihrem Transkript nach 30 Tagen ohne Aktivität.
- **Älteres crok.** Ein Computer, auf dem nur crok 2.0.3 oder älter läuft, kann keine Fotos oder Dateien annehmen: Wer welche dorthin sendet, bekommt „Update crok on … to send photos and files there.“ (sinngemäß: Aktualisiere crok auf …, um Fotos und Dateien dorthin zu senden). Text-Prompts funktionieren wie bisher.
- **Aktualisieren.** Das crok, das die Sitzungsliste eines Computers führt, listet jede Sitzung auf der Festplatte neu auf, sobald jemand auf Aktualisieren drückt, und schickt danach wie bisher alle 30 Sekunden nur, was sich geändert hat. Der Spinner stoppt, sobald jeder Computer, der online ist, geantwortet hat, oder nach 15 Sekunden. Ein Computer, auf dem nur älteres crok läuft, antwortet womöglich erst mit seiner nächsten regulären Auflistung. Computer, die offline sind, können ihre Sitzungen nicht auflisten: Ihre Sitzungen bleiben, wie sie zuletzt gelistet wurden, und wenn kein Computer online ist, zeigen Telefone und Web den Hinweis „Kein Computer ist online. Die Liste zeigt, was sie zuletzt aufgelistet haben.“
- **Aktualisiere die Computer.** Fotos und Dateien in Prompts sowie eine sofortige Antwort auf Aktualisieren kommen mit crok 2.0.4 auf jedem Computer.

### Feedback und Agent Observability

Wie in 2.0.3 meldet jedes crok dieses Releases jeden Modellaufruf, den es macht, mit seinen Turns, Werkzeugläufen, Schritten und Guard-Prüfungen an [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) auf dem Grafana-Cloud-Stack des Maintainers, und `crok version --json` zeigt den Host unter `agentObservability`.

- **Wohin ein Daumen geht.** Ein Daumen hoch oder runter, ob aus Crok Desktop oder aus dem Terminal, wird in Agent Observability beim Gespräch dieses Turns erfasst und zusätzlich als Gauge `crok_feedback_rating`. Nimmst du einen Daumen zurück, wird er als neutral erfasst und zählt nicht mehr. Solange das Melden aus ist, wird nichts gesendet.
- **Die Frage im Terminal.** Sie erscheint einmal unter einem fertigen Turn, aber nicht nach einem abgebrochenen oder fehlgeschlagenen Turn, nicht im Minimalmodus und nicht in einem Terminal mit sehr wenigen Zeilen. `/dont-show-again` schaltet sie ab, indem es `feedback_prompt = false` unter `[features]` in `~/.crok/config.toml` schreibt; setze den Wert wieder auf `true`, um die Frage wieder zu sehen.
- **Die Auswertung des Maintainers.** Ein neues Dashboard **crok Feedback** zeigt den Anteil der Daumen hoch unter den Turns mit Feedback, mit einem Alert unter 80 % über einen Tag und einem 30-Tage-Ziel. Die Auswertung greift erst, sobald ein Zeitraum mindestens 20 Urteile enthält.

Um das Melden abzuschalten, füge `agent_observability = false` unter `[features]` in `~/.crok/config.toml` hinzu oder setze `CROK_AGENT_OBSERVABILITY=0`. Um an deinen eigenen Stack zu melden, schreibe `~/.crok/agento11y.env` mit `crates/codegen/xai-grok-agento11y/setup.sh` aus dem Repository.

### Für Entwickler

- Releases entstehen wie bisher durch `.github/workflows/release.yml`: Wenn ein Pull Request, der `VERSION` erhöht, in `main` gemergt wird, baut, prüft und signiert er jede Datei, führt das Eval-Gate aus und veröffentlicht das Release mit den Notes aus `release/notes/v2.0.4/`.
- Fotos und Dateien: Geräte laden über `files:uploadUrl` hoch und nennen die Uploads in `commands:sendPrompt` und `sessions:create` (`attachments`); das Relay hält sie in einer Tabelle `files` (Eigentümer, Sitzung, SHA-256, Vorschau) und gibt der Inbox des Computers und jeder Transkript-Abfrage ihre Download-URLs. Solche Prompts werden nur einem crok angeboten, dessen `features` `attachments` enthalten, und `bridge:connect` antwortet mit den eigenen `features` des Relays. `relay/DESIGN.md` §2–§5, „Photos and files“, ist der Vertrag; `relay/scripts/attachments-e2e.mjs` und `attachments-bridge-e2e.mjs` prüfen ihn.
- Aktualisieren: `sessions:refresh` (`{asked, offline, at}`) setzt `refreshAt` auf den Katalog jedes Computers, der online ist; solange dieser Zeitpunkt nach dem Beginn des letzten Uploads liegt, sieht jedes crok dort `catalogWanted`, und `bridge:beginCatalog` gibt den Katalog sofort dem ersten, das fragt, auch dem bisherigen Halter. `sessions:refreshState({since})` nennt die Computer, die noch auflisten. `x.ai/remote/refresh` des Viewers erledigt beides für Crok Desktop und das Terminal. `relay/scripts/refresh-e2e.mjs` prüft das mit echten crok-Prozessen.
- Feedback: Frontends senden `x.ai/feedback/rating` (`1`, `-1`, `0` zum Zurücknehmen) für einen Turn. `[features] feedback_prompt` (Standard `true`, `CROK_FEEDBACK_PROMPT`) steuert die Frage des Terminals. Die Auswertung besteht aus dem Dashboard `crok Feedback`, dem Alert `crok-feedback-good-rate-low` und dem SLO `crok feedback is mostly positive`.
- Auf OpenRouter bittet der Sampler mit `tool_choice: "auto"` in Worten um einen erzwungenen Werkzeugaufruf und gibt einem Reasoning-Modell mindestens 4.096 Ausgabe-Tokens bei der niedrigsten Denkstufe, die der Katalog nennt, sofern der Aufruf keine festlegt. Zwei Felder von `SamplerConfig` tragen die Reasoning-Unterstützung und die niedrigste Denkstufe aus dem Katalog.
- Die Cache-Trefferquote des Dashboards **LLM Overview** umfasst jetzt Claude Platform, OpenRouter und die Aufrufe, die crok selbst meldet, jede Quelle für sich abgefragt, sodass eine Quelle ohne Aufrufe im Zeitraum nichts beiträgt.

### Signatur

2.0.4 ist mit demselben Zertifikat „Crok Code Signing“ signiert wie 2.0.3, 2.0.2, 2.0.1, 2.0.0, 1.5.2 und 1.5.3. macOS knüpft Datenschutzberechtigungen an die Signatur, sodass das, was du für 2.0.3 erlaubt hast (Bildschirmaufnahme, Bedienungshilfen, Mikrofon, Spracherkennung), für 2.0.4 übernommen wird. Der Build ist nicht notarisiert, daher ist bei einer neuen Installation der Schritt **Dennoch öffnen** oben einmal nötig.

Die Android-App ist mit dem Release-Schlüssel signiert, den 2.0.0 eingeführt hat. Die iOS-App ist nicht signiert, wie unter **Telefon-Apps** erklärt. Die signierte Prüfsummenliste ist etwas anderes: Mit ihr kann die Aktualisierung einen Download prüfen; wie macOS die App behandelt, ändert sie nicht.

### Upgrade von 2.0.3

Verwende **Crok Desktop › Nach Updates suchen…** oder `crok upgrade` im Terminal bei beendeter Crok Desktop App. Dieses Update wird an Ort und Stelle in die installierte `Crok Desktop.app` gemacht, sodass sie ihren Platz im Dock und im Finder behält und keine alte Kopie im Papierkorb zurückbleibt. Es nimmt das Image, das mit demselben SDK gebaut wurde wie die installierte App (macOS26-SDK oder macOS15-SDK), niemals das andere.

Die Anmeldung bei deinen Modellanbietern, deine Einstellungen, deine Aufgaben und das Relay bleiben erhalten: 2.0.4 spricht mit demselben Produktions-Relay wie 2.0.3. Aktualisiere jeden Computer, den du mit dem Relay nutzt, damit er Fotos und Dateien annehmen und sofort auf Aktualisieren antworten kann, und installiere die Telefon-Apps dieses Releases, wie oben unter **Telefon-Apps** steht.

### Details

- Enthält crok `{{CROK_VERSION}}`.
- Von GitHub Actions gebaut aus dem Tag `desktop-v2.0.4` bei `{{COMMIT}}` auf `main`. Das Image mit dem macOS 26 SDK wurde mit Xcode {{XCODE26}} und dem macOS {{SDK26}} SDK gebaut, das Image mit dem macOS 15 SDK mit Xcode {{XCODE15}} und dem macOS {{SDK15}} SDK und das eigenständige `crok` mit dem macOS {{TUI_SDK}} SDK.
- Beide Images sind arm64, mit dem Crok-Code-Signing-Zertifikat signiert und nicht notarisiert, und beide laufen unter macOS 14 Sonoma oder neuer.
- Die iOS-App (`dev.chenli.crok.mobile`) ist ein Release-Build, erstellt mit Xcode {{XCODE26}}; die Android-App ist ein Release-Build für Android 8.0 oder neuer.
- Die SHA-256-Prüfsummen stehen am Ende dieser Hinweise und in der Datei `SHA256SUMS.txt`, die auch die Telefon-Apps umfasst. Die Datei `release/README.md` im Repository zeigt, wie sich die Signatur der Liste von Hand prüfen lässt.
