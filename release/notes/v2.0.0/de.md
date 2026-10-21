Crok Desktop 2.0.0 ist die native macOS-App dieses Forks. Sie enthält crok, also die Laufzeit des Agenten und die Terminal-Oberfläche `crok`, sodass nichts weiter installiert werden muss. Dieses Release gibt der Fernsteuerung ein eigenes Produktions-Relay unter https://crok.chenli.dev und enthält zum ersten Mal die Apps für iOS und Android. Antworten im Web und auf Telefonen werden jetzt als vollständiges Markdown dargestellt. Updates werden in die App installiert, die du bereits hast, und wenn du das Fenster schließt, läuft Crok Desktop weiter. Wegen des neuen Relays muss sich jeder Computer und jedes Telefon noch einmal bei der Fernsteuerung anmelden: **Fernsteuerung** unten beschreibt, wie.

Es ist außerdem das erste Release, das von GitHub Actions gebaut und veröffentlicht wurde, sobald sein Pull Request gemergt war.

### Installation

1. Lade das Disk-Image herunter, das zu deiner macOS-Version passt, und öffne es. Welches das ist, zeigt die Tabelle unter **Welches Disk-Image laden**.
2. Ziehe **Crok Desktop** auf **Programme**.
3. Öffne Crok Desktop aus dem Ordner „Programme“. Dieser Build ist nicht notarisiert, also nicht von Apple beglaubigt. Beim ersten Start meldet macOS deshalb, dass es die App nicht überprüfen kann: Schließe die Meldung, öffne **Systemeinstellungen › Datenschutz & Sicherheit**, klicke neben der Meldung zu Crok Desktop auf **Dennoch öffnen** und bestätige. Das ist nur einmal nötig.
4. Melde dich unter **Einstellungen › Accounts** an: mit OpenRouter, OpenAI Codex, einem Anthropic-API-Schlüssel, einem DeepSeek-API-Schlüssel oder einem Schlüssel für den GLM Coding Plan.

Erfordert macOS 14 Sonoma oder neuer auf einem Mac mit Apple Chip (M1 oder neuer).

### Welches Disk-Image laden

Beide Images enthalten Crok Desktop 2.0.0 mit denselben Funktionen. Sie unterscheiden sich nur im macOS-SDK, mit dem sie gebaut wurden. Es entscheidet, ob der Fensterrahmen Apples Liquid Glass verwendet:

