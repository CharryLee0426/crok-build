Crok Desktop 2.0.2 ist die native macOS-App dieses Forks. Sie bringt crok mit, die Agent-Laufzeit und die Terminal-Oberfläche `crok`, sodass nichts weiter zu installieren ist. Sie folgt auf 2.0.1, das beide Telefon-Apps rund um Computer, Projekte und Themen neu gestaltet hat. In 2.0.2 arbeitet das Browser-Werkzeug in dem Chrome, das du schon benutzt, angemeldet als du. Jedes Gerät kann Modell und Denkstufe des Computers einer Sitzung wählen, die Web-App folgt dem Design der Telefon-Apps, und das Terminal hat ein Remote-Panel. Das Ende eines Turns erreicht Web und Telefone jetzt in etwa einer Sekunde. Agent Observability verfolgt ganze Turns, und der Release-Workflow kann vor dem Veröffentlichen eine Eval-Suite ausführen.

Dieses Release wird von GitHub Actions gebaut und veröffentlicht, sobald sein Pull Request gemergt wurde, wie es bei 2.0.1 der Fall war.

### Installation

1. Lade das Disk-Image herunter, das zu deiner macOS-Version passt, und öffne es. Welches das ist, zeigt die Tabelle unter **Welches Disk-Image laden**.
2. Ziehe **Crok Desktop** auf **Programme**.
3. Öffne Crok Desktop aus dem Ordner „Programme“. Dieser Build ist nicht notarisiert, also nicht von Apple beglaubigt. Beim ersten Start meldet macOS deshalb, dass es die App nicht überprüfen kann: Klicke auf **Fertig**, öffne **Systemeinstellungen › Datenschutz & Sicherheit**, klicke neben der Meldung zu Crok Desktop auf **Dennoch öffnen** und bestätige. Das ist nur einmal nötig.
4. Melde dich unter **Einstellungen › Accounts** an: mit OpenRouter, OpenAI Codex, einem Anthropic-API-Schlüssel, einem DeepSeek-API-Schlüssel oder einem Schlüssel für den GLM Coding Plan.

Erfordert macOS 14 Sonoma oder neuer auf einem Mac mit Apple Chip (M1 oder neuer).

### Welches Disk-Image laden

Beide Images sind Crok Desktop 2.0.2 und enthalten dieselben Funktionen. Sie unterscheiden sich nur im macOS-SDK, mit dem sie gebaut wurden. Es entscheidet, ob der Fensterrahmen Apples Liquid Glass verwendet:

