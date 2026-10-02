# Ledger canónico de ejecución

El ledger es la fuente local durable para identidad, propiedad, dependencias, scopes, concurrencia y reconciliación. No lo persiste el runtime. El modelo tiene dos niveles: sesiones worker de primer nivel y subagents hijos de un worker. Las dependencias DAG ordenan ejecución; nunca expresan propiedad.

## Esquema único

La raíz es siempre un mapa con `schema_version`, `run` y `tasks` como lista. No uses una lista en la raíz ni pongas tareas directamente en el mapa raíz. El bloque vacío y el poblado usan la misma forma.

~~~~yaml
schema_version: 3
run:
  server:
    mode: "shared-default"
    endpoint_redacted: "http://127.0.0.1:4096"
    observed_id: "server-id-from-api-info"
    version: "version-from-api-info"
  location:
    directory: "/workspace/from-api-location"
    # directory_client: "/ruta/visible/para/el/validador"   # opcional; ver la viñeta de location
    projectID: null
    subpath: null
  root_session:
    sessionID: "root-session-id"
    parentID: null
  client:
    tabs_scope: "current-client"
    active_tab_hint: "optional-ui-hint"
  min_subagents_per_worker: 2

## Bloque opcional `run.client`

Los validadores aceptan (y la navaja `attach-tabs` escribe) un bloque opcional `run.client` con dos campos:

- `tabs_scope`: `"global"` o `"current-client"`; determina si la tab se publica en `tabs.json` global o bajo la clave cwd del TUI.
- `active_tab_hint`: string libre para que el TUI muestre una pestaña activa (no usado por los validadores).

Cuando este bloque aparece, el validador acepta las claves `tabs_scope` y `active_tab_hint` y rechaza cualquier otra clave bajo `client`. Si está ausente, los validadores no lo exigen. La documentación canónica del mecanismo de tabs está en `recipe-tui-tabs.md`.
tasks: []
~~~~