| Disk-Image | Gebaut mit | Geeignet für | Titelleiste |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.0-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 und neuer | Liquid Glass |
| `Crok-Desktop-2.0.0-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 und 15 | Milchglas-Unschärfe innerhalb des Fensters |

Nimm unter macOS 26 und neuer das Image mit dem macOS 26 SDK, um die Titelleiste in Liquid Glass zu bekommen. Nimm unter macOS 14 oder 15 das Image mit dem macOS 15 SDK. Es läuft auch auf neueren Versionen und ist deshalb die sichere Wahl, wenn du nicht weißt, welches macOS du hast.

`crok-2.0.0-aarch64-apple-darwin.tar.gz` ist die Terminal-Oberfläche `crok` für sich allein, für einen Mac, auf dem du die App nicht haben möchtest: Entpacke das Archiv und lege `crok` in deinen `PATH`. Die Apps für Telefone sind unter **Telefon-Apps** beschrieben. `SHA256SUMS.txt` listet die SHA-256-Prüfsummen aller Downloads auf, und `SHA256SUMS.txt.sig` ist die Signatur dieser Liste, die die Aktualisierung prüft.

### Telefon-Apps

Die Crok-App für iPhone und Android verfolgt die Sitzungen deiner Computer, zeigt ihre Antworten und Berechtigungsanfragen und startet oder steuert Aufgaben von überall aus. Bisher hast du sie selbst aus dem Repository gebaut; dieses Release enthält sie. Alle drei Dateien melden sich beim Produktions-Relay an.

- **Android 8.0 oder neuer:** Lade `Crok-Android-2.0.0.apk` auf dem Telefon herunter und öffne es (erlaube deinem Browser, Apps zu installieren, wenn Android danach fragt), oder führe `adb install -r Crok-Android-2.0.0.apk` aus. Das APK ist mit dem Release-Schlüssel signiert, den auch spätere Releases behalten, sodass sich das nächste APK darüber installieren lässt. Ein Crok-APK, das du selbst gebaut hast, ist mit einem anderen Schlüssel signiert und verhindert die Installation: Entferne es zuerst mit `adb uninstall dev.chenli.crok.mobile` oder in den Einstellungen des Telefons.
- **iPhone und iPad, iOS 17 oder neuer:** `Crok-iOS-2.0.0-unsigned.ipa` ist nicht signiert, weil eine App für iOS-Geräte mit der Apple-ID derjenigen Person signiert wird, die sie installiert. Installiere sie mit einem Sideloading-Tool wie AltStore oder Sideloadly, das sie mit deiner Apple-ID signiert. Mit einer kostenlosen Apple-ID öffnet iOS die App nach 7 Tagen nicht mehr, bis du sie erneut installierst. Um sie stattdessen selbst zu bauen, verwende die Konfiguration **Release**: Der Run-Button in Xcode baut Debug, und ein Debug-Build meldet sich beim Test-Relay an.
- **iOS-Simulator:** `Crok-iOS-2.0.0-Simulator.zip` ergibt entpackt `Crok.app`, zur Installation mit `xcrun simctl install booted Crok.app` auf einem Mac mit Xcode.

Um das Telefon anzumelden, tippe auf **Weiter mit GitHub oder Google**, melde dich auf der Seite an, die sich unter https://crok.chenli.dev öffnet, und tippe auf **Genehmigen**. Verknüpfe dann jeden Computer: Führe dort `crok remote login` aus und scanne den angezeigten QR-Code in der App unter **Einstellungen › Computer verknüpfen**, oder genehmige den Computer auf der Webseite, die sich öffnet.

### Neuerungen

- **Die Fernsteuerung hat ein Produktions-Relay.** Releases melden sich jetzt bei ihrem eigenen Relay an, dessen Web-App unter https://crok.chenli.dev liegt. Das Relay, das 1.5.1 bis 1.5.3 verwendet haben, mit seiner Web-App unter https://crok-relay.vercel.app, ist jetzt nur noch für Test-Builds da. Zwischen den beiden wird nichts übertragen, daher meldest du dich einmal erneut an. Siehe **Fernsteuerung** unten.
- **Die Telefon-Apps kommen mit dem Release.** Das Android-APK, die unsignierte iOS-App und ein Build für den iOS-Simulator gehören zu den Downloads dieses Releases, gebaut für das Produktions-Relay. Siehe **Telefon-Apps** oben.
- **Antworten werden im Web und auf Telefonen als Markdown dargestellt.** Tabellen, Überschriften, verschachtelte Listen, Aufgabenlisten, Zitate, Links und Codeblöcke werden richtig dargestellt. Code wird in den Farben von GitHub hervorgehoben und hat eine Schaltfläche **Kopieren**. LaTeX-Formeln werden dargestellt, im Fließtext als `$…$` oder `\(…\)` und in einer eigenen Zeile als `$$…$$` oder `\[…\]`; ein Preis wie „$5 und $10“ bleibt Text. Breiter Code, Tabellen und Formeln lassen sich innerhalb der Antwort seitlich scrollen. Bilder werden nie heruntergeladen: Sie erscheinen als Link.
- **Lange Antworten öffnen sich auf Telefonen an ihrem Ende.** Eine Sitzung, deren letzte Antwort höher als der Bildschirm ist, öffnet sich am Ende dieser Antwort, und die Schaltfläche zum Scrollen nach unten erscheint, während du in einer langen Antwort liest. Unter Android ziehen dich neue Nachrichten nicht mehr nach unten, während du liest; das Senden eines Prompts tut es weiterhin. Auf dem iPhone ist dafür iOS 18 nötig.
- **Updates werden in die vorhandene App installiert.** Ab 2.0.0 legen **Crok Desktop › Nach Updates suchen…** und `crok upgrade` die neue Version in einem Schritt in die installierte `Crok Desktop.app`, sodass sie ihren Platz im Dock und im Finder behält und keine alte Kopie im Papierkorb zurückbleibt. Vor der Installation prüfen sie, ob die neue Version mit demselben Zertifikat signiert ist; genau das erhält die Berechtigungen, die macOS Crok Desktop erteilt hat (Bedienungshilfen, Bildschirmaufnahme, Mikrofon). Ein anders signiertes Release wird abgelehnt, sofern du nicht `crok upgrade --allow-new-signature` ausführst.
- **Wenn du das Fenster schließt, läuft Crok Desktop weiter.** Der rote Schließen-Knopf blendet das Fenster jetzt aus, und Aufgaben, Terminals in der Seitenleiste, Browserseiten und dein Entwurf laufen im Hintergrund weiter. **⌘Q** beendet die App. Klicke auf das Symbol im Dock, wähle das Fenster im Menü **Fenster** oder verwende einen Menübefehl wie **Neue Aufgabe**, um das Fenster zurückzuholen.
- **Der Agent stellt sich als Crok vor.** Der System-Prompt beginnt jetzt bei jedem Anbieter mit „You are Crok.“, während er früher Grok nannte, selbst wenn das Modell Claude, DeepSeek oder GLM war. `agent.system_prompt_label`, `model.<id>.system_prompt_label` und `CROK_SYSTEM_PROMPT_LABEL` legen weiterhin einen anderen Namen fest.

### Fernsteuerung

Jedes crok in diesem Release (die Terminal-Oberfläche, das crok in Crok Desktop und der eigenständige Tarball) meldet sich beim Produktions-Relay an. `crok remote status` zeigt dessen Adresse, `https://tacit-finch-29.convex.cloud`, und `crok version --json` zeigt sie unter `remote`.

