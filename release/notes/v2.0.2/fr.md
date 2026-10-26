Crok Desktop 2.0.2 est l'app macOS native de ce fork. Elle intègre crok, l'environnement d'exécution de l'agent et l'interface terminal `crok`, il n'y a donc rien d'autre à installer. Elle suit la 2.0.1, qui a redessiné les deux apps pour téléphone autour des ordinateurs, des projets et des sujets. Dans la 2.0.2, l'outil navigateur travaille dans le Chrome que vous utilisez déjà, connecté en votre nom. Chaque appareil peut choisir le modèle et le niveau de réflexion de l'ordinateur d'une session, l'app web suit le design des apps pour téléphone et le terminal a un panneau Distant. La fin d'un tour atteint désormais le web et les téléphones en une seconde environ. Agent Observability suit des tours entiers, et le workflow de publication peut lancer une suite d'évaluations avant de publier.

Comme la 2.0.1, cette version est compilée et publiée par GitHub Actions, dès la fusion de sa pull request.

### Installation

1. Téléchargez l'image disque qui correspond à votre version de macOS et ouvrez-la. Le tableau de la section **Quelle image disque télécharger** indique laquelle.
2. Faites glisser **Crok Desktop** sur **Applications**.
3. Ouvrez Crok Desktop depuis Applications. Cette version n'est pas notariée : la première fois, macOS indique donc qu'il ne peut pas vérifier l'app. Fermez le message, ouvrez **Réglages Système › Confidentialité et sécurité**, cliquez sur **Ouvrir quand même** à côté du message concernant Crok Desktop, puis confirmez. Cette opération n'est à faire qu'une fois.
4. Connectez-vous dans **Réglages › Comptes** avec OpenRouter, OpenAI Codex, une clé d'API Anthropic, une clé d'API DeepSeek ou une clé GLM Coding Plan.

Nécessite macOS 14 Sonoma ou une version ultérieure sur un Mac avec puce Apple (M1 ou plus récent).

### Quelle image disque télécharger

Les deux images correspondent à Crok Desktop 2.0.2 et contiennent les mêmes fonctionnalités. Elles ne diffèrent que par le SDK macOS utilisé pour la compilation, qui détermine si l'habillage de la fenêtre utilise le Liquid Glass d'Apple :

