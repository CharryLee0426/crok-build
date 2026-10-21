Crok Desktop 2.0.0 es la app nativa para macOS de este fork. Incluye crok, es decir, el entorno de ejecución del agente y la interfaz de terminal `crok`, así que no hay que instalar nada más. Esta versión da al control remoto un relé de producción propio, en https://crok.chenli.dev, y por primera vez incluye las apps de iOS y Android. Las respuestas en la web y en los teléfonos ahora se muestran con formato Markdown completo. Las actualizaciones se instalan en la app que ya tienes, y cerrar la ventana mantiene Crok Desktop en marcha. Por el nuevo relé, cada ordenador y cada teléfono inicia sesión en el control remoto una vez más: **Control remoto**, más abajo, explica cómo.

Esta es también la primera versión que compila y publica GitHub Actions, nada más fusionarse su pull request.

### Instalación

1. Descarga la imagen de disco que corresponda a tu versión de macOS y ábrela. La tabla de **Qué imagen de disco descargar** indica cuál.
2. Arrastra **Crok Desktop** a **Aplicaciones**.
3. Abre Crok Desktop desde Aplicaciones. Esta compilación no está notarizada, así que la primera vez macOS dirá que no puede verificar la app: cierra el aviso, abre **Ajustes del Sistema › Privacidad y seguridad**, haz clic en **Abrir igualmente** junto al mensaje de Crok Desktop y confirma. Solo hay que hacerlo una vez.
4. Inicia sesión en **Ajustes › Cuentas** con OpenRouter, OpenAI Codex, una clave de API de Anthropic, una clave de API de DeepSeek o una clave de GLM Coding Plan.

Requiere macOS 14 Sonoma o posterior en un Mac con chip de Apple (M1 o posterior).

### Qué imagen de disco descargar

Las dos imágenes son Crok Desktop 2.0.0 y tienen las mismas funciones. Solo se diferencian en el SDK de macOS con el que se compilaron, que decide si el marco de la ventana usa Liquid Glass de Apple:

| Imagen de disco | Compilada con | Úsala en | Barra de título |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.0-arm64-macOS26-SDK.dmg` | SDK {{SDK26}} de macOS | macOS 26 y posteriores | Liquid Glass |
| `Crok-Desktop-2.0.0-arm64-macOS15-SDK.dmg` | SDK {{SDK15}} de macOS | macOS 14 y 15 | Desenfoque esmerilado dentro de la ventana |

En macOS 26 y posteriores, elige la imagen del SDK de macOS 26 para tener la barra de título con Liquid Glass. En macOS 14 o 15, usa la imagen del SDK de macOS 15. También funciona en versiones posteriores, así que, si no sabes qué macOS tienes, es la opción segura.

`crok-2.0.0-aarch64-apple-darwin.tar.gz` es la interfaz de terminal `crok` sola, para un Mac en el que no quieras la app: descomprímelo y pon `crok` en tu `PATH`. Las apps del teléfono se describen en **Apps del teléfono**. `SHA256SUMS.txt` lista el SHA-256 de cada descarga, y `SHA256SUMS.txt.sig` es la firma de esa lista, que el actualizador comprueba.

### Apps del teléfono

La app Crok para iPhone y Android sigue las sesiones de tus ordenadores, muestra sus respuestas y solicitudes de permiso, e inicia o dirige tareas desde cualquier lugar. Hasta ahora había que compilarla desde el repositorio; esta versión la incluye. Los tres archivos inician sesión en el relé de producción.

- **Android 8.0 o posterior:** descarga `Crok-Android-2.0.0.apk` en el teléfono y ábrelo, y permite que tu navegador instale apps cuando Android lo pida, o ejecuta `adb install -r Crok-Android-2.0.0.apk`. Va firmado con la clave de publicación, que las versiones posteriores mantendrán, así que el siguiente APK se instala encima. Un APK de Crok que hayas compilado tú va firmado con otra clave e impide la instalación: quítalo primero con `adb uninstall dev.chenli.crok.mobile` o desde los ajustes del teléfono.
- **iPhone y iPad, iOS 17 o posterior:** `Crok-iOS-2.0.0-unsigned.ipa` no está firmado, porque una app para dispositivos iOS se firma con el Apple ID de quien la instala. Instálalo con una herramienta de sideloading como AltStore o Sideloadly, que lo firma con tu Apple ID. Con un Apple ID gratuito, iOS deja de abrir la app a los 7 días hasta que la vuelvas a instalar. Si prefieres compilarla tú, usa la configuración **Release**: el botón Run de Xcode compila Debug, que inicia sesión en el relé de pruebas.
- **Simulador de iOS:** `Crok-iOS-2.0.0-Simulator.zip` se descomprime en `Crok.app`, para `xcrun simctl install booted Crok.app` en un Mac con Xcode.

Para iniciar sesión en el teléfono, toca **Continuar con GitHub o Google**, inicia sesión en la página que se abre en https://crok.chenli.dev y toca **Aprobar**. Después vincula cada ordenador: ejecuta `crok remote login` en él y escanea el código QR que muestra desde **Ajustes › Vincular un ordenador** en la app, o aprueba el ordenador en la página web que se abre.

### Novedades

- **El control remoto tiene un relé de producción.** Las versiones publicadas ahora inician sesión en un relé propio, con su app web en https://crok.chenli.dev. El relé que usaban de la 1.5.1 a la 1.5.3, con su app web en https://crok-relay.vercel.app, queda ahora solo para las compilaciones de prueba. No se traslada nada de uno a otro, así que vuelves a iniciar sesión una vez. Consulta **Control remoto** más abajo.
- **Las apps del teléfono vienen con la versión.** El APK de Android, la app de iOS sin firmar y una compilación para el Simulador de iOS están entre las descargas de esta versión, compiladas para el relé de producción. Consulta **Apps del teléfono** más arriba.
- **Las respuestas se muestran como Markdown en la web y en los teléfonos.** Las tablas, los encabezados, las listas anidadas, las listas de tareas, las citas, los enlaces y los bloques de código se muestran correctamente. El código se resalta con los colores de GitHub y tiene un botón **Copiar**. Las fórmulas de LaTeX se muestran, en línea como `$…$` o `\(…\)` y en su propia línea como `$$…$$` o `\[…\]`; un precio como «$5 y $10» sigue siendo texto. El código, las tablas y las fórmulas que no caben a lo ancho se desplazan en horizontal dentro de la respuesta. Las imágenes nunca se descargan: aparecen como un enlace.
- **Las respuestas largas se abren por el final en los teléfonos.** Una sesión cuya última respuesta es más alta que la pantalla se abre en el final de esa respuesta, y el botón para ir al final aparece mientras lees dentro de una respuesta larga. En Android, los mensajes nuevos ya no te llevan al final mientras lees; enviar un prompt sí lo sigue haciendo. En iPhone hace falta iOS 18.
- **Las actualizaciones se instalan en la app que tienes.** A partir de la 2.0.0, **Crok Desktop › Buscar actualizaciones…** y `crok upgrade` ponen la versión nueva en la app instalada, `Crok Desktop.app`, en un solo paso, así que conserva su lugar en el Dock y en Finder y no queda ninguna copia antigua en la Papelera. Antes de instalar, comprueban que la versión nueva esté firmada por el mismo certificado, que es lo que conserva los permisos que macOS dio a Crok Desktop (Accesibilidad, Grabación de pantalla, micrófono). Una versión firmada de otra forma se rechaza, a menos que ejecutes `crok upgrade --allow-new-signature`.
- **Cerrar la ventana mantiene Crok Desktop en marcha.** El botón rojo de cerrar ahora oculta la ventana, y las tareas, los terminales del panel lateral, las páginas del navegador y tu borrador siguen en segundo plano. Con **⌘Q** se sale de la app. Haz clic en el icono del Dock, elige la ventana en el menú **Ventana** o usa un comando de menú como **Nueva tarea** para que la ventana vuelva.
- **El agente se presenta como Crok.** El prompt del sistema ahora empieza por «You are Crok.» con todos los proveedores, cuando antes nombraba a Grok incluso si el modelo era Claude, DeepSeek o GLM. `agent.system_prompt_label`, `model.<id>.system_prompt_label` y `CROK_SYSTEM_PROMPT_LABEL` siguen permitiendo poner otro nombre.

### Control remoto

Cada crok de esta versión (la interfaz de terminal, el que va dentro de Crok Desktop y el tarball independiente) inicia sesión en el relé de producción. `crok remote status` muestra su dirección, `https://tacit-finch-29.convex.cloud`, y `crok version --json` la muestra en `remote`.

- **Vuelve a iniciar sesión en cada ordenador.** Ejecuta `crok remote login` (o `/remote login` en la interfaz de terminal), o usa **Ajustes › Control remoto › Iniciar sesión…** en Crok Desktop. Se abre una página en https://crok.chenli.dev: inicia sesión con GitHub o Google y haz clic en **Aprobar**. Un teléfono que ya tenga la sesión iniciada puede vincular el ordenador en su lugar, escaneando el código QR desde **Ajustes › Vincular un ordenador**.
- **El relé de producción empieza vacío.** Tu cuenta, tus dispositivos, las sesiones fijadas y archivadas y el orden de tus proyectos están en el relé, así que el primer inicio de sesión crea allí una cuenta nueva, y lo fijado y el orden empiezan de cero.
- **Tu inicio de sesión de la 1.5.x se conserva para las compilaciones de prueba.** La primera vez que se ejecuta la 2.0.0, crok lo mueve de `~/.crok/remote/credentials.json` a `~/.crok/remote/credentials-dev.json`, y el ordenador aparece con la sesión cerrada hasta que vuelvas a iniciarla.
- **Actualiza todos los ordenadores y teléfonos.** Un ordenador con la 1.5.x, o una app del teléfono compilada antes de esta versión, sigue en el relé de pruebas y no ve los ordenadores con la 2.0.0.

Un relé propio, configurado con `[remote] url` o `CROK_REMOTE_URL`, funciona como antes.

### Agent Observability

