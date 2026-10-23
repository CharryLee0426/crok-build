Crok Desktop 2.0.1 est l'app macOS native de ce fork. Elle intègre crok, c'est-à-dire le moteur d'exécution de l'agent et l'interface de terminal `crok` : il n'y a donc rien d'autre à installer. Elle succède à la 2.0.0, la version qui a donné au contrôle à distance son propre relais de production, à l'adresse https://crok.chenli.dev, et qui a porté pour la première fois les apps iOS et Android. La 2.0.1 est la version du travail qui suit. Les deux apps pour téléphone sont redessinées autour des ordinateurs, des projets et des sujets ; une session d'un autre ordinateur affiche sa branche et ses chiffres de tokens dans Crok Desktop, et son Git Graph lit le dépôt de cet ordinateur ; une session distante peut démarrer avec le modèle et le niveau de réflexion choisis ; et Agent Observability chiffre les appels de Codex, GLM et DeepSeek.

Comme la 2.0.0, cette version est compilée et publiée par GitHub Actions, dès la fusion de sa pull request.

### Installation

1. Téléchargez l'image disque qui correspond à votre version de macOS et ouvrez-la. Le tableau de la section **Quelle image disque télécharger** indique laquelle.
2. Faites glisser **Crok Desktop** sur **Applications**.
3. Ouvrez Crok Desktop depuis Applications. Cette version n'est pas notariée : la première fois, macOS indique donc qu'il ne peut pas vérifier l'app. Fermez le message, ouvrez **Réglages Système › Confidentialité et sécurité**, cliquez sur **Ouvrir quand même** à côté du message concernant Crok Desktop, puis confirmez. Cette opération n'est à faire qu'une fois.
4. Connectez-vous dans **Réglages › Comptes** avec OpenRouter, OpenAI Codex, une clé d'API Anthropic, une clé d'API DeepSeek ou une clé GLM Coding Plan.

Nécessite macOS 14 Sonoma ou une version ultérieure sur un Mac avec puce Apple (M1 ou plus récent).

### Quelle image disque télécharger

Les deux images correspondent à Crok Desktop 2.0.1 et contiennent les mêmes fonctionnalités. Elles ne diffèrent que par le SDK macOS utilisé pour la compilation, qui détermine si l'habillage de la fenêtre utilise le Liquid Glass d'Apple :

