Crok Desktop 2.0.2 es la app nativa de macOS de este fork. Incluye crok, el entorno de ejecución del agente y la interfaz de terminal `crok`, así que no hay que instalar nada más. Sigue a la 2.0.1, que rediseñó las dos apps del teléfono en torno a ordenadores, proyectos y temas. En la 2.0.2 la herramienta de navegador trabaja en el Chrome que ya usas, con tu sesión iniciada. Cualquier dispositivo puede elegir el modelo y el nivel de razonamiento del ordenador de una sesión, la app web sigue el diseño de las apps del teléfono y el terminal tiene un panel Remoto. El final de un turno llega ahora a la web y a los teléfonos en alrededor de un segundo. Agent Observability sigue turnos completos, y el flujo de publicación puede ejecutar una batería de evaluaciones antes de publicar.

Esta versión la compila y publica GitHub Actions, nada más fusionarse su pull request, como la 2.0.1.

### Instalación

1. Descarga la imagen de disco que corresponda a tu versión de macOS y ábrela. La tabla de **Qué imagen de disco descargar** indica cuál.
2. Arrastra **Crok Desktop** a **Aplicaciones**.
3. Abre Crok Desktop desde Aplicaciones. Esta compilación no está notarizada, así que la primera vez macOS dirá que no puede verificar la app: cierra el aviso, abre **Ajustes del Sistema › Privacidad y seguridad**, haz clic en **Abrir igualmente** junto al mensaje de Crok Desktop y confirma. Solo hay que hacerlo una vez.
4. Inicia sesión en **Ajustes › Cuentas** con OpenRouter, OpenAI Codex, una clave de API de Anthropic, una clave de API de DeepSeek o una clave de GLM Coding Plan.

Requiere macOS 14 Sonoma o posterior en un Mac con chip de Apple (M1 o posterior).

### Qué imagen de disco descargar

Las dos imágenes son Crok Desktop 2.0.2 y tienen las mismas funciones. Solo se diferencian en el SDK de macOS con el que se compilaron, que decide si el marco de la ventana usa Liquid Glass de Apple:

| Imagen de disco | Compilada con | Úsala en | Barra de título |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.2-arm64-macOS26-SDK.dmg` | SDK {{SDK26}} de macOS | macOS 26 y posteriores | Liquid Glass |
| `Crok-Desktop-2.0.2-arm64-macOS15-SDK.dmg` | SDK {{SDK15}} de macOS | macOS 14 y 15 | Desenfoque esmerilado dentro de la ventana |

En macOS 26 y posteriores, elige la imagen del SDK de macOS 26 para tener la barra de título con Liquid Glass. En macOS 14 o 15, usa la imagen del SDK de macOS 15. También funciona en versiones posteriores, así que, si no sabes qué macOS tienes, es la opción segura.

`crok-2.0.2-aarch64-apple-darwin.tar.gz` es la interfaz de terminal `crok` sola, para un Mac en el que no quieras la app: descomprímelo y pon `crok` en tu `PATH`. Las apps del teléfono se describen en **Apps del teléfono**. `SHA256SUMS.txt` lista el SHA-256 de cada descarga, y `SHA256SUMS.txt.sig` es la firma de esa lista, que el actualizador comprueba.

### Apps del teléfono

La app Crok para iPhone y Android sigue las sesiones de tus ordenadores, muestra sus respuestas y solicitudes de permiso, e inicia o dirige tareas desde cualquier lugar. Viene con esta versión, como vino con la 2.0.1. Los tres archivos inician sesión en el relé de producción.

- **Android 8.0 o posterior:** descarga `Crok-Android-2.0.2.apk` en el teléfono y ábrelo, y permite que tu navegador instale apps cuando Android lo pida, o ejecuta `adb install -r Crok-Android-2.0.2.apk`. Va firmado con la clave de publicación que mantendrán las versiones posteriores, así que el siguiente APK se instala encima. Un APK de Crok que hayas compilado tú va firmado con otra clave e impide la instalación: quítalo primero con `adb uninstall dev.chenli.crok.mobile` o desde los ajustes del teléfono.
- **iPhone y iPad, iOS 17 o posterior:** `Crok-iOS-2.0.2-unsigned.ipa` no está firmado, porque una app para dispositivos iOS se firma con el Apple ID de quien la instala. Instálalo con una herramienta de sideloading como AltStore o Sideloadly, que lo firma con tu Apple ID. Con un Apple ID gratuito, iOS deja de abrir la app a los 7 días hasta que la vuelvas a instalar. Si prefieres compilarla tú, usa la configuración **Release**: el botón Run de Xcode compila Debug, que inicia sesión en el relé de pruebas.
- **Simulador de iOS:** `Crok-iOS-2.0.2-Simulator.zip` se descomprime en `Crok.app`, para `xcrun simctl install booted Crok.app` en un Mac con Xcode.

Para iniciar sesión en el teléfono, toca **Continuar con GitHub o Google**, inicia sesión en la página que se abre en https://crok.chenli.dev y toca **Aprobar**. Después vincula cada ordenador: ejecuta `crok remote login` en él y escanea el código QR que muestra desde **Ajustes › Vincular un ordenador** en la app, o aprueba el ordenador en la página web que se abre.

### Novedades

- **La herramienta de navegador trabaja en tu propio Chrome.** Abre una ventana del navegador que ya tienes abierto, con el perfil que usaste por última vez, así que los sitios en los que tienes sesión iniciada la conservan. Necesita activar una opción en Chrome una sola vez y tu **Allow**: consulta **Tu propio navegador** más abajo.
- **Elige el modelo y el nivel de razonamiento de una sesión en cualquier dispositivo.** iPhone, Android y la web muestran dos píldoras encima del compositor, en sesiones nuevas y abiertas: el modelo, con una hoja que busca y agrupa los modelos por proveedor, y el nivel de razonamiento. Una tarea nueva en **Otros ordenadores** de Crok Desktop ofrece la misma elección antes de empezar.
- **Los ordenadores con cientos de modelos los ofrecen todos.** Un ordenador con sesión en OpenRouter lista unos 480 modelos. El relay rechazaba cualquier lista de más de 200, así que un ordenador así no ofrecía ninguna elección; ahora guarda hasta 1.000.
- **La app web sigue a las apps del teléfono.** Está organizada como Telegram Web: a la izquierda, los proyectos del ordenador elegido y sus temas; en el centro, la sesión con su tema; a la derecha, la información de la sesión.
- **Un panel Remoto en el terminal.** `/remote` muestra los otros ordenadores, sus proyectos y sus sesiones, como hace **Otros ordenadores** en Crok Desktop, y `n` empieza allí una sesión con el modelo que elijas.
- **El final de un turno llega enseguida a la web y a los teléfonos.** Tras un turno intenso seguían mostrando la sesión trabajando durante segundos, a veces minutos, después de que el ordenador hubiera terminado. Ahora el final llega en alrededor de un segundo.
- **Las sesiones largas se abren rápido en los teléfonos.** Las apps del teléfono cargan la transcripción en partes pequeñas y en vivo, mantienen a la vista el primer prompt de una sesión nueva y muestran el razonamiento y las llamadas a herramientas por su estado, como Crok Desktop.
- **Los modelos de 1M de tokens de OpenRouter siguen funcionando pasados los 105K tokens.** crok pedía un margen de salida que no dejaba sitio al prompt, y OpenRouter lo rechazaba cuando la conversación crecía; ahora no pide más salida de la que cabe junto al prompt.
- **Agent Observability sigue turnos completos.** Cada turno es una traza con sus llamadas al modelo y sus ejecuciones de herramientas, y el stack del mantenedor puntúa el tráfico real y revisa las llamadas a herramientas que pueden cambiar algo. Consulta **Agent Observability** más abajo.

### Tu propio navegador

La herramienta de navegador arrancaba un navegador propio, con un perfil de Crok. Ahora abre una ventana del Chrome que ya tienes abierto, con el perfil que usaste por última vez, así que todos los sitios en los que tienes sesión iniciada la conservan. Al modelo se le avisa de que la ventana puede tener tu sesión iniciada.

- **Activa la depuración remota una vez.** Hace falta Chrome 144 o posterior. Abre `chrome://inspect/#remote-debugging` en Chrome y activa **Allow remote debugging for this browser instance**. Chrome rechaza una dirección `chrome://` que le pasa otra app, así que **Ajustes › Uso del navegador y del ordenador** de Crok Desktop tiene un botón **Copiar dirección** para ella.
- **Permite cada tarea una vez.** Cuando una tarea usa el navegador por primera vez, Chrome pregunta **Allow remote debugging?** Haz clic en **Allow**. Crok espera la respuesta dos minutos y explica qué hacer si la depuración remota está desactivada o se rechazó la pregunta.
- **Tu navegador sigue siendo tuyo.** Crok nunca lo cierra ni se queda con sus pestañas de inicio, y las descargas van adonde dicen tus ajustes de Chrome.
- **El perfil propio de Crok sigue disponible.** Elige **Perfil propio de Crok** en **Ajustes › Uso del navegador y del ordenador › Perfil del navegador** de Crok Desktop, o pon `profile = "crok"` en `[toolset.browser]` de `~/.crok/config.toml`. El valor predeterminado es `profile = "user"`.

