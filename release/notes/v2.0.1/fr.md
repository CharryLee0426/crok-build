Crok Desktop 2.0.1 est l'app macOS native de ce fork. Elle intègre crok, c'est-à-dire le moteur d'exécution de l'agent et l'interface de terminal `crok` : il n'y a donc rien d'autre à installer. Elle succède à la 2.0.0, la version qui a donné au contrôle à distance son propre relais de production, à l'adresse https://crok.chenli.dev, et qui a porté pour la première fois les apps iOS et Android. La 2.0.1 est la version du travail qui suit : les correctifs et les améliorations faits par-dessus la 2.0.0. La liste de la section **Nouveautés** s'allonge à mesure que ce travail est livré.

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

### Nouveautés

- **La 2.0.1 est la version du travail qui suit la 2.0.0.** Elle porte les correctifs et les améliorations faits sur la branche `charlie/dev` depuis la 2.0.0, et cette liste s'allonge à mesure que ce travail est livré.
- **Le processus de publication est celui que la 2.0.0 a introduit.** La 2.0.1 est compilée, vérifiée, signée et publiée par la même chaîne GitHub Actions, et ces notes sont commitées dans `release/notes/v2.0.1/`.
- **Le relais et les apps pour téléphone continuent de fonctionner comme avant.** La 2.0.1 se connecte au même relais de production, à l'adresse https://crok.chenli.dev, et les apps pour téléphone gardent le comportement que la 2.0.0 leur a donné. Voir **Contrôle à distance** ci-dessous.
- **Les mises à jour s'installent dans l'app que vous avez.** À partir de la 2.0.0, **Crok Desktop › Rechercher des mises à jour…** et `crok upgrade` placent la nouvelle version dans le `Crok Desktop.app` installé en une seule étape : l'app garde donc sa place dans le Dock et le Finder, et aucune ancienne copie ne reste dans la Corbeille. Avant l'installation, ils vérifient que la nouvelle version est signée par le même certificat, ce qui permet de conserver les autorisations que macOS a accordées à Crok Desktop (Accessibilité, Enregistrement de l'écran, microphone). Une version signée autrement est refusée, sauf si vous lancez `crok upgrade --allow-new-signature`.
- **L'agent se présente sous le nom de Crok.** Avec tous les fournisseurs, le prompt système commence désormais par « You are Crok. », alors qu'il nommait Grok auparavant, même quand le modèle était Claude, DeepSeek ou GLM. `agent.system_prompt_label`, `model.<id>.system_prompt_label` et `CROK_SYSTEM_PROMPT_LABEL` permettent toujours de choisir un autre nom.

### Contrôle à distance

Chaque crok de cette version (l'interface de terminal, celui intégré à Crok Desktop et l'archive autonome) se connecte au relais de production. `crok remote status` affiche son adresse, `https://tacit-finch-29.convex.cloud`, et `crok version --json` l'affiche sous `remote`.

- **Votre connexion de la 2.0.0 est conservée.** Un ordinateur en 2.0.0 est déjà connecté au relais de production, et la 2.0.1 utilise cette même connexion : il n'y a donc pas à se reconnecter, et aucun fichier à déplacer. La connexion de la 1.5.x a été déplacée de `~/.crok/remote/credentials.json` vers `~/.crok/remote/credentials-dev.json` par la 2.0.0, qui a fait ce déplacement une seule fois ; la 2.0.1 laisse les deux fichiers où ils sont.
- **Le relais de production est où il était.** Votre compte, vos appareils, vos sessions épinglées et archivées et l'ordre de vos projets sont stockés sur le relais, et la 2.0.1 les lit au même endroit : rien ne se déplace donc quand vous mettez à jour.
- **Mettez à jour chaque ordinateur et chaque téléphone.** Un ordinateur en 1.5.x, ou une app pour téléphone compilée avant la 2.0.0, reste sur le relais de test et ne voit pas les ordinateurs en 2.0.0 ou versions ultérieures.

Votre propre relais, défini avec `[remote] url` ou `CROK_REMOTE_URL`, fonctionne comme avant.

### Agent Observability

Comme dans la 2.0.0, chaque crok de cette version signale chaque appel de modèle qu'il effectue à [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) sur la stack Grafana Cloud du mainteneur : l'invite, la réponse, les appels d'outils, l'utilisation des tokens et les durées, étiquetés avec le nom de l'ordinateur. `crok version --json` affiche, sous `agentObservability`, l'hôte auquel les rapports sont envoyés. Pour le désactiver, ajoutez `agent_observability = false` sous `[features]` dans `~/.crok/config.toml`, ou définissez `CROK_AGENT_OBSERVABILITY=0`. Pour envoyer les rapports à votre propre stack, créez `~/.crok/agento11y.env` avec le script `crates/codegen/xai-grok-agento11y/setup.sh` du dépôt.

### Pour les développeurs

- Les versions sont produites par `.github/workflows/release.yml` : quand une pull request qui incrémente `VERSION` est fusionnée dans `main`, ce workflow compile l'interface de terminal, les deux images disque et les apps pour téléphone, les vérifie et les signe, puis publie la version avec les notes commitées dans `release/notes/v2.0.1/`. `release/ci-secrets.sh` lui fournit les clés de signature. `release/README.md` décrit l'ensemble.
- `.github/workflows/ci.yml` compile l'interface de terminal, Crok Desktop pour les deux SDK, l'app iOS et l'app Android à chaque pull request vers `main`, et vérifie les notes d'une `VERSION` qui n'a pas encore été publiée.
- Le relais a deux environnements, `relay/environments/prod.env` et `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` ou `relay/scripts/deploy.sh test` déploie l'un d'eux, et `make clients-prod` et `make clients-test` compilent aussi les apps pour téléphone pour cet environnement. crok choisit son relais à la compilation, avec `CROK_RELAY_ENV` (prod, sauf pour une compilation de test).
- `desktop/macOS/scripts/build-app.sh` compile avec le système de build natif de SwiftPM (`SWIFT_BUILD_SYSTEM` permet d'en choisir un autre), ce qui garde corrects `SDKROOT` et la version du SDK inscrite dans le binaire, y compris avec Xcode 27.
- `mobile/scripts/build-apps.sh --ios-device` ajoute un `.ipa` non signé pour les appareils, et les compilations release d'Android sont signées avec le keystore que désigne `CROK_ANDROID_KEYSTORE`.

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
