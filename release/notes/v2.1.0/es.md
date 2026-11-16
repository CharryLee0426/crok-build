Crok Desktop 2.1.0 es la app nativa de macOS de este fork. Incluye crok, el entorno de ejecución del agente y la interfaz de terminal `crok`, así que no hay que instalar nada más. Sigue a la 2.0.4, que llevó fotos y archivos a los prompts remotos. La 2.1.0 añade Meta Model API como séptimo proveedor, con sus modelos Muse, al terminal y a Crok Desktop. La web y las apps del teléfono muestran ahora juntos el modelo y el nivel de razonamiento de una sesión, también en las sesiones abiertas desde la lista. Crok Desktop dibuja su cristal solo en la ventana activa y pinta por su cuenta el cristal del área de entrada, así que una ventana inactiva detrás de otras apps cuesta lo que una ventana normal y Mission Control sigue fluido. El pulgar de feedback elegido ahora se rellena, y el punto de estado de **Otros ordenadores** es más grande y verde cuando están en línea.

Esta versión la compila y publica GitHub Actions, nada más fusionarse su pull request, como la 2.0.4.

### Instalación

1. Descarga la imagen de disco que corresponda a tu versión de macOS y ábrela. La tabla de **Qué imagen de disco descargar** dice cuál.
2. Arrastra **Crok Desktop** a **Aplicaciones**.
3. Abre Crok Desktop desde Aplicaciones. Esta compilación no está notarizada, así que la primera vez macOS dirá que no puede verificar la app: cierra el aviso, abre **Ajustes del Sistema › Privacidad y seguridad**, haz clic en **Abrir igualmente** junto al mensaje de Crok Desktop y confirma. Solo hay que hacerlo una vez.
4. Inicia sesión en **Ajustes › Cuentas** con OpenRouter, OpenAI Codex, una clave de API de Anthropic, una clave de API de DeepSeek, una clave de Meta Model API o una clave de GLM Coding Plan.

Requiere macOS 14 Sonoma o posterior en Apple silicon (M1 o posterior).

### Qué imagen de disco descargar

Ambas imágenes son Crok Desktop 2.1.0 y contienen las mismas funciones. Solo cambia el SDK de macOS con el que se compilaron, que decide si el marco de la ventana usa el Liquid Glass de Apple:

| Imagen de disco | Compilada con | Úsala en | Barra de título |
| --- | --- | --- | --- |
| `Crok-Desktop-2.1.0-arm64-macOS26-SDK.dmg` | SDK {{SDK26}} de macOS | macOS 26 y posterior | Liquid Glass |
| `Crok-Desktop-2.1.0-arm64-macOS15-SDK.dmg` | SDK {{SDK15}} de macOS | macOS 14 y 15 | Desenfoque esmerilado dentro de la ventana |

En macOS 26 y posterior, prefiere la imagen del SDK de macOS 26 para la barra de título Liquid Glass. En macOS 14 o 15, usa la imagen del SDK de macOS 15. También funciona en versiones posteriores, así que si no sabes qué macOS tienes, es la opción segura. El área de entrada se dibuja igual en ambas imágenes.

`crok-2.1.0-aarch64-apple-darwin.tar.gz` es la interfaz de terminal `crok` por sí sola, para un Mac donde no quieras la app: descomprímela y pon `crok` en tu `PATH`. Las apps del teléfono se describen en **Apps del teléfono**. `SHA256SUMS.txt` enumera el SHA-256 de cada descarga, y `SHA256SUMS.txt.sig` es la firma de esa lista, que comprueba el actualizador.

### Apps del teléfono

La app Crok para iPhone y Android sigue las sesiones de tus ordenadores, muestra sus respuestas y solicitudes de permiso, y permite empezar o dirigir tareas desde cualquier lugar. Las apps del teléfono de esta versión son nuevas: una sesión abierta muestra juntos su modelo y su nivel de razonamiento, y un modelo que un ordenador antiguo nombra como el proveedor se encuentra igualmente en la lista. Instálalas sobre las de la 2.0.4 para tenerlo. Las apps del teléfono de la 2.0.4 y anteriores siguen funcionando como antes. Los tres archivos inician sesión en el relé de producción.

