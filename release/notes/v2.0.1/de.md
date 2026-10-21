Crok Desktop 2.0.1 ist die native macOS-App dieses Forks. Sie enthält crok, also die Laufzeit des Agenten und die Terminal-Oberfläche `crok`, sodass nichts weiter installiert werden muss. Sie folgt auf 2.0.0, das Release, das der Fernsteuerung ein eigenes Produktions-Relay unter https://crok.chenli.dev gab und erstmals die Apps für iOS und Android mitbrachte. 2.0.1 ist das Release der Arbeit, die darauf folgt: die Fehlerbehebungen und Verbesserungen auf Basis von 2.0.0. Die Liste unter **Neuerungen** wächst, sobald diese Arbeit landet.

Dieses Release wird von GitHub Actions gebaut und veröffentlicht, sobald sein Pull Request gemergt wurde, wie es bei 2.0.0 der Fall war.

### Installation

1. Lade das Disk-Image herunter, das zu deiner macOS-Version passt, und öffne es. Welches das ist, zeigt die Tabelle unter **Welches Disk-Image laden**.
2. Ziehe **Crok Desktop** auf **Programme**.
3. Öffne Crok Desktop aus dem Ordner „Programme“. Dieser Build ist nicht notarisiert, also nicht von Apple beglaubigt. Beim ersten Start meldet macOS deshalb, dass es die App nicht überprüfen kann: Klicke auf **Fertig**, öffne **Systemeinstellungen › Datenschutz & Sicherheit**, klicke neben der Meldung zu Crok Desktop auf **Dennoch öffnen** und bestätige. Das ist nur einmal nötig.
4. Melde dich unter **Einstellungen › Accounts** an: mit OpenRouter, OpenAI Codex, einem Anthropic-API-Schlüssel, einem DeepSeek-API-Schlüssel oder einem Schlüssel für den GLM Coding Plan.

Erfordert macOS 14 Sonoma oder neuer auf einem Mac mit Apple Chip (M1 oder neuer).

### Welches Disk-Image laden

Beide Images sind Crok Desktop 2.0.1 und enthalten dieselben Funktionen. Sie unterscheiden sich nur im macOS-SDK, mit dem sie gebaut wurden. Es entscheidet, ob der Fensterrahmen Apples Liquid Glass verwendet:

| Disk-Image | Gebaut mit | Geeignet für | Titelleiste |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.1-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 und neuer | Liquid Glass |
| `Crok-Desktop-2.0.1-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 und 15 | Milchglas-Unschärfe innerhalb des Fensters |

Nimm unter macOS 26 und neuer das Image mit dem macOS 26 SDK, um die Titelleiste in Liquid Glass zu bekommen. Nimm unter macOS 14 oder 15 das Image mit dem macOS 15 SDK. Es läuft auch auf neueren Versionen und ist deshalb die sichere Wahl, wenn du nicht weißt, welches macOS du hast.

`crok-2.0.1-aarch64-apple-darwin.tar.gz` ist die Terminal-Oberfläche `crok` für sich allein, für einen Mac, auf dem du die App nicht haben möchtest: Entpacke das Archiv und lege `crok` in deinen `PATH`. Die Apps für Telefone sind unter **Telefon-Apps** beschrieben. `SHA256SUMS.txt` listet die SHA-256-Prüfsummen aller Downloads auf, und `SHA256SUMS.txt.sig` ist die Signatur dieser Liste, die die Aktualisierung prüft.

### Telefon-Apps

Die Crok-App für iPhone und Android verfolgt die Sitzungen deiner Computer, zeigt ihre Antworten und Berechtigungsanfragen und startet oder steuert Aufgaben von überall aus. Sie kommt mit diesem Release, wie sie mit 2.0.0 kam. Alle drei Dateien melden sich beim Produktions-Relay an.

- **Android 8.0 oder neuer:** Lade `Crok-Android-2.0.1.apk` auf dem Telefon herunter und öffne es (erlaube deinem Browser, Apps zu installieren, wenn Android danach fragt), oder führe `adb install -r Crok-Android-2.0.1.apk` aus. Das APK ist mit dem Release-Schlüssel signiert, den auch spätere Releases behalten, sodass sich das nächste APK darüber installieren lässt. Ein Crok-APK, das du selbst gebaut hast, ist mit einem anderen Schlüssel signiert und verhindert die Installation: Entferne es zuerst mit `adb uninstall dev.chenli.crok.mobile` oder in den Einstellungen des Telefons.
- **iPhone und iPad, iOS 17 oder neuer:** `Crok-iOS-2.0.1-unsigned.ipa` ist nicht signiert, weil eine App für iOS-Geräte mit der Apple-ID derjenigen Person signiert wird, die sie installiert. Installiere sie mit einem Sideloading-Tool wie AltStore oder Sideloadly, das sie mit deiner Apple-ID signiert. Mit einer kostenlosen Apple-ID öffnet iOS die App nach 7 Tagen nicht mehr, bis du sie erneut installierst. Um sie stattdessen selbst zu bauen, verwende die Konfiguration **Release**: Der Run-Button in Xcode baut Debug, und ein Debug-Build meldet sich beim Test-Relay an.
- **iOS-Simulator:** `Crok-iOS-2.0.1-Simulator.zip` ergibt entpackt `Crok.app`, zur Installation mit `xcrun simctl install booted Crok.app` auf einem Mac mit Xcode.

Um das Telefon anzumelden, tippe auf **Weiter mit GitHub oder Google**, melde dich auf der Seite an, die sich unter https://crok.chenli.dev öffnet, und tippe auf **Genehmigen**. Verknüpfe dann jeden Computer: Führe dort `crok remote login` aus und scanne den angezeigten QR-Code in der App unter **Einstellungen › Computer verknüpfen**, oder genehmige den Computer auf der Webseite, die sich öffnet.

### Neuerungen

- **2.0.1 ist das Release der Arbeit nach 2.0.0.** Es enthält die Fehlerbehebungen und Verbesserungen, die seit 2.0.0 auf dem Branch `charlie/dev` entstanden sind, und diese Liste wächst mit dieser Arbeit.
- **Der Release-Prozess ist der, den 2.0.0 eingeführt hat.** 2.0.1 wird von derselben GitHub-Actions-Pipeline gebaut, geprüft, signiert und veröffentlicht, und diese Hinweise sind in `release/notes/v2.0.1/` eingecheckt.
- **Das Relay und die Telefon-Apps funktionieren weiter wie bisher.** 2.0.1 meldet sich beim selben Produktions-Relay an, dessen Adresse https://crok.chenli.dev ist, und die Telefon-Apps behalten das Verhalten, das 2.0.0 ihnen gegeben hat. Siehe **Fernsteuerung** unten.
- **Updates werden in die vorhandene App installiert.** Ab 2.0.0 legen **Crok Desktop › Nach Updates suchen…** und `crok upgrade` die neue Version in einem Schritt in die installierte `Crok Desktop.app`, sodass sie ihren Platz im Dock und im Finder behält und keine alte Kopie im Papierkorb zurückbleibt. Vor der Installation prüfen sie, ob die neue Version mit demselben Zertifikat signiert ist; genau das erhält die Berechtigungen, die macOS Crok Desktop erteilt hat (Bedienungshilfen, Bildschirmaufnahme, Mikrofon). Ein anders signiertes Release wird abgelehnt, sofern du nicht `crok upgrade --allow-new-signature` ausführst.
- **Der Agent stellt sich als Crok vor.** Der System-Prompt beginnt jetzt bei jedem Anbieter mit „You are Crok.“, während er früher Grok nannte, selbst wenn das Modell Claude, DeepSeek oder GLM war. `agent.system_prompt_label`, `model.<id>.system_prompt_label` und `CROK_SYSTEM_PROMPT_LABEL` legen weiterhin einen anderen Namen fest.

### Fernsteuerung

Jedes crok in diesem Release (die Terminal-Oberfläche, das crok in Crok Desktop und der eigenständige Tarball) meldet sich beim Produktions-Relay an. `crok remote status` zeigt dessen Adresse, `https://tacit-finch-29.convex.cloud`, und `crok version --json` zeigt sie unter `remote`.

- **Deine Anmeldung aus 2.0.0 bleibt erhalten.** Ein Computer mit 2.0.0 ist beim Produktions-Relay bereits angemeldet, und 2.0.1 nutzt dieselbe Anmeldung: Es gibt keine erneute Anmeldung und keine Datei, die verschoben werden müsste. Die Anmeldung aus 1.5.x hat 2.0.0 einmalig von `~/.crok/remote/credentials.json` nach `~/.crok/remote/credentials-dev.json` verschoben; 2.0.1 lässt beide Dateien dort, wo sie sind.
- **Das Produktions-Relay ist, wo es war.** Dein Konto, deine Geräte, angeheftete und archivierte Sitzungen und die Reihenfolge deiner Projekte liegen im Relay, und 2.0.1 liest sie von dort, sodass beim Aktualisieren nichts übertragen wird.
- **Aktualisiere jeden Computer und jedes Telefon.** Ein Computer mit 1.5.x oder eine Telefon-App, die vor 2.0.0 gebaut wurde, bleibt beim Test-Relay und sieht keine Computer mit 2.0.0 oder neuer.

Ein eigenes Relay, das du mit `[remote] url` oder `CROK_REMOTE_URL` festlegst, funktioniert wie bisher.

### Agent Observability

Wie in 2.0.0 meldet jedes crok in diesem Release jeden Modellaufruf, den es macht, an [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) auf dem Grafana-Cloud-Stack des Maintainers: den Prompt, die Antwort, Tool-Aufrufe, Token-Verbrauch und Zeitangaben, gekennzeichnet mit dem Namen des Computers. `crok version --json` zeigt unter `agentObservability` den Host, an den gemeldet wird. Zum Ausschalten füge `agent_observability = false` unter `[features]` in `~/.crok/config.toml` hinzu oder setze `CROK_AGENT_OBSERVABILITY=0`. Um an deinen eigenen Stack zu melden, schreibe `~/.crok/agento11y.env` mit `crates/codegen/xai-grok-agento11y/setup.sh` aus dem Repository.