| Image disque | Compilée avec | À utiliser sur | Barre de titre |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.2-arm64-macOS26-SDK.dmg` | SDK macOS {{SDK26}} | macOS 26 et versions ultérieures | Liquid Glass |
| `Crok-Desktop-2.0.2-arm64-macOS15-SDK.dmg` | SDK macOS {{SDK15}} | macOS 14 et 15 | Flou dépoli dans la fenêtre |

Sur macOS 26 et versions ultérieures, préférez l'image du SDK macOS 26 pour avoir la barre de titre en Liquid Glass. Sur macOS 14 ou 15, prenez l'image du SDK macOS 15. Elle fonctionne aussi sur les versions ultérieures : si vous ne savez pas quelle version de macOS vous avez, c'est le choix sûr.

`crok-2.0.2-aarch64-apple-darwin.tar.gz` est l'interface de terminal `crok` seule, pour un Mac sur lequel vous ne voulez pas de l'app : décompressez-le et placez `crok` dans votre `PATH`. Les apps pour téléphone sont décrites dans la section **Apps pour téléphone**. `SHA256SUMS.txt` donne le SHA-256 de chaque téléchargement, et `SHA256SUMS.txt.sig` est la signature de cette liste, que l'outil de mise à jour vérifie.

### Apps pour téléphone

L'app Crok pour iPhone et Android suit les sessions de vos ordinateurs, affiche leurs réponses et leurs demandes d'autorisation, et lance ou pilote des tâches depuis n'importe où. Elle est fournie avec cette version, comme elle l'était avec la 2.0.1. Les trois fichiers se connectent au relais de production.

- **Android 8.0 ou ultérieur :** téléchargez `Crok-Android-2.0.2.apk` sur le téléphone et ouvrez-le, en autorisant votre navigateur à installer des apps quand Android le demande, ou lancez `adb install -r Crok-Android-2.0.2.apk`. Il est signé avec la clé de publication, que les versions suivantes conserveront : l'APK suivant s'installera donc par-dessus. Un APK Crok que vous avez compilé vous-même est signé avec une autre clé et bloque l'installation : supprimez-le d'abord avec `adb uninstall dev.chenli.crok.mobile`, ou depuis les réglages du téléphone.
- **iPhone et iPad, iOS 17 ou ultérieur :** `Crok-iOS-2.0.2-unsigned.ipa` n'est pas signé, car une app pour appareils iOS est signée avec l'identifiant Apple de la personne qui l'installe. Installez-le avec un outil de sideloading comme AltStore ou Sideloadly, qui le signe avec votre identifiant Apple. Avec un identifiant Apple gratuit, iOS cesse d'ouvrir l'app au bout de 7 jours, jusqu'à ce que vous l'installiez de nouveau. Pour la compiler plutôt vous-même, utilisez la configuration **Release** : le bouton Run de Xcode compile la configuration Debug, qui se connecte au relais de test.
- **Simulateur iOS :** `Crok-iOS-2.0.2-Simulator.zip` se décompresse en `Crok.app`, à installer avec `xcrun simctl install booted Crok.app` sur un Mac équipé de Xcode.

Pour connecter le téléphone, touchez **Continuer avec GitHub ou Google**, connectez-vous sur la page qui s'ouvre à l'adresse https://crok.chenli.dev, puis touchez **Approuver**. Associez ensuite chaque ordinateur : lancez `crok remote login` dessus et scannez le code QR qu'il affiche depuis **Réglages › Associer un ordinateur** dans l'app, ou approuvez l'ordinateur sur la page web qui s'ouvre.

### Nouveautés

- **L'outil navigateur travaille dans votre propre Chrome.** Il ouvre une fenêtre du navigateur que vous utilisez déjà, sur le profil utilisé en dernier, si bien que les sites où vous êtes connecté le restent. Il faut activer une option dans Chrome une fois et cliquer sur **Allow** : voir **Votre propre navigateur** plus bas.
- **Choisissez le modèle et le niveau de réflexion d'une session sur chaque appareil.** iPhone, Android et le web affichent deux pastilles au-dessus du champ de saisie, dans les sessions nouvelles et ouvertes : le modèle, avec une feuille qui cherche et regroupe les modèles par fournisseur, et le niveau de réflexion. Une nouvelle tâche dans **Autres ordinateurs** de Crok Desktop propose le même choix avant de démarrer.
- **Les ordinateurs aux centaines de modèles les proposent tous.** Un ordinateur connecté à OpenRouter liste environ 480 modèles. Le relais refusait toute liste de plus de 200, si bien qu'un tel ordinateur ne proposait aucun choix ; il en garde désormais jusqu'à 1 000.
- **L'app web suit les apps pour téléphone.** Elle est organisée comme Telegram Web : à gauche les projets de l'ordinateur choisi et leurs sujets, au milieu la session avec son thème, à droite les infos de la session.
- **Un panneau Distant dans le terminal.** `/remote` montre les autres ordinateurs, leurs projets et leurs sessions, comme **Autres ordinateurs** dans Crok Desktop, et `n` y démarre une session sur le modèle de votre choix.
- **La fin d'un tour atteint aussitôt le web et les téléphones.** Après un tour chargé, ils montraient encore la session au travail pendant des secondes, parfois des minutes, alors que l'ordinateur avait fini. La fin arrive maintenant en une seconde environ.
- **Les longues sessions s'ouvrent vite sur les téléphones.** Les apps pour téléphone chargent la transcription par petites parties en direct, gardent en vue le premier prompt d'une nouvelle session et montrent la réflexion et les appels d'outils par leur état, comme Crok Desktop.
- **Les modèles à 1M de tokens d'OpenRouter fonctionnent au-delà de 105K tokens.** crok demandait une marge de sortie qui ne laissait aucune place au prompt, ce qu'OpenRouter refusait dès que la conversation grandissait ; il ne demande plus que la sortie qui tient à côté du prompt.
- **Agent Observability suit des tours entiers.** Chaque tour est une trace avec ses appels au modèle et ses exécutions d'outils, et le stack du mainteneur note le trafic réel et vérifie les appels d'outils qui peuvent modifier quelque chose. Voir **Agent Observability** plus bas.

### Votre propre navigateur

L'outil navigateur démarrait un navigateur à lui, avec un profil propre à Crok. Il ouvre maintenant une fenêtre du Chrome que vous utilisez déjà, sur le profil utilisé en dernier, si bien que vous restez connecté à tous vos sites. Le modèle est prévenu que la fenêtre peut être connectée en votre nom.

- **Activez le débogage à distance une fois.** Il faut Chrome 144 ou plus récent. Ouvrez `chrome://inspect/#remote-debugging` dans Chrome et activez **Allow remote debugging for this browser instance**. Chrome refuse une adresse `chrome://` transmise par une autre app, c'est pourquoi **Réglages › Utilisation du navigateur et de l'ordinateur** de Crok Desktop a un bouton **Copier l'adresse**.
- **Autorisez chaque tâche une fois.** Quand une tâche utilise le navigateur pour la première fois, Chrome demande **Allow remote debugging?** Cliquez sur **Allow**. Crok attend la réponse deux minutes et indique quoi faire si le débogage à distance est désactivé ou si la demande a été refusée.
- **Votre navigateur reste le vôtre.** Crok ne le quitte jamais et ne s'approprie pas ses onglets de démarrage, et les téléchargements vont là où vos réglages de Chrome les envoient.
- **Le profil propre à Crok existe toujours.** Choisissez **Profil propre à Crok** dans **Réglages › Utilisation du navigateur et de l'ordinateur › Profil du navigateur** de Crok Desktop, ou mettez `profile = "crok"` sous `[toolset.browser]` dans `~/.crok/config.toml`. La valeur par défaut est `profile = "user"`.

