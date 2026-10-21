Crok Desktop 2.0.1 es la app nativa para macOS de este fork. Incluye crok, es decir, el entorno de ejecución del agente y la interfaz de terminal `crok`, así que no hay que instalar nada más. Viene después de la 2.0.0, la versión que dio al control remoto un relé de producción propio, en https://crok.chenli.dev, y que por primera vez llevó las apps de iOS y Android. La 2.0.1 es la versión del trabajo que viene a continuación: las correcciones y las mejoras hechas sobre la 2.0.0. La lista de **Novedades** crece a medida que ese trabajo se incorpora.

Esta versión la compila y publica GitHub Actions, nada más fusionarse su pull request, como la 2.0.0.

### Instalación

1. Descarga la imagen de disco que corresponda a tu versión de macOS y ábrela. La tabla de **Qué imagen de disco descargar** indica cuál.
2. Arrastra **Crok Desktop** a **Aplicaciones**.
3. Abre Crok Desktop desde Aplicaciones. Esta compilación no está notarizada, así que la primera vez macOS dirá que no puede verificar la app: cierra el aviso, abre **Ajustes del Sistema › Privacidad y seguridad**, haz clic en **Abrir igualmente** junto al mensaje de Crok Desktop y confirma. Solo hay que hacerlo una vez.
4. Inicia sesión en **Ajustes › Cuentas** con OpenRouter, OpenAI Codex, una clave de API de Anthropic, una clave de API de DeepSeek o una clave de GLM Coding Plan.

Requiere macOS 14 Sonoma o posterior en un Mac con chip de Apple (M1 o posterior).

### Qué imagen de disco descargar

Las dos imágenes son Crok Desktop 2.0.1 y tienen las mismas funciones. Solo se diferencian en el SDK de macOS con el que se compilaron, que decide si el marco de la ventana usa Liquid Glass de Apple:

| Imagen de disco | Compilada con | Úsala en | Barra de título |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.1-arm64-macOS26-SDK.dmg` | SDK {{SDK26}} de macOS | macOS 26 y posteriores | Liquid Glass |
| `Crok-Desktop-2.0.1-arm64-macOS15-SDK.dmg` | SDK {{SDK15}} de macOS | macOS 14 y 15 | Desenfoque esmerilado dentro de la ventana |

En macOS 26 y posteriores, elige la imagen del SDK de macOS 26 para tener la barra de título con Liquid Glass. En macOS 14 o 15, usa la imagen del SDK de macOS 15. También funciona en versiones posteriores, así que, si no sabes qué macOS tienes, es la opción segura.

`crok-2.0.1-aarch64-apple-darwin.tar.gz` es la interfaz de terminal `crok` sola, para un Mac en el que no quieras la app: descomprímelo y pon `crok` en tu `PATH`. Las apps del teléfono se describen en **Apps del teléfono**. `SHA256SUMS.txt` lista el SHA-256 de cada descarga, y `SHA256SUMS.txt.sig` es la firma de esa lista, que el actualizador comprueba.

### Apps del teléfono

La app Crok para iPhone y Android sigue las sesiones de tus ordenadores, muestra sus respuestas y solicitudes de permiso, e inicia o dirige tareas desde cualquier lugar. Viene con esta versión, como vino con la 2.0.0. Los tres archivos inician sesión en el relé de producción.

- **Android 8.0 o posterior:** descarga `Crok-Android-2.0.1.apk` en el teléfono y ábrelo, y permite que tu navegador instale apps cuando Android lo pida, o ejecuta `adb install -r Crok-Android-2.0.1.apk`. Va firmado con la clave de publicación que mantendrán las versiones posteriores, así que el siguiente APK se instala encima. Un APK de Crok que hayas compilado tú va firmado con otra clave e impide la instalación: quítalo primero con `adb uninstall dev.chenli.crok.mobile` o desde los ajustes del teléfono.
- **iPhone y iPad, iOS 17 o posterior:** `Crok-iOS-2.0.1-unsigned.ipa` no está firmado, porque una app para dispositivos iOS se firma con el Apple ID de quien la instala. Instálalo con una herramienta de sideloading como AltStore o Sideloadly, que lo firma con tu Apple ID. Con un Apple ID gratuito, iOS deja de abrir la app a los 7 días hasta que la vuelvas a instalar. Si prefieres compilarla tú, usa la configuración **Release**: el botón Run de Xcode compila Debug, que inicia sesión en el relé de pruebas.
- **Simulador de iOS:** `Crok-iOS-2.0.1-Simulator.zip` se descomprime en `Crok.app`, para `xcrun simctl install booted Crok.app` en un Mac con Xcode.

Para iniciar sesión en el teléfono, toca **Continuar con GitHub o Google**, inicia sesión en la página que se abre en https://crok.chenli.dev y toca **Aprobar**. Después vincula cada ordenador: ejecuta `crok remote login` en él y escanea el código QR que muestra desde **Ajustes › Vincular un ordenador** en la app, o aprueba el ordenador en la página web que se abre.

### Novedades

- **La 2.0.1 es la versión del trabajo posterior a la 2.0.0.** Recoge las correcciones y las mejoras hechas en la rama `charlie/dev` desde la 2.0.0, y esta lista crece a medida que ese trabajo se incorpora.
- **El proceso de publicación es el que introdujo la 2.0.0.** La 2.0.1 la compila, la comprueba, la firma y la publica la misma canalización de GitHub Actions, y estas notas están incluidas en el repositorio en `release/notes/v2.0.1/`.
- **El relé y las apps del teléfono siguen funcionando como antes.** La 2.0.1 inicia sesión en el mismo relé de producción, en https://crok.chenli.dev, y las apps del teléfono conservan el comportamiento que les dio la 2.0.0. Consulta **Control remoto** más abajo.
- **Las actualizaciones se instalan en la app que tienes.** A partir de la 2.0.0, **Crok Desktop › Buscar actualizaciones…** y `crok upgrade` ponen la versión nueva en la app instalada, `Crok Desktop.app`, en un solo paso, así que conserva su lugar en el Dock y en Finder y no queda ninguna copia antigua en la Papelera. Antes de instalar, comprueban que la versión nueva esté firmada por el mismo certificado, que es lo que conserva los permisos que macOS dio a Crok Desktop (Accesibilidad, Grabación de pantalla, micrófono). Una versión firmada de otra forma se rechaza, a menos que ejecutes `crok upgrade --allow-new-signature`.
- **El agente se presenta como Crok.** El prompt del sistema ahora empieza por «You are Crok.» con todos los proveedores, cuando antes nombraba a Grok incluso si el modelo era Claude, DeepSeek o GLM. `agent.system_prompt_label`, `model.<id>.system_prompt_label` y `CROK_SYSTEM_PROMPT_LABEL` siguen permitiendo poner otro nombre.

### Control remoto

Cada crok de esta versión (la interfaz de terminal, el que va dentro de Crok Desktop y el tarball independiente) inicia sesión en el relé de producción. `crok remote status` muestra su dirección, `https://tacit-finch-29.convex.cloud`, y `crok version --json` la muestra en `remote`.

- **Tu inicio de sesión se conserva desde la 2.0.0.** Un ordenador con la 2.0.0 ya tiene la sesión iniciada en el relé de producción, y la 2.0.1 usa ese mismo inicio de sesión: no hay que volver a iniciar sesión ni que mover ningún archivo. El inicio de sesión de la 1.5.x lo movió la 2.0.0 de `~/.crok/remote/credentials.json` a `~/.crok/remote/credentials-dev.json`, y lo hizo una sola vez; la 2.0.1 deja ambos archivos donde están.
- **El relé de producción sigue donde estaba.** Tu cuenta, tus dispositivos, las sesiones fijadas y archivadas y el orden de tus proyectos están en el relé, y la 2.0.1 los lee del mismo sitio, así que no se traslada nada al actualizar.
- **Actualiza todos los ordenadores y teléfonos.** Un ordenador con la 1.5.x, o una app del teléfono compilada antes de la 2.0.0, sigue en el relé de pruebas y no ve los ordenadores con la 2.0.0 o posteriores.

Un relé propio, configurado con `[remote] url` o `CROK_REMOTE_URL`, funciona como antes.

### Agent Observability

Como en la 2.0.0, cada crok de esta versión envía un informe de cada llamada al modelo que hace a [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/), en el stack de Grafana Cloud del mantenedor: el prompt, la respuesta, las llamadas a herramientas, el uso de tokens y los tiempos, con el nombre del ordenador como etiqueta. `crok version --json` muestra el host al que envía los informes, en `agentObservability`. Para desactivarlo, añade `agent_observability = false` en `[features]` en `~/.crok/config.toml`, o define `CROK_AGENT_OBSERVABILITY=0`. Para enviar los informes a tu propio stack, escribe `~/.crok/agento11y.env` con `crates/codegen/xai-grok-agento11y/setup.sh` del repositorio.