- **Android 8.0 o posterior:** descarga `Crok-Android-2.1.0.apk` en el teléfono y ábrelo, permitiendo a tu navegador instalar apps cuando Android lo pida, o ejecuta `adb install -r Crok-Android-2.1.0.apk`. Va firmado con la clave de publicación que introdujo la 2.0.0, así que se instala sobre el APK de una versión anterior. Un APK de Crok que hayas compilado tú va firmado con otra clave y bloquea la instalación: elimínalo antes con `adb uninstall dev.chenli.crok.mobile`, o desde los ajustes del teléfono.
- **iPhone y iPad, iOS 17 o posterior:** `Crok-iOS-2.1.0-unsigned.ipa` no está firmado, porque una app para dispositivos iOS se firma con el Apple ID de quien la instala. Instálalo con una herramienta de instalación lateral como AltStore o Sideloadly, que lo firma con tu Apple ID. Con un Apple ID gratuito, iOS deja de abrir la app a los 7 días hasta que la instales otra vez. Para compilarla tú mismo, usa la configuración **Release**: el botón Run de Xcode compila Debug, que inicia sesión en el relé de pruebas.
- **Simulador de iOS:** `Crok-iOS-2.1.0-Simulator.zip` se descomprime en `Crok.app`, para `xcrun simctl install booted Crok.app` en un Mac con Xcode.

Para iniciar sesión en el teléfono, toca **Continuar con GitHub o Google**, inicia sesión en la página que se abre en https://crok.chenli.dev y toca **Aprobar**. Después vincula cada ordenador: ejecuta `crok remote login` en él y escanea el código QR que muestra desde **Ajustes › Vincular un ordenador** en la app, o aprueba el ordenador en la página web que se abre.

### Novedades principales

- **Meta Model API, un séptimo proveedor.** El terminal y Crok Desktop inician sesión en el Model API propio de Meta, que se factura por token a una cuenta de Meta, con una clave de dev.meta.ai. `crok login meta` pide la clave sin mostrarla y la comprueba con Meta antes de guardarla; una clave rechazada no se guarda. `meta-code` y `muse` son alias, `META_API_KEY` y `MODEL_API_KEY` inician sesión del mismo modo, y `crok logout meta` elimina la clave guardada. **Ajustes › Cuentas** de Crok Desktop y el menú de primera ejecución del terminal listan el proveedor.
- **Los modelos Muse.** Al iniciar sesión se obtiene la lista de modelos de tu cuenta, que después se actualiza cada hora. La lista integrada es Muse Wonder, Muse Spark 1.3, 1.2 y 1.1, sus variantes de modo Contributor y Muse Ember; un modelo que Meta publique más adelante funciona al momento con su ID `meta/<model>`. Los modelos leen texto, imágenes, PDF, audio y vídeo. Siempre razonan: `/effort` ofrece `minimal`, `low`, `medium`, `high`, `xhigh` y `max`, con `max` por defecto en Muse Wonder y Muse Ember y `high` en Muse Spark. `none` no se ofrece porque Meta lo rechaza, y las variantes Contributor llegan hasta `xhigh`.
- **El modelo y el nivel de razonamiento de una sesión, siempre juntos.** Abrir una sesión en la web, iOS o Android podía mostrar solo el ID del modelo, sin la píldora del nivel de razonamiento. crok ahora nombra el modelo de una sesión con el ID de su lista de modelos, así que los dispositivos encuentran el modelo y sus niveles. Una sesión de un crok antiguo, que nombra el modelo como el proveedor, se encuentra igualmente por el ID sin su proveedor y, después, por el nombre. La píldora del nivel de razonamiento muestra el nivel de la sesión mientras carga la lista, y nombra un nivel que la lista del modelo no tiene en vez de decir **Predeterminado**. Solo se omite para un modelo cuya lista dice que no tiene niveles, o cuando ni la lista ni la sesión nombran un nivel.
- **Un cristal que cuesta menos dibujar.** Solo el cristal de la ventana activa está vivo, como en las barras laterales del sistema: una ventana detrás de otras apps pinta colores sólidos y las tarjetas de la página de bienvenida dejan de deslizarse. Deslizar a Mission Control ya no se entrecorta, y menos aún con una pantalla externa. En un M1 con una pantalla 4K, Mission Control con Crok detrás de Finder pasó de 14,1 a 8,9 de uso medio de la GPU (p90 de 46 a 31).
- **El área de entrada, dibujada en vez de Liquid Glass.** El servidor de ventanas vuelve a dibujar Liquid Glass cada vez que cambia algo en su ventana, incluido un cursor que parpadea. La superficie del área de entrada se dibuja ahora con un material esmerilado y un solo Canvas que contiene su sombra, relleno, borde iluminado, brillo y línea fina, y coincide con el aspecto del sistema dentro de unos pocos niveles de 255. En el mismo M1 y la misma pantalla 4K, el uso de la GPU de Crok delante en reposo pasó de unos 25 a 10,6, y el de Mission Control con Crok delante, de 18,8 a 13,0.
- **Detalles pequeños.** Un pulgar arriba o abajo se rellena al elegirlo, así que el veredicto se ve de un vistazo. El punto en línea de **Otros ordenadores** mide 10 puntos, es verde y tiene halo, y el punto fuera de línea es del mismo tamaño en gris.

