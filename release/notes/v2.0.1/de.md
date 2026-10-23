Crok Desktop 2.0.1 ist die native macOS-App dieses Forks. Sie enthält crok, also die Laufzeit des Agenten und die Terminal-Oberfläche `crok`, sodass nichts weiter installiert werden muss. Sie folgt auf 2.0.0, das Release, das der Fernsteuerung ein eigenes Produktions-Relay unter https://crok.chenli.dev gab und erstmals die Apps für iOS und Android mitbrachte. 2.0.1 ist das Release der Arbeit, die darauf folgt. Beide Telefon-Apps sind um Computer, Projekte und Themen neu gestaltet; eine Sitzung eines anderen Computers zeigt in Crok Desktop ihren Branch und ihre Token-Zahlen, und ihr Git Graph liest das Repository dieses Computers; eine Remote-Sitzung kann mit gewähltem Modell und Denk-Level starten; und Agent Observability bepreist Aufrufe von Codex, GLM und DeepSeek.

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

**Die Telefon-Apps sind neu gestaltet.** Ein verknüpfter Computer ist ein Konto, ein Projekt ist eine Gruppe mit Themen, und eine Sitzung ist ein Thema darin. Der Tab **Sitzungen** zeigt die Projekte des ausgewählten Computers und öffnet ihre Themen, **Profil** ersetzt **Einstellungen**, **Archivierte Sitzungen** hat einen eigenen Bildschirm, und **Darstellung** bietet Telegrams Chat-Themes oder ein Foto. Der nächste Abschnitt beschreibt das Design, das beide Apps teilen.

### Telefone: Computer, Projekte und Themen

Beide Telefon-Apps folgen jetzt demselben Design nach dem Vorbild von Telegram, und es ersetzt die Sitzungsliste, die 2.0.0 mitbrachte. Auf iOS und Android ist es gleich.

- **Zwei Tabs: Sitzungen und Profil.** Das Symbol des Profil-Tabs ist das Bild des Relay-Kontos, und sein Badge zählt ungelesene Sitzungen der anderen Computer. Ein langer Druck auf **Sitzungen** bietet **Alle als gelesen markieren**; ein langer Druck auf **Profil** öffnet die Computer-Auswahl, ebenso der Titel von Sitzungen.
- **Der Tab Sitzungen zeigt einen Computer.** Die Projekte des ausgewählten Computers erscheinen als Forum-Zeilen: ein abgerundetes quadratisches Avatar, die neuesten Thementitel, ob er arbeitet, eine Freigabe braucht oder was die letzte Antwort ankündigt, und seine ungelesene Summe. Die Auswahl wird auf dem Telefon gemerkt; ein neues Telefon startet mit dem zuletzt aktiven Computer.
- **Ein Projekt ist eine Gruppe mit Themen.** Beim Öffnen eines Projekts erscheinen seine Sitzungen als Themenzeilen, jede mit einem farbigen Themensymbol, Titel, Uhrzeit, Ordner, Vorschau und Ungelesen-Badge. Der Projektbildschirm bietet Suche, **Alle als gelesen markieren**, **Neu anordnen**, **Nach letzter Aktivität sortieren** und einen Schreiben-Button; Wischen über ein Thema heftet es an oder archiviert es, und ein langer Druck bietet Anheften, Stopp, Als gelesen markieren, Archivieren, Nach oben und Nach unten.
- **Archivierte Sitzungen.** Eine Zeile oben im Tab Sitzungen öffnet das Archiv des ausgewählten Computers. Wische eine Sitzung nach links, um sie zu archivieren; auf dem Archivbildschirm hebst du sie auf dieselbe Weise auf.
- **Profil ist die Kontoseite.** Sie zeigt Bild, Name und E-Mail des Kontos, dann jeden Computer mit Ungelesen-Badge und einem Häkchen am ausgewählten, **Computer verknüpfen**, **Geräte**, **Darstellung**, **Sprache**, **Version**, die GitHub- und X-Links des Entwicklers und **Abmelden**.
- **Darstellung enthält Telegrams Chat-Themes.** Eine Vorschau und eine Kartenreihe bieten **Kein Design**, **Klassisch** und neun Emoji-Themes (Zuhause, Küken, Schneemann, Diamant, Lehrer, Tulpe, Lila Herz, Weihnachtsbaum und Videospiel), jeweils hell und dunkel, oder ein Foto aus der Bibliothek mit **Weichzeichnen**. Ein Theme legt den Sitzungshintergrund und die eigenen Sprechblasen fest; die Blasen des Agenten bleiben unverändert. **Farbmodus** bleibt System, Hell oder Dunkel.
- **Jede App spricht sechs Sprachen.** Jeder neue Bildschirm und jeder neue Text ist auf Englisch, 简体中文, 日本語, Español, Français und Deutsch verfügbar.