| Disk-Image | Gebaut mit | Geeignet für | Titelleiste |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.2-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 und neuer | Liquid Glass |
| `Crok-Desktop-2.0.2-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 und 15 | Milchglas-Unschärfe innerhalb des Fensters |

Nimm unter macOS 26 und neuer das Image mit dem macOS 26 SDK, um die Titelleiste in Liquid Glass zu bekommen. Nimm unter macOS 14 oder 15 das Image mit dem macOS 15 SDK. Es läuft auch auf neueren Versionen und ist deshalb die sichere Wahl, wenn du nicht weißt, welches macOS du hast.

`crok-2.0.2-aarch64-apple-darwin.tar.gz` ist die Terminal-Oberfläche `crok` für sich allein, für einen Mac, auf dem du die App nicht haben möchtest: Entpacke das Archiv und lege `crok` in deinen `PATH`. Die Apps für Telefone sind unter **Telefon-Apps** beschrieben. `SHA256SUMS.txt` listet die SHA-256-Prüfsummen aller Downloads auf, und `SHA256SUMS.txt.sig` ist die Signatur dieser Liste, die die Aktualisierung prüft.

### Telefon-Apps

Die Crok-App für iPhone und Android verfolgt die Sitzungen deiner Computer, zeigt ihre Antworten und Berechtigungsanfragen und startet oder steuert Aufgaben von überall aus. Sie kommt mit diesem Release, wie sie mit 2.0.1 kam. Alle drei Dateien melden sich beim Produktions-Relay an.

- **Android 8.0 oder neuer:** Lade `Crok-Android-2.0.2.apk` auf dem Telefon herunter und öffne es (erlaube deinem Browser, Apps zu installieren, wenn Android danach fragt), oder führe `adb install -r Crok-Android-2.0.2.apk` aus. Das APK ist mit dem Release-Schlüssel signiert, den auch spätere Releases behalten, sodass sich das nächste APK darüber installieren lässt. Ein Crok-APK, das du selbst gebaut hast, ist mit einem anderen Schlüssel signiert und verhindert die Installation: Entferne es zuerst mit `adb uninstall dev.chenli.crok.mobile` oder in den Einstellungen des Telefons.
- **iPhone und iPad, iOS 17 oder neuer:** `Crok-iOS-2.0.2-unsigned.ipa` ist nicht signiert, weil eine App für iOS-Geräte mit der Apple-ID derjenigen Person signiert wird, die sie installiert. Installiere sie mit einem Sideloading-Tool wie AltStore oder Sideloadly, das sie mit deiner Apple-ID signiert. Mit einer kostenlosen Apple-ID öffnet iOS die App nach 7 Tagen nicht mehr, bis du sie erneut installierst. Um sie stattdessen selbst zu bauen, verwende die Konfiguration **Release**: Der Run-Button in Xcode baut Debug, und ein Debug-Build meldet sich beim Test-Relay an.
- **iOS-Simulator:** `Crok-iOS-2.0.2-Simulator.zip` ergibt entpackt `Crok.app`, zur Installation mit `xcrun simctl install booted Crok.app` auf einem Mac mit Xcode.

Um das Telefon anzumelden, tippe auf **Weiter mit GitHub oder Google**, melde dich auf der Seite an, die sich unter https://crok.chenli.dev öffnet, und tippe auf **Genehmigen**. Verknüpfe dann jeden Computer: Führe dort `crok remote login` aus und scanne den angezeigten QR-Code in der App unter **Einstellungen › Computer verknüpfen**, oder genehmige den Computer auf der Webseite, die sich öffnet.

### Neuerungen

- **Das Browser-Werkzeug arbeitet in deinem eigenen Chrome.** Es öffnet ein Fenster des Browsers, der schon läuft, mit dem zuletzt benutzten Profil, sodass du auf allen Websites angemeldet bleibst. Nötig sind eine einmalige Einstellung in Chrome und dein **Allow**: siehe **Dein eigener Browser** weiter unten.
- **Modell und Denkstufe einer Sitzung auf jedem Gerät wählen.** iPhone, Android und das Web zeigen über dem Eingabefeld zwei Pillen, in neuen und offenen Sitzungen: das Modell, mit einer Liste, die Modelle durchsucht und nach Anbieter gruppiert, und die Denkstufe. Eine neue Aufgabe unter **Andere Computer** in Crok Desktop bietet dieselbe Wahl, bevor sie startet.
- **Computer mit Hunderten Modellen bieten alle an.** Ein bei OpenRouter angemeldeter Computer listet rund 480 Modelle. Das Relay lehnte jede Liste über 200 ab, sodass ein solcher Computer gar keine Wahl bot; jetzt behält es bis zu 1.000.
- **Die Web-App folgt den Telefon-Apps.** Sie ist aufgebaut wie Telegram Web: links die Projekte des gewählten Computers und ihre Themen, in der Mitte die Sitzung mit ihrem Theme, rechts die Sitzungsinfos.
- **Ein Remote-Panel im Terminal.** `/remote` zeigt die anderen Computer, ihre Projekte und Sitzungen, wie **Andere Computer** in Crok Desktop, und `n` startet dort eine Sitzung mit einem Modell deiner Wahl.
- **Das Ende eines Turns erreicht Web und Telefone sofort.** Nach einem arbeitsreichen Turn zeigten sie die Sitzung noch Sekunden, manchmal Minuten als arbeitend, obwohl der Computer längst fertig war. Jetzt kommt das Ende in etwa einer Sekunde an.
- **Lange Sitzungen öffnen sich auf den Telefonen schnell.** Die Telefon-Apps laden ein Transkript in kleinen Live-Teilen, halten den ersten Prompt einer neuen Sitzung im Blick und zeigen Denken und Werkzeugaufrufe nach ihrem Status, wie Crok Desktop.
- **OpenRouters Modelle mit 1M Token arbeiten über 105K Token hinaus.** crok verlangte einen Ausgaberahmen, der dem Prompt keinen Platz ließ, und OpenRouter lehnte ab, sobald ein Gespräch wuchs; jetzt verlangt crok nicht mehr Ausgabe, als neben den Prompt passt.
- **Agent Observability verfolgt ganze Turns.** Jeder Turn ist ein Trace mit seinen Modellaufrufen und Werkzeugläufen, und der Stack des Maintainers bewertet echten Verkehr und prüft Werkzeugaufrufe, die etwas ändern können. Siehe **Agent Observability** weiter unten.

### Dein eigener Browser

Das Browser-Werkzeug startete bisher einen eigenen Browser mit einem Profil von Crok. Jetzt öffnet es ein Fenster des Chrome, das schon läuft, mit dem zuletzt benutzten Profil, sodass du auf jeder Website angemeldet bleibst. Das Modell erfährt, dass das Fenster als du angemeldet sein kann.

- **Remote-Debugging einmal einschalten.** Dafür ist Chrome 144 oder neuer nötig. Öffne `chrome://inspect/#remote-debugging` in Chrome und schalte **Allow remote debugging for this browser instance** ein. Chrome lehnt eine `chrome://`-Adresse ab, die eine andere App übergibt, daher gibt es in Crok Desktop unter **Einstellungen › Browser- und Computernutzung** eine Schaltfläche **Adresse kopieren**.
- **Jede Aufgabe einmal erlauben.** Wenn eine Aufgabe den Browser zum ersten Mal nutzt, fragt Chrome **Allow remote debugging?** Klicke auf **Allow**. Crok wartet zwei Minuten auf die Antwort und sagt, was zu tun ist, wenn Remote-Debugging aus ist oder die Frage abgelehnt wurde.
- **Dein Browser bleibt deiner.** Crok beendet ihn nie und übernimmt nie seine Start-Tabs, und Downloads landen dort, wo deine Chrome-Einstellungen sie hinlegen.
- **Das eigene Profil für Crok gibt es weiter.** Wähle in Crok Desktop unter **Einstellungen › Browser- und Computernutzung › Browserprofil** den Eintrag **Eigenes Profil für Crok**, oder setze `profile = "crok"` unter `[toolset.browser]` in `~/.crok/config.toml`. Standard ist `profile = "user"`.