Se ha probado con Chrome en macOS. Edge, Brave y Chromium aún no están probados.

### Control remoto

Cada crok de esta versión inicia sesión en el relay de producción en https://crok.chenli.dev, como la 2.0.1, y conserva la sesión que ya tiene.

- **Modelo y nivel de razonamiento.** En una sesión nueva las píldoras dicen **Default** hasta que eliges, y la sesión empieza con tu elección. En una sesión abierta el cambio va a su ordenador, y la píldora gira hasta que ese ordenador lo ha aplicado; si lo rechaza, vuelve el valor anterior con el motivo. La información de la sesión muestra las mismas dos filas, y los comandos `/model` y `/think` de los teléfonos leen la misma lista.
- **La app web.** Su columna izquierda es una pila de páginas: las sesiones del ordenador elegido con sus proyectos, los temas de un proyecto, las sesiones archivadas y el perfil. Los temas tienen acciones al pasar el ratón y menús contextuales para fijar, detener, marcar como leído, archivar y reordenar. Los temas de sesión y el modo de color se guardan en el navegador. Por debajo de 1024 píxeles de ancho muestra una columna cada vez.
- **El panel Remoto del terminal.** `/remote` y `/remote open` muestran la cuenta, este ordenador y la conexión, y luego un árbol con los otros ordenadores (en línea o su última conexión, con los no leídos), sus proyectos y las sesiones de cada proyecto. Intro abre una sesión como `/resume`, `n` empieza una y pregunta por el modelo y el nivel de razonamiento de ese ordenador, y al escribir se filtra el árbol. `/remote status` imprime el texto de antes. Una sesión de otro ordenador muestra su rama y sus cifras de tokens en la línea de estado, y `/model` allí ya no cambia el predeterminado de este ordenador.
- **Los finales de turno llegan enseguida.** El enlace con el relay agrupa ahora en una sola escritura las actualizaciones que esperan detrás de cada una, así que un turno intenso ya no acumula una cola que retrasa su final. Un turno terminado aparece como terminado aunque un prompt en cola saliera de ella sin ejecutarse, y un prompt enviado después desde un teléfono se ejecuta.
- **Los teléfonos cargan las sesiones largas por partes.** Las apps del teléfono abren una transcripción por sus 40 elementos más recientes y cargan los anteriores de 60 en 60 al desplazarte, así que una sesión reflejada durante semanas se abre rápido con una red lenta. El primer prompt de una sesión nueva se queda encima del compositor. El razonamiento se muestra en curso y luego terminado, y una llamada a herramienta en curso, terminada, fallida o detenida. El relay ya no envía a los teléfonos el texto de un razonamiento ni la salida de una herramienta.
- **Actualiza los ordenadores y los teléfonos.** Las listas de modelos y los finales de turno más rápidos llegan con crok 2.0.2 en el ordenador que tiene la sesión, y las píldoras y la ventana de transcripción con las apps del teléfono 2.0.2. Las apps del teléfono de la 2.0.1 siguen funcionando con el relay.