### Neuerungen

- **Die Telefon-Apps sind neu gestaltet.** Ein Computer ist ein Konto, ein Projekt ist eine Gruppe mit Themen, und eine Sitzung ist ein Thema. Der Tab Sitzungen zeigt den ausgewählten Computer, Profil ersetzt Einstellungen, und Sitzungen können Telegrams Chat-Themes tragen. Siehe **Telefone: Computer, Projekte und Themen** oben.
- **Branch und Token eines anderen Computers stehen in der Fußzeile des Composers.** In einer Aufgabe aus **Andere Computer** zeigt Crok Desktop den Branch, die Eingabe- und Ausgabe-Token, die Cache-Rate und die Ausgabegeschwindigkeit, die dieser Computer zuletzt gemeldet hat; sie aktualisieren sich am Ende eines Durchgangs dort.
- **Git Graph und die Branch-Auswahl arbeiten mit dem Repository dieses Computers.** Sie lesen das Repository über das Relay, und das Wechseln oder Erstellen eines Branches läuft dort und aktualisiert den Branch, den alle Geräte sehen. Der Computer mit der Sitzung braucht dafür crok 2.0.1.
- **Eine Sitzung kann mit dem gewählten Modell starten.** Der Bildschirm für neue Sitzungen in der Web-App listet die Modelle und Denk-Level des Zielcomputers über dem Composer; sein crok wendet sie vor dem ersten Prompt an. **Standard** behält die eigene Wahl des Computers.
- **Agent Observability bepreist die Aufrufe aller Anbieter.** Der Span jedes Aufrufs trägt jetzt seine Kosten in USD, die Herkunft dieser Kosten, sein Backend und ob du ihn abgebrochen hast, sodass Aufrufe von Codex, GLM und DeepSeek ihre Ausgaben zeigen. Die Dashboards erhalten eine Ansicht **Codex, GLM und DeepSeek**, 14 Tage Verlauf und Vergleiche von Woche zu Woche.
- **Kleinere Korrekturen in Crok Desktop und crok.** Der erste Titel einer Sitzung nutzt jetzt das Modell, das sie gerade ausführt, auch nach einem Wechsel vor dem ersten Prompt; beginnt ein Durchgang, während eine Aufgabe noch verbindet, wird das gemeldet, statt eine zweite Verbindung zu öffnen.
- **Updates werden in die vorhandene App installiert.** Ab 2.0.0 legen **Crok Desktop › Nach Updates suchen…** und `crok upgrade` die neue Version in einem Schritt in die installierte `Crok Desktop.app`, sodass sie ihren Platz im Dock und im Finder behält und keine alte Kopie im Papierkorb zurückbleibt. Vor der Installation prüfen sie, ob die neue Version mit demselben Zertifikat signiert ist; genau das erhält die Berechtigungen, die macOS Crok Desktop erteilt hat (Bedienungshilfen, Bildschirmaufnahme, Mikrofon). Ein anders signiertes Release wird abgelehnt, sofern du nicht `crok upgrade --allow-new-signature` ausführst.
- **Der Agent stellt sich als Crok vor.** Der System-Prompt beginnt jetzt bei jedem Anbieter mit „You are Crok.“, während er früher Grok nannte, selbst wenn das Modell Claude, DeepSeek oder GLM war. `agent.system_prompt_label`, `model.<id>.system_prompt_label` und `CROK_SYSTEM_PROMPT_LABEL` legen weiterhin einen anderen Namen fest.