Getestet mit Chrome unter macOS. Edge, Brave und Chromium sind noch nicht getestet.

### Fernsteuerung

Jedes crok dieses Releases meldet sich wie 2.0.1 beim Produktions-Relay unter https://crok.chenli.dev an und behält die Anmeldung, die es schon hat.

- **Modell und Denkstufe.** In einer neuen Sitzung zeigen die Pillen **Default**, bis du wählst, und die Sitzung startet mit deiner Wahl. In einer offenen Sitzung geht eine Änderung an ihren Computer, und die Pille dreht sich, bis dieser sie angewendet hat; lehnt er ab, kommt der alte Wert mit dem Grund zurück. Die Sitzungsinfos zeigen dieselben zwei Zeilen, und die Befehle `/model` und `/think` der Telefone lesen dieselbe Liste.
- **Die Web-App.** Ihre linke Spalte ist ein Stapel von Seiten: die Sitzungen des gewählten Computers mit seinen Projekten, die Themen eines Projekts, archivierte Sitzungen und das Profil. Themen haben Aktionen beim Überfahren und Kontextmenüs zum Anheften, Stoppen, Als gelesen markieren, Archivieren und Umordnen. Sitzungs-Themes und der Farbmodus bleiben im Browser gespeichert. Unter 1024 Pixel Breite zeigt sie eine Spalte auf einmal.
- **Das Remote-Panel im Terminal.** `/remote` und `/remote open` zeigen das Konto, diesen Computer und die Verbindung, dann einen Baum der anderen Computer (online oder zuletzt gesehen, mit Ungelesenem), ihrer Projekte und der Sitzungen jedes Projekts. Enter öffnet eine Sitzung wie `/resume`, `n` startet eine und fragt nach Modell und Denkstufe dieses Computers, und Tippen filtert den Baum. `/remote status` gibt den alten Text aus. Eine Sitzung eines anderen Computers zeigt Branch und Token-Zahlen in der Statuszeile, und `/model` ändert dort nicht mehr den Standard dieses Computers.
- **Turn-Enden kommen sofort an.** Die Verbindung zum Relay fasst jetzt die Updates, die hinter jedem Schreibvorgang warten, zu einem zusammen, sodass ein arbeitsreicher Turn keine Warteschlange mehr aufbaut, die sein Ende verzögert. Ein beendeter Turn erscheint als beendet, auch wenn ein eingereihter Prompt die Warteschlange verließ, ohne zu laufen, und ein danach vom Telefon gesendeter Prompt läuft.
- **Telefone laden lange Sitzungen in Teilen.** Die Telefon-Apps öffnen ein Transkript mit seinen neuesten 40 Einträgen und laden ältere beim Scrollen in Teilen zu 60, sodass eine wochenlang gespiegelte Sitzung auch in einem langsamen Netz schnell öffnet. Der erste Prompt einer neuen Sitzung bleibt über dem Eingabefeld. Denken erscheint als laufend und dann fertig, ein Werkzeugaufruf als laufend, fertig, fehlgeschlagen oder gestoppt. Das Relay schickt den Text eines Gedankens und die Ausgabe eines Werkzeugs nicht mehr an die Telefone.
- **Aktualisiere Computer und Telefone.** Die Modelllisten und die schnelleren Turn-Enden kommen mit crok 2.0.2 auf dem Computer, der die Sitzung hat, die Pillen und das Transkriptfenster mit den Telefon-Apps 2.0.2. Telefon-Apps von 2.0.1 funktionieren mit dem Relay weiter.