| Image disque | Compilée avec | À utiliser sur | Barre de titre |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.1-arm64-macOS26-SDK.dmg` | SDK macOS {{SDK26}} | macOS 26 et versions ultérieures | Liquid Glass |
| `Crok-Desktop-2.0.1-arm64-macOS15-SDK.dmg` | SDK macOS {{SDK15}} | macOS 14 et 15 | Flou dépoli dans la fenêtre |

Sur macOS 26 et versions ultérieures, préférez l'image du SDK macOS 26 pour avoir la barre de titre en Liquid Glass. Sur macOS 14 ou 15, prenez l'image du SDK macOS 15. Elle fonctionne aussi sur les versions ultérieures : si vous ne savez pas quelle version de macOS vous avez, c'est le choix sûr.

`crok-2.0.1-aarch64-apple-darwin.tar.gz` est l'interface de terminal `crok` seule, pour un Mac sur lequel vous ne voulez pas de l'app : décompressez-le et placez `crok` dans votre `PATH`. Les apps pour téléphone sont décrites dans la section **Apps pour téléphone**. `SHA256SUMS.txt` donne le SHA-256 de chaque téléchargement, et `SHA256SUMS.txt.sig` est la signature de cette liste, que l'outil de mise à jour vérifie.

### Apps pour téléphone

L'app Crok pour iPhone et Android suit les sessions de vos ordinateurs, affiche leurs réponses et leurs demandes d'autorisation, et lance ou pilote des tâches depuis n'importe où. Elle est fournie avec cette version, comme elle l'était avec la 2.0.0. Les trois fichiers se connectent au relais de production.

- **Android 8.0 ou ultérieur :** téléchargez `Crok-Android-2.0.1.apk` sur le téléphone et ouvrez-le, en autorisant votre navigateur à installer des apps quand Android le demande, ou lancez `adb install -r Crok-Android-2.0.1.apk`. Il est signé avec la clé de publication, que les versions suivantes conserveront : l'APK suivant s'installera donc par-dessus. Un APK Crok que vous avez compilé vous-même est signé avec une autre clé et bloque l'installation : supprimez-le d'abord avec `adb uninstall dev.chenli.crok.mobile`, ou depuis les réglages du téléphone.
- **iPhone et iPad, iOS 17 ou ultérieur :** `Crok-iOS-2.0.1-unsigned.ipa` n'est pas signé, car une app pour appareils iOS est signée avec l'identifiant Apple de la personne qui l'installe. Installez-le avec un outil de sideloading comme AltStore ou Sideloadly, qui le signe avec votre identifiant Apple. Avec un identifiant Apple gratuit, iOS cesse d'ouvrir l'app au bout de 7 jours, jusqu'à ce que vous l'installiez de nouveau. Pour la compiler plutôt vous-même, utilisez la configuration **Release** : le bouton Run de Xcode compile la configuration Debug, qui se connecte au relais de test.
- **Simulateur iOS :** `Crok-iOS-2.0.1-Simulator.zip` se décompresse en `Crok.app`, à installer avec `xcrun simctl install booted Crok.app` sur un Mac équipé de Xcode.

Pour connecter le téléphone, touchez **Continuer avec GitHub ou Google**, connectez-vous sur la page qui s'ouvre à l'adresse https://crok.chenli.dev, puis touchez **Approuver**. Associez ensuite chaque ordinateur : lancez `crok remote login` dessus et scannez le code QR qu'il affiche depuis **Réglages › Associer un ordinateur** dans l'app, ou approuvez l'ordinateur sur la page web qui s'ouvre.

**Les apps pour téléphone sont redessinées.** Un ordinateur associé est un compte, un projet est un groupe avec des sujets et une session est un sujet de ce groupe. L'onglet **Sessions** affiche les projets de l'ordinateur sélectionné et s'ouvre sur leurs sujets, **Profil** remplace **Réglages**, **Sessions archivées** a son propre écran et **Apparence** propose les thèmes de discussion de Telegram ou une photo. La section suivante décrit le design commun aux deux apps.

### Téléphones : ordinateurs, projets et sujets

Les deux apps pour téléphone suivent désormais le même design, inspiré de Telegram, et il remplace la liste des sessions fournie avec la 2.0.0. Il est identique sur iOS et Android.

- **Deux onglets : Sessions et Profil.** L'icône de l'onglet Profil est l'image du compte du relais, et son badge compte les sessions non lues des autres ordinateurs. Un appui long sur **Sessions** propose **Tout marquer comme lu** ; un appui long sur **Profil** ouvre le sélecteur d'ordinateurs, tout comme le titre de Sessions.
- **L'onglet Sessions affiche un ordinateur.** Les projets de l'ordinateur sélectionné apparaissent en lignes de forum : un avatar carré aux coins arrondis, les titres de ses sujets les plus récents, s'il travaille, attend une autorisation ou ce qu'annonce la dernière réponse, et son total non lu. Le choix est mémorisé sur le téléphone ; un nouveau téléphone démarre sur l'ordinateur actif le plus récemment.
- **Un projet est un groupe avec des sujets.** Ouvrir un projet liste ses sessions en lignes de sujet, chacune avec une icône de sujet colorée, son titre, l'heure, le dossier, l'aperçu et le badge de non-lus. L'écran du projet propose la recherche, **Tout marquer comme lu**, **Réorganiser**, **Trier par activité récente** et un bouton de rédaction ; balayer un sujet l'épingle ou l'archive, et un appui long propose Épingler, Arrêter, Marquer comme lu, Archiver, Monter et Descendre.
- **Sessions archivées.** Une ligne en haut de l'onglet Sessions ouvre les archives de l'ordinateur sélectionné. Balayez une session vers la gauche pour l'archiver ; sur l'écran des archives, désarchivez-la de la même façon.
- **Profil est la page du compte.** Elle affiche l'image, le nom et l'e-mail du compte, puis chaque ordinateur avec son badge de non-lus et une coche sur celui sélectionné, **Associer un ordinateur**, **Appareils**, **Apparence**, **Langue**, **Version**, les liens du développeur sur GitHub et X, et **Se déconnecter**.
- **Apparence reprend les thèmes de discussion de Telegram.** Un aperçu et une rangée de cartes proposent **Aucun thème**, **Classique** et neuf thèmes emoji (Maison, Caneton, Bonhomme de neige, Diamant, Professeur, Tulipe, Cœur violet, Sapin de Noël et Jeu vidéo), chacun en variante claire et sombre, ou une photo de la bibliothèque avec **Flou**. Un thème définit le fond de la session et les bulles de la personne ; les bulles de l'agent restent inchangées. **Mode de couleur** reste Système, Clair ou Sombre.
- **Chaque app parle six langues.** Chaque nouvel écran et chaque nouveau texte sont disponibles en anglais, 简体中文, 日本語, Español, Français et Deutsch.

### Nouveautés

- **Les apps pour téléphone sont redessinées.** Un ordinateur est un compte, un projet est un groupe avec des sujets et une session est un sujet. L'onglet Sessions affiche l'ordinateur sélectionné, Profil remplace Réglages et les sessions peuvent porter les thèmes de discussion de Telegram. Voir **Téléphones : ordinateurs, projets et sujets** ci-dessus.
- **La branche et les tokens d'un autre ordinateur sont dans le pied du compositeur.** Dans une tâche ouverte depuis **Autres ordinateurs**, Crok Desktop affiche la branche, les tokens d'entrée et de sortie, le taux de cache et la vitesse de sortie que cet ordinateur a signalés en dernier ; ils se rafraîchissent à la fin d'un tour là-bas.
- **Git Graph et le sélecteur de branches travaillent sur le dépôt de cet ordinateur.** Ils lisent le dépôt via le relais, et changer ou créer une branche s'exécute là-bas et met à jour la branche que voient tous les appareils. L'ordinateur qui héberge la session doit avoir crok 2.0.1 pour cela.
- **Une session peut démarrer avec le modèle de votre choix.** L'écran de nouvelle session de l'app web liste les modèles et niveaux de réflexion de l'ordinateur cible au-dessus du compositeur ; son crok les applique avant le premier prompt. **Par défaut** conserve le choix de l'ordinateur.
- **Agent Observability chiffre les appels de tous les fournisseurs.** Le span de chaque appel porte désormais son coût en USD, l'origine de ce coût, son backend et si vous l'avez annulé ; les appels de Codex, GLM et DeepSeek affichent donc leur dépense. Les tableaux de bord ajoutent une vue **Codex, GLM et DeepSeek**, 14 jours d'historique et des comparaisons d'une semaine à l'autre.
- **Correctifs mineurs dans Crok Desktop et crok.** Le premier titre d'une session utilise désormais le modèle qu'elle exécute à ce moment-là, y compris après un changement effectué avant le premier prompt ; démarrer un tour pendant qu'une tâche se connecte encore l'indique au lieu d'ouvrir une seconde connexion.
- **Les mises à jour s'installent dans l'app que vous avez.** À partir de la 2.0.0, **Crok Desktop › Rechercher des mises à jour…** et `crok upgrade` placent la nouvelle version dans le `Crok Desktop.app` installé en une seule étape : l'app garde donc sa place dans le Dock et le Finder, et aucune ancienne copie ne reste dans la Corbeille. Avant l'installation, ils vérifient que la nouvelle version est signée par le même certificat, ce qui permet de conserver les autorisations que macOS a accordées à Crok Desktop (Accessibilité, Enregistrement de l'écran, microphone). Une version signée autrement est refusée, sauf si vous lancez `crok upgrade --allow-new-signature`.
- **L'agent se présente sous le nom de Crok.** Avec tous les fournisseurs, le prompt système commence désormais par « You are Crok. », alors qu'il nommait Grok auparavant, même quand le modèle était Claude, DeepSeek ou GLM. `agent.system_prompt_label`, `model.<id>.system_prompt_label` et `CROK_SYSTEM_PROMPT_LABEL` permettent toujours de choisir un autre nom.

### Contrôle à distance

Chaque crok de cette version (l'interface de terminal, celui intégré à Crok Desktop et l'archive autonome) se connecte au relais de production. `crok remote status` affiche son adresse, `https://tacit-finch-29.convex.cloud`, et `crok version --json` l'affiche sous `remote`.

