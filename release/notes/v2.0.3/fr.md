Crok Desktop 2.0.3 est l'app macOS native de ce fork. Elle intègre crok, l'environnement d'exécution de l'agent et l'interface terminal `crok`, il n'y a donc rien d'autre à installer. Elle suit la 2.0.2, qui a amené l'outil navigateur dans votre propre Chrome et les sélecteurs de modèle sur chaque appareil. La 2.0.3 tient à jour la liste des sessions de chaque appareil : une session créée, renommée ou supprimée sur un ordinateur atteint le web, les téléphones et les autres ordinateurs en une demi-minute environ. Une session démarrée sur un ordinateur depuis le web ou un téléphone apparaît désormais aussi sur cet ordinateur, comme tâche dans Crok Desktop et dans le panneau Distant du terminal. Une nouvelle session démarrée avec un modèle choisi démarre toujours sur ce modèle, et les appels Claude de crok ne sont plus comptés deux fois dans Agent Observability.

Comme la 2.0.2, cette version est compilée et publiée par GitHub Actions, dès la fusion de sa pull request.

### Installation

1. Téléchargez l'image disque qui correspond à votre version de macOS et ouvrez-la. Le tableau de la section **Quelle image disque télécharger** indique laquelle.
2. Faites glisser **Crok Desktop** sur **Applications**.
3. Ouvrez Crok Desktop depuis Applications. Cette version n'est pas notariée : la première fois, macOS indique donc qu'il ne peut pas vérifier l'app. Fermez le message, ouvrez **Réglages Système › Confidentialité et sécurité**, cliquez sur **Ouvrir quand même** à côté du message concernant Crok Desktop, puis confirmez. Cette opération n'est à faire qu'une fois.
4. Connectez-vous dans **Réglages › Comptes** avec OpenRouter, OpenAI Codex, une clé d'API Anthropic, une clé d'API DeepSeek ou une clé GLM Coding Plan.

Nécessite macOS 14 Sonoma ou une version ultérieure sur un Mac avec puce Apple (M1 ou plus récent).

### Quelle image disque télécharger

Les deux images correspondent à Crok Desktop 2.0.3 et contiennent les mêmes fonctionnalités. Elles ne diffèrent que par le SDK macOS utilisé pour la compilation, qui détermine si l'habillage de la fenêtre utilise le Liquid Glass d'Apple :