### Agent Observability

Como en la 2.0.1, cada crok de esta versión informa de cada llamada al modelo que hace a [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) en el stack de Grafana Cloud del mantenedor, y `crok version --json` muestra el host en `agentObservability`. La 2.0.2 también informa de lo que pasa entre llamadas:

- **Turnos y ejecuciones de herramientas.** Un turno es una traza cuyo span raíz contiene sus llamadas al modelo y sus ejecuciones de herramientas, con cómo terminó el turno y cuántas llamadas y errores de herramientas tuvo. Una ejecución de herramienta registra su resultado, su tipo, su código de salida y el tamaño de su salida, no sus argumentos ni su contenido. El turno de un subagente queda bajo el turno que lo inició.
- **Pasos, veredictos y valoraciones.** Las decisiones de permisos, los resultados del hook PreToolUse, las compactaciones y los arranques de servidores MCP aparecen como pasos de la conversación. El evaluador de objetivos de crok, su clasificador de pereza, su guarda de llamadas repetidas y su límite de turnos informan puntuaciones, y las valoraciones que das van ahí también, además de a xAI.
- **Etiquetas.** Las llamadas llevan `origin` (`local`, `headless` para `crok -p`, `relay` para los prompts de la web y los teléfonos, `eval` para los experimentos), y `repo`, `branch` y `user`, el nombre de inicio de sesión del ordenador.
- **Comprobaciones de las guardas, en modo aviso.** Antes de que se ejecute una llamada a herramienta que puede cambiar algo, y antes de que un resultado de herramienta vuelva al modelo, crok lo envía a las guardas del stack, que buscan comandos de git que reescriben el historial, comandos de shell destructivos y claves reales. crok nunca espera la respuesta ni bloquea una llamada; una coincidencia queda registrada como aviso en la conversación. `CROK_AGENTO11Y_GUARDS=off` detiene las comprobaciones.
- **Métricas.** `crok_turns_total`, `crok_tool_runs_total`, `crok_workflow_steps_total` y `crok_guard_checks_total`, con las duraciones de turnos y herramientas, alimentan el panel del harness del stack, sus alertas y sus SLO.

Para desactivar el envío, añade `agent_observability = false` en `[features]` de `~/.crok/config.toml`, o define `CROK_AGENT_OBSERVABILITY=0`. Para enviar a tu propio stack, escribe `~/.crok/agento11y.env` con `crates/codegen/xai-grok-agento11y/setup.sh` del repositorio.

### Para desarrolladores