### Control remoto

Todos los crok de esta versión inician sesión en el relé de producción en https://crok.chenli.dev, como la 2.0.4, y conservan la sesión que ya tienen. El relé de producción sirve los cambios de web de esta versión cuando se publique; lo que ocurre en un ordenador llega con crok 2.1.0 allí.

- **Nombres de modelo.** Una sesión guarda su modelo como lo llama el proveedor (`claude-sonnet-5-5`, `deepseek-flash`, el `deepseek/deepseek-v4.1-flash` de OpenRouter), mientras que la lista que publica crok lo nombra por su clave de catálogo (`anthropic/claude-sonnet-5-5`, `deepseek/deepseek-flash`, `openrouter/deepseek/deepseek-v4.1-flash`). crok 2.1.0 envía el ID de la lista, así que la web y los teléfonos encuentran el modelo y sus niveles de razonamiento. Un modelo que el ordenador ya no ofrece conserva su nombre.
- **crok antiguo.** Un ordenador que solo ejecuta crok 2.0.4 o anterior sigue nombrando el modelo como el proveedor. La web y las apps del teléfono de esta versión lo encuentran por el ID sin su proveedor, así que el modelo y su nivel siguen apareciendo; el ID desnudo solo aparece cuando no coincide ninguna de las dos formas.
- **Las dos píldoras.** La web, iOS y Android muestran juntos el modelo y el nivel de razonamiento de la sesión. Mientras llega la lista del ordenador, el modelo se muestra y la píldora del nivel de razonamiento dice el nivel de la sesión; si no hay lista porque el crok es antiguo, ambas se atenúan y un toque explica que ese ordenador aún no ofrece opciones de modelo. Un nivel que falta en la lista del modelo se muestra con el nombre de su nivel.
- **Actualiza los ordenadores.** Meta Model API y los nombres exactos de modelo llegan con crok 2.1.0 en cada ordenador. Instala las apps del teléfono de esta versión, como dice **Apps del teléfono** arriba, para tener las dos píldoras.

### Feedback y Agent Observability

El informe no cambia respecto a la 2.0.4: cada crok informa de cada llamada a un modelo que hace, con sus turnos, ejecuciones de herramientas, pasos y comprobaciones de seguridad, a [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) en el stack de Grafana Cloud del mantenedor, y `crok version --json` muestra el host en `agentObservability`. Un pulgar arriba o abajo desde Crok Desktop o el terminal se registra en la conversación de ese turno y como el gauge `crok_feedback_rating`; retirarlo se registra como neutral.

Para desactivar el informe, añade `agent_observability = false` en `[features]` de `~/.crok/config.toml`, o define `CROK_AGENT_OBSERVABILITY=0`. Para informar a tu propio stack, escribe `~/.crok/agento11y.env` con `crates/codegen/xai-grok-agento11y/setup.sh` del repositorio.

### Para desarrolladores

