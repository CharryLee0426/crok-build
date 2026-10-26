Crok Desktop 2.0.3 ist die native macOS-App dieses Forks. Sie bringt crok mit, die Agent-Laufzeit und die Terminal-Oberfläche `crok`, sodass nichts weiter zu installieren ist. Sie folgt auf 2.0.2, das das Browser-Werkzeug in dein eigenes Chrome und die Modellauswahl auf jedes Gerät gebracht hat. 2.0.3 hält die Sitzungsliste jedes Geräts aktuell: Eine Sitzung, die auf einem Computer angelegt, umbenannt oder gelöscht wird, erreicht Web, Telefone und die anderen Computer in etwa einer halben Minute. Eine Sitzung, die vom Web oder von einem Telefon aus auf einem Computer gestartet wird, erscheint jetzt auch auf diesem Computer, als Aufgabe in Crok Desktop und im Remote-Panel des Terminals. Eine neue Sitzung, die mit einem gewählten Modell gestartet wird, startet immer mit diesem Modell, und croks Claude-Aufrufe werden in Agent Observability nicht mehr doppelt gezählt.

Dieses Release wird von GitHub Actions gebaut und veröffentlicht, sobald sein Pull Request gemergt wurde, wie es bei 2.0.2 der Fall war.

### Installation

1. Lade das Disk-Image herunter, das zu deiner macOS-Version passt, und öffne es. Welches das ist, zeigt die Tabelle unter **Welches Disk-Image laden**.
2. Ziehe **Crok Desktop** auf **Programme**.
3. Öffne Crok Desktop aus dem Ordner „Programme“. Dieser Build ist nicht notarisiert, also nicht von Apple beglaubigt. Beim ersten Start meldet macOS deshalb, dass es die App nicht überprüfen kann: Klicke auf **Fertig**, öffne **Systemeinstellungen › Datenschutz & Sicherheit**, klicke neben der Meldung zu Crok Desktop auf **Dennoch öffnen** und bestätige. Das ist nur einmal nötig.
4. Melde dich unter **Einstellungen › Accounts** an: mit OpenRouter, OpenAI Codex, einem Anthropic-API-Schlüssel, einem DeepSeek-API-Schlüssel oder einem Schlüssel für den GLM Coding Plan.

Erfordert macOS 14 Sonoma oder neuer auf einem Mac mit Apple Chip (M1 oder neuer).

### Welches Disk-Image laden

Beide Images sind Crok Desktop 2.0.3 und enthalten dieselben Funktionen. Sie unterscheiden sich nur im macOS-SDK, mit dem sie gebaut wurden. Es entscheidet, ob der Fensterrahmen Apples Liquid Glass verwendet:

| Disk-Image | Gebaut mit | Geeignet für | Titelleiste |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.3-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 und neuer | Liquid Glass |
| `Crok-Desktop-2.0.3-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 und 15 | Milchglas-Unschärfe innerhalb des Fensters |

Nimm unter macOS 26 und neuer das Image mit dem macOS 26 SDK, um die Titelleiste in Liquid Glass zu bekommen. Nimm unter macOS 14 oder 15 das Image mit dem macOS 15 SDK. Es läuft auch auf neueren Versionen und ist deshalb die sichere Wahl, wenn du nicht weißt, welches macOS du hast.

`crok-2.0.3-aarch64-apple-darwin.tar.gz` ist die Terminal-Oberfläche `crok` für sich allein, für einen Mac, auf dem du die App nicht haben möchtest: Entpacke das Archiv und lege `crok` in deinen `PATH`. Die Apps für Telefone sind unter **Telefon-Apps** beschrieben. `SHA256SUMS.txt` listet die SHA-256-Prüfsummen aller Downloads auf, und `SHA256SUMS.txt.sig` ist die Signatur dieser Liste, die die Aktualisierung prüft.

### Telefon-Apps

Die Crok-App für iPhone und Android verfolgt die Sitzungen deiner Computer, zeigt ihre Antworten und Berechtigungsanfragen und startet oder steuert Aufgaben von überall aus. Sie kommt mit diesem Release, wie sie mit 2.0.2 kam, und funktioniert wie die von 2.0.2: Die Änderungen dieses Releases liegen auf den Computern und im Relay, sodass auch Telefon-Apps von 2.0.2 und 2.0.1 sie bekommen. Alle drei Dateien melden sich beim Produktions-Relay an.

- **Android 8.0 oder neuer:** Lade `Crok-Android-2.0.3.apk` auf dem Telefon herunter und öffne es (erlaube deinem Browser, Apps zu installieren, wenn Android danach fragt), oder führe `adb install -r Crok-Android-2.0.3.apk` aus. Das APK ist mit dem Release-Schlüssel signiert, den auch spätere Releases behalten, sodass sich das nächste APK darüber installieren lässt. Ein Crok-APK, das du selbst gebaut hast, ist mit einem anderen Schlüssel signiert und verhindert die Installation: Entferne es zuerst mit `adb uninstall dev.chenli.crok.mobile` oder in den Einstellungen des Telefons.
- **iPhone und iPad, iOS 17 oder neuer:** `Crok-iOS-2.0.3-unsigned.ipa` ist nicht signiert, weil eine App für iOS-Geräte mit der Apple-ID derjenigen Person signiert wird, die sie installiert. Installiere sie mit einem Sideloading-Tool wie AltStore oder Sideloadly, das sie mit deiner Apple-ID signiert. Mit einer kostenlosen Apple-ID öffnet iOS die App nach 7 Tagen nicht mehr, bis du sie erneut installierst. Um sie stattdessen selbst zu bauen, verwende die Konfiguration **Release**: Der Run-Button in Xcode baut Debug, und ein Debug-Build meldet sich beim Test-Relay an.
- **iOS-Simulator:** `Crok-iOS-2.0.3-Simulator.zip` ergibt entpackt `Crok.app`, zur Installation mit `xcrun simctl install booted Crok.app` auf einem Mac mit Xcode.

Um das Telefon anzumelden, tippe auf **Weiter mit GitHub oder Google**, melde dich auf der Seite an, die sich unter https://crok.chenli.dev öffnet, und tippe auf **Genehmigen**. Verknüpfe dann jeden Computer: Führe dort `crok remote login` aus und scanne den angezeigten QR-Code in der App unter **Einstellungen › Computer verknüpfen**, oder genehmige den Computer auf der Webseite, die sich öffnet.

### Neuerungen

- **Die Sitzungsliste jedes Geräts bleibt aktuell.** Eine Sitzung, die sich nur auf der Festplatte eines Computers geändert hat (angelegt von einem crok, das nicht beim Relay angemeldet war, umbenannt oder gelöscht), erreichte Web, Telefone und die anderen Computer bisher erst mit der nächsten vollständigen Liste dieses Computers. Die kam etwa alle 20 Minuten und blieb aus, sobald das crok, das sie schickte, beendet wurde. Jetzt kommt die Änderung in etwa einer halben Minute an, und ein anderes crok auf dem Computer übernimmt die Liste, sobald das erste beendet wird.
- **Sitzungen, die vom Web oder von einem Telefon aus gestartet wurden, erscheinen auf ihrem Computer.** Crok Desktop fügt eine solche Sitzung als ungelesene Aufgabe in ihrem Projekt hinzu und zeigt sie als arbeitend, solange ein Turn läuft. Das Terminal sagt, welches Gerät sie gestartet hat, und listet sie in `/remote` unter **Dieser Computer**.
- **Eine neue Sitzung startet mit dem Modell, das du gewählt hast.** Eine Sitzung, die vom Web oder von einem Telefon aus mit gewähltem Modell und gewählter Denkstufe gestartet wurde, konnte stattdessen mit dem Standard des Computers starten, wenn ein älteres crok auf diesem Computer (etwa ein Terminal, das noch von vor einem Update offen war) sie zuerst übernahm. Jetzt kann sie nur ein crok übernehmen, das die Wahl auch anwendet.
- **Der Bereich Andere Computer füllt sich sofort.** Der Bereich **Andere Computer** in Crok Desktop fragt die Liste jedes Mal neu ab, wenn seine Verbindung zum Relay hergestellt wird, und dann alle 5 Sekunden, bis eine Antwort da ist, statt bis zu 4 Minuten zu warten.
- **Claude-Aufrufe werden nur einmal an Agent Observability gemeldet.** Der eigene Telemetrie-Export von Claude Platform speicherte eine zweite Kopie jedes Claude-Aufrufs, den crok meldete. Jetzt bittet crok die API von Anthropic, die Aufrufe, die es selbst meldet, nicht zu exportieren. Siehe **Agent Observability** weiter unten.

### Fernsteuerung

Jedes crok dieses Releases meldet sich wie 2.0.2 beim Produktions-Relay unter https://crok.chenli.dev an und behält die Anmeldung, die es schon hat. Das Produktions-Relay läuft bereits mit den Relay-Änderungen dieses Releases, sodass die unten beschriebene Regel für ein gewähltes Modell schon heute gilt; der Rest kommt mit crok 2.0.3 auf jedem Computer.

- **Sitzungslisten.** Auf jedem Computer führt ein crok die Liste dieses Computers: Alle 30 Sekunden sieht es sich die Sitzungen auf der Festplatte an und schickt nur, was sich geändert hat, und alle 30 Minuten schickt es die ganze Liste erneut. Wird es beendet oder verliert es seine Verbindung, wird jedes andere crok auf diesem Computer gebeten, die Liste zu übernehmen, und das erste, das antwortet, übernimmt sie. Ein Computer, dessen crok neu startet, listet seine Sitzungen sofort. Computer, auf denen noch crok 2.0.2 oder älter läuft, schicken ihre ganze Liste weiter selbst, jetzt alle 10 Minuten statt etwa alle 20.
- **Anderswo gestartete Sitzungen in Crok Desktop.** Eine Sitzung, die ein anderes Gerät auf diesem Mac gestartet hat, wird zu einer Aufgabe ihres Projekts, sobald das Relay sie listet, samt Projekt, wenn die App für diesen Ordner noch keines hat. Die Aufgabe ist ungelesen, übernimmt den Titel der Sitzung, bis du sie öffnest, erscheint als arbeitend, solange dort ein Turn läuft, und als ungelesen, wenn er endet, und öffnet sich wie jede andere Aufgabe. Jede solche Sitzung wird nur einmal hinzugefügt, sodass eine Aufgabe oder ein Projekt, das du entfernt hast, nicht zurückkommt.
- **Anderswo gestartete Sitzungen im Terminal.** Solange das Terminal mit dem Relay verbunden ist, meldet es jede Sitzung, die ein anderes Gerät auf diesem Computer startet, zum Beispiel „iPhone hat eine Sitzung in app gestartet: … — öffne sie mit /resume oder /remote“. Das Remote-Panel listet diese Sitzungen zuerst, unter **Dieser Computer**, jede mit dem Gerät markiert, von dem sie kam („von iPhone“). Enter öffnet eine davon hier, und `n` auf diesem Computer verweist auf `/new`.
- **Das gewählte Modell.** Eine neue Sitzung mit Modell oder Denkstufe geht nur an ein crok, das diese Wahl anwendet: crok 2.0.1 und neuer. Auf einem Computer, auf dem nur crok 2.0.0 oder älter läuft, schlägt der Start einer solchen Sitzung mit „Update crok on … to start a session there with a chosen model or thinking level“ fehl (sinngemäß: Aktualisiere crok auf …, um dort eine Sitzung mit gewähltem Modell oder gewählter Denkstufe zu starten), statt mit dem Standard zu starten. Eine Sitzung mit **Standard** startet weiterhin auf jedem crok. Ein Prompt oder ein erneuter Versuch, der eine Sitzung wieder öffnet, deren Start fehlgeschlagen ist, folgt derselben Regel.
- **Aktualisiere die Computer.** Listen, die mit der Festplatte Schritt halten, und Sitzungen anderer Geräte, die auf ihrem Computer erscheinen, kommen mit crok 2.0.3 auf diesem Computer. Auf den Telefonen ändert sich nichts.

### Agent Observability

Wie in 2.0.2 meldet jedes crok dieses Releases jeden Modellaufruf, den es macht, mit seinen Turns, Werkzeugläufen, Schritten und Guard-Prüfungen an [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) auf dem Grafana-Cloud-Stack des Maintainers, und `crok version --json` zeigt den Host unter `agentObservability`.

- **Keine zweite Kopie von Claude-Aufrufen.** Eine Organisation auf Claude Platform kann für jede API-Anfrage einen Trace-Span an ihre Telemetrie-Ziele exportieren, und Agent Observability machte aus jedem davon ein eigenes Gespräch, benannt nach seiner Trace-ID, unter dem Agent `claude-platform`. So wurde jeder Claude-Aufruf, den crok meldete, doppelt gespeichert. Jetzt schickt crok die Aufrufe, die es meldet, mit einem als nicht gesampelt markierten Trace-Kontext an `api.anthropic.com`, und die API von Anthropic exportiert daraufhin nichts für sie. Aufrufe, die crok nicht meldet (Kompaktierungen und jeder Aufruf, solange das Melden aus ist), werden wie bisher exportiert, ebenso Aufrufe an andere Anbieter.
- **Wenn deine Organisation Claude-Telemetrie exportiert,** sind die Claude-Aufrufe, die crok an Agent Observability meldet, nicht mehr in diesem Export; schalte das Melden ab, um sie dort wieder zu haben.
- **Die Dashboards zählen croks Claude-Aufrufe anstelle derer von Claude Platform.** croks Span eines solchen Aufrufs trägt `crok.unsampled = true` und führt seine Cache-Lesevorgänge und Thinking-Tokens unter den Attributnamen von Claude Platform, sodass die LLM-Observability-Dashboards ihn einmal zählen. Aufrufe von crok 2.0.2 und älter werden weiter aus dem Export von Claude Platform gezählt.
- **Bereits gespeicherte Kopien sind markiert.** Agent Observability kann nicht löschen, was es gespeichert hat, deshalb ist jede der 586 Kopien, die durch crok 1.5.0 bis 2.0.2 entstanden sind, als Kopie eines Aufrufs von crok gekennzeichnet. So lässt sie sich von Aufrufen unterscheiden, die nur Claude Platform gesehen hat. Jeder Computer, auf dem noch crok 2.0.2 oder älter läuft, fügt weiter Kopien hinzu, bis er aktualisiert ist.

Um das Melden abzuschalten, füge `agent_observability = false` unter `[features]` in `~/.crok/config.toml` hinzu oder setze `CROK_AGENT_OBSERVABILITY=0`. Um an deinen eigenen Stack zu melden, schreibe `~/.crok/agento11y.env` mit `crates/codegen/xai-grok-agento11y/setup.sh` aus dem Repository.

### Für Entwickler

- Releases entstehen wie bisher durch `.github/workflows/release.yml`: Wenn ein Pull Request, der `VERSION` erhöht, in `main` gemergt wird, baut, prüft und signiert er jede Datei, führt das Eval-Gate aus und veröffentlicht das Release mit den Notes aus `release/notes/v2.0.3/`.
- Das Relay führt pro Computer einen Katalog-Halter: `bridge:catalogUpdate` nimmt die Änderungen des Halters seit seinem letzten Upload entgegen (`EXPIRED`, sobald ein anderer Prozess ihn hält), ein freigegebener Katalog legt `catalogWanted` in die Inbox jedes crok auf diesem Computer, und `bridge:connect` listet `catalog`. `sessions:create` speichert `startedFrom` (`{kind: phone | web | computer, name, at}`), und `x.ai/remote/sessions` des Viewers trägt `here`, die anderswo gestarteten Sitzungen dieses Computers (die neuesten 100). `relay/DESIGN.md` beschreibt das in §2–§5.
- Ein `create` mit Modell oder Denkstufe wird nur Hosts angeboten, deren `features` `setup` (crok 2.0.3 listet es) oder `git` (crok 2.0.1 und 2.0.2) enthalten.
- `relay/scripts/sessions-live-e2e.mjs` prüft zwei Computer und ein Telefon gegen ein lokales Relay: sofort gelistete laufende Sitzungen, auf der Festplatte angelegte und gelöschte Sitzungen, das Beenden des Halters und die Sitzung eines Telefons, die das eigene Frontend des Computers erreicht. `commands-e2e` und `bridge-e2e` prüfen jetzt, wo eine Sitzung mit gewähltem Modell startet und mit welchem Modell ihr erster Turn lief.
- Debug-Builds der Telefon-Apps haben einen dritten Tab, **o11y**, rechts von **Profil**: die Grafana-Cloud-Dashboards, Evaluierungen und Agent Observability des Eigentümers als Telefonseiten, gebaut vom Relay (`o11y:page`, `o11y:refresh`; `mobile/DESIGN.md` „o11y“, `relay/DESIGN.md` §3). Release-Builds, auch die dieses Releases, haben ihn nicht, und im Produktions-Relay ist er abgeschaltet. `relay/scripts/o11y-setup.sh` legt das Dienstkonto mit reinem Lesezugriff und die Variablen des Deployments an, `o11y-preview.mjs` baut die Seiten ohne Relay, und `o11y-demo.mjs` erstellt die Demoseiten der Telefone.
- `observability/agento11y/stack.py duplicates [--label]` findet die Kopien, die Claude Platform von croks Aufrufen gemacht hat, anhand der Response-ID und kennzeichnet jede, und `gcx_api` fragt gcx jetzt nach reinem JSON, sodass `backfill` lange Gespräche nicht mehr überspringt.

### Signatur

2.0.3 ist mit demselben Zertifikat „Crok Code Signing“ signiert wie 2.0.2, 2.0.1, 2.0.0, 1.5.2 und 1.5.3. macOS knüpft Datenschutzberechtigungen an die Signatur, sodass das, was du für 2.0.2 erlaubt hast (Bildschirmaufnahme, Bedienungshilfen, Mikrofon, Spracherkennung), für 2.0.3 übernommen wird. Der Build ist nicht notarisiert, daher ist bei einer neuen Installation der Schritt **Dennoch öffnen** oben einmal nötig.

Die Android-App ist mit dem Release-Schlüssel signiert, den 2.0.0 eingeführt hat. Die iOS-App ist nicht signiert, wie unter **Telefon-Apps** erklärt. Die signierte Prüfsummenliste ist etwas anderes: Mit ihr kann die Aktualisierung einen Download prüfen; wie macOS die App behandelt, ändert sie nicht.

### Upgrade von 2.0.2

Verwende **Crok Desktop › Nach Updates suchen…** oder `crok upgrade` im Terminal bei beendeter Crok Desktop App. Dieses Update wird an Ort und Stelle in die installierte `Crok Desktop.app` gemacht, sodass sie ihren Platz im Dock und im Finder behält und keine alte Kopie im Papierkorb zurückbleibt. Es nimmt das Image, das mit demselben SDK gebaut wurde wie die installierte App (macOS26-SDK oder macOS15-SDK), niemals das andere.

Die Anmeldung bei deinen Modellanbietern, deine Einstellungen, deine Aufgaben und das Relay bleiben erhalten: 2.0.3 spricht mit demselben Produktions-Relay wie 2.0.2. Aktualisiere jeden Computer, den du mit dem Relay nutzt, damit seine Sitzungen überall aktuell bleiben. Die Telefon-Apps brauchen kein Update, wie oben unter **Telefon-Apps** steht.

### Details

- Enthält crok `{{CROK_VERSION}}`.
- Von GitHub Actions gebaut aus dem Tag `desktop-v2.0.3` bei `{{COMMIT}}` auf `main`. Das Image mit dem macOS 26 SDK wurde mit Xcode {{XCODE26}} und dem macOS {{SDK26}} SDK gebaut, das Image mit dem macOS 15 SDK mit Xcode {{XCODE15}} und dem macOS {{SDK15}} SDK und das eigenständige `crok` mit dem macOS {{TUI_SDK}} SDK.
- Beide Images sind arm64, mit dem Crok-Code-Signing-Zertifikat signiert und nicht notarisiert, und beide laufen unter macOS 14 Sonoma oder neuer.
- Die iOS-App (`dev.chenli.crok.mobile`) ist ein Release-Build, erstellt mit Xcode {{XCODE26}}; die Android-App ist ein Release-Build für Android 8.0 oder neuer.
- Die SHA-256-Prüfsummen stehen am Ende dieser Hinweise und in der Datei `SHA256SUMS.txt`, die auch die Telefon-Apps umfasst. Die Datei `release/README.md` im Repository zeigt, wie sich die Signatur der Liste von Hand prüfen lässt.