- Las versiones las hace `.github/workflows/release.yml` como antes: cuando una pull request que sube `VERSION` se fusiona en `main`, compila, comprueba y firma cada archivo y publica la versión con las notas de `release/notes/v2.0.2/`.
- El flujo de publicación tiene un trabajo nuevo, `eval`, que `publish` espera. Ejecuta dos veces los siete casos de humo de `evals/run.py` contra la compilación de la versión y falla cuando pass@1 baja más de 0,20 por debajo de `evals/baselines/smoke.json`, o cuando falla un caso de seguridad que siempre pasaba. Sin el secreto `CROK_EVAL_OPENROUTER_API_KEY` en el entorno release, avisa y pasa.
- `evals/run.py` ejecuta crok sin interfaz sobre pequeños repositorios de prueba en tres baterías (`s1` regresiones, `s2` uso de herramientas, `s3` seguridad; 22 casos) e informa de tasas de acierto, coste y comportamiento por modelo y compilación. `evals/README.md` describe los casos y las comprobaciones.
- `observability/agento11y/stack.json` contiene los evaluadores, reglas y guardas del stack, y `observability/agento11y/stack.py` los aplica mediante la API del plugin de Agent Observability, puntúa las conversaciones guardadas antes de que existiera una regla e instala las alertas y los SLO.
- El sampler informa de cada turno, ejecución de herramienta, paso, veredicto, valoración y comprobación de guardas mediante `crates/codegen/xai-grok-sampler/src/observe_harness.rs`, y el puente los registra en `crates/codegen/xai-grok-agento11y/bridge/src/harness.ts`.
- `sessions:transcript` del relay devuelve un rango de los elementos de una sesión, los más recientes primero y sin el texto de razonamientos y salidas de herramientas, para la ventana de transcripción de los teléfonos (`relay/DESIGN.md` §3). `bridge:setModels` guarda hasta 1.000 modelos, `devices:models` es la lista que leen los clientes, y el visor de crok la pide con `x.ai/remote/models`.
- El enlace con el relay agrupa en una escritura las actualizaciones que esperan en una sesión (`fold_backlog`), y `relay/scripts/status-e2e.mjs` mide cuánto tarda un teléfono en ver el final de un turno a través de un relay lento.
- La petición a OpenRouter ajusta `max_tokens` a la ventana de contexto menos el prompt estimado.

### Firma

La 2.0.2 va firmada por el mismo certificado «Crok Code Signing» que la 2.0.1, la 2.0.0, la 1.5.2 y la 1.5.3. macOS vincula los permisos de privacidad a la firma, así que lo que autorizaste para la 2.0.1 (Grabación de pantalla, Accesibilidad, micrófono, reconocimiento de voz) se conserva en la 2.0.2. La compilación no está notarizada, así que una instalación nueva necesita una vez el paso **Abrir igualmente** de arriba.

La app de Android va firmada con la clave de publicación que introdujo la 2.0.0. La app de iOS no está firmada, como explica **Apps del teléfono**. La lista firmada de sumas de comprobación es otra cosa: permite al actualizador comprobar una descarga, y no cambia cómo trata macOS a la app.

### Actualizar desde la 2.0.1

Usa **Crok Desktop › Buscar actualizaciones…**, o `crok upgrade` en un terminal con Crok Desktop cerrado. Esta actualización se hace en el sitio, dentro de la app instalada, `Crok Desktop.app`, así que conserva su lugar en el Dock y en Finder y no queda ninguna copia antigua en la Papelera. La actualización toma la imagen compilada con el mismo SDK que la app instalada (macOS26-SDK o macOS15-SDK), nunca la otra.

El inicio de sesión en tus proveedores de modelos, los ajustes, las tareas y el relé se conservan: la 2.0.2 habla con el mismo relé de producción que la 2.0.1. Las apps del teléfono se instalan a partir de los archivos de esta versión, como describe **Apps del teléfono** más arriba.

### Detalles

- Incluye crok `{{CROK_VERSION}}`.
- Compilada por GitHub Actions desde la etiqueta `desktop-v2.0.2` en `{{COMMIT}}` de `main`. La imagen del SDK de macOS 26 se compiló con Xcode {{XCODE26}} y el SDK {{SDK26}} de macOS, la imagen del SDK de macOS 15 con Xcode {{XCODE15}} y el SDK {{SDK15}} de macOS, y el `crok` independiente con el SDK {{TUI_SDK}} de macOS.
- Las dos imágenes son arm64, van firmadas por el certificado Crok Code Signing y no están notarizadas, y las dos funcionan en macOS 14 Sonoma o posterior.
- La app de iOS (`dev.chenli.crok.mobile`) es una compilación Release hecha con Xcode {{XCODE26}}; la app de Android es una compilación release para Android 8.0 o posterior.
- Las sumas SHA-256 están al final de estas notas y en `SHA256SUMS.txt`, que ahora también cubre las apps del teléfono. El archivo `release/README.md` del repositorio explica cómo comprobar a mano la firma de la lista.