- Meta es un `ApiBackend` (`meta`) con un dialecto propio de Chat Completions. `GET /v1/models` se obtiene al iniciar sesión y cada hora, y se guarda en caché en `~/.crok/meta-models.json`; hasta la primera descarga se usa la lista integrada. `provider_compat.rs` envía `none` y `minimal` como `minimal`, eleva cualquier `max_tokens` por debajo de 4.096 porque el razonamiento sale del mismo presupuesto, pide con palabras una llamada de herramienta forzada con `tool_choice: "auto"`, conserva los esquemas JSON nativos, elimina `reasoning_content` de los turnos reproducidos y elimina `frequency_penalty` y `presence_penalty`.
- Un cambio de modelo entre familias compacta antes, como en Anthropic. Los costes estándar se estiman con los precios publicados de Meta, incluido el tramo de contexto largo de 200.000 tokens de entrada de Muse Ember y las tarifas de Contributor.
- Remoto: `bridge:upsertSession` (solo cuando cambió el modelo), `bridge:catalogBatch` y `catalogUpdate` nombran el modelo de una sesión con la clave de catálogo que resuelve `selectable_catalog_key_for_persisted`, del mismo modo que se resuelve el modelo de una sesión reanudada. Un modelo que la lista no tiene conserva su nombre. `relay/DESIGN.md` y `mobile/DESIGN.md` describen el contrato.
- La web, iOS y Android encuentran el modelo de una sesión por su ID, luego por el ID sin su proveedor y luego por el nombre, y muestran la píldora del nivel de razonamiento siempre que la sesión nombre un nivel. La vista previa web tiene los casos nuevos (`session-provider-model`, `session-models-loading`, `session-unknown-model`).
- Escritorio: `GlassBackdrop` usa los colores sólidos mientras la ventana está inactiva y tiñe sobre el fondo de otra región en vez de desenfocar de nuevo el escritorio; `GlassSurface` dibuja su aspecto `FrostedGlass` en un solo Canvas. Las pruebas comprueban que no quedan capas de Liquid Glass y que las ventanas inactivas pintan colores sólidos.
- Las versiones las hace `.github/workflows/release.yml` como antes: cuando una pull request que sube `VERSION` se fusiona en `main`, compila, comprueba y firma cada archivo, ejecuta la puerta de evaluación y publica la versión con las notas de `release/notes/v2.1.0/`.

### Firma

La 2.1.0 va firmada por el mismo certificado «Crok Code Signing» que la 2.0.4, la 2.0.3, la 2.0.2, la 2.0.1, la 2.0.0, la 1.5.2 y la 1.5.3. macOS vincula los permisos de privacidad a la firma, así que lo que autorizaste para la 2.0.4 (Grabación de pantalla, Accesibilidad, micrófono, reconocimiento de voz) se conserva en la 2.1.0. La compilación no está notarizada, así que una instalación nueva necesita una vez el paso **Abrir igualmente** de arriba.

La app de Android va firmada con la clave de publicación que introdujo la 2.0.0. La app de iOS no está firmada, como explica **Apps del teléfono**. La lista firmada de sumas de comprobación es otra cosa: permite al actualizador comprobar una descarga, y no cambia cómo trata macOS a la app.

### Actualizar desde la 2.0.4

Usa **Crok Desktop › Buscar actualizaciones…**, o `crok upgrade` en un terminal con Crok Desktop cerrado. Esta actualización se hace en el sitio, dentro de la app instalada, `Crok Desktop.app`, así que conserva su lugar en el Dock y en Finder y no queda ninguna copia antigua en la Papelera. La actualización toma la imagen compilada con el mismo SDK que la app instalada (macOS26-SDK o macOS15-SDK), nunca la otra.

El inicio de sesión en tus proveedores de modelos, los ajustes, las tareas y el relé se conservan: la 2.1.0 habla con el mismo relé de producción que la 2.0.4. Actualiza a crok 2.1.0 cada ordenador que uses con el relé para tener Meta Model API y los nombres exactos de modelo, e instala las apps del teléfono de esta versión, como dice **Apps del teléfono** arriba.

### Detalles

- Incluye crok `{{CROK_VERSION}}`.
- Compilada por GitHub Actions desde la etiqueta `desktop-v2.1.0` en `{{COMMIT}}` de `main`. La imagen del SDK de macOS 26 se compiló con Xcode {{XCODE26}} y el SDK {{SDK26}} de macOS, la imagen del SDK de macOS 15 con Xcode {{XCODE15}} y el SDK {{SDK15}} de macOS, y el `crok` independiente con el SDK {{TUI_SDK}} de macOS.
- Ambas imágenes son arm64, están firmadas por el certificado Crok Code Signing y no están notarizadas, y ambas funcionan en macOS 14 Sonoma o posterior.
- La app de iOS (`dev.chenli.crok.mobile`) es una compilación Release hecha con Xcode {{XCODE26}}; la app de Android es una compilación release para Android 8.0 o posterior.
- Las sumas de comprobación SHA-256 están al final de estas notas y en `SHA256SUMS.txt`, que también cubre las apps del teléfono. `release/README.md` del repositorio explica cómo comprobar a mano la firma de la lista.
