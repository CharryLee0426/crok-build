Crok Desktop 2.0.0 est l'app macOS native de ce fork. Elle intègre crok, c'est-à-dire le moteur d'exécution de l'agent et l'interface de terminal `crok` : il n'y a donc rien d'autre à installer. Cette version donne au contrôle à distance son propre relais de production, à l'adresse https://crok.chenli.dev, et inclut pour la première fois les apps iOS et Android. Sur le web et sur les téléphones, les réponses s'affichent désormais en Markdown complet. Les mises à jour s'installent dans l'app que vous avez déjà, et fermer la fenêtre laisse Crok Desktop en marche. En raison du nouveau relais, chaque ordinateur et chaque téléphone doit se reconnecter une fois au contrôle à distance : la section **Contrôle à distance** ci-dessous explique comment.

C'est aussi la première version compilée et publiée par GitHub Actions, dès la fusion de sa pull request.

### Installation

1. Téléchargez l'image disque qui correspond à votre version de macOS et ouvrez-la. Le tableau de la section **Quelle image disque télécharger** indique laquelle.
2. Faites glisser **Crok Desktop** sur **Applications**.
3. Ouvrez Crok Desktop depuis Applications. Cette version n'est pas notariée : la première fois, macOS indique donc qu'il ne peut pas vérifier l'app. Fermez le message, ouvrez **Réglages Système › Confidentialité et sécurité**, cliquez sur **Ouvrir quand même** à côté du message concernant Crok Desktop, puis confirmez. Cette opération n'est à faire qu'une fois.
4. Connectez-vous dans **Réglages › Comptes** avec OpenRouter, OpenAI Codex, une clé d'API Anthropic, une clé d'API DeepSeek ou une clé GLM Coding Plan.

Nécessite macOS 14 Sonoma ou une version ultérieure sur un Mac avec puce Apple (M1 ou plus récent).

### Quelle image disque télécharger

Les deux images contiennent Crok Desktop 2.0.0 avec les mêmes fonctionnalités. Elles ne diffèrent que par le SDK macOS utilisé pour la compilation, qui détermine si l'habillage de la fenêtre utilise le Liquid Glass d'Apple :

