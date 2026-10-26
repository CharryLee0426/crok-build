Crok Desktop 2.0.3 es la app nativa de macOS de este fork. Incluye crok, el entorno de ejecución del agente y la interfaz de terminal `crok`, así que no hay que instalar nada más. Sigue a la 2.0.2, que llevó la herramienta de navegador a tu propio Chrome y los selectores de modelo a todos los dispositivos. La 2.0.3 mantiene al día la lista de sesiones de cada dispositivo: una sesión creada, renombrada o eliminada en un ordenador llega a la web, a los teléfonos y a los demás ordenadores en alrededor de medio minuto. Una sesión iniciada en un ordenador desde la web o desde un teléfono aparece ahora también en ese ordenador, como tarea en Crok Desktop y en el panel Remoto del terminal. Una sesión nueva iniciada con un modelo elegido siempre empieza con ese modelo, y las llamadas de crok a Claude ya no se cuentan dos veces en Agent Observability.

Esta versión la compila y publica GitHub Actions, nada más fusionarse su pull request, como la 2.0.2.

### Instalación

1. Descarga la imagen de disco que corresponda a tu versión de macOS y ábrela. La tabla de **Qué imagen de disco descargar** indica cuál.
2. Arrastra **Crok Desktop** a **Aplicaciones**.
3. Abre Crok Desktop desde Aplicaciones. Esta compilación no está notarizada, así que la primera vez macOS dirá que no puede verificar la app: cierra el aviso, abre **Ajustes del Sistema › Privacidad y seguridad**, haz clic en **Abrir igualmente** junto al mensaje de Crok Desktop y confirma. Solo hay que hacerlo una vez.
4. Inicia sesión en **Ajustes › Cuentas** con OpenRouter, OpenAI Codex, una clave de API de Anthropic, una clave de API de DeepSeek o una clave de GLM Coding Plan.

Requiere macOS 14 Sonoma o posterior en un Mac con chip de Apple (M1 o posterior).

### Qué imagen de disco descargar

Las dos imágenes son Crok Desktop 2.0.3 y tienen las mismas funciones. Solo se diferencian en el SDK de macOS con el que se compilaron, que decide si el marco de la ventana usa Liquid Glass de Apple:

| Imagen de disco | Compilada con | Úsala en | Barra de título |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.3-arm64-macOS26-SDK.dmg` | SDK {{SDK26}} de macOS | macOS 26 y posteriores | Liquid Glass |
| `Crok-Desktop-2.0.3-arm64-macOS15-SDK.dmg` | SDK {{SDK15}} de macOS | macOS 14 y 15 | Desenfoque esmerilado dentro de la ventana |

En macOS 26 y posteriores, elige la imagen del SDK de macOS 26 para tener la barra de título con Liquid Glass. En macOS 14 o 15, usa la imagen del SDK de macOS 15. También funciona en versiones posteriores, así que, si no sabes qué macOS tienes, es la opción segura.

`crok-2.0.3-aarch64-apple-darwin.tar.gz` es la interfaz de terminal `crok` sola, para un Mac en el que no quieras la app: descomprímelo y pon `crok` en tu `PATH`. Las apps del teléfono se describen en **Apps del teléfono**. `SHA256SUMS.txt` lista el SHA-256 de cada descarga, y `SHA256SUMS.txt.sig` es la firma de esa lista, que el actualizador comprueba.

### Apps del teléfono

La app Crok para iPhone y Android sigue las sesiones de tus ordenadores, muestra sus respuestas y solicitudes de permiso, e inicia o dirige tareas desde cualquier lugar. Viene con esta versión, como vino con la 2.0.2, y funciona igual que la de la 2.0.2: los cambios de esta versión están en los ordenadores y en el relé, así que las apps del teléfono de la 2.0.2 y de la 2.0.1 también los reciben. Los tres archivos inician sesión en el relé de producción.

- **Android 8.0 o posterior:** descarga `Crok-Android-2.0.3.apk` en el teléfono y ábrelo, y permite que tu navegador instale apps cuando Android lo pida, o ejecuta `adb install -r Crok-Android-2.0.3.apk`. Va firmado con la clave de publicación que mantendrán las versiones posteriores, así que el siguiente APK se instala encima. Un APK de Crok que hayas compilado tú va firmado con otra clave e impide la instalación: quítalo primero con `adb uninstall dev.chenli.crok.mobile` o desde los ajustes del teléfono.
- **iPhone y iPad, iOS 17 o posterior:** `Crok-iOS-2.0.3-unsigned.ipa` no está firmado, porque una app para dispositivos iOS se firma con el Apple ID de quien la instala. Instálalo con una herramienta de sideloading como AltStore o Sideloadly, que lo firma con tu Apple ID. Con un Apple ID gratuito, iOS deja de abrir la app a los 7 días hasta que la vuelvas a instalar. Si prefieres compilarla tú, usa la configuración **Release**: el botón Run de Xcode compila Debug, que inicia sesión en el relé de pruebas.
- **Simulador de iOS:** `Crok-iOS-2.0.3-Simulator.zip` se descomprime en `Crok.app`, para `xcrun simctl install booted Crok.app` en un Mac con Xcode.

Para iniciar sesión en el teléfono, toca **Continuar con GitHub o Google**, inicia sesión en la página que se abre en https://crok.chenli.dev y toca **Aprobar**. Después vincula cada ordenador: ejecuta `crok remote login` en él y escanea el código QR que muestra desde **Ajustes › Vincular un ordenador** en la app, o aprueba el ordenador en la página web que se abre.

### Novedades

- **La lista de sesiones de cada dispositivo se mantiene al día.** Una sesión que solo cambiaba en el disco de un ordenador (creada por un crok sin sesión iniciada en el relé, renombrada o eliminada) llegaba a la web, a los teléfonos y a los demás ordenadores solo con el siguiente listado completo de ese ordenador, que se enviaba más o menos cada 20 minutos y dejaba de enviarse cuando se cerraba el crok que lo enviaba. Ahora llega en alrededor de medio minuto, y otro crok del ordenador se hace cargo del listado en cuanto se cierra el primero.
- **Las sesiones iniciadas desde la web o desde un teléfono aparecen en su ordenador.** Crok Desktop añade una sesión así como tarea sin leer en su proyecto, y la muestra trabajando mientras se ejecuta un turno. El terminal indica qué dispositivo la inició y la lista en **Este ordenador** de `/remote`.
- **Una sesión nueva empieza con el modelo que elegiste.** Una sesión iniciada desde la web o desde un teléfono con un modelo y un nivel de razonamiento elegidos podía empezar con el predeterminado del ordenador, cuando un crok más antiguo de ese ordenador (por ejemplo, un terminal que quedó abierto desde antes de una actualización) la tomaba primero. Ahora solo puede tomarla un crok que aplique la elección.
- **Otros ordenadores se rellena enseguida.** **Otros ordenadores** de Crok Desktop vuelve a pedir la lista cada vez que se conecta su enlace con el relé, y cada 5 segundos hasta que recibe respuesta, en lugar de esperar hasta 4 minutos.
- **Las llamadas a Claude llegan a Agent Observability una sola vez.** La exportación de telemetría propia de Claude Platform guardaba una segunda copia de cada llamada a Claude de la que crok informaba. Ahora crok pide a la API de Anthropic que no exporte las llamadas de las que ya informa él mismo. Consulta **Agent Observability** más abajo.

### Control remoto

Cada crok de esta versión inicia sesión, como la 2.0.2, en el relé de producción en https://crok.chenli.dev y conserva la sesión que ya tiene. El relé de producción ya ejecuta los cambios de esta versión en el relé, así que la regla del modelo elegido que se describe abajo se aplica desde hoy; el resto llega con crok 2.0.3 en cada ordenador.

- **Listas de sesiones.** Un crok de cada ordenador mantiene la lista de ese ordenador: cada 30 segundos mira las sesiones que hay en el disco y envía solo lo que ha cambiado, y cada 30 minutos vuelve a enviar la lista completa. Cuando se cierra o pierde la conexión, se pide a todos los demás crok de ese ordenador que se hagan cargo de la lista, y lo hace el primero que responde. Un ordenador cuyo crok vuelve a arrancar lista sus sesiones al momento. Los ordenadores que aún ejecutan crok 2.0.2 o anterior siguen enviando ellos mismos su lista completa, ahora cada 10 minutos en lugar de cada 20 más o menos.
- **Sesiones iniciadas desde otro dispositivo, en Crok Desktop.** Una sesión que otro dispositivo inició en este Mac se convierte en una tarea de su proyecto en cuanto el relé la lista, junto con el proyecto si la app no tiene ninguno para esa carpeta. Está sin leer, toma el título de la sesión hasta que la abres, aparece trabajando mientras se ejecuta allí un turno y como no leída cuando termina, y se abre como cualquier otra tarea. Cada una de estas sesiones se añade una sola vez, así que una tarea o un proyecto que quitaste no vuelve a aparecer.
- **Sesiones iniciadas desde otro dispositivo, en el terminal.** Mientras el terminal está conectado al relé, anuncia cada sesión que otro dispositivo inicia en este ordenador, por ejemplo «iPhone inició una sesión en app: … — ábrela con /resume o /remote». El panel Remoto lista esas sesiones primero, en **Este ordenador**, cada una marcada con el dispositivo del que vino («desde iPhone»). Intro abre una aquí, y `n` en este ordenador te remite a `/new`.
- **El modelo elegido.** Una sesión nueva que lleva un modelo o un nivel de razonamiento solo va a un crok que lo aplique: crok 2.0.1 y posteriores. En un ordenador que solo ejecuta crok 2.0.0 o anterior, iniciar una sesión así falla con «Update crok on … to start a session there with a chosen model or thinking level» (actualiza crok en ese ordenador para iniciar allí una sesión con el modelo o el nivel de razonamiento elegidos) en lugar de empezar con el predeterminado. Una sesión en **Predeterminado** sigue empezando en cualquier crok. Un prompt o un reintento que reabre una sesión que no llegó a iniciarse sigue la misma regla.
- **Actualiza los ordenadores.** Las listas que se mantienen al día con el disco, y las sesiones de otros dispositivos que aparecen en su ordenador, llegan con crok 2.0.3 en ese ordenador. En los teléfonos no cambia nada.

### Agent Observability

Como en la 2.0.2, cada crok de esta versión informa de cada llamada al modelo que hace, con sus turnos, ejecuciones de herramientas, pasos y comprobaciones de las guardas, a [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) en el stack de Grafana Cloud del mantenedor, y `crok version --json` muestra el host en `agentObservability`.

- **Sin segunda copia de las llamadas a Claude.** Una organización de Claude Platform puede exportar un span de traza de cada petición a la API a sus destinos de telemetría, y Agent Observability convertía cada uno de ellos en una conversación propia, con su id de traza como nombre, bajo el agente `claude-platform`. Así, cada llamada a Claude de la que crok informaba se guardaba dos veces. Ahora crok envía las llamadas de las que informa a `api.anthropic.com` con un contexto de traza marcado como no muestreado, y la API de Anthropic responde a eso no exportando nada de ellas. Las llamadas de las que crok no informa (las compactaciones, y todas las llamadas mientras el envío está desactivado) se exportan como antes, igual que las llamadas a otros proveedores.
- **Si tu organización exporta la telemetría de Claude,** las llamadas a Claude de las que crok informa a Agent Observability ya no están en esa exportación; desactiva el envío para que vuelvan a estar ahí.
- **Los paneles cuentan las llamadas de crok a Claude en el lugar que ocupaba Claude Platform.** El span de crok de una llamada así indica `crok.unsampled = true` y lleva sus lecturas de caché y sus tokens de razonamiento con los nombres de atributo de Claude Platform, así que los paneles de LLM Observability la cuentan una sola vez. Las llamadas de crok 2.0.2 y anteriores se siguen contando a partir de la exportación de Claude Platform.
- **Las copias ya guardadas quedan marcadas.** Agent Observability no puede borrar lo que ha guardado, así que cada una de las 586 copias que generaron las versiones de crok de la 1.5.0 a la 2.0.2 lleva una etiqueta de copia de la llamada de crok, que la distingue de las llamadas que solo vio Claude Platform. Cada ordenador que siga con crok 2.0.2 o anterior seguirá añadiendo copias hasta que se actualice.

Para desactivar el envío, añade `agent_observability = false` en `[features]` de `~/.crok/config.toml`, o define `CROK_AGENT_OBSERVABILITY=0`. Para enviar a tu propio stack, escribe `~/.crok/agento11y.env` con `crates/codegen/xai-grok-agento11y/setup.sh` del repositorio.

### Para desarrolladores

- Las versiones las hace `.github/workflows/release.yml` como antes: cuando una pull request que sube `VERSION` se fusiona en `main`, compila, comprueba y firma cada archivo, ejecuta el filtro de evaluaciones y publica la versión con las notas de `release/notes/v2.0.3/`.
- El relé mantiene un responsable del catálogo por ordenador: `bridge:catalogUpdate` recibe los cambios del responsable desde su última subida (`EXPIRED` en cuanto otro proceso tiene el catálogo), un catálogo liberado pone `catalogWanted` en la bandeja de entrada de cada crok de ese ordenador, y `bridge:connect` lista `catalog`. `sessions:create` guarda `startedFrom` (`{kind: phone | web | computer, name, at}`), y el `x.ai/remote/sessions` del visor lleva `here`, las sesiones de este ordenador iniciadas desde otro sitio (las 100 más recientes). `relay/DESIGN.md` §2–§5 lo describe.
- Un `create` que lleva un modelo o un nivel de razonamiento solo se ofrece a los hosts cuyos `features` incluyen `setup` (crok 2.0.3 lo incluye) o `git` (crok 2.0.1 y 2.0.2).
- `relay/scripts/sessions-live-e2e.mjs` comprueba dos ordenadores y un teléfono contra un relé local: sesiones en ejecución listadas al momento, sesiones creadas y eliminadas en el disco, el responsable que se cierra, y la sesión de un teléfono que llega a la interfaz propia del ordenador. `commands-e2e` y `bridge-e2e` comprueban ahora dónde empieza una sesión con un modelo elegido y con qué modelo se ejecutó su primer turno.
- Las compilaciones de depuración de las apps del teléfono tienen una tercera pestaña, **o11y**, a la derecha de **Perfil**: los paneles de Grafana Cloud, las evaluaciones y Agent Observability del propietario como páginas del teléfono, generadas por el relé (`o11y:page`, `o11y:refresh`; `mobile/DESIGN.md` «o11y», `relay/DESIGN.md` §3). Las compilaciones de publicación, incluida la de esta versión, no la tienen, y el relé de producción la tiene desactivada. `relay/scripts/o11y-setup.sh` crea la cuenta de servicio de solo lectura y las variables del despliegue, `o11y-preview.mjs` genera las páginas sin relé, y `o11y-demo.mjs` crea las páginas de demostración de los teléfonos.
- `observability/agento11y/stack.py duplicates [--label]` empareja por id de respuesta las copias de Claude Platform de las llamadas de crok y etiqueta cada una, y `gcx_api` ahora pide a gcx JSON simple, así que `backfill` ya no se salta las conversaciones largas.

### Firma

La 2.0.3 va firmada por el mismo certificado «Crok Code Signing» que la 2.0.2, la 2.0.1, la 2.0.0, la 1.5.2 y la 1.5.3. macOS vincula los permisos de privacidad a la firma, así que lo que autorizaste para la 2.0.2 (Grabación de pantalla, Accesibilidad, micrófono, reconocimiento de voz) se conserva en la 2.0.3. La compilación no está notarizada, así que una instalación nueva necesita una vez el paso **Abrir igualmente** de arriba.

La app de Android va firmada con la clave de publicación que introdujo la 2.0.0. La app de iOS no está firmada, como explica **Apps del teléfono**. La lista firmada de sumas de comprobación es otra cosa: permite al actualizador comprobar una descarga, y no cambia cómo trata macOS a la app.

### Actualizar desde la 2.0.2

Usa **Crok Desktop › Buscar actualizaciones…**, o `crok upgrade` en un terminal con Crok Desktop cerrado. Esta actualización se hace en el sitio, dentro de la app instalada, `Crok Desktop.app`, así que conserva su lugar en el Dock y en Finder y no queda ninguna copia antigua en la Papelera. La actualización toma la imagen compilada con el mismo SDK que la app instalada (macOS26-SDK o macOS15-SDK), nunca la otra.

El inicio de sesión en tus proveedores de modelos, los ajustes, las tareas y el relé se conservan: la 2.0.3 habla con el mismo relé de producción que la 2.0.2. Actualiza todos los ordenadores que uses con el relé, para que sus sesiones se mantengan al día en todas partes. Las apps del teléfono no necesitan actualizarse, como indica **Apps del teléfono** más arriba.

### Detalles

- Incluye crok `{{CROK_VERSION}}`.
- Compilada por GitHub Actions desde la etiqueta `desktop-v2.0.3` en `{{COMMIT}}` de `main`. La imagen del SDK de macOS 26 se compiló con Xcode {{XCODE26}} y el SDK {{SDK26}} de macOS, la imagen del SDK de macOS 15 con Xcode {{XCODE15}} y el SDK {{SDK15}} de macOS, y el `crok` independiente con el SDK {{TUI_SDK}} de macOS.
- Las dos imágenes son arm64, van firmadas por el certificado Crok Code Signing y no están notarizadas, y las dos funcionan en macOS 14 Sonoma o posterior.
- La app de iOS (`dev.chenli.crok.mobile`) es una compilación Release hecha con Xcode {{XCODE26}}; la app de Android es una compilación release para Android 8.0 o posterior.
- Las sumas SHA-256 están al final de estas notas y en `SHA256SUMS.txt`, que también cubre las apps del teléfono. El archivo `release/README.md` del repositorio explica cómo comprobar a mano la firma de la lista.
