Crok Desktop 2.0.4 est l'app macOS native de ce fork. Elle intègre crok, l'environnement d'exécution de l'agent et l'interface terminal `crok`, il n'y a donc rien d'autre à installer. Elle suit la 2.0.3, qui a tenu à jour la liste des sessions de chaque appareil. Avec la 2.0.4, un prompt envoyé depuis le web, un téléphone ou un autre ordinateur peut porter des photos et des fichiers, et la transcription les montre sur chaque appareil. Chaque liste de sessions reçoit un bouton **Actualiser**, qui demande à chaque ordinateur en ligne de lister à nouveau ses sessions sur-le-champ. Crok Desktop place un bouton de copie et les pouces levé et baissé sous chaque réponse, le terminal pose une courte question après un tour, et davantage de modèles de raisonnement sur OpenRouter nomment désormais leurs sessions.

Comme la 2.0.3, cette version est compilée et publiée par GitHub Actions, dès la fusion de sa pull request.

### Installation

1. Téléchargez l'image disque qui correspond à votre version de macOS et ouvrez-la. Le tableau de la section **Quelle image disque télécharger** indique laquelle.
2. Faites glisser **Crok Desktop** sur **Applications**.
3. Ouvrez Crok Desktop depuis Applications. Cette version n'est pas notariée : la première fois, macOS indique donc qu'il ne peut pas vérifier l'app. Fermez le message, ouvrez **Réglages Système › Confidentialité et sécurité**, cliquez sur **Ouvrir quand même** à côté du message concernant Crok Desktop, puis confirmez. Cette opération n'est à faire qu'une fois.
4. Connectez-vous dans **Réglages › Comptes** avec OpenRouter, OpenAI Codex, une clé d'API Anthropic, une clé d'API DeepSeek ou une clé GLM Coding Plan.

Nécessite macOS 14 Sonoma ou une version ultérieure sur un Mac avec puce Apple (M1 ou plus récent).

### Quelle image disque télécharger

Les deux images correspondent à Crok Desktop 2.0.4 et contiennent les mêmes fonctionnalités. Elles ne diffèrent que par le SDK macOS utilisé pour la compilation, qui détermine si l'habillage de la fenêtre utilise le Liquid Glass d'Apple :