### Agent Observability

Wie in 2.0.1 meldet jedes crok dieses Releases jeden Modellaufruf, den es macht, an [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) auf dem Grafana-Cloud-Stack des Maintainers, und `crok version --json` zeigt den Host unter `agentObservability`. 2.0.2 meldet auch, was zwischen den Aufrufen geschieht:

- **Turns und Werkzeugläufe.** Ein Turn ist ein Trace, dessen Root-Span seine Modellaufrufe und Werkzeugläufe enthält, mit dem Ausgang des Turns und der Zahl seiner Aufrufe und Werkzeugfehler. Ein Werkzeuglauf hält Ergebnis, Art, Exit-Code und die Größe seiner Ausgabe fest, nicht seine Argumente oder deren Inhalt. Der Turn eines Sub-Agents liegt unter dem Turn, der ihn gestartet hat.
- **Schritte, Urteile und Bewertungen.** Berechtigungsentscheidungen, Ergebnisse des PreToolUse-Hooks, Kompaktierungen und Starts von MCP-Servern erscheinen als Schritte im Gespräch. croks eigene Zielbewertung, der Faulheits-Klassifikator, der Schutz vor wiederholten Aufrufen und das Turn-Limit melden Scores, und deine Bewertungen gehen ebenfalls dorthin, zusätzlich zu xAI.
- **Tags.** Aufrufe tragen `origin` (`local`, `headless` für `crok -p`, `relay` für Prompts aus Web und Telefonen, `eval` für Experimente) sowie `repo`, `branch` und `user`, den Anmeldenamen des Computers.
- **Guard-Prüfungen im Warnmodus.** Bevor ein Werkzeugaufruf läuft, der etwas ändern kann, und bevor ein Werkzeugergebnis zum Modell zurückgeht, schickt crok es an die Guards des Stacks, die nach Git-Befehlen suchen, die die Historie umschreiben, nach zerstörerischen Shell-Befehlen und nach echten Schlüsseln. crok wartet nie auf die Antwort und blockiert nie einen Aufruf; ein Treffer wird als Warnung im Gespräch festgehalten. `CROK_AGENTO11Y_GUARDS=off` stoppt die Prüfungen.
- **Metriken.** `crok_turns_total`, `crok_tool_runs_total`, `crok_workflow_steps_total` und `crok_guard_checks_total`, mit den Dauern von Turns und Werkzeugen, speisen das Harness-Dashboard des Stacks, seine Alerts und seine SLOs.

Um das Melden abzuschalten, füge `agent_observability = false` unter `[features]` in `~/.crok/config.toml` hinzu oder setze `CROK_AGENT_OBSERVABILITY=0`. Um an deinen eigenen Stack zu melden, schreibe `~/.crok/agento11y.env` mit `crates/codegen/xai-grok-agento11y/setup.sh` aus dem Repository.

### Für Entwickler