- **Melde dich auf jedem Computer erneut an.** Führe `crok remote login` aus (oder `/remote login` in der Terminal-Oberfläche), oder verwende in Crok Desktop **Einstellungen › Fernsteuerung › Anmelden…**. Eine Seite öffnet sich unter https://crok.chenli.dev: Melde dich mit GitHub oder Google an und klicke auf **Genehmigen**. Ein Telefon, das bereits angemeldet ist, kann den Computer stattdessen verknüpfen: Scanne den QR-Code in der App unter **Einstellungen › Computer verknüpfen**.
- **Das Produktions-Relay startet leer.** Dein Konto, deine Geräte, angeheftete und archivierte Sitzungen und die Reihenfolge deiner Projekte liegen im Relay. Deshalb legt die erste Anmeldung dort ein neues Konto an, und angeheftete Sitzungen und die Reihenfolge fangen neu an.
- **Deine Anmeldung aus 1.5.x bleibt für die Test-Builds erhalten.** Beim ersten Start von 2.0.0 verschiebt crok sie von `~/.crok/remote/credentials.json` nach `~/.crok/remote/credentials-dev.json`, und der Computer erscheint als abgemeldet, bis du dich erneut anmeldest.
- **Aktualisiere jeden Computer und jedes Telefon.** Ein Computer mit 1.5.x oder eine Telefon-App, die vor diesem Release gebaut wurde, bleibt beim Test-Relay und sieht keine Computer mit 2.0.0.

Ein eigenes Relay, das du mit `[remote] url` oder `CROK_REMOTE_URL` festlegst, funktioniert wie bisher.

### Agent Observability

Wie in 1.5.3 meldet jedes crok in diesem Release jeden Modellaufruf, den es macht, an [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) auf dem Grafana-Cloud-Stack des Maintainers: den Prompt, die Antwort, Tool-Aufrufe, Token-Verbrauch und Zeitangaben, gekennzeichnet mit dem Namen des Computers. `crok version --json` zeigt unter `agentObservability` den Host, an den gemeldet wird. Zum Ausschalten füge `agent_observability = false` unter `[features]` in `~/.crok/config.toml` hinzu oder setze `CROK_AGENT_OBSERVABILITY=0`. Um an deinen eigenen Stack zu melden, schreibe `~/.crok/agento11y.env` mit `crates/codegen/xai-grok-agento11y/setup.sh` aus dem Repository.

### Für Entwickler