- **Démarrez une session avec le modèle et le niveau de réflexion voulus.** Sur le web, l'écran de nouvelle session liste les modèles et niveaux de réflexion de l'ordinateur cible au-dessus du compositeur, et cet ordinateur les applique avant le premier prompt. **Par défaut** laisse son propre choix.
- **Une tâche d'un autre ordinateur affiche ses chiffres.** Le pied du compositeur montre la branche, les tokens d'entrée et de sortie, le taux de cache et la vitesse de sortie de la session, tels que son ordinateur les a signalés à la fin de son dernier tour.
- **Lisez et changez le dépôt d'un autre ordinateur.** Dans Crok Desktop, **Git Graph** et le sélecteur de branches d'une tâche dans **Autres ordinateurs** lisent le dépôt de cet ordinateur via le relais ; changer ou créer une branche s'exécute là-bas, et la branche extraite par une commande met à jour la ligne de la session pour tous les appareils. L'ordinateur qui héberge la session doit avoir crok 2.0.1 ; un crok plus ancien répond qu'il faut le mettre à jour.
- **Votre connexion de la 2.0.0 est conservée.** Un ordinateur en 2.0.0 est déjà connecté au relais de production, et la 2.0.1 utilise cette même connexion : il n'y a donc pas à se reconnecter, et aucun fichier à déplacer. La connexion de la 1.5.x a été déplacée de `~/.crok/remote/credentials.json` vers `~/.crok/remote/credentials-dev.json` par la 2.0.0, qui a fait ce déplacement une seule fois ; la 2.0.1 laisse les deux fichiers où ils sont.
- **Le relais de production est où il était.** Votre compte, vos appareils, vos sessions épinglées et archivées et l'ordre de vos projets sont stockés sur le relais, et la 2.0.1 les lit au même endroit : rien ne se déplace donc quand vous mettez à jour.
- **Mettez à jour chaque ordinateur et chaque téléphone.** Un ordinateur en 1.5.x, ou une app pour téléphone compilée avant la 2.0.0, reste sur le relais de test et ne voit pas les ordinateurs en 2.0.0 ou versions ultérieures.

