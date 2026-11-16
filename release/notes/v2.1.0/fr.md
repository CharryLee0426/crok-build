Crok Desktop 2.1.0 est l'app macOS native de ce fork. Elle intègre crok, l'environnement d'exécution de l'agent et l'interface terminal `crok`, il n'y a donc rien d'autre à installer. Elle suit la 2.0.4, qui a apporté les photos et les fichiers aux prompts distants. La 2.1.0 ajoute Meta Model API comme septième fournisseur, avec ses modèles Muse, au terminal et à Crok Desktop. Le web et les apps du téléphone affichent désormais ensemble le modèle et le niveau de réflexion d'une session, y compris pour les sessions ouvertes depuis la liste. Crok Desktop ne dessine son verre que dans la fenêtre active et peint lui-même le verre de la zone de saisie : une fenêtre inactive derrière d'autres apps coûte donc ce que coûte une fenêtre ordinaire, et Mission Control reste fluide. Le pouce de feedback choisi se remplit, et le point d'état d'**Autres ordinateurs** est plus grand et vert en ligne.

Comme la 2.0.4, cette version est compilée et publiée par GitHub Actions, dès la fusion de sa pull request.

### Installation

1. Téléchargez l'image disque qui correspond à votre version de macOS et ouvrez-la. Le tableau de **Quelle image disque télécharger** indique laquelle.
2. Glissez **Crok Desktop** sur **Applications**.
3. Ouvrez Crok Desktop depuis Applications. Cette version n'est pas notariée : la première fois, macOS indique donc qu'il ne peut pas vérifier l'app. Fermez le message, ouvrez **Réglages Système › Confidentialité et sécurité**, cliquez sur **Ouvrir quand même** à côté du message concernant Crok Desktop, puis confirmez. Cette opération n'est à faire qu'une fois.
4. Connectez-vous dans **Réglages › Comptes** avec OpenRouter, OpenAI Codex, une clé d'API Anthropic, une clé d'API DeepSeek, une clé de Meta Model API ou une clé GLM Coding Plan.

Nécessite macOS 14 Sonoma ou ultérieur sur Apple silicon (M1 ou ultérieur).

### Quelle image disque télécharger

Les deux images sont Crok Desktop 2.1.0 et contiennent les mêmes fonctions. Elles ne diffèrent que par le SDK macOS avec lequel elles ont été compilées, qui décide si le cadre de la fenêtre utilise le Liquid Glass d'Apple :

| Image disque | Compilée avec | À utiliser sur | Barre de titre |
| --- | --- | --- | --- |
| `Crok-Desktop-2.1.0-arm64-macOS26-SDK.dmg` | SDK macOS {{SDK26}} | macOS 26 et ultérieur | Liquid Glass |
| `Crok-Desktop-2.1.0-arm64-macOS15-SDK.dmg` | SDK macOS {{SDK15}} | macOS 14 et 15 | Flou dépoli dans la fenêtre |

Sur macOS 26 et ultérieur, préférez l'image du SDK macOS 26 pour la barre de titre Liquid Glass. Sur macOS 14 ou 15, prenez l'image du SDK macOS 15. Elle fonctionne aussi sur les versions ultérieures : si vous ne savez pas quelle version de macOS vous avez, c'est le choix sûr. La zone de saisie est dessinée de la même façon dans les deux images.

`crok-2.1.0-aarch64-apple-darwin.tar.gz` est l'interface terminal `crok` seule, pour un Mac où vous ne voulez pas l'app : décompressez-la et placez `crok` dans votre `PATH`. Les apps du téléphone sont décrites dans **Apps pour téléphone**. `SHA256SUMS.txt` liste le SHA-256 de chaque téléchargement, et `SHA256SUMS.txt.sig` est la signature de cette liste, que l'outil de mise à jour vérifie.

### Apps pour téléphone

L'app Crok pour iPhone et Android suit les sessions de vos ordinateurs, affiche leurs réponses et demandes d'autorisation, et permet de lancer ou de diriger des tâches depuis n'importe où. Les apps du téléphone de cette version sont nouvelles : une session ouverte affiche ensemble son modèle et son niveau de réflexion, et un modèle qu'un ordinateur plus ancien nomme à la manière du fournisseur est quand même trouvé dans la liste. Installez-les par-dessus celles de la 2.0.4 pour en profiter. Les apps du téléphone de la 2.0.4 et antérieures continuent de fonctionner comme avant. Les trois fichiers se connectent au relais de production.