- `mode` es una convención del ledger: `shared-default`, `explicit-server` o `standalone`. Registra lo observado (`shared-default` por defecto en cliente local); la semántica de los flags de la CLI (`--server`, `--standalone`) requiere verificación con la ayuda de tu instalación ([api-and-sessions.md](api-and-sessions.md#transporte-de-las-llamadas)).
- `min_subagents_per_worker` debe ser exactamente `2`. `max_sessions_in_flight` es opcional y se rige por la sección [Límite opcional `max_sessions_in_flight`](#límite-opcional-max_sessions_in_flight).
- `location.directory` es la ruta literal del servidor OpenCode tal como la devuelve `/api/location`, en cualquier forma absoluta: POSIX (`/srv/p`), unidad Windows (`C:\Users\dev\p`) o UNC (`\\host\share\p`); **en el YAML, entre comillas dobles, cada barra invertida se escribe doblada**: `"C:\\Users\\dev\\p"`, `"\\\\host\\share\\p"` (el validador decodifica `\\` a `\`; una barra simple falla con «scalar inválido»). Se copia sin transformar a `location_directory` de cada tarea y a toda creación de sesión.
- `location.directory_client` (opcional) es la ruta del mismo workspace tal como la ve el validador (`pwd -P`): úsala cuando el servidor usa una ruta distinta de la visible en el shell (servidor Windows, UNC, montaje o mapeo distinto, Git Bash `/c/...`, WSL `/mnt/c/...`). Si falta, el validador compara `location.directory` con `pwd -P`. Los scopes relativos se resuelven contra `directory_client` (o `directory` si falta) y los scopes absolutos que cuelgan de `location.directory` se reasignan a esa base.
- Hechos vigentes de V2: confirma identidad y location del servidor (detalle en las dos viñetas siguientes) y los IDs runtime antes de operar. Las tabs son pistas de cliente sin identidad HTTP pública. El hijo nativo es `subagent`; su política de permisos sigue la regla canónica de [agents-and-safety.md](agents-and-safety.md#reglas-de-permisos) (el permiso del padre controla qué agentes lanzar; la política del hijo rige sus herramientas; la herencia descrita es de reglas específicas de sesión, no de la política del agente).
- Confirma `endpoint_redacted`, `observed_id` y `version` con `/api/info`; quita secretos del endpoint.
- Confirma `directory`, `projectID` y `subpath` con `/api/location` y compáralos con `Session.Info.location`.
- `root_session.sessionID` y `parentID` son IDs runtime confirmados de la sesión raíz del run. Los campos de cada tarea describen por separado la sesión worker o subagent y su `parentID` real.
- Las rutas de sesión son experimentales: antes de usarlas, verifica su presencia en el `/openapi.json` activo del endpoint guardado.

## Campos de tarea

Cada tarea usa las claves exactas mostradas en el ejemplo. `task_id`, `agent_id` y los IDs se escriben como strings entre comillas dobles. `task_id` es único y empieza con letra o dígito, seguido de letras, dígitos, punto, guion o guion bajo. Dependencias, scopes y evidencias son listas flow-style de strings entre comillas dobles.

- `task_kind`: `worker_session` para un worker de primer nivel; `subagent` para una sesión hija nativa.
- `parent_task_id`: `null` para `worker_session`; el `task_id` del worker propietario para `subagent`.
- `parentID`: el `parentID` real reportado por OpenCode. Es `null` para una sesión worker raíz y el `sessionID` runtime del worker para un subagent.
- `location_directory`: copia exacta de `run.location.directory` en cada fila, aunque la location también aparezca en los metadatos del runtime.
- `sessionID`: sesión runtime confirmada, o `null` en filas `pending`/pre-creación antes de crearla. Un `null` no cuenta para el mínimo de hijos de un worker verificado. No reutilices un `sessionID` entre tareas.
- `agent_id`: ID confirmado del agente usado para la sesión.
- `dependencias`: IDs de tareas que deben quedar verificadas antes de iniciar esta tarea. No uses dependencias para representar `parent_task_id`.
- `scope_escritura`: lista del presupuesto de escritura de la tarea. Cada scope de subagent debe quedar dentro de algún scope de escritura de su worker.
- `criterion`: afirmación concreta que el worker propietario pueda comprobar antes de despachar o cerrar la tarea.
- `output_path`: artefacto esperado; debe quedar dentro de al menos un `scope_escritura`. `null` es válido mientras la tarea esté en `pending`/`launching`/`running`/`awaiting-approval`/`outcome-unknown` (aún no produce artefacto); el validador de cierre lo exige no nulo y existente en el disco para `verified`, y con `notas` justificativas para los terminales no verificados.
- `evidence_refs`: lista de archivos de evidencia. Para `verified`, cada tarea subagent verificada escribe su archivo de evidencia dentro de su `scope_escritura` con criterion, result ("pass") y observed; la evidencia de un worker verificado incluye además `subagent_results_integrated` con todos sus hijos verificados que inspecciona e integra en su informe.
- `estado`: estado local entre `pending`, `launching`, `outcome-unknown`, `running`, `awaiting-approval`, `completed`, `verified`, `blocked`, `failed`, `interrupted`, `cancelled` y `partial`.
- `runtime_status`: valor literal observado del runtime activo o `null`; no es el estado local.
- `execution_outcome`: clasificación local `unknown`, `succeeded`, `failed`, `interrupted` o `cancelled`; no reemplaza el estado del runtime.
- `source_sessionID` y `before_messageID`: ambos `null`, o ambos presentes para un fork confirmado.
- `created_at` no cambia; `last_state_at` avanza en cada transición. Ambos son UTC `YYYY-MM-DDTHH:MM:SSZ`.
- `notas`: motivo, decisión o contexto operativo en texto.

## Gate de worker verificado

Esta sección es la única definición del mínimo de dos subagents; el resto de los documentos la enlazan.

El gate canónico solo permite marcar un `worker_session` como `verified` si tiene al menos `run.min_subagents_per_worker` (exactamente dos en este esquema) filas hijas `subagent` en estado `verified`. Para contar, cada fila debe tener `parent_task_id` igual al `task_id` del worker, `parentID` igual al `sessionID` runtime confirmado y no nulo del worker, un `sessionID` propio no nulo y distinto del de cada otra fila contada, y `location_directory` igual a `run.location.directory`, cuya location se confirmó comparándola con `/api/location` y `Session.Info.location`. Por tanto, filas con `sessionID: null` no cuentan y dos filas con IDs duplicados no satisfacen el mínimo de dos sesiones distintas. Además, la evidencia del worker debe confirmar que su informe inspecciona e integra todos los resultados verificados de sus hijos. Los workers `failed`, `blocked` o `partial` se pueden registrar sin cumplir el mínimo; no los marques `verified` para representar trabajo incompleto.

## Scopes y orden de escritura

Definición canónica única en [agents-and-safety.md#presupuesto-de-escritura-y-scopes](agents-and-safety.md#presupuesto-de-escritura-y-scopes). Esta sección solo ancla la referencia: los scopes se comparan por componentes de ruta; dos tareas sin relación padre-hijo con scopes solapados necesitan una dependencia DAG transitiva (también para siblings); la relación worker↔subagent permite scope anidado pero prohíbe escritura simultánea del padre en la parte solapada.

## Límite opcional `max_sessions_in_flight`

Las fuentes consultadas no publican un tope global de concurrencia de OpenCode, y la skill no define un valor por defecto: no importes un límite de otra versión ni uses `max_in_flight` (eliminado en schema 3). Añade `run.max_sessions_in_flight: N` (entero positivo) solo ante un límite real observado en la instancia activa. Si se configura, cuenta en conjunto workers y subagents en `launching`, `outcome-unknown`, `running` y `awaiting-approval`; el `outcome-unknown` y la aprobación pendiente conservan la reserva. El validador admite para ambos enteros de `run` (`min_subagents_per_worker` y `max_sessions_in_flight`) el rango 1–2147483647 (tope interno).

El validador solo admite el entero; no tiene un campo de procedencia en `run`. Conserva fuente, contexto del runtime, versión/instancia y fecha en `notas` de una fila `worker_session` (campo de tarea aceptado) y no inventes una clave `run.*_source`. Si no puedes dejar esa procedencia durable en un campo aceptado, omite el límite hasta ampliar esquema y validador.

## Write-ahead y reconciliación

Edita el ledger con un helper programático o regenerándolo desde un modelo en memoria; las sustituciones `sed`/regex in place son fuente de corrupción (campos perdidos silenciosamente). Crear/editar:

1. Crea cada fila como `pending`; completa criterio, propiedad, location, dependencias, scopes, output y `parentID` real/null según la capa.
2. Antes de invocar un worker o subagent, escribe estado `launching` y actualiza `last_state_at`. Si configuraste `max_sessions_in_flight`, cuenta el slot en ambas capas antes de lanzar.
3. Si no sabes si el envío tuvo efecto, registra estado `outcome-unknown` y `execution_outcome: "unknown"`. Conserva el slot y el scope; no reenvíes hasta reconciliar endpoint, location, sessionID y parentID.
4. Al confirmar ejecución o permiso pendiente, registra estado local y runtime por separado. `running` y `awaiting-approval` cuentan contra el límite configurado; `outcome-unknown` también conserva la reserva.
5. Al obtener resultado terminal, registra `runtime_status` literal y `execution_outcome`. Cambia a `completed`; el worker propietario aún debe inspeccionar el artefacto. Un worker no escribe en el scope de un hijo activo mientras ese hijo escribe.
6. Solo tras comprobar `output_path` contra `criterion` y que cada `evidence_refs` exista y satisfaga el [gate de evidencia](#formato-de-evidencia), cambia a `verified`. El informe del worker integra los resultados verificados de sus subagents y su evidencia los enumera en `subagent_results_integrated`. Los estados `blocked`, `failed`, `interrupted`, `cancelled` y `partial` conservan el motivo en `notas`.
7. Un fork confirmado registra el nuevo `sessionID`, junto con `source_sessionID` y `before_messageID`. Comprueba el `/openapi.json` activo antes de llamar una ruta experimental de sesión.

La herencia de reglas específicas de sesión al crear una hija está descrita en la viñeta de [Hechos vigentes de V2](#esquema-único); no la generalices a la política configurada del agente hijo.

## Ejemplo poblado de dos niveles

Las rutas son ilustrativas y relativas a la raíz del workspace; sustitúyelas por rutas reales. Los subagents escriben su `output_path`, así que usan `general`; `explore` es de solo lectura ([agents-and-safety.md](agents-and-safety.md#selección-de-agentes-para-los-dos-niveles)). El ejemplo muestra la forma de un ledger válido de dos niveles. Los paths ilustrativos de output y evidencia deben existir y contener los registros indicados antes de marcar las filas `verified` o pasar el gate de cierre.

~~~~yaml
schema_version: 3
run:
  server:
    mode: "shared-default"
    endpoint_redacted: "http://127.0.0.1:4096"
    observed_id: "server-42"
    version: "version-confirmed-by-api-info"
  location:
    directory: "/workspace/project"
    projectID: "project-7"
    subpath: "src"
  root_session:
    sessionID: "sid-root"
    parentID: null
  client:
    tabs_scope: "current-client"
    active_tab_hint: "workers"
  min_subagents_per_worker: 2
tasks:
  - task_id: "W1"
    task_kind: "worker_session"
    parent_task_id: null
    location_directory: "/workspace/project"
    sessionID: "sid-worker"
    parentID: null
    agent_id: "build"
    dependencias: []
    scope_escritura: ["artifacts"]
    criterion: "The report inspects and integrates both verified subagent results."
    output_path: "artifacts/W1-report.md"
    evidence_refs: ["artifacts/W1-evidence.yml"]
    estado: "verified"
    runtime_status: "completed"
    execution_outcome: "succeeded"
    source_sessionID: null
    before_messageID: null
    created_at: "2026-09-30T12:00:00Z"
    last_state_at: "2026-09-30T12:30:00Z"
    notas: ""
  - task_id: "S1"
    task_kind: "subagent"
    parent_task_id: "W1"
    location_directory: "/workspace/project"
    sessionID: "sid-subagent-1"
    parentID: "sid-worker"
    agent_id: "general"
    dependencias: []
    scope_escritura: ["artifacts/subagent-1"]
    criterion: "The output records the first independent result."
    output_path: "artifacts/subagent-1/S1-output.md"
    evidence_refs: ["artifacts/subagent-1/S1-evidence.yml"]
    estado: "verified"
    runtime_status: "completed"
    execution_outcome: "succeeded"
    source_sessionID: null
    before_messageID: null
    created_at: "2026-09-30T12:05:00Z"
    last_state_at: "2026-09-30T12:20:00Z"
    notas: ""
  - task_id: "S2"
    task_kind: "subagent"
    parent_task_id: "W1"
    location_directory: "/workspace/project"
    sessionID: "sid-subagent-2"
    parentID: "sid-worker"
    agent_id: "general"
    dependencias: []
    scope_escritura: ["artifacts/subagent-2"]
    criterion: "The output records the second independent result."
    output_path: "artifacts/subagent-2/S2-output.md"
    evidence_refs: ["artifacts/subagent-2/S2-evidence.yml"]
    estado: "verified"
    runtime_status: "completed"
    execution_outcome: "succeeded"
    source_sessionID: null
    before_messageID: null
    created_at: "2026-09-30T12:06:00Z"
    last_state_at: "2026-09-30T12:21:00Z"
    notas: ""
~~~~

## Formato de evidencia

Cada archivo de `evidence_refs` de una tarea verificada usa un registro plano con formato YAML, con los valores base entre comillas dobles. Cada tarea `subagent` verificada escribe su archivo de evidencia dentro de su `scope_escritura` asignado con criterion, result ("pass") y observed (o lo incluye en su entrega al worker, que lo integra en su informe, para que el orquestador lo persista):

~~~~yaml
criterion: "The output records the first independent result."
result: "pass"
observed: "Ran test suite; all 12 tests passed successfully."
~~~~

El archivo de evidencia del worker verificado incluye además la lista exacta `subagent_results_integrated` con los `task_id` de sus hijos subagent verificados que el informe inspecciona e integra:

~~~~yaml
criterion: "The report inspects and integrates both verified subagent results."
result: "pass"
observed: "Inspected W1-report.md; it compares and integrates the findings from S1 and S2."
subagent_results_integrated: ["S1", "S2"]
~~~~

La extensión del archivo es la que declara `evidence_refs`: si un hijo escribió `.yaml` en lugar de `.yml`, reconcilia `evidence_refs` hacia el archivo existente (nunca reescribas el archivo del hijo; R14a). El gate exige que `criterion` del registro coincida exactamente con la tarea, que `result` sea `pass` y que `observed` no esté vacío. Para un worker verificado, también exige `subagent_results_integrated` con todos sus hijos verificados. Esto registra que se inspeccionó el informe para comprobar integración; el gate de evidencia no sustituye la revisión del contenido del informe. Que exista un archivo, sin ese contenido y correspondencia, no basta. El validador comprueba del archivo: existencia, contención en la raíz del workspace y este contenido; que quede dentro del `scope_escritura` del subagent es obligación de autoría que el script no comprueba.

## Subconjunto YAML aceptado

Los scripts usan POSIX sh y awk, no una biblioteca YAML. Aceptan solo el formato ilustrado: mapa raíz con `schema_version: 3`, `run:` y `tasks:`; indentación con espacios exactos; tareas como elementos de lista bajo `tasks`; strings entre comillas dobles; `null` literal; entero positivo para `min_subagents_per_worker` y, opcionalmente, `max_sessions_in_flight`; listas flow-style. Codificación: UTF-8 sin BOM (un BOM inicial se tolera y se descarta; los acentos son válidos). Se permiten líneas vacías, comentarios de línea completa y comentarios inline (`#` precedido de espacio y fuera de comillas dobles); un valor como `null  ` o `null # raíz` equivale a `null` en ambos validadores. Se rechazan lista raíz, bloques, anchors, aliases, tabs, claves duplicadas/desconocidas, inline maps y valores o indentaciones fuera de ese subconjunto. Un ledger schema 2 recibe un error que indica la migración requerida.

Los scopes y rutas relativas se resuelven desde la raíz del workspace, que es el directorio físico actual (`pwd -P`, con symlinks resueltos). Esa raíz debe coincidir con `run.location.directory_client` o, si falta, con `run.location.directory`, tras la normalización de forma aplicada por el validador (mayúscula de unidad, vistas POSIX `/c/...` y colapso de `.`/`..`). Cada `location_directory` debe ser idéntico a `run.location.directory` (literal del servidor). Una ruta relativa que normalice fuera de la raíz falla. Los scopes absolutos se conservan; los que cuelgan de `run.location.directory` se reasignan a la raíz del workspace cuando `directory_client` difiere. Los scopes se comparan léxicamente por componentes de ruta; `src` se solapa con `src/a.py`, pero no con `src2`. Un subagent hereda el orden DAG de su worker: si `W2` depende (directa o transitivamente) de `W1`, los hijos de ambos árboles no se consideran paralelos; en cambio, hermanos del mismo worker o workers en paralelo con scopes solapados y sin dependencia siguen fallando. Los symlinks internos del workspace no se resuelven. Un ledger con finales de línea CRLF se acepta: ambos validadores descartan el `\r` final y los espacios finales de `run:`/`tasks:`. Los paths con espacios deben ir entre comillas dobles. Los errores de extracción del cierre indican la línea (`[FAIL] línea N: …`).

Formas de ruta absoluta admitidas: POSIX, unidad Windows (`C:\x` o `C:/x`, la letra se normaliza a mayúscula) y UNC con barras invertidas (`\\host\share\x`). Recuerda escribir las barras invertidas dobladas (`"C:\\x"`, `"\\\\host\\share\\x"`) porque solo se admiten los escapes `\\` y `\"` dentro de las comillas. En rutas Windows/UNC las barras invertidas ya decodificadas se convierten a `/` para comparar; las mayúsculas/minúsculas del resto de la ruta no se normalizan. Si el workspace declarado es una unidad Windows y el shell es Git Bash, WSL o Cygwin, el validador acepta la vista POSIX `/c/x`, `/mnt/c/x` o `/cygdrive/c/x` del mismo directorio. Para rutas POSIX el comportamiento es el mismo que antes.

**`directory_client` en forma Windows y límite honesto:** `validate_ledger_closed.sh` convierte la raíz física (`pwd -P`) a la misma forma Windows (solo las vistas `/c/…`, `/mnt/c/…`, `/cygdrive/c/…`), comprueba la contención allí y vuelve a la vista física antes de `[ -f ]`. No existe una conversión automática para UNC ni para montajes arbitrarios (por ejemplo, un recurso de red montado en `/mnt/share` o `\\wsl$`): en esos casos declara `directory_client` con la **ruta POSIX que ve el shell**; es la opción más robusta también para Git Bash y WSL. Si la conversión no es posible, el validador falla cerrado (la ruta queda «fuera de la raíz del workspace»).

## Validadores: dependencias, uso y códigos de salida

Ambos scripts son POSIX `sh` + `awk`; `validate_ledger_closed.sh` además usa `dirname`. Fijan `LC_ALL=C` (longitudes y comparaciones por byte, independientes del locale) y, si falta `awk`, salen con código 2 y `ERROR: awk no disponible`. Deben extraerse con finales de línea **LF** (el repositorio lo fuerza con `.gitattributes`: `*.sh text eol=lf`); una copia convertida a CRLF falla bajo `sh` con código no cero. No necesitan Python, yq ni datos fuera del ledger, la evidencia y el workspace. En Windows, ejecútalos desde Git Bash o WSL; sin shell, sigue el fallback manual de [SKILL.md](../SKILL.md#validadores).

| Script | Uso | Qué comprueba |
| --- | --- | --- |
| `scripts/validate_dag.sh` | `sh validate_dag.sh <ledger>` | Forma YAML canónica, identidad y ubicación, estados, DAG sin ciclos, scopes, límite opcional, gate de worker verificado |
| `scripts/validate_ledger_closed.sh` | `sh validate_ledger_closed.sh [--require-evidence] [--allow-degraded] <ledger>` | Ejecuta el anterior y exige cierre: en modo estricto todas las tareas `verified`, `execution_outcome: succeeded`, evidencia con criterion/result/observed e integración; con `--allow-degraded`, estados y requisitos según el párrafo «Invocación única» de abajo |

`output_path` y `evidence_refs` siguen la misma regla de rutas que los scopes: `validate_ledger_closed.sh` reasigna a `directory_client` las rutas absolutas bajo `run.location.directory`, las devuelve a la vista física del shell y rechaza toda ruta (absoluta o relativa con `..`) que termine fuera de la raíz física del workspace (por ejemplo, `/etc/hosts`).

**Invocación única:** `validate_ledger_closed.sh` ya ejecuta `validate_dag.sh`; para un cierre completo basta `sh scripts/validate_ledger_closed.sh --require-evidence <ledger>`. Si la corrida cerró en estados terminales degradados (`failed`, `blocked`, `partial`, `cancelled`, `interrupted`), añade `--allow-degraded`: las tareas `verified` mantienen los requisitos estrictos (`execution_outcome: succeeded`, `output_path`, `evidence_refs`), mientras que las tareas en estados terminales no verificados requieren `notas` no vacías con el motivo/causa y comprueban evidencia si está presente; los estados activos (`pending`, `launching`, `running`, `awaiting-approval`, `outcome-unknown`) siguen prohibidos al cerrar, y `completed` también: es un estado transitorio del ledger, así que toda fila debe pasar de `completed` a `verified` o a un estado terminal degradado antes de validar (el validador lo rechaza en ambos modos). Ejecuta `validate_dag.sh` por separado solo para validar un ledger aún abierto (en curso). Ejecútalos con el workspace como directorio actual. Códigos de salida: `0` pasa, `1` falla la validación, `2` error de uso o entorno (argumentos, ledger ilegible, `pwd -P` inválido, `awk` ausente). La última línea es `TOTAL: N passed, M failed`, con contadores reales de comprobaciones.