### Für Entwickler

- Releases entstehen durch `.github/workflows/release.yml`: Wenn ein Pull Request, der `VERSION` anhebt, in `main` gemergt wird, baut der Workflow die TUI, beide Disk-Images und die Telefon-Apps, prüft und signiert sie und veröffentlicht das Release mit den Hinweisen, die in `release/notes/v2.0.1/` eingecheckt sind. `release/ci-secrets.sh` stellt ihm die Signaturschlüssel bereit. `release/README.md` beschreibt das alles.
- `.github/workflows/ci.yml` kompiliert bei jedem Pull Request in `main` die TUI, Crok Desktop für beide SDKs, die iOS-App und die Android-App und prüft die Hinweise einer `VERSION`, für die es noch kein Release gibt.
- Das Relay hat zwei Umgebungen, `relay/environments/prod.env` und `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` oder `relay/scripts/deploy.sh test` stellt eine davon bereit, und `make clients-prod` und `make clients-test` bauen zusätzlich die Telefon-Apps dafür. crok legt beim Bauen fest, welches Relay es verwendet, mit `CROK_RELAY_ENV` (prod, sofern es kein Test-Build ist).
- `desktop/macOS/scripts/build-app.sh` baut mit dem nativen Build-System von SwiftPM (`SWIFT_BUILD_SYSTEM` wählt ein anderes), wodurch `SDKROOT` und der SDK-Stempel auch mit Xcode 27 stimmen.
- `mobile/scripts/build-apps.sh --ios-device` fügt ein unsigniertes `.ipa` für Geräte hinzu, und Android-Release-Builds werden mit dem Keystore signiert, den `CROK_ANDROID_KEYSTORE` nennt.

### Signatur

2.0.1 ist mit demselben Zertifikat „Crok Code Signing“ signiert wie 2.0.0, 1.5.2 und 1.5.3. macOS knüpft Datenschutzberechtigungen an die Signatur, sodass das, was du für 2.0.0 erlaubt hast (Bildschirmaufnahme, Bedienungshilfen, Mikrofon, Spracherkennung), für 2.0.1 übernommen wird. Der Build ist nicht notarisiert, daher ist bei einer neuen Installation der Schritt **Dennoch öffnen** oben einmal nötig.

Die Android-App ist mit dem Release-Schlüssel signiert, den 2.0.0 eingeführt hat. Die iOS-App ist nicht signiert, wie unter **Telefon-Apps** erklärt. Die signierte Prüfsummenliste ist etwas anderes: Mit ihr kann die Aktualisierung einen Download prüfen; wie macOS die App behandelt, ändert sie nicht.

### Upgrade von 2.0.0

Verwende **Crok Desktop › Nach Updates suchen…** oder `crok upgrade` im Terminal bei beendeter Crok Desktop App. Dieses Update wird an Ort und Stelle in die installierte `Crok Desktop.app` gemacht, sodass sie ihren Platz im Dock und im Finder behält und keine alte Kopie im Papierkorb zurückbleibt. Es nimmt das Image, das mit demselben SDK gebaut wurde wie die installierte App (macOS26-SDK oder macOS15-SDK), niemals das andere.

Die Anmeldung bei deinen Modellanbietern, deine Einstellungen, deine Aufgaben und das Relay bleiben erhalten: 2.0.1 spricht mit demselben Produktions-Relay wie 2.0.0. Die Telefon-Apps installierst du aus den Dateien dieses Releases, wie oben unter **Telefon-Apps** beschrieben.

### Details

- Enthält crok `{{CROK_VERSION}}`.
- Von GitHub Actions gebaut aus dem Tag `desktop-v2.0.1` bei `{{COMMIT}}` auf `main`. Das Image mit dem macOS 26 SDK wurde mit Xcode {{XCODE26}} und dem macOS {{SDK26}} SDK gebaut, das Image mit dem macOS 15 SDK mit Xcode {{XCODE15}} und dem macOS {{SDK15}} SDK und das eigenständige `crok` mit dem macOS {{TUI_SDK}} SDK.
- Beide Images sind arm64, mit dem Crok-Code-Signing-Zertifikat signiert und nicht notarisiert, und beide laufen unter macOS 14 Sonoma oder neuer.
- Die iOS-App (`dev.chenli.crok.mobile`) ist ein Release-Build, erstellt mit Xcode {{XCODE26}}; die Android-App ist ein Release-Build für Android 8.0 oder neuer.
- Die SHA-256-Prüfsummen stehen am Ende dieser Hinweise und in der Datei `SHA256SUMS.txt`, die jetzt auch die Telefon-Apps umfasst. Die Datei `release/README.md` im Repository zeigt, wie sich die Signatur der Liste von Hand prüfen lässt.