- **Android 8.0 ou ultérieur :** téléchargez `Crok-Android-2.1.0.apk` sur le téléphone et ouvrez-le, en autorisant votre navigateur à installer des apps quand Android le demande, ou exécutez `adb install -r Crok-Android-2.1.0.apk`. Il est signé par la clé de publication introduite par la 2.0.0, donc il s'installe par-dessus l'APK d'une version antérieure. Un APK Crok que vous avez compilé vous-même est signé par une autre clé et bloque l'installation : retirez-le d'abord avec `adb uninstall dev.chenli.crok.mobile`, ou depuis les réglages du téléphone.
- **iPhone et iPad, iOS 17 ou ultérieur :** `Crok-iOS-2.1.0-unsigned.ipa` n'est pas signé, car une app pour appareils iOS est signée avec l'Apple ID de la personne qui l'installe. Installez-le avec un outil de chargement latéral comme AltStore ou Sideloadly, qui le signe avec votre Apple ID. Avec un Apple ID gratuit, iOS cesse d'ouvrir l'app au bout de 7 jours jusqu'à ce que vous l'installiez de nouveau. Pour la compiler vous-même, utilisez la configuration **Release** : le bouton Run de Xcode compile Debug, qui se connecte au relais de test.
- **Simulateur iOS :** `Crok-iOS-2.1.0-Simulator.zip` se décompresse en `Crok.app`, pour `xcrun simctl install booted Crok.app` sur un Mac avec Xcode.

Pour connecter le téléphone, touchez **Continuer avec GitHub ou Google**, connectez-vous sur la page qui s'ouvre à l'adresse https://crok.chenli.dev, puis touchez **Approuver**. Associez ensuite chaque ordinateur : lancez `crok remote login` dessus et scannez le code QR qu'il affiche depuis **Réglages › Associer un ordinateur** dans l'app, ou approuvez l'ordinateur sur la page web qui s'ouvre.

### Points forts

- **Meta Model API, un septième fournisseur.** Le terminal et Crok Desktop se connectent au Model API de Meta, facturé au token sur un compte Meta, avec une clé obtenue sur dev.meta.ai. `crok login meta` demande la clé sans l'afficher et la vérifie auprès de Meta avant de l'enregistrer ; une clé refusée n'est pas enregistrée. `meta-code` et `muse` sont des alias, `META_API_KEY` et `MODEL_API_KEY` connectent de la même façon, et `crok logout meta` supprime la clé enregistrée. **Réglages › Comptes** de Crok Desktop et le menu du premier lancement du terminal listent le fournisseur.
- **Les modèles Muse.** La connexion récupère la liste de modèles de votre compte, qui se rafraîchit ensuite toutes les heures. La liste intégrée contient Muse Wonder, Muse Spark 1.3, 1.2 et 1.1, leurs variantes en mode Contributor et Muse Ember ; un modèle que Meta publie plus tard fonctionne aussitôt avec son ID `meta/<model>`. Ces modèles lisent le texte, les images, les PDF, l'audio et la vidéo. Ils réfléchissent toujours : `/effort` propose `minimal`, `low`, `medium`, `high`, `xhigh` et `max`, avec `max` par défaut sur Muse Wonder et Muse Ember et `high` sur Muse Spark. `none` n'est pas proposé, car Meta le refuse, et les variantes Contributor s'arrêtent à `xhigh`.
- **Le modèle et le niveau de réflexion d'une session, toujours ensemble.** Ouvrir une session sur le web, iOS ou Android pouvait n'afficher que l'ID brut du modèle, sans pastille de niveau de réflexion. crok nomme désormais le modèle d'une session par l'ID de sa liste de modèles, si bien que les appareils trouvent le modèle et ses niveaux. Une session d'un crok plus ancien, qui nomme le modèle à la manière du fournisseur, est quand même trouvée par l'ID sans son fournisseur, puis par le nom. La pastille du niveau de réflexion affiche le niveau de la session pendant le chargement de la liste, et nomme un niveau absent de la liste du modèle au lieu d'afficher **Par défaut**. Elle n'est omise que pour un modèle dont la liste dit qu'il n'a pas de niveaux, ou quand ni la liste ni la session ne nomment un niveau.
- **Un verre moins coûteux à dessiner.** Seul le verre de la fenêtre active est vivant, comme dans les barres latérales du système : une fenêtre derrière d'autres apps peint des couleurs unies et les cartes de la page d'accueil cessent de défiler. Le balayage vers Mission Control ne saccade plus, surtout avec un écran externe. Sur un M1 avec un écran 4K, Mission Control avec Crok derrière Finder est passé de 14,1 à 8,9 d'utilisation moyenne du GPU (p90 de 46 à 31).
- **La zone de saisie, dessinée au lieu de Liquid Glass.** Le serveur de fenêtres redessine Liquid Glass dès que quelque chose change dans sa fenêtre, y compris un curseur qui clignote. La surface de la zone de saisie est désormais dessinée avec un matériau dépoli et un seul Canvas qui contient son ombre, son remplissage, son bord éclairé, sa lueur et son filet, et correspond à l'aspect du système à quelques niveaux près sur 255. Sur le même M1 et le même écran 4K, l'utilisation du GPU de Crok au premier plan au repos est passée d'environ 25 à 10,6, et celle de Mission Control avec Crok au premier plan, de 18,8 à 13,0.
- **Petits détails.** Un pouce levé ou baissé se remplit quand il est choisi, si bien que le verdict se lit d'un coup d'œil. Le point en ligne d'**Autres ordinateurs** fait 10 points, est vert et entouré d'un halo, et le point hors ligne a la même taille en gris.