Votre propre relais, défini avec `[remote] url` ou `CROK_REMOTE_URL`, fonctionne comme avant.

### Agent Observability

Comme dans la 2.0.0, chaque crok de cette version signale chaque appel de modèle qu'il effectue à [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) sur la stack Grafana Cloud du mainteneur : l'invite, la réponse, les appels d'outils, l'utilisation des tokens et les durées, étiquetés avec le nom de l'ordinateur. `crok version --json` affiche, sous `agentObservability`, l'hôte auquel les rapports sont envoyés. Pour le désactiver, ajoutez `agent_observability = false` sous `[features]` dans `~/.crok/config.toml`, ou définissez `CROK_AGENT_OBSERVABILITY=0`. Pour envoyer les rapports à votre propre stack, créez `~/.crok/agento11y.env` avec le script `crates/codegen/xai-grok-agento11y/setup.sh` du dépôt.

Le span de chaque appel porte aussi désormais `crok.cost.usd`, `crok.cost.source`, `crok.backend` et, pour un appel que vous avez interrompu, `crok.cancelled`. Le coût est celui du fournisseur lorsqu'il le signale, sinon le prix API standard du modèle pour les tokens de l'appel. Les appels de Codex, GLM et DeepSeek sont donc chiffrés même si ces fournisseurs n'exportent pas de traces. Les tableaux de bord incluent une vue **Codex, GLM et DeepSeek**, conservent 14 jours d'historique et comparent chaque semaine à la précédente.

### Pour les développeurs