- Releases entstehen durch `.github/workflows/release.yml`: Wenn ein Pull Request, der `VERSION` anhebt, in `main` gemergt wird, baut der Workflow die TUI, beide Disk-Images und die Telefon-Apps, prüft und signiert sie und veröffentlicht das Release mit den Hinweisen, die in `release/notes/v2.0.0/` eingecheckt sind. `release/ci-secrets.sh` stellt ihm die Signaturschlüssel bereit. `release/README.md` beschreibt das alles.
- `.github/workflows/ci.yml` kompiliert bei jedem Pull Request in `main` die TUI, Crok Desktop für beide SDKs, die iOS-App und die Android-App und prüft die Hinweise einer `VERSION`, für die es noch kein Release gibt.
- Das Relay hat zwei Umgebungen, `relay/environments/prod.env` und `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` oder `relay/scripts/deploy.sh test` stellt eine davon bereit, und `make clients-prod` und `make clients-test` bauen zusätzlich die Telefon-Apps dafür. crok legt beim Bauen fest, welches Relay es verwendet, mit `CROK_RELAY_ENV` (prod, sofern es kein Test-Build ist).
- `desktop/macOS/scripts/build-app.sh` baut mit dem nativen Build-System von SwiftPM (`SWIFT_BUILD_SYSTEM` wählt ein anderes), wodurch `SDKROOT` und der SDK-Stempel auch mit Xcode 27 stimmen.
- `mobile/scripts/build-apps.sh --ios-device` fügt ein unsigniertes `.ipa` für Geräte hinzu, und Android-Release-Builds werden mit dem Keystore signiert, den `CROK_ANDROID_KEYSTORE` nennt.

### Signatur

2.0.0 ist mit demselben Zertifikat „Crok Code Signing“ signiert wie 1.5.2 und 1.5.3. macOS knüpft Datenschutzberechtigungen an die Signatur, sodass das, was du für 1.5.3 erlaubt hast (Bildschirmaufnahme, Bedienungshilfen, Mikrofon, Spracherkennung), für 2.0.0 übernommen wird. Kommst du von 1.5.1 oder früher, die ad hoc signiert waren, fragt macOS diese Berechtigungen noch einmal an. Wenn die Systemeinstellungen Crok Desktop als eingeschaltet zeigen, während Crok meldet, dass es nicht erlaubt ist, entferne es mit **−** aus der Liste und erlaube es einmal erneut. Der Build ist nicht notarisiert, daher ist bei einer neuen Installation der Schritt **Dennoch öffnen** oben einmal nötig.

Die Android-App ist mit dem Release-Schlüssel signiert, den es erst seit diesem Release gibt. Die iOS-App ist nicht signiert, wie unter **Telefon-Apps** erklärt. Die signierte Prüfsummenliste ist etwas anderes: Mit ihr kann die Aktualisierung einen Download prüfen; wie macOS die App behandelt, ändert sie nicht.

### Upgrade von 1.5.3

Verwende **Crok Desktop › Nach Updates suchen…** oder `crok upgrade` im Terminal bei beendeter Crok Desktop App. Dieses Update erledigt noch die Aktualisierungsfunktion von 1.5.3, die die ganze App ersetzt und die alte als `Crok Desktop 1.5.3.app` in den Papierkorb legt. Leere danach den Papierkorb: Diese Kopie ist eine zweite App mit der Kennung von Crok Desktop. Updates ab 2.0.0 werden direkt in die vorhandene App installiert. Das Update nimmt das Image, das mit demselben SDK gebaut wurde wie die installierte App (macOS26-SDK oder macOS15-SDK), niemals das andere.

Die Anmeldung bei deinen Modellanbietern, Einstellungen und Aufgaben bleiben erhalten. Die Fernsteuerung nicht: Melde dich erneut an, wie unter **Fernsteuerung** oben beschrieben, und installiere die Telefon-Apps aus diesem Release.

### Details

- Enthält crok `{{CROK_VERSION}}`.
- Von GitHub Actions gebaut aus dem Tag `desktop-v2.0.0` bei `{{COMMIT}}` auf `main`. Das Image mit dem macOS 26 SDK wurde mit Xcode {{XCODE26}} und dem macOS {{SDK26}} SDK gebaut, das Image mit dem macOS 15 SDK mit Xcode {{XCODE15}} und dem macOS {{SDK15}} SDK und das eigenständige `crok` mit dem macOS {{TUI_SDK}} SDK.
- Beide Images sind arm64, mit dem Crok-Code-Signing-Zertifikat signiert und nicht notarisiert, und beide laufen unter macOS 14 Sonoma oder neuer.
- Die iOS-App (`dev.chenli.crok.mobile`) ist ein Release-Build, erstellt mit Xcode {{XCODE26}}; die Android-App ist ein Release-Build für Android 8.0 oder neuer.
- Die SHA-256-Prüfsummen stehen am Ende dieser Hinweise und in der Datei `SHA256SUMS.txt`, die jetzt auch die Telefon-Apps umfasst. Die Datei `release/README.md` im Repository zeigt, wie sich die Signatur der Liste von Hand prüfen lässt.