### Contrôle à distance

Tous les crok de cette version se connectent au relais de production à https://crok.chenli.dev, comme la 2.0.4, et conservent la connexion existante. Le relais de production sert les changements web de cette version lorsqu'elle est publiée ; ce qui se passe sur un ordinateur arrive avec crok 2.1.0 sur cet ordinateur.

- **Noms de modèle.** Une session conserve son modèle tel que le fournisseur l'appelle (`claude-sonnet-5-5`, `deepseek-flash`, le `deepseek/deepseek-v4.1-flash` d'OpenRouter), tandis que la liste publiée par crok le nomme par sa clé de catalogue (`anthropic/claude-sonnet-5-5`, `deepseek/deepseek-flash`, `openrouter/deepseek/deepseek-v4.1-flash`). crok 2.1.0 envoie l'ID de la liste, si bien que le web et les téléphones trouvent le modèle et ses niveaux de réflexion. Un modèle que l'ordinateur ne propose plus garde son nom.
- **crok plus ancien.** Un ordinateur qui n'exécute que crok 2.0.4 ou antérieur nomme encore le modèle à la manière du fournisseur. Le web et les apps du téléphone de cette version le trouvent par l'ID sans son fournisseur, donc le modèle et son niveau s'affichent quand même ; l'ID brut n'apparaît que si aucune des deux formes ne correspond.
- **Les deux pastilles.** Le web, iOS et Android affichent ensemble le modèle et le niveau de réflexion de la session. Pendant que la liste de l'ordinateur arrive, le modèle s'affiche et la pastille du niveau de réflexion montre le niveau de la session ; sans liste, parce que le crok est plus ancien, les deux sont atténuées et une touche explique que cet ordinateur ne propose pas encore de choix de modèle. Un niveau absent de la liste du modèle s'affiche par le nom de son niveau.
- **Mettez les ordinateurs à jour.** Meta Model API et les noms de modèle exacts arrivent avec crok 2.1.0 sur chaque ordinateur. Installez les apps du téléphone de cette version, comme l'explique **Apps pour téléphone** ci-dessus, pour les deux pastilles.

### Feedback et Agent Observability

Le rapport est inchangé par rapport à la 2.0.4 : chaque crok signale chaque appel de modèle qu'il fait, avec ses tours, exécutions d'outils, étapes et contrôles de garde, à [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) sur la stack Grafana Cloud du mainteneur, et `crok version --json` affiche l'hôte sous `agentObservability`. Un pouce levé ou baissé depuis Crok Desktop ou le terminal est enregistré sur la conversation de ce tour et comme la jauge `crok_feedback_rating` ; le retirer l'enregistre comme neutre.

Pour désactiver le rapport, ajoutez `agent_observability = false` sous `[features]` dans `~/.crok/config.toml`, ou définissez `CROK_AGENT_OBSERVABILITY=0`. Pour rapporter à votre propre stack, écrivez `~/.crok/agento11y.env` avec `crates/codegen/xai-grok-agento11y/setup.sh` du dépôt.

### Pour les développeurs