| Image disque | Compilée avec | À utiliser sur | Barre de titre |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.0-arm64-macOS26-SDK.dmg` | SDK macOS {{SDK26}} | macOS 26 et versions ultérieures | Liquid Glass |
| `Crok-Desktop-2.0.0-arm64-macOS15-SDK.dmg` | SDK macOS {{SDK15}} | macOS 14 et 15 | Flou dépoli dans la fenêtre |

Sur macOS 26 et versions ultérieures, préférez l'image du SDK macOS 26 pour avoir la barre de titre en Liquid Glass. Sur macOS 14 ou 15, prenez l'image du SDK macOS 15. Elle fonctionne aussi sur les versions ultérieures : si vous ne savez pas quelle version de macOS vous avez, c'est le choix sûr.

`crok-2.0.0-aarch64-apple-darwin.tar.gz` est l'interface de terminal `crok` seule, pour un Mac sur lequel vous ne voulez pas de l'app : décompressez-le et placez `crok` dans votre `PATH`. Les apps pour téléphone sont décrites dans la section **Apps pour téléphone**. `SHA256SUMS.txt` donne le SHA-256 de chaque téléchargement, et `SHA256SUMS.txt.sig` est la signature de cette liste, que l'outil de mise à jour vérifie.

### Apps pour téléphone

L'app Crok pour iPhone et Android suit les sessions de vos ordinateurs, affiche leurs réponses et leurs demandes d'autorisation, et lance ou pilote des tâches depuis n'importe où. Jusqu'ici, il fallait la compiler depuis le dépôt ; cette version l'inclut. Les trois fichiers se connectent au relais de production.

- **Android 8.0 ou ultérieur :** téléchargez `Crok-Android-2.0.0.apk` sur le téléphone et ouvrez-le, en autorisant votre navigateur à installer des apps quand Android le demande, ou lancez `adb install -r Crok-Android-2.0.0.apk`. Il est signé avec la clé de publication, que les versions suivantes conserveront : l'APK suivant s'installera donc par-dessus. Un APK Crok que vous avez compilé vous-même est signé avec une autre clé et bloque l'installation : supprimez-le d'abord avec `adb uninstall dev.chenli.crok.mobile`, ou depuis les réglages du téléphone.
- **iPhone et iPad, iOS 17 ou ultérieur :** `Crok-iOS-2.0.0-unsigned.ipa` n'est pas signé, car une app pour appareils iOS est signée avec l'identifiant Apple de la personne qui l'installe. Installez-le avec un outil de sideloading comme AltStore ou Sideloadly, qui le signe avec votre identifiant Apple. Avec un identifiant Apple gratuit, iOS cesse d'ouvrir l'app au bout de 7 jours, jusqu'à ce que vous l'installiez de nouveau. Pour la compiler plutôt vous-même, utilisez la configuration **Release** : le bouton Run de Xcode compile la configuration Debug, qui se connecte au relais de test.
- **Simulateur iOS :** `Crok-iOS-2.0.0-Simulator.zip` se décompresse en `Crok.app`, à installer avec `xcrun simctl install booted Crok.app` sur un Mac équipé de Xcode.

Pour connecter le téléphone, touchez **Continuer avec GitHub ou Google**, connectez-vous sur la page qui s'ouvre à l'adresse https://crok.chenli.dev, puis touchez **Approuver**. Associez ensuite chaque ordinateur : lancez `crok remote login` dessus et scannez le code QR qu'il affiche depuis **Réglages › Associer un ordinateur** dans l'app, ou approuvez l'ordinateur sur la page web qui s'ouvre.

### Nouveautés

- **Le contrôle à distance a un relais de production.** Les versions publiées se connectent désormais à leur propre relais, dont l'app web se trouve à l'adresse https://crok.chenli.dev. Le relais qu'utilisaient les versions 1.5.1 à 1.5.3, avec son app web à l'adresse https://crok-relay.vercel.app, est désormais réservé aux compilations de test. Rien n'est transféré de l'un à l'autre : vous vous reconnectez donc une fois. Voir **Contrôle à distance** ci-dessous.
- **Les apps pour téléphone sont fournies avec la version.** L'APK Android, l'app iOS non signée et une compilation pour le Simulateur iOS font partie des téléchargements de cette version, tous compilés pour le relais de production. Voir **Apps pour téléphone** ci-dessus.
- **Les réponses s'affichent en Markdown sur le web et sur les téléphones.** Les tableaux, les titres, les listes imbriquées, les listes de tâches, les citations, les liens et les blocs de code s'affichent correctement. La coloration du code reprend les couleurs de GitHub, et chaque bloc a un bouton **Copier**. Les formules mathématiques LaTeX s'affichent, dans le texte avec `$…$` ou `\(…\)` et sur leur propre ligne avec `$$…$$` ou `\[…\]` ; un prix comme « $5 et $10 » reste du texte. Le code, les tableaux et les formules trop larges défilent horizontalement à l'intérieur de la réponse. Les images ne sont jamais téléchargées : elles s'affichent sous forme de lien.
- **Sur les téléphones, les longues réponses s'ouvrent à leur fin.** Une session dont la dernière réponse est plus haute que l'écran s'ouvre sur la fin de cette réponse, et le bouton de défilement vers le bas apparaît pendant que vous lisez à l'intérieur d'une longue réponse. Sur Android, les nouveaux messages ne vous ramènent plus en bas pendant votre lecture ; envoyer une invite le fait toujours. Sur iPhone, cela nécessite iOS 18.
- **Les mises à jour s'installent dans l'app que vous avez.** À partir de la 2.0.0, **Crok Desktop › Rechercher des mises à jour…** et `crok upgrade` placent la nouvelle version dans le `Crok Desktop.app` installé en une seule étape : l'app garde donc sa place dans le Dock et le Finder, et aucune ancienne copie ne reste dans la Corbeille. Avant l'installation, ils vérifient que la nouvelle version est signée par le même certificat, ce qui permet de conserver les autorisations que macOS a accordées à Crok Desktop (Accessibilité, Enregistrement de l'écran, microphone). Une version signée autrement est refusée, sauf si vous lancez `crok upgrade --allow-new-signature`.
- **Fermer la fenêtre laisse Crok Desktop en marche.** Le bouton de fermeture rouge masque désormais la fenêtre, et les tâches, les terminaux du panneau latéral, les pages du navigateur et votre brouillon continuent en arrière-plan. **⌘Q** quitte l'app. Pour faire revenir la fenêtre, cliquez sur l'icône du Dock, choisissez la fenêtre dans le menu **Fenêtre**, ou utilisez une commande de menu comme **Nouvelle tâche**.
- **L'agent se présente sous le nom de Crok.** Avec tous les fournisseurs, le prompt système commence désormais par « You are Crok. », alors qu'il nommait Grok auparavant, même quand le modèle était Claude, DeepSeek ou GLM. `agent.system_prompt_label`, `model.<id>.system_prompt_label` et `CROK_SYSTEM_PROMPT_LABEL` permettent toujours de choisir un autre nom.

### Contrôle à distance

Chaque crok de cette version (l'interface de terminal, celui intégré à Crok Desktop et l'archive autonome) se connecte au relais de production. `crok remote status` affiche son adresse, `https://tacit-finch-29.convex.cloud`, et `crok version --json` l'affiche sous `remote`.