### Fernsteuerung

Jedes crok in diesem Release (die Terminal-Oberfläche, das crok in Crok Desktop und der eigenständige Tarball) meldet sich beim Produktions-Relay an. `crok remote status` zeigt dessen Adresse, `https://tacit-finch-29.convex.cloud`, und `crok version --json` zeigt sie unter `remote`.

- **Starte eine Sitzung mit dem gewünschten Modell und Denk-Level.** Im Web listet der Bildschirm für neue Sitzungen die Modelle und Denk-Level des Zielcomputers über dem Composer, und dieser Computer wendet sie vor dem ersten Prompt an. **Standard** lässt seine eigene Wahl.
- **Eine Aufgabe eines anderen Computers zeigt ihre Zahlen.** Die Fußzeile des Composers zeigt Branch, Eingabe- und Ausgabe-Token, Cache-Rate und Ausgabegeschwindigkeit der Sitzung, wie ihr Computer sie am Ende seines letzten Durchgangs gemeldet hat.
- **Lies und wechsle das Repository eines anderen Computers.** In Crok Desktop lesen **Git Graph** und die Branch-Auswahl einer Aufgabe unter **Andere Computer** das Repository dieses Computers über das Relay; Wechseln oder Erstellen eines Branches läuft dort, und der von einem Befehl ausgecheckte Branch aktualisiert die Sitzungszeile für alle Geräte. Der Computer mit der Sitzung braucht crok 2.0.1; ein älteres crok antwortet, dass es aktualisiert werden muss.
- **Deine Anmeldung aus 2.0.0 bleibt erhalten.** Ein Computer mit 2.0.0 ist beim Produktions-Relay bereits angemeldet, und 2.0.1 nutzt dieselbe Anmeldung: Es gibt keine erneute Anmeldung und keine Datei, die verschoben werden müsste. Die Anmeldung aus 1.5.x hat 2.0.0 einmalig von `~/.crok/remote/credentials.json` nach `~/.crok/remote/credentials-dev.json` verschoben; 2.0.1 lässt beide Dateien dort, wo sie sind.
- **Das Produktions-Relay ist, wo es war.** Dein Konto, deine Geräte, angeheftete und archivierte Sitzungen und die Reihenfolge deiner Projekte liegen im Relay, und 2.0.1 liest sie von dort, sodass beim Aktualisieren nichts übertragen wird.
- **Aktualisiere jeden Computer und jedes Telefon.** Ein Computer mit 1.5.x oder eine Telefon-App, die vor 2.0.0 gebaut wurde, bleibt beim Test-Relay und sieht keine Computer mit 2.0.0 oder neuer.

Ein eigenes Relay, das du mit `[remote] url` oder `CROK_REMOTE_URL` festlegst, funktioniert wie bisher.

### Agent Observability

Wie in 2.0.0 meldet jedes crok in diesem Release jeden Modellaufruf, den es macht, an [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) auf dem Grafana-Cloud-Stack des Maintainers: den Prompt, die Antwort, Tool-Aufrufe, Token-Verbrauch und Zeitangaben, gekennzeichnet mit dem Namen des Computers. `crok version --json` zeigt unter `agentObservability` den Host, an den gemeldet wird. Zum Ausschalten füge `agent_observability = false` unter `[features]` in `~/.crok/config.toml` hinzu oder setze `CROK_AGENT_OBSERVABILITY=0`. Um an deinen eigenen Stack zu melden, schreibe `~/.crok/agento11y.env` mit `crates/codegen/xai-grok-agento11y/setup.sh` aus dem Repository.