- Meta est un `ApiBackend` (`meta`) avec son propre dialecte Chat Completions. `GET /v1/models` est récupéré à la connexion puis toutes les heures, et mis en cache dans `~/.crok/meta-models.json` ; la liste intégrée sert jusqu'à la première récupération. `provider_compat.rs` envoie `none` et `minimal` comme `minimal`, relève tout `max_tokens` sous 4 096 car le raisonnement sort du même budget, demande un appel d'outil forcé en toutes lettres avec `tool_choice: "auto"`, conserve les schémas JSON natifs, retire `reasoning_content` des tours rejoués, et retire `frequency_penalty` et `presence_penalty`.
- Un changement de modèle entre familles compacte d'abord, comme pour Anthropic. Les coûts standard sont estimés d'après les prix publiés de Meta, y compris le palier de contexte long à 200 000 tokens d'entrée de Muse Ember et les tarifs Contributor.
- À distance : `bridge:upsertSession` (uniquement quand le modèle a changé), `bridge:catalogBatch` et `catalogUpdate` nomment le modèle d'une session par la clé de catalogue que résout `selectable_catalog_key_for_persisted`, de la même façon que le modèle d'une session reprise est résolu. Un modèle absent de la liste garde son nom. `relay/DESIGN.md` et `mobile/DESIGN.md` décrivent le contrat.
- Le web, iOS et Android trouvent le modèle d'une session par l'ID, puis par l'ID sans son fournisseur, puis par le nom, et affichent la pastille du niveau de réflexion dès que la session nomme un niveau. L'aperçu web a les nouveaux cas (`session-provider-model`, `session-models-loading`, `session-unknown-model`).
- Bureau : `GlassBackdrop` utilise les couleurs unies tant qu'une fenêtre est inactive et teinte par-dessus le fond d'une autre région au lieu de flouter de nouveau le bureau ; `GlassSurface` dessine son aspect `FrostedGlass` dans un seul Canvas. Les tests vérifient qu'il ne reste pas de couches Liquid Glass et que les fenêtres inactives peignent des couleurs unies.
- Les versions sont faites par `.github/workflows/release.yml` comme avant : quand une pull request qui monte `VERSION` est fusionnée dans `main`, il compile, vérifie et signe chaque fichier, exécute la porte d'évaluation et publie la version avec les notes de `release/notes/v2.1.0/`.

### Signature

La 2.1.0 est signée par le même certificat "Crok Code Signing" que la 2.0.4, la 2.0.3, la 2.0.2, la 2.0.1, la 2.0.0, la 1.5.2 et la 1.5.3. macOS lie les autorisations de confidentialité à la signature : ce que vous avez autorisé pour la 2.0.4 (Enregistrement de l'écran, Accessibilité, microphone, reconnaissance vocale) est donc conservé pour la 2.1.0. Cette compilation n'est pas notariée : une nouvelle installation nécessite donc une fois l'étape **Ouvrir quand même** ci-dessus.

L'app Android est signée avec la clé de publication que la 2.0.0 a introduite. L'app iOS n'est pas signée, comme l'explique **Apps pour téléphone**. La liste signée des sommes de contrôle est une chose distincte : elle permet à l'outil de mise à jour de vérifier un téléchargement et ne change pas la façon dont macOS traite l'app.

### Mise à jour depuis la 2.0.4

Utilisez **Crok Desktop › Rechercher des mises à jour…**, ou `crok upgrade` dans un terminal après avoir quitté Crok Desktop. Cette mise à jour est effectuée en place, dans le `Crok Desktop.app` installé : l'app garde donc sa place dans le Dock et le Finder, et aucune ancienne copie ne reste dans la Corbeille. La mise à jour prend l'image compilée avec le même SDK que l'app installée (macOS26-SDK ou macOS15-SDK), jamais l'autre.

La connexion à vos fournisseurs de modèles, les réglages, les tâches et le relais sont conservés : la 2.1.0 parle au même relais de production que la 2.0.4. Mettez à jour vers crok 2.1.0 chaque ordinateur que vous utilisez avec le relais pour Meta Model API et les noms de modèle exacts, et installez les apps du téléphone de cette version, comme l'explique **Apps pour téléphone** ci-dessus.

### Détails

- Intègre crok `{{CROK_VERSION}}`.
- Compilée par GitHub Actions à partir du tag `desktop-v2.1.0` sur `{{COMMIT}}` dans `main`. L'image du SDK macOS 26 a été compilée avec Xcode {{XCODE26}} et le SDK macOS {{SDK26}}, l'image du SDK macOS 15 avec Xcode {{XCODE15}} et le SDK macOS {{SDK15}}, et le `crok` autonome avec le SDK macOS {{TUI_SDK}}.
- Les deux images sont arm64, signées par le certificat Crok Code Signing et non notariées, et fonctionnent toutes deux sur macOS 14 Sonoma ou ultérieur.
- L'app iOS (`dev.chenli.crok.mobile`) est une compilation Release faite avec Xcode {{XCODE26}} ; l'app Android est une compilation release pour Android 8.0 ou ultérieur.
- Les sommes de contrôle SHA-256 sont à la fin de ces notes et dans `SHA256SUMS.txt`, qui couvre aussi les apps du téléphone. `release/README.md` dans le dépôt explique comment vérifier à la main la signature de la liste.