| Image disque | Compilée avec | À utiliser sur | Barre de titre |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.3-arm64-macOS26-SDK.dmg` | SDK macOS {{SDK26}} | macOS 26 et versions ultérieures | Liquid Glass |
| `Crok-Desktop-2.0.3-arm64-macOS15-SDK.dmg` | SDK macOS {{SDK15}} | macOS 14 et 15 | Flou dépoli dans la fenêtre |

Sur macOS 26 et versions ultérieures, préférez l'image du SDK macOS 26 pour avoir la barre de titre en Liquid Glass. Sur macOS 14 ou 15, prenez l'image du SDK macOS 15. Elle fonctionne aussi sur les versions ultérieures : si vous ne savez pas quelle version de macOS vous avez, c'est le choix sûr.

`crok-2.0.3-aarch64-apple-darwin.tar.gz` est l'interface de terminal `crok` seule, pour un Mac sur lequel vous ne voulez pas de l'app : décompressez-le et placez `crok` dans votre `PATH`. Les apps pour téléphone sont décrites dans la section **Apps pour téléphone**. `SHA256SUMS.txt` donne le SHA-256 de chaque téléchargement, et `SHA256SUMS.txt.sig` est la signature de cette liste, que l'outil de mise à jour vérifie.

### Apps pour téléphone

L'app Crok pour iPhone et Android suit les sessions de vos ordinateurs, affiche leurs réponses et leurs demandes d'autorisation, et lance ou pilote des tâches depuis n'importe où. Elle est fournie avec cette version, comme elle l'était avec la 2.0.2, et fonctionne comme celle de la 2.0.2 : les changements de cette version portent sur les ordinateurs et le relais, si bien que les apps pour téléphone de la 2.0.2 et de la 2.0.1 en profitent aussi. Les trois fichiers se connectent au relais de production.

- **Android 8.0 ou ultérieur :** téléchargez `Crok-Android-2.0.3.apk` sur le téléphone et ouvrez-le, en autorisant votre navigateur à installer des apps quand Android le demande, ou lancez `adb install -r Crok-Android-2.0.3.apk`. Il est signé avec la clé de publication, que les versions suivantes conserveront : l'APK suivant s'installera donc par-dessus. Un APK Crok que vous avez compilé vous-même est signé avec une autre clé et bloque l'installation : supprimez-le d'abord avec `adb uninstall dev.chenli.crok.mobile`, ou depuis les réglages du téléphone.
- **iPhone et iPad, iOS 17 ou ultérieur :** `Crok-iOS-2.0.3-unsigned.ipa` n'est pas signé, car une app pour appareils iOS est signée avec l'identifiant Apple de la personne qui l'installe. Installez-le avec un outil de sideloading comme AltStore ou Sideloadly, qui le signe avec votre identifiant Apple. Avec un identifiant Apple gratuit, iOS cesse d'ouvrir l'app au bout de 7 jours, jusqu'à ce que vous l'installiez de nouveau. Pour la compiler plutôt vous-même, utilisez la configuration **Release** : le bouton Run de Xcode compile la configuration Debug, qui se connecte au relais de test.
- **Simulateur iOS :** `Crok-iOS-2.0.3-Simulator.zip` se décompresse en `Crok.app`, à installer avec `xcrun simctl install booted Crok.app` sur un Mac équipé de Xcode.

Pour connecter le téléphone, touchez **Continuer avec GitHub ou Google**, connectez-vous sur la page qui s'ouvre à l'adresse https://crok.chenli.dev, puis touchez **Approuver**. Associez ensuite chaque ordinateur : lancez `crok remote login` dessus et scannez le code QR qu'il affiche depuis **Réglages › Associer un ordinateur** dans l'app, ou approuvez l'ordinateur sur la page web qui s'ouvre.

### Nouveautés

- **La liste des sessions de chaque appareil reste à jour.** Une session qui n'avait changé que sur le disque d'un ordinateur (créée par un crok qui n'était pas connecté au relais, renommée ou supprimée) n'atteignait le web, les téléphones et les autres ordinateurs qu'avec la liste complète suivante de cet ordinateur, qui arrivait environ toutes les 20 minutes et cessait quand le crok qui l'envoyait se fermait. Elle arrive maintenant en une demi-minute environ, et un autre crok de l'ordinateur reprend la liste dès que le premier se ferme.
- **Les sessions démarrées depuis le web ou un téléphone apparaissent sur leur ordinateur.** Crok Desktop ajoute une telle session comme tâche non lue dans son projet, et la montre au travail pendant qu'un tour s'exécute. Le terminal indique quel appareil l'a démarrée et la liste sous **Cet ordinateur** dans `/remote`.
- **Une nouvelle session démarre sur le modèle que vous avez choisi.** Une session démarrée depuis le web ou un téléphone avec un modèle et un niveau de réflexion choisis pouvait démarrer à la place sur le modèle par défaut de l'ordinateur, quand un crok plus ancien de cet ordinateur (par exemple un terminal resté ouvert depuis avant une mise à jour) la prenait en premier. Seul un crok qui applique ce choix peut désormais la prendre.
- **Les autres ordinateurs s'affichent aussitôt.** Dans Crok Desktop, **Autres ordinateurs** redemande la liste chaque fois que son lien avec le relais se connecte, puis toutes les 5 secondes tant qu'il n'a pas de réponse, au lieu d'attendre jusqu'à 4 minutes.
- **Les appels Claude n'arrivent qu'une fois dans Agent Observability.** L'export de télémétrie propre à Claude Platform stockait une seconde copie de chaque appel Claude que crok rapportait. crok demande désormais à l'API d'Anthropic de ne pas exporter les appels qu'il rapporte lui-même. Voir **Agent Observability** plus bas.

### Contrôle à distance

Chaque crok de cette version se connecte au relais de production à https://crok.chenli.dev, comme la 2.0.2, et garde la connexion qu'il a déjà. Le relais de production exécute déjà les changements de cette version qui le concernent, si bien que la règle sur le modèle choisi ci-dessous s'applique dès aujourd'hui ; le reste vient avec crok 2.0.3 sur chaque ordinateur.

- **Listes de sessions.** Sur chaque ordinateur, un crok tient la liste de cet ordinateur : toutes les 30 secondes, il regarde les sessions sur le disque et n'envoie que ce qui a changé, et toutes les 30 minutes il renvoie la liste entière. Quand il se ferme ou perd sa connexion, tous les autres crok de cet ordinateur sont invités à reprendre la liste, et le premier qui répond la reprend. Un ordinateur dont le crok redémarre liste aussitôt ses sessions. Les ordinateurs qui exécutent encore crok 2.0.2 ou plus ancien continuent d'envoyer eux-mêmes leur liste entière, désormais toutes les 10 minutes au lieu d'environ toutes les 20.
- **Sessions démarrées ailleurs, dans Crok Desktop.** Une session qu'un autre appareil a démarrée sur ce Mac devient une tâche de son projet dès que le relais la liste, avec le projet aussi quand l'app n'en a aucun pour ce dossier. Elle est non lue, prend le titre de la session jusqu'à ce que vous l'ouvriez, s'affiche au travail pendant qu'un tour s'y exécute et comme non lue quand il se termine, et s'ouvre comme n'importe quelle autre tâche. Chacune de ces sessions n'est ajoutée qu'une fois : une tâche ou un projet que vous avez supprimé ne revient donc pas.
- **Sessions démarrées ailleurs, dans le terminal.** Tant que le terminal est connecté au relais, il annonce chaque session qu'un autre appareil démarre sur cet ordinateur, par exemple "iPhone a démarré une session dans app : … — ouvrez-la avec /resume ou /remote". Le panneau Distant liste ces sessions en premier, sous **Cet ordinateur**, chacune marquée de l'appareil d'où elle vient ("depuis iPhone"). Entrée en ouvre une ici, et `n` sur cet ordinateur renvoie vers `/new`.
- **Le modèle choisi.** Une nouvelle session qui porte un modèle ou un niveau de réflexion ne va qu'à un crok qui l'applique : crok 2.0.1 et ultérieur. Sur un ordinateur qui n'exécute que crok 2.0.0 ou plus ancien, démarrer une telle session échoue avec "Update crok on … to start a session there with a chosen model or thinking level" (mettez à jour crok sur … pour y démarrer une session avec un modèle ou un niveau de réflexion choisi) au lieu de démarrer sur le modèle par défaut. Une session sur **Par défaut** continue de démarrer sur n'importe quel crok. Un prompt ou une nouvelle tentative qui rouvre une session qui n'a pas pu démarrer suit la même règle.
- **Mettez à jour les ordinateurs.** Les listes qui suivent le disque, et les sessions d'autres appareils qui apparaissent sur leur ordinateur, viennent avec crok 2.0.3 sur cet ordinateur. Rien ne change sur les téléphones.

### Agent Observability

Comme dans la 2.0.2, chaque crok de cette version rapporte chaque appel au modèle qu'il fait, avec ses tours, ses exécutions d'outils, ses étapes et ses vérifications des gardes, à [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) sur le stack Grafana Cloud du mainteneur, et `crok version --json` indique l'hôte sous `agentObservability`.

- **Plus de seconde copie des appels Claude.** Une organisation Claude Platform peut exporter un span de trace de chaque requête d'API vers ses destinations de télémétrie, et Agent Observability faisait de chacun d'eux une conversation à part, nommée d'après son identifiant de trace, sous l'agent `claude-platform`. Chaque appel Claude que crok rapportait était donc stocké deux fois. crok envoie désormais à `api.anthropic.com` les appels qu'il rapporte avec un contexte de trace marqué comme non échantillonné, ce à quoi l'API d'Anthropic répond en n'exportant rien pour eux. Les appels que crok ne rapporte pas (les compactages, et tous les appels faits pendant que l'envoi est coupé) sont exportés comme avant, tout comme les appels vers d'autres fournisseurs.
- **Si votre organisation exporte la télémétrie de Claude,** les appels Claude que crok rapporte à Agent Observability ne figurent plus dans cet export ; coupez l'envoi pour les y retrouver.
- **Les tableaux de bord comptent les appels Claude de crok à la place de ceux de Claude Platform.** Le span de crok pour un tel appel indique `crok.unsampled = true` et porte ses lectures de cache et ses tokens de réflexion sous les noms d'attributs de Claude Platform, si bien que les tableaux de bord LLM Observability ne le comptent qu'une fois. Les appels de crok 2.0.2 et plus ancien sont toujours comptés à partir de l'export de Claude Platform.
- **Les copies déjà stockées sont marquées.** Agent Observability ne peut pas supprimer ce qu'il a stocké : chacune des 586 copies faites par crok 1.5.0 à 2.0.2 porte donc une étiquette qui la désigne comme copie d'un appel de crok, ce qui la distingue des appels que seule Claude Platform a vus. Chaque ordinateur encore sous crok 2.0.2 ou plus ancien continue d'ajouter des copies jusqu'à sa mise à jour.

Pour couper l'envoi, ajoutez `agent_observability = false` sous `[features]` dans `~/.crok/config.toml`, ou définissez `CROK_AGENT_OBSERVABILITY=0`. Pour envoyer vers votre propre stack, écrivez `~/.crok/agento11y.env` avec `crates/codegen/xai-grok-agento11y/setup.sh` du dépôt.

### Pour les développeurs

- Les versions sont faites par `.github/workflows/release.yml` comme avant : quand une pull request qui augmente `VERSION` est fusionnée dans `main`, il compile, vérifie et signe chaque fichier, exécute le contrôle des évaluations et publie la version avec les notes de `release/notes/v2.0.3/`.
- Le relais garde un détenteur du catalogue par ordinateur : `bridge:catalogUpdate` prend les changements du détenteur depuis son dernier envoi (`EXPIRED` dès qu'un autre processus le détient), un catalogue libéré dépose `catalogWanted` dans la boîte de réception de chaque crok de cet ordinateur, et `bridge:connect` liste `catalog`. `sessions:create` stocke `startedFrom` (`{kind: phone | web | computer, name, at}`), et `x.ai/remote/sessions` du visualiseur porte `here`, les sessions de cet ordinateur démarrées ailleurs (les 100 plus récentes). `relay/DESIGN.md` §2–§5 décrit tout cela.
- Un `create` qui porte un modèle ou un niveau de réflexion n'est proposé qu'aux hôtes dont `features` liste `setup` (crok 2.0.3 le liste) ou `git` (crok 2.0.1 et 2.0.2).
- `relay/scripts/sessions-live-e2e.mjs` vérifie deux ordinateurs et un téléphone face à un relais local : sessions en cours listées aussitôt, sessions créées et supprimées sur le disque, détenteur qui se ferme, session d'un téléphone qui atteint l'interface de l'ordinateur lui-même. `commands-e2e` et `bridge-e2e` vérifient désormais où démarre une session avec un modèle choisi et sur quoi son premier tour s'est exécuté.
- Les compilations Debug des apps pour téléphone ont un troisième onglet, **o11y**, à droite de **Profil** : les tableaux de bord Grafana Cloud du propriétaire, ses évaluations et Agent Observability sous forme de pages pour téléphone, construites par le relais (`o11y:page`, `o11y:refresh` ; `mobile/DESIGN.md` "o11y", `relay/DESIGN.md` §3). Les compilations Release, y compris celles de cette version, ne l'ont pas, et le relais de production l'a désactivé. `relay/scripts/o11y-setup.sh` crée le compte de service en lecture seule et les variables du déploiement, `o11y-preview.mjs` construit les pages sans relais, et `o11y-demo.mjs` crée les pages de démonstration des téléphones.
- `observability/agento11y/stack.py duplicates [--label]` retrouve par identifiant de réponse les copies des appels de crok faites par Claude Platform et étiquette chacune d'elles, et `gcx_api` demande désormais à gcx du JSON simple, si bien que `backfill` ne saute plus les longues conversations.

### Signature

La 2.0.3 est signée par le même certificat "Crok Code Signing" que la 2.0.2, la 2.0.1, la 2.0.0, la 1.5.2 et la 1.5.3. macOS lie les autorisations de confidentialité à la signature : ce que vous avez autorisé pour la 2.0.2 (Enregistrement de l'écran, Accessibilité, microphone, reconnaissance vocale) est donc conservé pour la 2.0.3. Cette compilation n'est pas notariée : une nouvelle installation nécessite donc une fois l'étape **Ouvrir quand même** ci-dessus.

L'app Android est signée avec la clé de publication que la 2.0.0 a introduite. L'app iOS n'est pas signée, comme l'explique la section **Apps pour téléphone**. La liste signée des sommes de contrôle est une chose distincte : elle permet à l'outil de mise à jour de vérifier un téléchargement et ne change pas la façon dont macOS traite l'app.

### Mise à jour depuis la 2.0.2

Utilisez **Crok Desktop › Rechercher des mises à jour…**, ou `crok upgrade` dans un terminal après avoir quitté Crok Desktop. Cette mise à jour est effectuée en place, dans le `Crok Desktop.app` installé : l'app garde donc sa place dans le Dock et le Finder, et aucune ancienne copie ne reste dans la Corbeille. La mise à jour prend l'image compilée avec le même SDK que l'app installée (macOS26-SDK ou macOS15-SDK), jamais l'autre.

La connexion à vos fournisseurs de modèles, les réglages, les tâches et le relais sont conservés : la 2.0.3 parle au même relais de production que la 2.0.2. Mettez à jour chaque ordinateur que vous utilisez avec le relais, pour que ses sessions restent à jour partout. Les apps pour téléphone n'ont pas besoin de mise à jour, comme l'indique la section **Apps pour téléphone** ci-dessus.

### Détails

- Intègre crok `{{CROK_VERSION}}`.
- Compilée par GitHub Actions à partir du tag `desktop-v2.0.3` sur `{{COMMIT}}` dans `main`. L'image du SDK macOS 26 a été compilée avec Xcode {{XCODE26}} et le SDK macOS {{SDK26}}, l'image du SDK macOS 15 avec Xcode {{XCODE15}} et le SDK macOS {{SDK15}}, et le `crok` autonome avec le SDK macOS {{TUI_SDK}}.
- Les deux images sont en arm64, signées par le certificat Crok Code Signing et non notariées, et fonctionnent toutes deux sur macOS 14 Sonoma ou une version ultérieure.
- L'app iOS (`dev.chenli.crok.mobile`) est une compilation Release faite avec Xcode {{XCODE26}} ; l'app Android est une compilation release pour Android 8.0 ou ultérieur.
- Les sommes de contrôle SHA-256 figurent à la fin de ces notes et dans `SHA256SUMS.txt`, qui couvre aussi les apps pour téléphone. Le fichier `release/README.md` du dépôt explique comment vérifier à la main la signature de la liste.