Como en la 1.5.3, cada crok de esta versión envía un informe de cada llamada al modelo que hace a [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/), en el stack de Grafana Cloud del mantenedor: el prompt, la respuesta, las llamadas a herramientas, el uso de tokens y los tiempos, con el nombre del ordenador como etiqueta. `crok version --json` muestra el host al que envía los informes, en `agentObservability`. Para desactivarlo, añade `agent_observability = false` en `[features]` en `~/.crok/config.toml`, o define `CROK_AGENT_OBSERVABILITY=0`. Para enviar los informes a tu propio stack, escribe `~/.crok/agento11y.env` con `crates/codegen/xai-grok-agento11y/setup.sh` del repositorio.

### Para desarrolladores

- Las versiones las publica `.github/workflows/release.yml`: cuando un pull request que sube `VERSION` se fusiona en `main`, compila la TUI, las dos imágenes de disco y las apps del teléfono, las comprueba y las firma, y publica la versión con las notas incluidas en el repositorio en `release/notes/v2.0.0/`. `release/ci-secrets.sh` le proporciona las claves de firma. `release/README.md` lo describe todo.
- `.github/workflows/ci.yml` compila la TUI, Crok Desktop para los dos SDK, la app de iOS y la app de Android en cada pull request hacia `main`, y comprueba las notas cuando `VERSION` indica una versión que aún no se ha publicado.
- El relé tiene dos entornos, `relay/environments/prod.env` y `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` o `relay/scripts/deploy.sh test` despliega uno de ellos, y `make clients-prod` y `make clients-test` además compilan las apps del teléfono para él. crok elige su relé al compilarse, con `CROK_RELAY_ENV` (prod, salvo que sea una compilación de prueba).
- `desktop/macOS/scripts/build-app.sh` compila con el sistema de compilación nativo de SwiftPM (`SWIFT_BUILD_SYSTEM` elige otro), lo que mantiene correctos `SDKROOT` y el sello del SDK también con Xcode 27.
- `mobile/scripts/build-apps.sh --ios-device` añade un `.ipa` sin firmar para dispositivos, y las compilaciones release de Android se firman con el almacén de claves que indique `CROK_ANDROID_KEYSTORE`.

### Firma

La 2.0.0 va firmada por el mismo certificado «Crok Code Signing» que la 1.5.2 y la 1.5.3. macOS vincula los permisos de privacidad a la firma, así que lo que autorizaste para la 1.5.3 (Grabación de pantalla, Accesibilidad, micrófono, reconocimiento de voz) se conserva en la 2.0.0. Si vienes de la 1.5.1 o anteriores, que llevaban firma ad hoc, macOS pide esos permisos una vez más. Si Ajustes del Sistema muestra Crok Desktop como activado mientras Crok dice que no tiene permiso, quítalo de la lista con **−** y autorízalo de nuevo, una vez. La compilación no está notarizada, así que una instalación nueva necesita una vez el paso **Abrir igualmente** de arriba.

La app de Android va firmada con la clave de publicación, nueva en esta versión. La app de iOS no está firmada, como explica **Apps del teléfono**. La lista firmada de sumas de comprobación es otra cosa: permite al actualizador comprobar una descarga, y no cambia cómo trata macOS a la app.

### Actualizar desde la 1.5.3

Usa **Crok Desktop › Buscar actualizaciones…**, o `crok upgrade` en un terminal con Crok Desktop cerrado. Esta actualización todavía la hace el propio actualizador de la 1.5.3, que reemplaza la app entera y mueve la antigua a la Papelera como `Crok Desktop 1.5.3.app`. Vacía la Papelera después: esa copia es una segunda app con el identificador de Crok Desktop. A partir de la 2.0.0, las actualizaciones se instalan en la propia app, sin moverla. La actualización toma la imagen compilada con el mismo SDK que la app instalada (macOS26-SDK o macOS15-SDK), nunca la otra.

El inicio de sesión en tus proveedores de modelos, los ajustes y las tareas se conservan. El control remoto no: vuelve a iniciar sesión como explica **Control remoto** más arriba, e instala las apps del teléfono de esta versión.

### Detalles

- Incluye crok `{{CROK_VERSION}}`.
- Compilada por GitHub Actions desde la etiqueta `desktop-v2.0.0` en `{{COMMIT}}` de `main`. La imagen del SDK de macOS 26 se compiló con Xcode {{XCODE26}} y el SDK {{SDK26}} de macOS, la imagen del SDK de macOS 15 con Xcode {{XCODE15}} y el SDK {{SDK15}} de macOS, y el `crok` independiente con el SDK {{TUI_SDK}} de macOS.
- Las dos imágenes son arm64, van firmadas por el certificado Crok Code Signing y no están notarizadas, y las dos funcionan en macOS 14 Sonoma o posterior.
- La app de iOS (`dev.chenli.crok.mobile`) es una compilación Release hecha con Xcode {{XCODE26}}; la app de Android es una compilación release para Android 8.0 o posterior.
- Las sumas SHA-256 están al final de estas notas y en `SHA256SUMS.txt`, que ahora también cubre las apps del teléfono. El archivo `release/README.md` del repositorio explica cómo comprobar a mano la firma de la lista.