Der Span jedes Aufrufs trägt jetzt außerdem `crok.cost.usd`, `crok.cost.source`, `crok.backend` und bei einem von dir unterbrochenen Aufruf `crok.cancelled`. Die Kosten sind die Zahl des Anbieters, wenn er eine meldet, sonst der Standard-API-Preis des Modells für die Token des Aufrufs. Aufrufe von Codex, GLM und DeepSeek werden deshalb bepreist, obwohl diese Anbieter keine Traces exportieren. Die Dashboards enthalten eine Ansicht **Codex, GLM und DeepSeek**, behalten 14 Tage Verlauf und vergleichen jede Woche mit der vorigen.

### Für Entwickler

- Releases entstehen durch `.github/workflows/release.yml`: Wenn ein Pull Request, der `VERSION` anhebt, in `main` gemergt wird, baut der Workflow die TUI, beide Disk-Images und die Telefon-Apps, prüft und signiert sie und veröffentlicht das Release mit den Hinweisen, die in `release/notes/v2.0.1/` eingecheckt sind. `release/ci-secrets.sh` stellt ihm die Signaturschlüssel bereit. `release/README.md` beschreibt das alles.
- Die Release-Runner fügen den importierten Signatur-Schlüsselbund der Suchliste des Benutzer-Schlüsselbunds hinzu und signieren dann vor jedem Build eine Wegwerfkopie von `/usr/bin/true`: `.github/scripts/release/import-codesign.sh` stoppt einen Job in seinem Import-Schritt, wenn `codesign` diesen Schlüsselbund nicht nutzen kann, statt erst nach 46 Minuten Build.
- `.github/workflows/ci.yml` kompiliert bei jedem Pull Request in `main` die TUI, Crok Desktop für beide SDKs, die iOS-App und die Android-App und prüft die Hinweise einer `VERSION`, für die es noch kein Release gibt.
- Beide Telefon-Apps implementieren `mobile/DESIGN.md`, den Vertrag für Computer als Konten, Projekte als Gruppen mit Themen, Profil und Sitzungs-Themes. Er ersetzt den Telefon-Teil von `relay/DESIGN.md` §5; die Web-App behält diesen Teil.
- Das Relay hat zwei Umgebungen, `relay/environments/prod.env` und `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` oder `relay/scripts/deploy.sh test` stellt eine davon bereit, und `make clients-prod` und `make clients-test` bauen zusätzlich die Telefon-Apps dafür. crok legt beim Bauen fest, welches Relay es verwendet, mit `CROK_RELAY_ENV` (prod, sofern es kein Test-Build ist).
- Der Befehlstyp `git` des Relays trägt `commands:git` (`{op: "graph"|"branches"|"files"|"diff"|"workspace"|"workspace_diff"|"signature"|"switch"|"create", …}`) zu jedem crok auf dem Computer der Sitzung, das `git` anbietet, und `bridge:setBranch` hält den Branch fest, den ein Befehl ausgecheckt hat. Die Zeile einer Sitzung trägt jetzt `gitBranch` und `usage`, darunter `outputTokensPerSecond`.
- Die Agent-Observability-Bridge schreibt `crok.cost.usd`, `crok.cost.source`, `crok.backend` und `crok.cancelled` auf jeden Span. `observability/grafana-llm/build_dashboards.py` erzeugt das Dashboard **Codex, GLM und DeepSeek** und die 64 Verlaufsregeln, und `prices.json` enthält die Standard-API-Preise.
- `desktop/macOS/scripts/build-app.sh` baut mit dem nativen Build-System von SwiftPM (`SWIFT_BUILD_SYSTEM` wählt ein anderes), wodurch `SDKROOT` und der SDK-Stempel auch mit Xcode 27 stimmen.
- `mobile/scripts/build-apps.sh --ios-device` fügt ein unsigniertes `.ipa` für Geräte hinzu, und Android-Release-Builds werden mit dem Keystore signiert, den `CROK_ANDROID_KEYSTORE` nennt. Debug-Builds beider Apps tragen ein gelbes Symbol, Release-Builds das blaue.

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