- **Reconnectez-vous sur chaque ordinateur.** Lancez `crok remote login` (ou `/remote login` dans l'interface de terminal), ou utilisez **Réglages › Contrôle à distance › Se connecter…** dans Crok Desktop. Sur la page qui s'ouvre à l'adresse https://crok.chenli.dev, connectez-vous avec GitHub ou Google et cliquez sur **Approuver**. Un téléphone déjà connecté peut aussi associer l'ordinateur à la place, en scannant le code QR depuis **Réglages › Associer un ordinateur**.
- **Le relais de production démarre vide.** Votre compte, vos appareils, vos sessions épinglées et archivées et l'ordre de vos projets sont stockés sur le relais : la première connexion y crée donc un nouveau compte, et les épingles comme l'ordre repartent à zéro.
- **Votre connexion de la 1.5.x est conservée pour les compilations de test.** Au premier lancement de la 2.0.0, crok la déplace de `~/.crok/remote/credentials.json` vers `~/.crok/remote/credentials-dev.json`, et l'ordinateur apparaît comme déconnecté jusqu'à ce que vous vous reconnectiez.
- **Mettez à jour chaque ordinateur et chaque téléphone.** Un ordinateur en 1.5.x, ou une app pour téléphone compilée avant cette version, reste sur le relais de test et ne voit pas les ordinateurs en 2.0.0.

Votre propre relais, défini avec `[remote] url` ou `CROK_REMOTE_URL`, fonctionne comme avant.

### Agent Observability

Comme dans la 1.5.3, chaque crok de cette version signale chaque appel de modèle qu'il effectue à [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) sur la stack Grafana Cloud du mainteneur : l'invite, la réponse, les appels d'outils, l'utilisation des tokens et les durées, étiquetés avec le nom de l'ordinateur. `crok version --json` affiche, sous `agentObservability`, l'hôte auquel les rapports sont envoyés. Pour le désactiver, ajoutez `agent_observability = false` sous `[features]` dans `~/.crok/config.toml`, ou définissez `CROK_AGENT_OBSERVABILITY=0`. Pour envoyer les rapports à votre propre stack, créez `~/.crok/agento11y.env` avec le script `crates/codegen/xai-grok-agento11y/setup.sh` du dépôt.

### Pour les développeurs

- Les versions sont produites par `.github/workflows/release.yml` : quand une pull request qui incrémente `VERSION` est fusionnée dans `main`, ce workflow compile l'interface de terminal, les deux images disque et les apps pour téléphone, les vérifie et les signe, puis publie la version avec les notes commitées dans `release/notes/v2.0.0/`. `release/ci-secrets.sh` lui fournit les clés de signature. `release/README.md` décrit l'ensemble.
- `.github/workflows/ci.yml` compile l'interface de terminal, Crok Desktop pour les deux SDK, l'app iOS et l'app Android à chaque pull request vers `main`, et vérifie les notes d'une `VERSION` qui n'a pas encore été publiée.
- Le relais a deux environnements, `relay/environments/prod.env` et `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` ou `relay/scripts/deploy.sh test` déploie l'un d'eux, et `make clients-prod` et `make clients-test` compilent aussi les apps pour téléphone pour cet environnement. crok choisit son relais à la compilation, avec `CROK_RELAY_ENV` (prod, sauf pour une compilation de test).
- `desktop/macOS/scripts/build-app.sh` compile avec le système de build natif de SwiftPM (`SWIFT_BUILD_SYSTEM` permet d'en choisir un autre), ce qui garde corrects `SDKROOT` et la version du SDK inscrite dans le binaire, y compris avec Xcode 27.
- `mobile/scripts/build-apps.sh --ios-device` ajoute un `.ipa` non signé pour les appareils, et les compilations release d'Android sont signées avec le keystore que désigne `CROK_ANDROID_KEYSTORE`.

### Signature

La 2.0.0 est signée par le même certificat "Crok Code Signing" que la 1.5.2 et la 1.5.3. macOS lie les autorisations de confidentialité à la signature : ce que vous avez autorisé pour la 1.5.3 (Enregistrement de l'écran, Accessibilité, microphone, reconnaissance vocale) est donc conservé pour la 2.0.0. Si vous venez de la 1.5.1 ou d'une version antérieure, qui étaient signées ad hoc, macOS redemande ces autorisations une fois. Si les Réglages Système montrent Crok Desktop comme activé alors que Crok indique qu'il n'est pas autorisé, retirez-le de la liste avec **−** et autorisez-le de nouveau, une fois. Cette compilation n'est pas notariée : une nouvelle installation nécessite donc une fois l'étape **Ouvrir quand même** ci-dessus.

L'app Android est signée avec la clé de publication, nouvelle dans cette version. L'app iOS n'est pas signée, comme l'explique la section **Apps pour téléphone**. La liste signée des sommes de contrôle est une chose distincte : elle permet à l'outil de mise à jour de vérifier un téléchargement et ne change pas la façon dont macOS traite l'app.

### Mise à jour depuis la 1.5.3

Utilisez **Crok Desktop › Rechercher des mises à jour…**, ou `crok upgrade` dans un terminal après avoir quitté Crok Desktop. Cette mise à jour est encore effectuée par l'outil de mise à jour de la 1.5.3, qui remplace l'app entière et place l'ancienne dans la Corbeille sous le nom `Crok Desktop 1.5.3.app`. Videz ensuite la Corbeille : cette copie est une deuxième app avec l'identifiant de Crok Desktop. À partir de la 2.0.0, les mises à jour s'installent directement dans l'app en place. La mise à jour prend l'image compilée avec le même SDK que l'app installée (macOS26-SDK ou macOS15-SDK), jamais l'autre.

La connexion à vos fournisseurs de modèles, les réglages et les tâches sont conservés. Ce n'est pas le cas du contrôle à distance : reconnectez-vous comme l'explique la section **Contrôle à distance** ci-dessus, et installez les apps pour téléphone de cette version.

### Détails

- Intègre crok `{{CROK_VERSION}}`.
- Compilée par GitHub Actions à partir du tag `desktop-v2.0.0` sur `{{COMMIT}}` dans `main`. L'image du SDK macOS 26 a été compilée avec Xcode {{XCODE26}} et le SDK macOS {{SDK26}}, l'image du SDK macOS 15 avec Xcode {{XCODE15}} et le SDK macOS {{SDK15}}, et le `crok` autonome avec le SDK macOS {{TUI_SDK}}.
- Les deux images sont en arm64, signées par le certificat Crok Code Signing et non notariées, et fonctionnent toutes deux sur macOS 14 Sonoma ou une version ultérieure.
- L'app iOS (`dev.chenli.crok.mobile`) est une compilation Release faite avec Xcode {{XCODE26}} ; l'app Android est une compilation release pour Android 8.0 ou ultérieur.
- Les sommes de contrôle SHA-256 figurent à la fin de ces notes et dans `SHA256SUMS.txt`, qui couvre désormais aussi les apps pour téléphone. Le fichier `release/README.md` du dépôt explique comment vérifier à la main la signature de la liste.