| Image disque | Compilée avec | À utiliser sur | Barre de titre |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.4-arm64-macOS26-SDK.dmg` | SDK macOS {{SDK26}} | macOS 26 et versions ultérieures | Liquid Glass |
| `Crok-Desktop-2.0.4-arm64-macOS15-SDK.dmg` | SDK macOS {{SDK15}} | macOS 14 et 15 | Flou dépoli dans la fenêtre |

Sur macOS 26 et versions ultérieures, préférez l'image du SDK macOS 26 pour avoir la barre de titre en Liquid Glass. Sur macOS 14 ou 15, prenez l'image du SDK macOS 15. Elle fonctionne aussi sur les versions ultérieures : si vous ne savez pas quelle version de macOS vous avez, c'est le choix sûr.

`crok-2.0.4-aarch64-apple-darwin.tar.gz` est l'interface de terminal `crok` seule, pour un Mac sur lequel vous ne voulez pas de l'app : décompressez-le et placez `crok` dans votre `PATH`. Les apps pour téléphone sont décrites dans la section **Apps pour téléphone**. `SHA256SUMS.txt` donne le SHA-256 de chaque téléchargement, et `SHA256SUMS.txt.sig` est la signature de cette liste, que l'outil de mise à jour vérifie.

### Apps pour téléphone

L'app Crok pour iPhone et Android suit les sessions de vos ordinateurs, affiche leurs réponses et leurs demandes d'autorisation, et lance ou pilote des tâches depuis n'importe où. Les apps pour téléphone de cette version sont nouvelles : elles envoient des photos et des fichiers avec un prompt, les montrent dans la transcription et proposent **Actualiser**. Installez-les par-dessus celles de la 2.0.3 pour avoir les deux. Les apps pour téléphone de la 2.0.3 et plus anciennes continuent de fonctionner comme avant, sans ces nouveautés. Les trois fichiers se connectent au relais de production.

- **Android 8.0 ou ultérieur :** téléchargez `Crok-Android-2.0.4.apk` sur le téléphone et ouvrez-le, en autorisant votre navigateur à installer des apps quand Android le demande, ou lancez `adb install -r Crok-Android-2.0.4.apk`. Il est signé avec la clé de publication que la 2.0.0 a introduite : il s'installe donc par-dessus l'APK d'une version précédente. Un APK Crok que vous avez compilé vous-même est signé avec une autre clé et bloque l'installation : supprimez-le d'abord avec `adb uninstall dev.chenli.crok.mobile`, ou depuis les réglages du téléphone.
- **iPhone et iPad, iOS 17 ou ultérieur :** `Crok-iOS-2.0.4-unsigned.ipa` n'est pas signé, car une app pour appareils iOS est signée avec l'identifiant Apple de la personne qui l'installe. Installez-le avec un outil de sideloading comme AltStore ou Sideloadly, qui le signe avec votre identifiant Apple. Avec un identifiant Apple gratuit, iOS cesse d'ouvrir l'app au bout de 7 jours, jusqu'à ce que vous l'installiez de nouveau. Pour la compiler plutôt vous-même, utilisez la configuration **Release** : le bouton Run de Xcode compile la configuration Debug, qui se connecte au relais de test.
- **Simulateur iOS :** `Crok-iOS-2.0.4-Simulator.zip` se décompresse en `Crok.app`, à installer avec `xcrun simctl install booted Crok.app` sur un Mac équipé de Xcode.

Pour connecter le téléphone, touchez **Continuer avec GitHub ou Google**, connectez-vous sur la page qui s'ouvre à l'adresse https://crok.chenli.dev, puis touchez **Approuver**. Associez ensuite chaque ordinateur : lancez `crok remote login` dessus et scannez le code QR qu'il affiche depuis **Réglages › Associer un ordinateur** dans l'app, ou approuvez l'ordinateur sur la page web qui s'ouvre.

### Nouveautés

- **Des photos et des fichiers dans les prompts, depuis n'importe quel appareil.** Sur le web et dans les apps pour téléphone, le trombone à côté du champ de message ajoute des photos et des fichiers à un prompt : Photos, Appareil photo et Fichiers sur les téléphones, et sur le web, on peut aussi les coller ou les déposer sur la session. Jusqu'à 10 partent avec un même message, 20 Mo au plus chacun, et un message peut ne contenir que des photos. L'ordinateur transmet les images au modèle en tant qu'images et enregistre les autres fichiers dans un dossier dédié, où le modèle peut les lire. Les photos s'affichent dans la transcription sur chaque appareil et s'ouvrent en plein écran d'un simple toucher (avec **Partager** et **Enregistrer** sur les téléphones), et les images d'un prompt saisi sur l'ordinateur lui-même s'affichent aussi sur les téléphones et le web.
- **Actualiser chaque liste de sessions.** Le web, les apps pour téléphone, **Autres ordinateurs** dans Crok Desktop et le panneau Distant du terminal ont une commande Actualiser (↻, ou `r` dans `/remote`). Elle demande à chaque ordinateur en ligne de lister à nouveau toutes ses sessions sur-le-champ, plutôt qu'à sa prochaine vérification, et son icône tourne jusqu'à ce que chacun l'ait fait. Sur les téléphones, tirer la liste vers le bas fait de même.
- **Du feedback sur les réponses.** Crok Desktop affiche un bouton de copie et les pouces levé et baissé sous chaque réponse terminée. Le bouton de copie prend le Markdown de la réponse tel qu'il est écrit, et cliquer de nouveau sur le pouce choisi retire l'avis. Le terminal demande "Cette réponse vous a-t-elle aidé ?" une fois sous un tour terminé, et l'on y répond avec `/good`, `/not-so-well` ou `/dont-show-again`.
- **Des titres de session sur plus de modèles OpenRouter.** Les modèles de raisonnement qui refusent un appel d'outil forcé (Muse Spark 1.3) ou qui épuisent en raisonnement les quelques tokens d'une réponse courte (Muse Glimmer, GLM 5.3 Flash, Aion 2.0) n'obtenaient jamais de titre généré : leurs sessions étaient donc nommées d'après les premiers mots du prompt. Ils reçoivent désormais un titre comme n'importe quel autre modèle.

### Contrôle à distance

Chaque crok de cette version se connecte au relais de production à https://crok.chenli.dev, comme la 2.0.3, et garde la connexion qu'il a déjà. Le relais de production reçoit les changements de cette version qui le concernent au moment où elle est publiée ; ce qui se passe sur un ordinateur vient avec crok 2.0.4 sur celui-ci.

- **Photos et fichiers, sur l'ordinateur.** Avant d'exécuter un tel prompt, crok télécharge ses photos et ses fichiers. Les images vont au modèle comme entrée image. Les autres fichiers sont enregistrés sous `~/.crok/remote/attachments/` (un dossier par session et par message) et liés dans le prompt, comme Crok Desktop joint des fichiers. Dans une tâche déjà ouverte d'un autre ordinateur, Crok Desktop et le terminal envoient les images et les fichiers d'un prompt avec celui-ci ; une nouvelle tâche sur un autre ordinateur démarre toujours avec du texte seul.
- **Photos et fichiers, sur le relais.** Le web et les téléphones envoient les photos à l'endroit, à 2048 pixels au plus sur le grand côté et sans leurs métadonnées, avec un petit aperçu. Un envoi qu'aucun message ne réclame est supprimé au bout d'un jour ; les fichiers d'une session sont supprimés avec la session, ou avec sa transcription après 30 jours d'inactivité.
- **Les crok plus anciens.** Un ordinateur qui n'exécute que crok 2.0.3 ou plus ancien ne peut pas recevoir de photos ni de fichiers : en y envoyant, on obtient "Update crok on … to send photos and files there." (mettez à jour crok sur … pour pouvoir y envoyer des photos et des fichiers). Les prompts texte fonctionnent comme avant.
- **Actualiser.** Le crok qui tient la liste des sessions d'un ordinateur liste à nouveau chaque session sur le disque dès que quelqu'un appuie sur Actualiser, puis continue de n'envoyer que ce qui change, toutes les 30 secondes, comme avant. L'indicateur tourne jusqu'à ce que chaque ordinateur en ligne ait répondu, ou pendant 15 secondes au plus. Un ordinateur qui n'exécute qu'un crok plus ancien peut ne répondre qu'à sa prochaine liste habituelle. Les ordinateurs hors ligne ne peuvent pas lister leurs sessions : leurs sessions restent telles qu'elles ont été listées la dernière fois, et les téléphones et le web affichent "Aucun ordinateur n’est en ligne. La liste montre ce qu’ils ont listé la dernière fois." quand aucun ordinateur ne l'est.
- **Mettez à jour les ordinateurs.** Les photos et les fichiers dans les prompts, et une réponse immédiate à Actualiser, viennent avec crok 2.0.4 sur chaque ordinateur.

### Feedback et Agent Observability

Comme dans la 2.0.3, chaque crok de cette version rapporte chaque appel au modèle qu'il fait, avec ses tours, ses exécutions d'outils, ses étapes et ses vérifications des gardes, à [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) sur le stack Grafana Cloud du mainteneur, et `crok version --json` indique l'hôte sous `agentObservability`.

- **Où va un pouce.** Un pouce levé ou baissé, depuis Crok Desktop ou le terminal, est enregistré sur la conversation de ce tour dans Agent Observability et dans la jauge `crok_feedback_rating`. Retirer un pouce l'enregistre comme neutre : il ne compte donc plus. Rien n'est envoyé pendant que l'envoi est coupé.
- **La question dans le terminal.** Elle apparaît une fois sous un tour terminé, mais pas après un tour annulé ou en échec, ni en mode minimal, ni dans un terminal de très faible hauteur. `/dont-show-again` la désactive en écrivant `feedback_prompt = false` sous `[features]` dans `~/.crok/config.toml` ; remettez `true` pour revoir la question.
- **L'évaluation du mainteneur.** Un nouveau tableau de bord **crok Feedback** montre la part de pouces levés parmi les tours qui ont reçu un avis, avec une alerte sous 80 % sur une journée et un objectif sur 30 jours. L'évaluation ne vaut qu'à partir de 20 avis au moins sur la période.

Pour couper l'envoi, ajoutez `agent_observability = false` sous `[features]` dans `~/.crok/config.toml`, ou définissez `CROK_AGENT_OBSERVABILITY=0`. Pour envoyer vers votre propre stack, écrivez `~/.crok/agento11y.env` avec `crates/codegen/xai-grok-agento11y/setup.sh` du dépôt.

### Pour les développeurs

- Les versions sont faites par `.github/workflows/release.yml` comme avant : quand une pull request qui augmente `VERSION` est fusionnée dans `main`, il compile, vérifie et signe chaque fichier, exécute le contrôle des évaluations et publie la version avec les notes de `release/notes/v2.0.4/`.
- Photos et fichiers : les appareils envoient leurs fichiers vers `files:uploadUrl` et nomment ces envois dans `commands:sendPrompt` et `sessions:create` (`attachments`) ; le relais les garde dans une table `files` (propriétaire, session, SHA-256, aperçu) et donne leurs URL de téléchargement à la boîte de réception de l'ordinateur et à chaque requête de transcription. Seul un crok dont `features` liste `attachments` se voit proposer de tels prompts, et `bridge:connect` répond avec les `features` du relais lui-même. `relay/DESIGN.md` §2–§5, section "Photos and files", en est le contrat ; `relay/scripts/attachments-e2e.mjs` et `attachments-bridge-e2e.mjs` le vérifient.
- Actualisation : `sessions:refresh` (`{asked, offline, at}`) appose `refreshAt` sur le catalogue de chaque ordinateur en ligne ; tant que cette date est postérieure au début du dernier envoi, chaque crok de cet ordinateur voit `catalogWanted`, et `bridge:beginCatalog` accorde aussitôt le catalogue au premier qui le demande, détenteur compris. `sessions:refreshState({since})` nomme les ordinateurs qui sont encore en train de lister. `x.ai/remote/refresh` du visualiseur fait les deux pour Crok Desktop et le terminal. `relay/scripts/refresh-e2e.mjs` le vérifie avec de vrais processus crok.
- Feedback : les interfaces envoient `x.ai/feedback/rating` (`1`, `-1`, ou `0` pour le retirer) pour un tour. `[features] feedback_prompt` (`true` par défaut, `CROK_FEEDBACK_PROMPT`) contrôle la question du terminal. L'évaluation repose sur le tableau de bord `crok Feedback`, l'alerte `crok-feedback-good-rate-low` et le SLO `crok feedback is mostly positive`.
- Sur OpenRouter, l'échantillonneur demande un appel d'outil forcé en toutes lettres, avec `tool_choice: "auto"`, et donne à un modèle de raisonnement au moins 4 096 tokens de sortie au niveau d'effort le plus léger que liste le catalogue, sauf si l'appel en nomme un. Deux champs de `SamplerConfig` portent la prise en charge du raisonnement indiquée par le catalogue et son effort le plus léger.
- Le taux de succès du cache du tableau de bord **LLM Overview** couvre désormais Claude Platform, OpenRouter et les appels que crok rapporte lui-même, chacun interrogé séparément, si bien qu'une source sans appel sur la période n'ajoute rien.

### Signature

La 2.0.4 est signée par le même certificat "Crok Code Signing" que la 2.0.3, la 2.0.2, la 2.0.1, la 2.0.0, la 1.5.2 et la 1.5.3. macOS lie les autorisations de confidentialité à la signature : ce que vous avez autorisé pour la 2.0.3 (Enregistrement de l'écran, Accessibilité, microphone, reconnaissance vocale) est donc conservé pour la 2.0.4. Cette compilation n'est pas notariée : une nouvelle installation nécessite donc une fois l'étape **Ouvrir quand même** ci-dessus.

L'app Android est signée avec la clé de publication que la 2.0.0 a introduite. L'app iOS n'est pas signée, comme l'explique la section **Apps pour téléphone**. La liste signée des sommes de contrôle est une chose distincte : elle permet à l'outil de mise à jour de vérifier un téléchargement et ne change pas la façon dont macOS traite l'app.

### Mise à jour depuis la 2.0.3

Utilisez **Crok Desktop › Rechercher des mises à jour…**, ou `crok upgrade` dans un terminal après avoir quitté Crok Desktop. Cette mise à jour est effectuée en place, dans le `Crok Desktop.app` installé : l'app garde donc sa place dans le Dock et le Finder, et aucune ancienne copie ne reste dans la Corbeille. La mise à jour prend l'image compilée avec le même SDK que l'app installée (macOS26-SDK ou macOS15-SDK), jamais l'autre.

La connexion à vos fournisseurs de modèles, les réglages, les tâches et le relais sont conservés : la 2.0.4 parle au même relais de production que la 2.0.3. Mettez à jour chaque ordinateur que vous utilisez avec le relais, pour qu'il puisse recevoir des photos et des fichiers et répondre aussitôt à Actualiser, et installez les apps pour téléphone de cette version, comme l'indique la section **Apps pour téléphone** ci-dessus.

### Détails

- Intègre crok `{{CROK_VERSION}}`.
- Compilée par GitHub Actions à partir du tag `desktop-v2.0.4` sur `{{COMMIT}}` dans `main`. L'image du SDK macOS 26 a été compilée avec Xcode {{XCODE26}} et le SDK macOS {{SDK26}}, l'image du SDK macOS 15 avec Xcode {{XCODE15}} et le SDK macOS {{SDK15}}, et le `crok` autonome avec le SDK macOS {{TUI_SDK}}.
- Les deux images sont en arm64, signées par le certificat Crok Code Signing et non notariées, et fonctionnent toutes deux sur macOS 14 Sonoma ou une version ultérieure.
- L'app iOS (`dev.chenli.crok.mobile`) est une compilation Release faite avec Xcode {{XCODE26}} ; l'app Android est une compilation release pour Android 8.0 ou ultérieur.
- Les sommes de contrôle SHA-256 figurent à la fin de ces notes et dans `SHA256SUMS.txt`, qui couvre aussi les apps pour téléphone. Le fichier `release/README.md` du dépôt explique comment vérifier à la main la signature de la liste.