Testé avec Chrome sur macOS. Edge, Brave et Chromium ne sont pas encore testés.

### Contrôle à distance

Chaque crok de cette version se connecte au relais de production à https://crok.chenli.dev, comme la 2.0.1, et garde la connexion qu'il a déjà.

- **Modèle et niveau de réflexion.** Dans une nouvelle session, les pastilles affichent **Default** jusqu'à ce que vous choisissiez, et la session démarre sur votre choix. Dans une session ouverte, un changement part vers son ordinateur, et la pastille tourne jusqu'à ce que cet ordinateur l'ait appliqué ; s'il refuse, l'ancienne valeur revient avec la raison. Les infos de la session montrent les deux mêmes lignes, et les commandes `/model` et `/think` des téléphones lisent la même liste.
- **L'app web.** Sa colonne de gauche est une pile de pages : les sessions de l'ordinateur choisi avec ses projets, les sujets d'un projet, les sessions archivées et le profil. Les sujets ont des actions au survol et des menus contextuels pour épingler, arrêter, marquer comme lu, archiver et réordonner. Les thèmes de session et le mode de couleur sont conservés dans le navigateur. En dessous de 1024 pixels de large, elle affiche une colonne à la fois.
- **Le panneau Distant du terminal.** `/remote` et `/remote open` montrent le compte, cet ordinateur et la connexion, puis un arbre des autres ordinateurs (en ligne ou vus pour la dernière fois, avec les non-lus), de leurs projets et des sessions de chaque projet. Entrée ouvre une session comme `/resume`, `n` en démarre une en demandant le modèle et le niveau de réflexion de cet ordinateur, et la saisie filtre l'arbre. `/remote status` affiche l'ancien texte. Une session d'un autre ordinateur montre sa branche et ses chiffres de tokens dans la ligne d'état, et `/model` y ne change plus le défaut de cet ordinateur.
- **Les fins de tour arrivent aussitôt.** Le lien avec le relais regroupe désormais en une seule écriture les mises à jour qui attendent derrière chacune, si bien qu'un tour chargé ne forme plus une file qui retarde sa fin. Un tour terminé s'affiche comme terminé même quand un prompt en file en est sorti sans être exécuté, et un prompt envoyé ensuite depuis un téléphone s'exécute.
- **Les téléphones chargent les longues sessions par parties.** Les apps pour téléphone ouvrent une transcription sur ses 40 éléments les plus récents et chargent les plus anciens par 60 au défilement, si bien qu'une session reflétée depuis des semaines s'ouvre vite sur un réseau lent. Le premier prompt d'une nouvelle session reste au-dessus du champ de saisie. La réflexion s'affiche en cours puis terminée, et un appel d'outil en cours, terminé, en échec ou arrêté. Le relais n'envoie plus aux téléphones le texte d'une réflexion ni la sortie d'un outil.
- **Mettez à jour les ordinateurs et les téléphones.** Les listes de modèles et les fins de tour plus rapides viennent avec crok 2.0.2 sur l'ordinateur qui a la session, et les pastilles et la fenêtre de transcription avec les apps pour téléphone 2.0.2. Les apps pour téléphone de la 2.0.1 continuent de fonctionner avec le relais.