### Para desarrolladores

- Las versiones las publica `.github/workflows/release.yml`: cuando un pull request que sube `VERSION` se fusiona en `main`, compila la TUI, las dos imágenes de disco y las apps del teléfono, las comprueba y las firma, y publica la versión con las notas incluidas en el repositorio en `release/notes/v2.0.1/`. `release/ci-secrets.sh` le proporciona las claves de firma. `release/README.md` lo describe todo.
- `.github/workflows/ci.yml` compila la TUI, Crok Desktop para los dos SDK, la app de iOS y la app de Android en cada pull request hacia `main`, y comprueba las notas cuando `VERSION` indica una versión que aún no se ha publicado.
- El relé tiene dos entornos, `relay/environments/prod.env` y `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` o `relay/scripts/deploy.sh test` despliega uno de ellos, y `make clients-prod` y `make clients-test` además compilan las apps del teléfono para él. crok elige su relé al compilarse, con `CROK_RELAY_ENV` (prod, salvo que sea una compilación de prueba).
- `desktop/macOS/scripts/build-app.sh` compila con el sistema de compilación nativo de SwiftPM (`SWIFT_BUILD_SYSTEM` elige otro), lo que mantiene correctos `SDKROOT` y el sello del SDK también con Xcode 27.
- `mobile/scripts/build-apps.sh --ios-device` añade un `.ipa` sin firmar para dispositivos, y las compilaciones release de Android se firman con el almacén de claves que indique `CROK_ANDROID_KEYSTORE`.

### Firma

La 2.0.1 va firmada por el mismo certificado «Crok Code Signing» que la 2.0.0, la 1.5.2 y la 1.5.3. macOS vincula los permisos de privacidad a la firma, así que lo que autorizaste para la 2.0.0 (Grabación de pantalla, Accesibilidad, micrófono, reconocimiento de voz) se conserva en la 2.0.1. La compilación no está notarizada, así que una instalación nueva necesita una vez el paso **Abrir igualmente** de arriba.

La app de Android va firmada con la clave de publicación que introdujo la 2.0.0. La app de iOS no está firmada, como explica **Apps del teléfono**. La lista firmada de sumas de comprobación es otra cosa: permite al actualizador comprobar una descarga, y no cambia cómo trata macOS a la app.

### Actualizar desde la 2.0.0

Usa **Crok Desktop › Buscar actualizaciones…**, o `crok upgrade` en un terminal con Crok Desktop cerrado. Esta actualización se hace en el sitio, dentro de la app instalada, `Crok Desktop.app`, así que conserva su lugar en el Dock y en Finder y no queda ninguna copia antigua en la Papelera. La actualización toma la imagen compilada con el mismo SDK que la app instalada (macOS26-SDK o macOS15-SDK), nunca la otra.

El inicio de sesión en tus proveedores de modelos, los ajustes, las tareas y el relé se conservan: la 2.0.1 habla con el mismo relé de producción que la 2.0.0. Las apps del teléfono se instalan a partir de los archivos de esta versión, como describe **Apps del teléfono** más arriba.

### Detalles

- Incluye crok `{{CROK_VERSION}}`.
- Compilada por GitHub Actions desde la etiqueta `desktop-v2.0.1` en `{{COMMIT}}` de `main`. La imagen del SDK de macOS 26 se compiló con Xcode {{XCODE26}} y el SDK {{SDK26}} de macOS, la imagen del SDK de macOS 15 con Xcode {{XCODE15}} y el SDK {{SDK15}} de macOS, y el `crok` independiente con el SDK {{TUI_SDK}} de macOS.
- Las dos imágenes son arm64, van firmadas por el certificado Crok Code Signing y no están notarizadas, y las dos funcionan en macOS 14 Sonoma o posterior.
- La app de iOS (`dev.chenli.crok.mobile`) es una compilación Release hecha con Xcode {{XCODE26}}; la app de Android es una compilación release para Android 8.0 o posterior.
- Las sumas SHA-256 están al final de estas notas y en `SHA256SUMS.txt`, que ahora también cubre las apps del teléfono. El archivo `release/README.md` del repositorio explica cómo comprobar a mano la firma de la lista.