- Les versions sont produites par `.github/workflows/release.yml` : quand une pull request qui incrémente `VERSION` est fusionnée dans `main`, ce workflow compile l'interface de terminal, les deux images disque et les apps pour téléphone, les vérifie et les signe, puis publie la version avec les notes commitées dans `release/notes/v2.0.1/`. `release/ci-secrets.sh` lui fournit les clés de signature. `release/README.md` décrit l'ensemble.
- Les runners de publication ajoutent le trousseau de signature importé à la liste de recherche du trousseau de l'utilisateur, puis signent une copie jetable de `/usr/bin/true` avant toute compilation : `.github/scripts/release/import-codesign.sh` arrête un job à son étape d'import lorsque `codesign` ne peut pas utiliser ce trousseau, au lieu de le faire après 46 minutes de compilation.
- `.github/workflows/ci.yml` compile l'interface de terminal, Crok Desktop pour les deux SDK, l'app iOS et l'app Android à chaque pull request vers `main`, et vérifie les notes d'une `VERSION` qui n'a pas encore été publiée.
- Les deux apps pour téléphone implémentent `mobile/DESIGN.md`, le contrat des ordinateurs comme comptes, des projets comme groupes avec sujets, du Profil et des thèmes de session. Il remplace la partie téléphone de la section 5 de `relay/DESIGN.md` ; l'app web conserve cette partie.
- Le relais a deux environnements, `relay/environments/prod.env` et `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` ou `relay/scripts/deploy.sh test` déploie l'un d'eux, et `make clients-prod` et `make clients-test` compilent aussi les apps pour téléphone pour cet environnement. crok choisit son relais à la compilation, avec `CROK_RELAY_ENV` (prod, sauf pour une compilation de test).
- Le type de commande `git` du relais transporte `commands:git` (`{op: "graph"|"branches"|"files"|"diff"|"workspace"|"workspace_diff"|"signature"|"switch"|"create", …}`) vers tout crok de l'ordinateur de la session qui annonce `git`, et `bridge:setBranch` enregistre la branche extraite par une commande. La ligne d'une session porte désormais `gitBranch` et `usage`, dont `outputTokensPerSecond`.
- Le pont Agent Observability écrit `crok.cost.usd`, `crok.cost.source`, `crok.backend` et `crok.cancelled` sur chaque span. `observability/grafana-llm/build_dashboards.py` génère le tableau de bord **Codex, GLM et DeepSeek** et les 64 règles d'historique, et `prices.json` contient les prix API standard.
- `desktop/macOS/scripts/build-app.sh` compile avec le système de build natif de SwiftPM (`SWIFT_BUILD_SYSTEM` permet d'en choisir un autre), ce qui garde corrects `SDKROOT` et la version du SDK inscrite dans le binaire, y compris avec Xcode 27.
- `mobile/scripts/build-apps.sh --ios-device` ajoute un `.ipa` non signé pour les appareils, et les compilations release d'Android sont signées avec le keystore que désigne `CROK_ANDROID_KEYSTORE`. Les compilations de débogage des deux apps portent une icône jaune ; les compilations release, la bleue.

### Signature

La 2.0.1 est signée par le même certificat "Crok Code Signing" que la 2.0.0, la 1.5.2 et la 1.5.3. macOS lie les autorisations de confidentialité à la signature : ce que vous avez autorisé pour la 2.0.0 (Enregistrement de l'écran, Accessibilité, microphone, reconnaissance vocale) est donc conservé pour la 2.0.1. Cette compilation n'est pas notariée : une nouvelle installation nécessite donc une fois l'étape **Ouvrir quand même** ci-dessus.

L'app Android est signée avec la clé de publication que la 2.0.0 a introduite. L'app iOS n'est pas signée, comme l'explique la section **Apps pour téléphone**. La liste signée des sommes de contrôle est une chose distincte : elle permet à l'outil de mise à jour de vérifier un téléchargement et ne change pas la façon dont macOS traite l'app.

### Mise à jour depuis la 2.0.0

Utilisez **Crok Desktop › Rechercher des mises à jour…**, ou `crok upgrade` dans un terminal après avoir quitté Crok Desktop. Cette mise à jour est effectuée en place, dans le `Crok Desktop.app` installé : l'app garde donc sa place dans le Dock et le Finder, et aucune ancienne copie ne reste dans la Corbeille. La mise à jour prend l'image compilée avec le même SDK que l'app installée (macOS26-SDK ou macOS15-SDK), jamais l'autre.

La connexion à vos fournisseurs de modèles, les réglages, les tâches et le relais sont conservés : la 2.0.1 parle au même relais de production que la 2.0.0. Les apps pour téléphone s'installent à partir des fichiers de cette version, comme l'explique la section **Apps pour téléphone** ci-dessus.

### Détails

- Intègre crok `{{CROK_VERSION}}`.
- Compilée par GitHub Actions à partir du tag `desktop-v2.0.1` sur `{{COMMIT}}` dans `main`. L'image du SDK macOS 26 a été compilée avec Xcode {{XCODE26}} et le SDK macOS {{SDK26}}, l'image du SDK macOS 15 avec Xcode {{XCODE15}} et le SDK macOS {{SDK15}}, et le `crok` autonome avec le SDK macOS {{TUI_SDK}}.
- Les deux images sont en arm64, signées par le certificat Crok Code Signing et non notariées, et fonctionnent toutes deux sur macOS 14 Sonoma ou une version ultérieure.
- L'app iOS (`dev.chenli.crok.mobile`) est une compilation Release faite avec Xcode {{XCODE26}} ; l'app Android est une compilation release pour Android 8.0 ou ultérieur.
- Les sommes de contrôle SHA-256 figurent à la fin de ces notes et dans `SHA256SUMS.txt`, qui couvre désormais aussi les apps pour téléphone. Le fichier `release/README.md` du dépôt explique comment vérifier à la main la signature de la liste.