### Agent Observability

Comme dans la 2.0.1, chaque crok de cette version envoie chaque appel au modèle qu'il fait à [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) sur le stack Grafana Cloud du mainteneur, et `crok version --json` indique l'hôte sous `agentObservability`. La 2.0.2 rapporte aussi ce qui se passe entre les appels :

- **Tours et exécutions d'outils.** Un tour est une trace dont le span racine contient ses appels au modèle et ses exécutions d'outils, avec la façon dont le tour s'est terminé et le nombre d'appels et d'erreurs d'outils. Une exécution d'outil enregistre son résultat, son type, son code de sortie et la taille de sa sortie, pas ses arguments ni son contenu. Le tour d'un sous-agent se place sous le tour qui l'a lancé.
- **Étapes, verdicts et notes.** Les décisions de permission, les résultats du hook PreToolUse, les compactages et les démarrages de serveurs MCP apparaissent comme des étapes de la conversation. L'évaluateur d'objectif de crok, son classificateur de paresse, sa garde contre les appels répétés et sa limite de tours envoient des scores, et les notes que vous donnez y vont aussi, en plus de xAI.
- **Étiquettes.** Les appels portent `origin` (`local`, `headless` pour `crok -p`, `relay` pour les prompts du web et des téléphones, `eval` pour les expériences), ainsi que `repo`, `branch` et `user`, le nom de session de l'ordinateur.
- **Vérifications des gardes, en mode avertissement.** Avant qu'un appel d'outil pouvant modifier quelque chose ne s'exécute, et avant qu'un résultat d'outil ne revienne au modèle, crok l'envoie aux gardes du stack, qui cherchent des commandes git réécrivant l'historique, des commandes shell destructrices et des clés réelles. crok n'attend jamais la réponse et ne bloque jamais un appel ; une correspondance est enregistrée comme avertissement sur la conversation. `CROK_AGENTO11Y_GUARDS=off` arrête les vérifications.
- **Métriques.** `crok_turns_total`, `crok_tool_runs_total`, `crok_workflow_steps_total` et `crok_guard_checks_total`, avec les durées des tours et des outils, alimentent le tableau de bord du harness du stack, ses alertes et ses SLO.

Pour couper l'envoi, ajoutez `agent_observability = false` sous `[features]` dans `~/.crok/config.toml`, ou définissez `CROK_AGENT_OBSERVABILITY=0`. Pour envoyer vers votre propre stack, écrivez `~/.crok/agento11y.env` avec `crates/codegen/xai-grok-agento11y/setup.sh` du dépôt.

### Pour les développeurs