- Releases entstehen wie bisher durch `.github/workflows/release.yml`: Wenn ein Pull Request, der `VERSION` erhöht, in `main` gemergt wird, baut, prüft und signiert er jede Datei und veröffentlicht das Release mit den Notes aus `release/notes/v2.0.2/`.
- Der Release-Workflow hat einen neuen Job `eval`, auf den `publish` wartet. Er führt die sieben Smoke-Fälle von `evals/run.py` zweimal gegen den Release-Build aus und schlägt fehl, wenn pass@1 mehr als 0,20 unter `evals/baselines/smoke.json` fällt oder ein Sicherheitsfall fehlschlägt, der immer bestanden hat. Ohne das Secret `CROK_EVAL_OPENROUTER_API_KEY` in der release-Umgebung warnt er und besteht.
- `evals/run.py` führt crok headless über kleine Fixture-Repositorys in drei Suites aus (`s1` Regressionen, `s2` Werkzeugnutzung, `s3` Sicherheit; 22 Fälle) und meldet Erfolgsquoten, Kosten und Verhalten pro Modell und Build. `evals/README.md` beschreibt die Fälle und Prüfungen.
- `observability/agento11y/stack.json` enthält die Evaluatoren, Regeln und Guards des Stacks, und `observability/agento11y/stack.py` wendet sie über die Plugin-API von Agent Observability an, bewertet Gespräche, die vor einer Regel gespeichert wurden, und installiert die Alerts und SLOs.
- Der Sampler meldet jeden Turn, Werkzeuglauf, Schritt, jedes Urteil, jede Bewertung und Guard-Prüfung über `crates/codegen/xai-grok-sampler/src/observe_harness.rs`, und die Bridge hält sie in `crates/codegen/xai-grok-agento11y/bridge/src/harness.ts` fest.
- `sessions:transcript` des Relays liefert einen Bereich der Einträge einer Sitzung, neueste zuerst und ohne den Text von Gedanken und Werkzeugausgaben, für das Transkriptfenster der Telefone (`relay/DESIGN.md` §3). `bridge:setModels` behält bis zu 1.000 Modelle, `devices:models` ist die Liste, die Clients lesen, und croks Viewer fragt sie mit `x.ai/remote/models` ab.
- Die Verbindung zum Relay fasst die wartenden Updates einer Sitzung zu einem Schreibvorgang zusammen (`fold_backlog`), und `relay/scripts/status-e2e.mjs` misst, wie schnell ein Telefon das Ende eines Turns über ein langsames Relay sieht.
- Die OpenRouter-Anfrage passt `max_tokens` an das Kontextfenster abzüglich des geschätzten Prompts an.

### Signatur

2.0.2 ist mit demselben Zertifikat „Crok Code Signing“ signiert wie 2.0.1, 2.0.0, 1.5.2 und 1.5.3. macOS knüpft Datenschutzberechtigungen an die Signatur, sodass das, was du für 2.0.1 erlaubt hast (Bildschirmaufnahme, Bedienungshilfen, Mikrofon, Spracherkennung), für 2.0.2 übernommen wird. Der Build ist nicht notarisiert, daher ist bei einer neuen Installation der Schritt **Dennoch öffnen** oben einmal nötig.

Die Android-App ist mit dem Release-Schlüssel signiert, den 2.0.0 eingeführt hat. Die iOS-App ist nicht signiert, wie unter **Telefon-Apps** erklärt. Die signierte Prüfsummenliste ist etwas anderes: Mit ihr kann die Aktualisierung einen Download prüfen; wie macOS die App behandelt, ändert sie nicht.

### Upgrade von 2.0.1

Verwende **Crok Desktop › Nach Updates suchen…** oder `crok upgrade` im Terminal bei beendeter Crok Desktop App. Dieses Update wird an Ort und Stelle in die installierte `Crok Desktop.app` gemacht, sodass sie ihren Platz im Dock und im Finder behält und keine alte Kopie im Papierkorb zurückbleibt. Es nimmt das Image, das mit demselben SDK gebaut wurde wie die installierte App (macOS26-SDK oder macOS15-SDK), niemals das andere.

Die Anmeldung bei deinen Modellanbietern, deine Einstellungen, deine Aufgaben und das Relay bleiben erhalten: 2.0.2 spricht mit demselben Produktions-Relay wie 2.0.1. Die Telefon-Apps installierst du aus den Dateien dieses Releases, wie oben unter **Telefon-Apps** beschrieben.

### Details

- Enthält crok `{{CROK_VERSION}}`.
- Von GitHub Actions gebaut aus dem Tag `desktop-v2.0.2` bei `{{COMMIT}}` auf `main`. Das Image mit dem macOS 26 SDK wurde mit Xcode {{XCODE26}} und dem macOS {{SDK26}} SDK gebaut, das Image mit dem macOS 15 SDK mit Xcode {{XCODE15}} und dem macOS {{SDK15}} SDK und das eigenständige `crok` mit dem macOS {{TUI_SDK}} SDK.
- Beide Images sind arm64, mit dem Crok-Code-Signing-Zertifikat signiert und nicht notarisiert, und beide laufen unter macOS 14 Sonoma oder neuer.
- Die iOS-App (`dev.chenli.crok.mobile`) ist ein Release-Build, erstellt mit Xcode {{XCODE26}}; die Android-App ist ein Release-Build für Android 8.0 oder neuer.
- Die SHA-256-Prüfsummen stehen am Ende dieser Hinweise und in der Datei `SHA256SUMS.txt`, die jetzt auch die Telefon-Apps umfasst. Die Datei `release/README.md` im Repository zeigt, wie sich die Signatur der Liste von Hand prüfen lässt.
