# Playbook operativo — coordinación en dos niveles

Flujo para OpenCode V2. El runtime activo es la autoridad: confirma servidor, `/openapi.json`, catálogo de herramientas, permisos y ubicación antes de operar. El orquestador mantiene en exclusiva el ledger canónico. Crea sesiones `worker_session` raíz; cada worker coordina al menos dos sesiones `subagent` distintas, inspecciona e integra los resultados y reporta al orquestador. Los campos y estados locales del ledger no son estados nativos de OpenCode.

**Correspondencia con los 7 pasos de [SKILL.md](../SKILL.md#execution-steps)** (esta guía desglosa más): S1 → P1; S2 → P2; S3 → P3; S4 → P2–P3; S5 → P4–P5; S6 → P5–P7; S7 → P8 y checklist de cierre.

## Paso 1: Detectar intención y alcance

- **Entrada:** petición del usuario.
- **Salida:** veredicto (orquestar / no orquestar), objetivo, entregables y restricciones.
- **Verificación:** la tarea necesita coordinación de varias sesiones, delegación o reconciliación. Para trabajo de una sola sesión, responde inline.
- **Errores típicos:** activar por una keyword suelta → responde inline; dividir una unidad trivial → resuélvela directamente.

## Paso 2: Preflight de capacidades reales

Antes de crear tareas, consulta el catálogo, `/openapi.json` (solo vale si es JSON OpenAPI; una respuesta HTML no es un esquema, ver [Descubrimiento del contrato](api-and-sessions.md#descubrimiento-del-contrato)) y la interfaz de cliente/runtime activos. Para cada operación registra el nombre exacto anunciado, sus argumentos y la evidencia de que existe:

| Operación necesaria | Evidencia que se comprueba |
|---|---|
| Crear una sesión worker raíz | La capacidad real acepta como argumento explícito `run.location.directory` y devuelve/permite leer el `sessionID`. |
| Enviar el prompt a esa sesión | La capacidad real identifica el destino por su identidad de sesión y acepta el prompt completo. |
| Esperar y leer el resultado | Existe una señal documentada de finalización y una forma de leer salida/estado de esa misma sesión. |
| Exponer y comprobar una tab TUI (**solo si el usuario pidió tabs**) | Crear la sesión por API HTTP no demuestra que aparezca en la TUI. Confirma si la versión activa ofrece API de tabs del CLI plugin o usa estado local `tabs.json`, verifica el esquema/mecanismo y confirma que la tab resultante muestra el `sessionID` esperado; consulta la [receta local](recipe-tui-tabs.md). |
| Leer resultado de worker | El orquestador puede leer estado y resultado de la sesión mediante la capacidad confirmada; esta es la vía base para informes y solicitudes de cambio. |
| Canal dinámico worker↔orquestador (opcional) | Solo se habilita si preflight confirma una vía real de ida y vuelta para pedir cambios y responder. No es requisito para el despacho preautorizado. |
| Crear subagent desde un worker | El catálogo y los permisos permiten el `parentID` nativo correcto, y la ubicación hija cumple la [regla única](subagent-contract.md#regla-única-de-ubicación-de-hijas) (incluida la comprobación `GET /api/session/{childID}`). |

No inventes nombres de herramientas, parámetros, rutas, notificaciones ni IDs. No sustituyas crear/abrir/comprobar una sesión o tab por llamar `subagent`. Si falta una capacidad, registra la operación exacta, la fuente consultada y el efecto: detén solo el lanzamiento que depende de ella y reporta el bloqueo; continúa únicamente preparación independiente. Para la ubicación hija, aplica la [regla única](subagent-contract.md#regla-única-de-ubicación-de-hijas); no inventes parámetros.

## Paso 3: Confirmar acceso, servidor e identidad

- Confirma autorización y el endpoint que se usará. En clientes locales, registra `shared-default`, `explicit-server` o `standalone` según lo observado; no registres credenciales.
- Consulta `/openapi.json` para descubrir el contrato, y `/api/info` y `/api/location` únicamente si el esquema activo los publica. Registra `observed_id`, versión, `directory`, `projectID` y `subpath` canónicos en el ledger; si el validador ve el workspace con otra ruta (servidor Windows/UNC, Git Bash, WSL), registra también `directory_client` (ver [ledger-template.md](ledger-template.md#esquema-único)).
- Comprueba el `sessionID` y `parentID` nativos de la sesión actual del orquestador. `run.root_session` representa esa sesión, no una sesión worker.
- Cada worker raíz nuevo debe recibir `run.location.directory` como argumento explícito. Para una hija, aplica la [regla única de ubicación de hijas](subagent-contract.md#regla-única-de-ubicación-de-hijas). Después de crear toda sesión, consulta su identidad/location real y exige igualdad exacta con `run.location.directory` antes de enviar o contar trabajo.
- **Solo si el usuario pidió tabs:** una tab solo es una vista del cliente. Después de crear la sesión, expónla por la API local de tabs del CLI plugin o el estado `tabs.json` únicamente si el contrato/esquema de la versión activa lo confirma. Comprueba que la TUI presenta el `sessionID` esperado y usa `run.location.directory` como su cwd; la creación por API no garantiza esta exposición. Consulta la [receta local](recipe-tui-tabs.md), no inventes rutas ni claves, y no uses la tab como identidad de sesión o `parentID`.

**Si falla:** sin autorización, servidor verificable, capacidad de sesión explícita o coincidencia de ubicación, no simules éxito ni pruebes rutas adivinadas. Reporta qué comprobación o capacidad falta.

## Paso 4: Diseñar dos niveles y scopes heredados

El DAG tiene dos niveles de ejecución además del orquestador:

1. El orquestador asigna cada unidad de trabajo a una tarea `worker_session` nueva, con `parent_task_id: null` y `parentID: null`.
2. Cada worker, excluido el orquestador, ejecuta al menos dos tareas hijas útiles preautorizadas por el orquestador, como sesiones `subagent` distintas. Puede repetir el mismo `agent_id`; para el mínimo cuentan dos `sessionID` confirmados, no dos nombres de agente ni dos continuaciones de una sesión.
3. Los subagents no necesitan crear nietos. No afirmes el mínimo si falló la creación de hijos o si no hay dos IDs distintos.

Antes de enviar el prompt de trabajo, el orquestador registra en el ledger al menos dos filas `subagent` preautorizadas por worker, cada una con `task_id`, scope, `output_path` y `criterion`; completa `parentID` con el `sessionID` real del worker y `location_directory` con `run.location.directory`. Incluye esas filas en el prompt. El worker ejecuta solo las tareas/scope autorizados y no escribe el ledger. El orquestador lee los resultados por la capacidad confirmada de esa sesión; no se presupone un canal de mensajes entre sesiones raíz independientes. Un handshake dinámico solo se usa si preflight confirma ida y vuelta. Si el worker necesita cambiar una tarea o scope, se detiene y pide actualización por la vía confirmada; el orquestador actualiza el ledger antes de enviar un prompt actualizado.

| Regla | Acción |
|---|---|
| Dependencia | Si una tarea consume la salida de otra, añade dependencia y espera esa salida. |
| Scopes y timeouts | Un hijo recibe un subconjunto explícito del scope del worker; solapes, escritor padre y timeout: [regla única](agents-and-safety.md#presupuesto-de-escritura-y-scopes). |
| Capacidad | Serializa según la capacidad observada y las dependencias reales; `run.max_sessions_in_flight` solo con límite real y procedencia en `notas` ([ledger-template.md](ledger-template.md#límite-opcional-max_sessions_in_flight)). |

Declara las rutas relativas a la raíz del workspace (resueltas contra `run.location.directory_client` o, si falta, `run.location.directory`; ver [ledger-template.md](ledger-template.md#esquema-único)); comprueba que cada salida esté contenida en el scope de escritura asignado. Cada tarea, de ambos tipos, lleva `task_kind`, `parent_task_id`, `parentID` nativo y `location_directory` según el contrato schema 3 de [SKILL.md](../SKILL.md#identidad-y-ledger).

## Paso 5: Registrar y crear sesiones worker

El orquestador crea una fila por worker antes de despachar: `task_kind: worker_session`, `parent_task_id: null`, `parentID: null`, `location_directory` igual a `run.location.directory`, `source_sessionID: null`, `before_messageID: null`, objetivo, dependencias, scope, salida y criterio. Las filas de hijos nuevos también llevan `source_sessionID: null` y `before_messageID: null`; solo un fork documentado puede registrar sus IDs de origen/corte. Guarda la sesión actual del orquestador por separado en `run.root_session`.

**Ruta por defecto: los scripts deterministas.** No montes este paso a mano — la navaja suiza hace el trabajo repetible y sus decisiones de gate ya están centralizadas.

```sh
sh scripts/orchestrate.sh preflight "$PWD"                                  # P2 + gate de tabs
sh scripts/orchestrate.sh init-run --worker "Vermithrax" --worker "Glacielle" # raíz [00] + workers + tabs
```

`init-run` crea la raíz `[00] Orquestador`, crea cada worker con su `sessionID` verificado, aplica la numeración correlativa de la [nomenclatura](naming-convention.md) y expone las tabs cuando la gate dice `ready`. Un `--worker` por sesión: **el espacio no puede ser delimitador de lista** porque es parte del título. También acepta `--workers "A, B, C"`.

Usa `create-worker` paso a paso solo cuando de verdad lo necesites: crear un worker suelto, forzar uno nuevo con `--force-new`, o reutilizar el preflight cacheado. Cada llamada suelta es un viaje extra, y el flujo `create-worker` en bucle deja la exposición de tabs sin hacer.

Contrasta `init-run` con el ledger: los `sessionID` que emite son la identidad real. El dedup es **por nombre, ignorando el ordinal**, así que `--worker "Vermithrax"` reusa `[01] Vermithrax` en vez de crear un duplicado.

Si `init-run` responde `init-run: INCOMPLETO` y sale con código 1, algún worker no se creó: **no lo trates como éxito**. Reejecuta `init-run` con los mismos títulos; el dedup reutiliza lo ya creado y completa lo que falte.

Para cada worker, en este orden:

1. Registra estado local `pending` y luego `launching` antes de llamar la capacidad exacta descubierta.
2. Crea una sesión raíz con `run.location.directory` explícito. Comprueba el `sessionID`, que `parentID` nativo sea `null` y que la ubicación real coincida exactamente.
3. Antes de enviar el prompt, registra al menos dos filas `subagent` preautorizadas: `task_id` nuevos, `parent_task_id` igual al worker, `parentID` igual al `sessionID` nativo comprobado, `location_directory` igual a `run.location.directory`, `sessionID: null`, scope, salida y criterio. No uses un estado ficticio de autorización: las filas empiezan `pending`.
4. Expón la sesión como tab TUI por la vía del [gate de tabs de SKILL.md](../SKILL.md#decision-gates). Con TUI local activa, la exposición aditiva de `tabs.json` es la ruta por defecto ([receta §6](recipe-tui-tabs.md)) y `init-run` ya la hace; si la gate no está `ready`, el run continúa sin tabs y se marca "no verificada". Solo con autorización explícita del operador pasas `--force-tabs`. Comprueba que la TUI muestra el `sessionID` worker y la ubicación canónica. La tab no sustituye los IDs.
5. Envía el prompt autocontenido [de worker](prompt-templates.md#1-despacho-de-worker-session), incluyendo las filas y sus scopes/criterios exactos.
6. Registra `sessionID`, identidad comprobada y estado nativo observado. Espera y lee el resultado mediante la capacidad identificada.

No uses `subagent` para crear una sesión worker raíz ni para fingir una tab. Si una llamada se vuelve incierta, registra `outcome-unknown`, conserva el scope y reconcilia antes de repetir.

## Paso 6: Coordinar los subagents de cada worker

Cada prompt de worker incluye al menos dos tareas útiles, autocontenidas y verificables ya registradas por el orquestador. El worker no altera sus identidades, criterios ni scopes. Para cada hija preautorizada:

1. Cada hija usa el `task_id` de su fila preautorizada (registrado como ID nuevo por el orquestador), `task_kind: subagent`, `parent_task_id` igual al `task_id` del worker, `parentID` igual al `sessionID` nativo confirmado del worker y `location_directory` igual a `run.location.directory`.
2. Lanza una sesión hija nueva por la capacidad `subagent` que el catálogo activo permita, con la ubicación según la [regla única](subagent-contract.md#regla-única-de-ubicación-de-hijas). Comprueba el `sessionID`, `parentID` real y location antes de contarla.
3. Usa un `agent_id` del catálogo activo. Se permite repetirlo para una sesión distinta.
4. Dale solo el scope hijo asignado, los datos mínimos, el formato de salida, el criterio y la comprobación requerida.
5. Registra y reporta el resultado/fallo. No repitas lanzamientos inciertos hasta reconciliar; un fallo de creación no recibe un ID inventado ni cuenta para el mínimo.

Si una tarea o scope preautorizados necesitan cambiar, el worker detiene ese trabajo y solicita actualización por la vía confirmada; nunca modifica el ledger ni crea una fila/scope nuevo. Sin canal dinámico confirmado, deja la solicitud en el resultado que el orquestador puede leer y no reanuda el trabajo cambiado hasta recibir el prompt actualizado. Si no se pudo crear un hijo, avanza solo las otras tareas independientes ya autorizadas y reporta al orquestador los IDs confirmados, resultados, fallo literal y capacidad ausente. El trabajo ejecutado parcialmente queda `partial`; el worker no se declara `verified` ni afirma haber cumplido dos hijos sin el gate completo.

## Paso 7: Supervisar y reconciliar

- Espera la señal documentada de la sesión y lee el resultado con la [lectura acotada](api-and-sessions.md#lectura-acotada-del-resultado) y las [reglas de reconciliación](api-and-sessions.md#reglas-de-reconciliación-de-la-espera): confirma las hijas con `GET /api/session?parentID=`, revisa permisos pendientes en cada ciclo y re-arma el plazo solo si el worker sigue activo (tope; luego `outcome-unknown`). No sondees sin límite ni dupliques prompts.
- Conserva por separado `runtime_status` literal, `execution_outcome` local (`unknown`, `succeeded`, `failed`, `interrupted`, `cancelled`) y `estado` local del ledger.
- Un timeout, desconexión o ausencia de aviso no prueba que la sesión haya parado. Reconecta al mismo endpoint; reconfirma ubicación e IDs; usa solo lectura/reconciliación documentada en el `/openapi.json` activo.
- Hasta reconciliar, conserva el scope del hijo y evita que escriba el padre o un sibling solapado. No reenvíes una petición cuyo efecto sea incierto.
- El orquestador integra el ledger con cada reporte del worker. Si un worker no pudo crear hijos, registra qué hijos sí existen, sus resultados, el fallo y el mínimo incumplido; no conviertas ese incumplimiento en éxito.

## Paso 8: Inspeccionar, integrar y cerrar

El gate de `verified` de un worker (mínimo de dos subagents distintos, `parentID` y ubicación correctos, `subagent_results_integrated` con los `task_id` de los hijos verificados) está definido solo en [ledger-template.md](ledger-template.md#gate-de-worker-verificado). Aquí el worker lee los entregables, comprueba cada `criterion`, resuelve contradicciones por evidencia y deja una síntesis que integra todos los resultados verificados; el orquestador inspecciona el reporte y los artefactos del worker antes de cerrar su tarea.

- La mera existencia de `output_path` o una notificación terminal no prueba el criterio; un mensaje final vacío tampoco prueba no-ejecución (un turno puede cerrar tras tool-calls sin texto): verifica artefactos y `git diff` antes de diagnosticar.
- La evidencia enlazada sigue el [formato canónico](ledger-template.md#formato-de-evidencia); el padre inspecciona el artefacto, no solo la forma de la nota.
- Un `blocked`, `failed`, `interrupted`, `cancelled`, `partial`, `launching`, `outcome-unknown`, `running`, `awaiting-approval` o `completed` conserva su resultado real; ninguno satisface por sí solo el gate `verified`.
- La síntesis separa hechos del runtime, inferencias, convenciones locales, sesiones/IDs, hijos faltantes y límites pendientes.

## Checklist de cierre

1. Se descubrieron las capacidades reales para crear, promptar y esperar/leer (y, solo si el usuario pidió tabs, abrir/comprobar tabs); faltantes quedaron reportados con fuente.
2. Servidor y ubicación confirmados; cada worker raíz recibió `run.location.directory` explícito, cada hija cumplió la [regla única de ubicación de hijas](subagent-contract.md#regla-única-de-ubicación-de-hijas), comprobada con `GET /api/session/{childID}`, y toda location real coincide exactamente.
3. Ledger schema 3: `run.min_subagents_per_worker: 2`; cada fila tiene tipo, padres nativos/locales y ubicación coherentes.
4. Cada worker verificado cumple el [gate de worker verificado](ledger-template.md#gate-de-worker-verificado) y su evidencia sigue el [formato canónico](ledger-template.md#formato-de-evidencia).
5. Workers reportaron estado y resultados; solo el orquestador modificó el ledger.
6. Scopes heredados; siblings solapados serializados; el padre no escribió en scopes activos; timeout reconciliado antes de liberar.
7. Si figura `run.max_sessions_in_flight`, cumple la [regla del límite opcional](ledger-template.md#límite-opcional-max_sessions_in_flight).
8. Artefactos comprobados contra criterios; las limitaciones y puntos de integración pendientes constan en el cierre.

### Rutas de fallo

- Si el catálogo o `/openapi.json` no confirma una operación, no adivines su nombre ni llames una ruta especulativa.
- Si falta capacidad de creación de sesión, envío de prompt, espera/lectura de resultado o (solo si se pidieron tabs) exposición/verificación local de tab, nombra exactamente la capacidad ausente y la fuente consultada; bloquea solo el trabajo que depende de ella. El resultado worker se lee desde su sesión; no asumas un canal independiente de reportes.
- Si el worker raíz no recibió la ubicación explícita, o si la location real de cualquier sesión no coincide con la canónica, no envíes ni cuentes ese trabajo. Si no se cumple la [regla única de ubicación de hijas](subagent-contract.md#regla-única-de-ubicación-de-hijas), reporta el bloqueo.
- Si la política del worker no permite `subagent`, o la ubicación hija no cumple la regla única, registra el bloqueo; no inventes argumentos ni sustituyas la sesión hija por una tab u otro tipo de tarea.
- Si scopes se solapan, serializa; si una ejecución tiene estado incierto, conserva el scope hasta reconciliar.
- Si se crean menos de dos hijos distintos, registra los IDs/resultados/fallos y deja el mínimo incumplido (`partial` si hubo avance incompleto; nunca `verified`; ver el [gate](ledger-template.md#gate-de-worker-verificado)).
