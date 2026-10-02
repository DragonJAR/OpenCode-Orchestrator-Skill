# Árboles de decisión — flujo OpenCode V2 de dos niveles

El contrato activo de la instancia y la [plantilla canónica del ledger](ledger-template.md) prevalecen. Las rutas HTTP de sesión V2 están marcadas experimentales; verifica el `/openapi.json` del endpoint confirmado antes de llamarlas. [API V2](https://opencode.ai/v2/docs/api/)

## Árbol 1 — ¿Están confirmados instancia, ubicación y controles?

Antes de crear una sesión o delegar:

- Confirma autorización e instancia con `GET /api/info`; consulta `/openapi.json` en ese mismo endpoint para versión y rutas disponibles.
- Obtén la ubicación de `GET /api/location` y compárala con la sesión del orquestador. Fija un único `run.location.directory` canónico.
- Si el usuario pidió ver las sesiones como tabs, comprueba que el modo efectivo de tabs de la TUI no sea `off` (`tabs.mode` explícito `on`, o `auto` sin `HERDR_ENV=1` en el proceso TUI, o legado `tabs.enabled: true` sin `mode`; regla completa en [recipe-tui-tabs.md](recipe-tui-tabs.md) §3) y que el cliente permita abrir la sesión existente y verificar la tab por `sessionID`; si no pidió tabs, una tab no verificable no bloquea (se marca "no verificada"; ver Modo degradado en [SKILL.md](../SKILL.md#modo-degradado)). Crear la sesión por HTTP no abre la tab (invariante y mecanismos de tabs: [api-and-sessions.md](api-and-sessions.md#sesión-worker-raíz-crear-y-abrir-tab-son-acciones-distintas)). [TUI V2](https://opencode.ai/v2/docs/cli/tui/), [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/), [configuración CLI](https://opencode.ai/v2/docs/cli/config)
- Inspecciona el catálogo de agentes, modos y permisos efectivos. Confirma que el worker pueda usar `subagent`, que los dos agentes hijos elegidos existan y puedan ejecutarse como hijos. [Agents V2](https://opencode.ai/v2/docs/agents), [Tools V2](https://opencode.ai/v2/docs/tools/)

    ¿Instancia, ubicación, permisos y herramientas confirmados (y, si el usuario pidió tabs, capacidad de abrir y verificar la tab confirmada)?
    ├── NO  → Registra el preflight faltante; no afirmes éxito ni envíes trabajo.
    └── SÍ  → Árbol 2.

Las rutas deben referirse al filesystem del servidor OpenCode. Para Windows, Linux y macOS pasa el valor canónico sin transformarlo según el sistema del cliente; si no corresponde a la misma instancia/ubicación, detente. [API V2](https://opencode.ai/v2/docs/api/)

## Árbol 1b — ¿Qué nomenclatura de título y cómo paso la lista de workers?

Antes de crear sesiones, decide cómo se van a llamar. El patrón canónico es `[NN] Nombre` (detalle en [naming-convention.md](naming-convention.md)):

- **`[00]`** es siempre la ranura de la raíz del orquestador: `init-run` la crea solo, y `--title` cambia el nombre, no el número.
- Los workers arrancan en **`[01]`** y siguen correlativos. `worker_list` aplica el correlativo y **reasigna un `[00]` explícito** al siguiente ordinal libre.
- El nombre propio describe el alcance (`[01] Vermithrax` para análisis ofensivo); el ID del run ya vive en el ledger, así que el título no lo repite.

¿Cómo paso la lista de workers?

    ├── ¿Títulos con espacios? (casi siempre sí, son legibles)
    │     ├── SÍ → `--worker "T1" --worker "T2"` (una flag por sesión; inequívoco)
    │     │        o `--workers "T1, T2"` (lista delimitada por comas)
    │     └── NUNCA → `--workers "T1 T2"`: el espacio es parte del título,
    │                  no un delimitador; partiría cada título en dos sesiones.
    └── ¿Sin número y quieres que se auto-numere?
          └── SÍ → `worker_list` asigna `01, 02, 03...` en orden de entrada.

El dedup compara por **nombre ignorando el ordinal**, así que `--worker "Vermithrax"` reusa `[01] Vermithrax` en vez de crear un duplicado. Si `init-run` responde `INCOMPLETO` y sale 1, algún worker no se creó: reejecuta con los mismos títulos y el dedup completa lo que faltó. [Nomenclatura](naming-convention.md)

## Árbol 2 — ¿Se puede iniciar al worker raíz con identidad verificable?

    ¿El orquestador dispone de una ruta documentada para crear la sesión worker?
    ├── NO  → Deja el run bloqueado con el acceso/capacidad que falta.
    └── SÍ  → Crea por separado una sesión raíz `worker_session` con
               `location.directory` explícito igual a `run.location.directory`.
               Confirma `sessionID`, `parentID: null` y `Session.Info.location`.
               Solo si el usuario pidió tabs: abre esa misma sesión en la TUI y
               verifica la tab con ese ID (la creación por API no abre la tab);
               si no, marca la tab "no verificada" y sigue.
               La API es experimental.

Si la API HTTP actual no está autorizada o no puede verificar servidor, sesión o ubicación, no la suplas con rutas privadas del cliente. Si la sesión se creó pero la tab no pudo verificarse, conserva la sesión como existente y marca la apertura como no verificada; reconcilia antes de reintentar. [API V2](https://opencode.ai/v2/docs/api/), [TUI V2](https://opencode.ai/v2/docs/cli/tui/)

Cuando la integración autorizada incluya el método local de estado privado, sigue sus gates de versión y concurrencia en [recipe-tui-tabs.md](recipe-tui-tabs.md); la receta puede fallar cerrado si no puede demostrar que modifica el estado de la TUI correcta.

## Árbol 3 — ¿El worker tiene un plan de hijos válido?

El worker divide su presupuesto de escritura en tareas cuyo scope cabe dentro del suyo. Cada hijo usa la herramienta nativa `subagent` desde la sesión worker; cada hijo debe tener su propio `sessionID`, `parentID` real del worker y ubicación según la [regla única](subagent-contract.md#regla-única-de-ubicación-de-hijas). La API de sesiones no es la herramienta `subagent` ni la invoca. [Tools V2](https://opencode.ai/v2/docs/tools/), [API V2](https://opencode.ai/v2/docs/api/)

    ¿Hay al menos dos tareas hijas distintas y agentes válidos?
    ├── NO  → Replanifica; no marques al worker `verified`.
    └── SÍ  → ¿Se solapan sus scopes de escritura?
        ├── SÍ  → Serializa con una dependencia ([regla de scopes](agents-and-safety.md#presupuesto-de-escritura-y-scopes)).
        └── NO  → Se pueden ejecutar en paralelo si no compiten por otro recurso.

Un worker solo alcanza `verified` con el gate de [ledger-template.md](ledger-template.md#gate-de-worker-verificado); puede quedar `failed`, `blocked` o `partial` sin fingir el mínimo.

## Árbol 4 — ¿Se puede ejecutar ahora sin conflicto ni límite inventado?

    ¿Hay dependencia pendiente o scopes/resource compartido en paralelo?
    ├── SÍ  → Serializa según el DAG y espera a que termine cada escritor.
    └── NO  → ¿El ledger registra un límite real observado en
              `run.max_sessions_in_flight` con evidencia?
        ├── SÍ  → Cuenta workers y subagents activos; conserva reserva para
        │         estado desconocido y aprobaciones pendientes.
        └── NO  → No impongas un número fijo no observado. Lanza según recursos y scopes
                  observados, manteniendo el orden de dependencias.

El DAG representa orden de ejecución, nunca propiedad padre-hijo. La propiedad se expresa con `task_kind`, `parent_task_id` y el `parentID` runtime observado. El límite opcional se define en [ledger-template.md](ledger-template.md#límite-opcional-max_sessions_in_flight); los estados locales, en el ledger. [API V2](https://opencode.ai/v2/docs/api/)

## Árbol 5 — ¿El worker integró y reportó evidencia suficiente?

    ¿Se reconciliaron cada resultado, efecto y aprobación de los dos niveles?
    ├── NO  → Mantén el estado desconocido/activo, conserva scopes ocupados,
    │         y reconcilia por mecanismos publicados en el `/openapi.json`
    │         ([reglas de espera](api-and-sessions.md#reglas-de-reconciliación-de-la-espera):
    │         hijas por `parentID`, permisos pendientes, plazo re-armable).
    └── SÍ  → ¿El informe del worker inspecciona e integra los hijos y cita
              evidencia verificable?
        ├── NO  → Marca `partial` o `blocked`; solicita la información pendiente.
        └── SÍ  → El orquestador valida evidencia, actualiza el ledger de dueño
                  único y marca `verified` solo si se cumple el mínimo.

No infieras que la tab, el silencio de un stream o el resumen por sí solos prueban finalización. El canal de retorno y las respuestas deben confirmarse por la instancia; si no se pueden leer, el resultado no es verificable. [Matriz de fallos](failure-matrix.md), [API y sesiones](api-and-sessions.md)

## Árbol 6 — ¿La acción siguiente es destructiva?

    ¿Borra sesiones, hijas o datos persistentes?
    ├── SÍ  → Detente; exige autorización para el ID exacto y confirma el efecto
    │         en cascada en el `/openapi.json` activo.
    └── NO  → Procede dentro del scope autorizado y registra evidencia.

## Fuentes oficiales

- [API HTTP V2](https://opencode.ai/v2/docs/api/) — sesiones, location y schemas; superficie experimental.
- [TUI V2](https://opencode.ai/v2/docs/cli/tui/) — abrir y cambiar sesiones.
- [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/) — apertura y lista de tabs en una interfaz existente.
- [Configuración CLI](https://opencode.ai/v2/docs/cli/config) — modo y alcance de tabs.
- [Agents V2](https://opencode.ai/v2/docs/agents) y [Tools V2](https://opencode.ai/v2/docs/tools/) — catálogo, permisos y delegación nativa.
