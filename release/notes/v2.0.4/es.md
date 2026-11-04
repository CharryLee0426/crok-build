Crok Desktop 2.0.4 es la app nativa de macOS de este fork. Incluye crok, el entorno de ejecución del agente y la interfaz de terminal `crok`, así que no hay que instalar nada más. Sigue a la 2.0.3, que mantuvo al día la lista de sesiones de cada dispositivo. La 2.0.4 permite que un prompt enviado desde la web, desde un teléfono o desde otro ordenador lleve fotos y archivos, y los muestra en la transcripción en todos los dispositivos. Cada lista de sesiones tiene un botón **Actualizar** que hace que cada ordenador en línea vuelva a listar sus sesiones al momento. Crok Desktop pone un botón de copiar y los pulgares arriba y abajo bajo cada respuesta, el terminal hace una breve pregunta después de un turno, y más modelos de razonamiento de OpenRouter dan ahora título a sus sesiones.

Esta versión la compila y publica GitHub Actions, nada más fusionarse su pull request, como la 2.0.3.

### Instalación

1. Descarga la imagen de disco que corresponda a tu versión de macOS y ábrela. La tabla de **Qué imagen de disco descargar** indica cuál.
2. Arrastra **Crok Desktop** a **Aplicaciones**.
3. Abre Crok Desktop desde Aplicaciones. Esta compilación no está notarizada, así que la primera vez macOS dirá que no puede verificar la app: cierra el aviso, abre **Ajustes del Sistema › Privacidad y seguridad**, haz clic en **Abrir igualmente** junto al mensaje de Crok Desktop y confirma. Solo hay que hacerlo una vez.
4. Inicia sesión en **Ajustes › Cuentas** con OpenRouter, OpenAI Codex, una clave de API de Anthropic, una clave de API de DeepSeek o una clave de GLM Coding Plan.

Requiere macOS 14 Sonoma o posterior en un Mac con chip de Apple (M1 o posterior).

### Qué imagen de disco descargar

Las dos imágenes son Crok Desktop 2.0.4 y tienen las mismas funciones. Solo se diferencian en el SDK de macOS con el que se compilaron, que decide si el marco de la ventana usa Liquid Glass de Apple:

| Imagen de disco | Compilada con | Úsala en | Barra de título |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.4-arm64-macOS26-SDK.dmg` | SDK {{SDK26}} de macOS | macOS 26 y posteriores | Liquid Glass |
| `Crok-Desktop-2.0.4-arm64-macOS15-SDK.dmg` | SDK {{SDK15}} de macOS | macOS 14 y 15 | Desenfoque esmerilado dentro de la ventana |

En macOS 26 y posteriores, elige la imagen del SDK de macOS 26 para tener la barra de título con Liquid Glass. En macOS 14 o 15, usa la imagen del SDK de macOS 15. También funciona en versiones posteriores, así que, si no sabes qué macOS tienes, es la opción segura.

`crok-2.0.4-aarch64-apple-darwin.tar.gz` es la interfaz de terminal `crok` sola, para un Mac en el que no quieras la app: descomprímelo y pon `crok` en tu `PATH`. Las apps del teléfono se describen en **Apps del teléfono**. `SHA256SUMS.txt` lista el SHA-256 de cada descarga, y `SHA256SUMS.txt.sig` es la firma de esa lista, que el actualizador comprueba.

### Apps del teléfono

La app Crok para iPhone y Android sigue las sesiones de tus ordenadores, muestra sus respuestas y solicitudes de permiso, e inicia o dirige tareas desde cualquier lugar. Las apps del teléfono de esta versión son nuevas: envían fotos y archivos con un prompt, los muestran en la transcripción y tienen **Actualizar**. Instálalas encima de las de la 2.0.3 para tener las dos cosas. Las apps del teléfono de la 2.0.3 y anteriores siguen funcionando como antes, sin ellas. Los tres archivos inician sesión en el relé de producción.

- **Android 8.0 o posterior:** descarga `Crok-Android-2.0.4.apk` en el teléfono y ábrelo, y permite que tu navegador instale apps cuando Android lo pida, o ejecuta `adb install -r Crok-Android-2.0.4.apk`. Va firmado con la clave de publicación que introdujo la 2.0.0, así que se instala encima del APK de una versión anterior. Un APK de Crok que hayas compilado tú va firmado con otra clave e impide la instalación: quítalo primero con `adb uninstall dev.chenli.crok.mobile` o desde los ajustes del teléfono.
- **iPhone y iPad, iOS 17 o posterior:** `Crok-iOS-2.0.4-unsigned.ipa` no está firmado, porque una app para dispositivos iOS se firma con el Apple ID de quien la instala. Instálalo con una herramienta de sideloading como AltStore o Sideloadly, que lo firma con tu Apple ID. Con un Apple ID gratuito, iOS deja de abrir la app a los 7 días hasta que la vuelvas a instalar. Si prefieres compilarla tú, usa la configuración **Release**: el botón Run de Xcode compila Debug, que inicia sesión en el relé de pruebas.
- **Simulador de iOS:** `Crok-iOS-2.0.4-Simulator.zip` se descomprime en `Crok.app`, para `xcrun simctl install booted Crok.app` en un Mac con Xcode.

Para iniciar sesión en el teléfono, toca **Continuar con GitHub o Google**, inicia sesión en la página que se abre en https://crok.chenli.dev y toca **Aprobar**. Después vincula cada ordenador: ejecuta `crok remote login` en él y escanea el código QR que muestra desde **Ajustes › Vincular un ordenador** en la app, o aprueba el ordenador en la página web que se abre.

### Novedades

- **Fotos y archivos en los prompts, desde cualquier dispositivo.** En la web y en las apps del teléfono, el clip junto al campo del mensaje añade fotos y archivos a un prompt: Fotos, Cámara y Archivos en los teléfonos, y en la web también pegándolos o soltándolos sobre la sesión. Con un mensaje pueden ir hasta 10, de 20 MB como máximo cada uno, y un mensaje puede llevar solo fotos. El ordenador pasa las imágenes al modelo como imágenes y guarda los demás archivos en una carpeta propia para que el modelo los lea. Las fotos aparecen en la transcripción en todos los dispositivos y se abren a pantalla completa al tocarlas (con **Compartir** y **Guardar** en los teléfonos), y las imágenes de un prompt escrito en el propio ordenador también aparecen en los teléfonos y en la web.
- **Actualiza cualquier lista de sesiones.** La web, las apps del teléfono, **Otros ordenadores** de Crok Desktop y el panel Remoto del terminal tienen un control Actualizar (↻, o `r` en `/remote`). Pide a cada ordenador en línea que vuelva a listar todas sus sesiones al momento, en lugar de en su siguiente comprobación, y gira hasta que todos lo han hecho. En los teléfonos, deslizar la lista hacia abajo hace lo mismo.
- **Valoración de las respuestas.** Crok Desktop muestra un botón de copiar y los pulgares arriba y abajo bajo cada respuesta terminada. El botón de copiar toma el Markdown de la respuesta tal como se escribió, y volver a hacer clic en el pulgar elegido retira la valoración. El terminal pregunta «¿Qué tal fue esta respuesta?» una vez bajo un turno terminado, y se responde con `/good`, `/not-so-well` o `/dont-show-again`.
- **Títulos de sesión con más modelos de OpenRouter.** Los modelos de razonamiento que rechazan una llamada forzada a una herramienta (Muse Spark 1.3) o que gastan en razonar el poco margen de una respuesta corta (Muse Glimmer, GLM 5.3 Flash, Aion 2.0) nunca recibían un título generado, así que sus sesiones se llamaban como las primeras palabras del prompt. Ahora reciben título como cualquier otro modelo.

### Control remoto

Cada crok de esta versión inicia sesión, como la 2.0.3, en el relé de producción en https://crok.chenli.dev y conserva la sesión que ya tiene. El relé de producción recibe los cambios de esta versión en el relé cuando se publica esta versión; lo que ocurre en un ordenador llega con crok 2.0.4 en ese ordenador.

- **Fotos y archivos, en el ordenador.** Antes de ejecutar un prompt así, crok descarga sus fotos y archivos. Las imágenes llegan al modelo como entrada de imagen. Los demás archivos se guardan en `~/.crok/remote/attachments/` (una carpeta por sesión y mensaje) y se enlazan en el prompt, igual que Crok Desktop adjunta archivos. En una tarea de otro ordenador que ya está abierta, Crok Desktop y el terminal suben las imágenes y los archivos de un prompt junto con él; una tarea nueva en otro ordenador sigue empezando solo con texto.
- **Fotos y archivos, en el relé.** La web y los teléfonos envían las fotos con la orientación corregida, con 2048 píxeles como máximo en el lado largo y sin sus metadatos, junto con una vista previa pequeña. Una subida que ningún mensaje reclama se borra al cabo de un día; los archivos de una sesión se borran con la sesión, o con su transcripción tras 30 días de inactividad.
- **Versiones antiguas de crok.** Un ordenador que solo ejecuta crok 2.0.3 o anterior no puede recibir fotos ni archivos: al enviarle alguno aparece «Update crok on … to send photos and files there.» (actualiza crok en ese ordenador para poder enviarle fotos y archivos). Los prompts de texto funcionan como antes.
- **Actualizar.** El crok que mantiene la lista de sesiones de un ordenador vuelve a listar todas las sesiones del disco en cuanto alguien pulsa Actualizar, y después sigue enviando solo lo que cambia, cada 30 segundos, como antes. El indicador de actividad se detiene cuando ha respondido cada ordenador en línea, o al cabo de 15 segundos. Un ordenador que solo ejecuta un crok más antiguo puede no responder hasta su siguiente listado periódico. Los ordenadores sin conexión no pueden listar sus sesiones: sus sesiones se quedan como se listaron la última vez, y los teléfonos y la web dicen «Ningún ordenador está en línea. La lista muestra lo que listaron la última vez.» cuando no hay ninguno en línea.
- **Actualiza los ordenadores.** Las fotos y los archivos en los prompts, y la respuesta inmediata a Actualizar, llegan con crok 2.0.4 en cada ordenador.

### Valoraciones y Agent Observability

Como en la 2.0.3, cada crok de esta versión informa de cada llamada al modelo que hace, con sus turnos, ejecuciones de herramientas, pasos y comprobaciones de las guardas, a [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) en el stack de Grafana Cloud del mantenedor, y `crok version --json` muestra el host en `agentObservability`.

- **Adónde va un pulgar.** Un pulgar arriba o abajo, desde Crok Desktop o desde el terminal, se registra en la conversación de ese turno en Agent Observability y en la métrica de tipo gauge `crok_feedback_rating`. Retirar un pulgar lo registra como neutro, así que deja de contar. No se envía nada mientras el envío está desactivado.
- **La pregunta del terminal.** Aparece una vez bajo un turno terminado, y no tras un turno cancelado o fallido, en modo mínimo ni en un terminal de muy poca altura. `/dont-show-again` la desactiva escribiendo `feedback_prompt = false` en `[features]` de `~/.crok/config.toml`; vuelve a ponerlo en `true` para ver otra vez la pregunta.
- **La evaluación del mantenedor.** Un panel nuevo, **crok Feedback**, muestra la proporción de pulgares arriba entre los turnos valorados, con una alerta por debajo del 80 % a lo largo de un día y un objetivo a 30 días. Se aplica en cuanto hay al menos 20 valoraciones en un intervalo.

Para desactivar el envío, añade `agent_observability = false` en `[features]` de `~/.crok/config.toml`, o define `CROK_AGENT_OBSERVABILITY=0`. Para enviar a tu propio stack, escribe `~/.crok/agento11y.env` con `crates/codegen/xai-grok-agento11y/setup.sh` del repositorio.

### Para desarrolladores

- Las versiones las hace `.github/workflows/release.yml` como antes: cuando una pull request que sube `VERSION` se fusiona en `main`, compila, comprueba y firma cada archivo, ejecuta el filtro de evaluaciones y publica la versión con las notas de `release/notes/v2.0.4/`.
- Fotos y archivos: los dispositivos suben a `files:uploadUrl` y nombran las subidas en `commands:sendPrompt` y `sessions:create` (`attachments`); el relé las guarda en una tabla `files` (propietario, sesión, SHA-256, vista previa) y da sus URL de descarga a la bandeja de entrada del ordenador y a cada consulta de transcripción. Solo se ofrecen prompts así a un crok cuyos `features` incluyen `attachments`, y `bridge:connect` responde con los `features` del propio relé. `relay/DESIGN.md` §2–§5, «Photos and files», es el contrato; `relay/scripts/attachments-e2e.mjs` y `attachments-bridge-e2e.mjs` lo comprueban.
- Actualizar: `sessions:refresh` (`{asked, offline, at}`) marca `refreshAt` en el catálogo de cada ordenador en línea; mientras sea posterior al inicio de la última subida, cada crok de ese ordenador ve `catalogWanted` y `bridge:beginCatalog` concede el catálogo al momento al primero que lo pide, también al responsable. `sessions:refreshState({since})` indica los ordenadores que aún están listando. El `x.ai/remote/refresh` del visor hace las dos cosas para Crok Desktop y el terminal. `relay/scripts/refresh-e2e.mjs` lo comprueba con procesos crok reales.
- Valoraciones: las interfaces envían `x.ai/feedback/rating` (`1`, `-1`, o `0` para retirarla) para un turno. `[features] feedback_prompt` (por defecto `true`, `CROK_FEEDBACK_PROMPT`) controla la pregunta del terminal. La evaluación es el panel `crok Feedback`, la alerta `crok-feedback-good-rate-low` y el SLO `crok feedback is mostly positive`.
- En OpenRouter, el sampler pide con palabras la llamada forzada a una herramienta, con `tool_choice: "auto"`, y da a un modelo de razonamiento al menos 4096 tokens de salida con el esfuerzo más ligero que lista el catálogo, salvo que la llamada indique uno. Dos campos de `SamplerConfig` llevan el soporte de razonamiento y el esfuerzo más ligero del catálogo.
- La tasa de aciertos de caché del panel **LLM Overview** cubre ahora Claude Platform, OpenRouter y las llamadas de las que informa el propio crok, cada fuente consultada por separado, así que una fuente sin llamadas en el intervalo no aporta nada.

### Firma

La 2.0.4 va firmada por el mismo certificado «Crok Code Signing» que la 2.0.3, la 2.0.2, la 2.0.1, la 2.0.0, la 1.5.2 y la 1.5.3. macOS vincula los permisos de privacidad a la firma, así que lo que autorizaste para la 2.0.3 (Grabación de pantalla, Accesibilidad, micrófono, reconocimiento de voz) se conserva en la 2.0.4. La compilación no está notarizada, así que una instalación nueva necesita una vez el paso **Abrir igualmente** de arriba.

La app de Android va firmada con la clave de publicación que introdujo la 2.0.0. La app de iOS no está firmada, como explica **Apps del teléfono**. La lista firmada de sumas de comprobación es otra cosa: permite al actualizador comprobar una descarga, y no cambia cómo trata macOS a la app.

### Actualizar desde la 2.0.3

Usa **Crok Desktop › Buscar actualizaciones…**, o `crok upgrade` en un terminal con Crok Desktop cerrado. Esta actualización se hace en el sitio, dentro de la app instalada, `Crok Desktop.app`, así que conserva su lugar en el Dock y en Finder y no queda ninguna copia antigua en la Papelera. La actualización toma la imagen compilada con el mismo SDK que la app instalada (macOS26-SDK o macOS15-SDK), nunca la otra.

El inicio de sesión en tus proveedores de modelos, los ajustes, las tareas y el relé se conservan: la 2.0.4 habla con el mismo relé de producción que la 2.0.3. Actualiza todos los ordenadores que uses con el relé, para que puedan recibir fotos y archivos y responder al momento a Actualizar, e instala las apps del teléfono de esta versión, como indica **Apps del teléfono** más arriba.

### Detalles

- Incluye crok `{{CROK_VERSION}}`.
- Compilada por GitHub Actions desde la etiqueta `desktop-v2.0.4` en `{{COMMIT}}` de `main`. La imagen del SDK de macOS 26 se compiló con Xcode {{XCODE26}} y el SDK {{SDK26}} de macOS, la imagen del SDK de macOS 15 con Xcode {{XCODE15}} y el SDK {{SDK15}} de macOS, y el `crok` independiente con el SDK {{TUI_SDK}} de macOS.
- Las dos imágenes son arm64, van firmadas por el certificado Crok Code Signing y no están notarizadas, y las dos funcionan en macOS 14 Sonoma o posterior.
- La app de iOS (`dev.chenli.crok.mobile`) es una compilación Release hecha con Xcode {{XCODE26}}; la app de Android es una compilación release para Android 8.0 o posterior.
- Las sumas SHA-256 están al final de estas notas y en `SHA256SUMS.txt`, que también cubre las apps del teléfono. El archivo `release/README.md` del repositorio explica cómo comprobar a mano la firma de la lista.