- Les versions sont faites par `.github/workflows/release.yml` comme avant : quand une pull request qui augmente `VERSION` est fusionnée dans `main`, il compile, vérifie et signe chaque fichier et publie la version avec les notes de `release/notes/v2.0.2/`.
- Le workflow de publication a un nouveau job `eval`, que `publish` attend. Il exécute deux fois les sept cas de fumée de `evals/run.py` contre la compilation de la version et échoue quand pass@1 tombe de plus de 0,20 sous `evals/baselines/smoke.json`, ou quand un cas de sécurité qui passait toujours échoue. Sans le secret `CROK_EVAL_OPENROUTER_API_KEY` dans l'environnement release, il avertit et passe.
- `evals/run.py` exécute crok sans interface sur de petits dépôts de test en trois suites (`s1` régressions, `s2` utilisation des outils, `s3` sécurité ; 22 cas) et rapporte les taux de réussite, le coût et le comportement par modèle et par compilation. `evals/README.md` décrit les cas et les vérifications.
- `observability/agento11y/stack.json` contient les évaluateurs, règles et gardes du stack, et `observability/agento11y/stack.py` les applique via l'API du plugin Agent Observability, note les conversations stockées avant qu'une règle existe et installe les alertes et les SLO.
- L'échantillonneur rapporte chaque tour, exécution d'outil, étape, verdict, note et vérification de garde via `crates/codegen/xai-grok-sampler/src/observe_harness.rs`, et le pont les enregistre dans `crates/codegen/xai-grok-agento11y/bridge/src/harness.ts`.
- `sessions:transcript` du relais renvoie une plage des éléments d'une session, les plus récents d'abord et sans le texte des réflexions ni la sortie des outils, pour la fenêtre de transcription des téléphones (`relay/DESIGN.md` §3). `bridge:setModels` garde jusqu'à 1 000 modèles, `devices:models` est la liste que lisent les clients, et le visualiseur de crok la demande avec `x.ai/remote/models`.
- Le lien avec le relais regroupe en une écriture les mises à jour en attente d'une session (`fold_backlog`), et `relay/scripts/status-e2e.mjs` mesure à quelle vitesse un téléphone voit la fin d'un tour à travers un relais lent.
- La requête OpenRouter ajuste `max_tokens` à la fenêtre de contexte moins le prompt estimé.

### Signature

La 2.0.2 est signée par le même certificat "Crok Code Signing" que la 2.0.1, la 2.0.0, la 1.5.2 et la 1.5.3. macOS lie les autorisations de confidentialité à la signature : ce que vous avez autorisé pour la 2.0.1 (Enregistrement de l'écran, Accessibilité, microphone, reconnaissance vocale) est donc conservé pour la 2.0.2. Cette compilation n'est pas notariée : une nouvelle installation nécessite donc une fois l'étape **Ouvrir quand même** ci-dessus.

L'app Android est signée avec la clé de publication que la 2.0.0 a introduite. L'app iOS n'est pas signée, comme l'explique la section **Apps pour téléphone**. La liste signée des sommes de contrôle est une chose distincte : elle permet à l'outil de mise à jour de vérifier un téléchargement et ne change pas la façon dont macOS traite l'app.

### Mise à jour depuis la 2.0.1

Utilisez **Crok Desktop › Rechercher des mises à jour…**, ou `crok upgrade` dans un terminal après avoir quitté Crok Desktop. Cette mise à jour est effectuée en place, dans le `Crok Desktop.app` installé : l'app garde donc sa place dans le Dock et le Finder, et aucune ancienne copie ne reste dans la Corbeille. La mise à jour prend l'image compilée avec le même SDK que l'app installée (macOS26-SDK ou macOS15-SDK), jamais l'autre.

La connexion à vos fournisseurs de modèles, les réglages, les tâches et le relais sont conservés : la 2.0.2 parle au même relais de production que la 2.0.1. Les apps pour téléphone s'installent à partir des fichiers de cette version, comme l'explique la section **Apps pour téléphone** ci-dessus.

### Détails

- Intègre crok `{{CROK_VERSION}}`.
- Compilée par GitHub Actions à partir du tag `desktop-v2.0.2` sur `{{COMMIT}}` dans `main`. L'image du SDK macOS 26 a été compilée avec Xcode {{XCODE26}} et le SDK macOS {{SDK26}}, l'image du SDK macOS 15 avec Xcode {{XCODE15}} et le SDK macOS {{SDK15}}, et le `crok` autonome avec le SDK macOS {{TUI_SDK}}.
- Les deux images sont en arm64, signées par le certificat Crok Code Signing et non notariées, et fonctionnent toutes deux sur macOS 14 Sonoma ou une version ultérieure.
- L'app iOS (`dev.chenli.crok.mobile`) est une compilation Release faite avec Xcode {{XCODE26}} ; l'app Android est une compilation release pour Android 8.0 ou ultérieur.
- Les sommes de contrôle SHA-256 figurent à la fin de ces notes et dans `SHA256SUMS.txt`, qui couvre désormais aussi les apps pour téléphone. Le fichier `release/README.md` du dépôt explique comment vérifier à la main la signature de la liste.
