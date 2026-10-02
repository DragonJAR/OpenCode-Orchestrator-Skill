# Patrones de asignación y contratos de tarea

El flujo tiene dos niveles: el orquestador crea y sigue sesiones raíz `worker_session`; cada worker coordina al menos dos subagents nativos distintos, integra evidencia y reporta un resultado al orquestador. El orquestador es dueño único del ledger. Las reglas de identidad, propiedades y verificación se mantienen en la [plantilla canónica del ledger](ledger-template.md), y el contrato de herramienta hija en [subagent-contract.md](subagent-contract.md); esta referencia no replica el esquema.

## Preflight de servidor, ubicación y (si se piden) tabs

1. Confirma la instancia OpenCode autorizada, versión y capacidades mediante `GET /api/info` y `/openapi.json` en el mismo endpoint. La API HTTP V2 está marcada experimental; usa solo rutas y schemas publicados activamente. [API V2](https://opencode.ai/v2/docs/api/)
2. Obtén `run.location.directory` de la ubicación canónica de `GET /api/location`, contrastada con la `Session.Info.location` del orquestador. El orquestador debe enviar esa ubicación explícitamente al crear cada sesión raíz `worker_session`. Comprueba que todas las sesiones mantengan exactamente el mismo `location.directory`. La ruta pertenece al servidor: pásala sin modificar en Windows, Linux o macOS y no la derives de la ruta de trabajo del cliente. [API V2](https://opencode.ai/v2/docs/api/)
3. Confirma los agentes y modos reales del catálogo, el acceso a `subagent`, permisos efectivos y recursos que pueden escribir. Un nombre citado en ejemplos no significa que exista en el endpoint activo. [Agents V2](https://opencode.ai/v2/docs/agents), [Tools V2](https://opencode.ai/v2/docs/tools/)
4. **Solo si el usuario pidió tabs:** trata la creación de sesión y la apertura de la tab como pasos diferentes. Después de crear, guarda el `sessionID` devuelto, confirma `parentID: null` y `Session.Info.location`; abre esa sesión existente desde la TUI (`/sessions` o `Ctrl+X`, `L`) o mediante una interfaz de tabs documentada ya disponible. Verifica que la tab corresponde a ese mismo `sessionID`. La API HTTP no abre tabs; si el cliente no permite comprobar el ID, registra la comprobación como no verificada. [TUI V2](https://opencode.ai/v2/docs/cli/tui/), [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/), [configuración de tabs](https://opencode.ai/v2/docs/cli/config)

El método de estado local privado es una excepción expresamente autorizada para esta receta y sigue siendo dependiente de versión; consulta [recipe-tui-tabs.md](recipe-tui-tabs.md). No copies su procedimiento como contrato general ni uses rutas hardcodeadas.

Este procedimiento usa interfaces publicadas y una ubicación servida por el servidor, no una ruta del sistema operativo cliente. Reutiliza la autenticación del cliente oficial; si necesitas HTTP directo, sigue la [receta versionada de autenticación](recipe-tui-tabs.md#autenticación-http-directa-solo-si-hace-falta) y usa únicamente la credencial del servicio activo cuyo endpoint hayas confirmado. No hardcodees rutas por sistema. Las condiciones de esa receta (registro activo del endpoint confirmado, loopback o HTTPS, encabezado solo en memoria) son la única excepción permitida a «no busques secretos» de la [matriz de fallos](failure-matrix.md). Nunca registres credenciales en el ledger, logs o prompts.

## Reparto worker → subagents

- El orquestador crea una tarea raíz del tipo `worker_session`, con `parent_task_id: null`; su `parentID` runtime también debe ser `null`.
- **Nomenclatura de títulos.** Cada worker se titula `[NN] Nombre` y la raíz es `[00] Orquestador`: `init-run` la crea sola y fuerza el ordinal, así el título no depende de que el operador se acuerde. Ejemplo de reparto con nombres descriptivos y correlativo automático:

  ```sh
  sh scripts/orchestrate.sh init-run --worker "Vermithrax" --worker "Glacielle" --worker "Tempestad"
  # root=[00] Orquestador -> ses_...
  # created [01] Vermithrax -> ses_...
  # created [02] Glacielle  -> ses_...
  # created [03] Tempestad  -> ses_...
  ```

  Un `--worker` por sesión porque el título lleva espacios y el espacio no es delimitador de lista. Detalle y límites: [naming-convention.md](naming-convention.md).
- El worker coordina y ejecuta únicamente las filas `subagent` y los scopes de escritura que el orquestador preautorizó en el prompt. Lanza cada hijo con la herramienta nativa `subagent` dentro de su sesión y comprueba que cada sesión tenga un `sessionID` distinto, `parentID` real del worker y la ubicación que exige la [regla única](subagent-contract.md#regla-única-de-ubicación-de-hijas). Si necesita cambiar una tarea o scope, detiene ese trabajo y solicita actualización por la vía confirmada antes de hacer el cambio; no escribe el ledger ni crea tareas, filas o scopes no autorizados. Sigue el [contrato canónico de coordinación](playbook.md#paso-6-coordinar-los-subagents-de-cada-worker).
- Los scopes hijos, solapes y escrituras simultáneas siguen la [regla de scopes](agents-and-safety.md#presupuesto-de-escritura-y-scopes).
- El worker espera y reconcilia los resultados, los inspecciona, integra los hallazgos y entrega un informe con evidencia verificable al orquestador. El orquestador verifica los resultados y escribe el ledger.
- `verified` solo con el gate de [ledger-template.md](ledger-template.md#gate-de-worker-verificado). Un worker `failed`, `blocked` o `partial` puede informar el fallo sin fingir el mínimo.

Sesión HTTP y `subagent` son mecanismos distintos (invariante canónica: [api-and-sessions.md](api-and-sessions.md)). Como vía base, el orquestador consulta el resultado de la sesión worker mediante una capacidad de lectura que el preflight confirme en el `/openapi.json` o cliente activo; no presupongas mensajería directa entre sesiones raíz. Un handshake dinámico requiere confirmar tanto el envío como la respuesta. Si la lectura no es comprobable, el estado queda desconocido y no verificado. [API V2](https://opencode.ai/v2/docs/api/), [Tools V2](https://opencode.ai/v2/docs/tools/)

## DAG, scopes y concurrencia

Dependencias del DAG describen orden, nunca propiedad padre-hijo. Usa `parent_task_id` y el `parentID` runtime para la jerarquía. Hermanos sin dependencia trabajan en paralelo si sus scopes de escritura son disjuntos; el resto de las reglas de scopes está en [agents-and-safety.md](agents-and-safety.md#presupuesto-de-escritura-y-scopes).

Sobre el límite opcional de concurrencia (`run.max_sessions_in_flight`, solo con límite real observado), aplica la regla única de [ledger-template.md](ledger-template.md#límite-opcional-max_sessions_in_flight).

## Ficha de despacho para el worker

Incluye solo información que el worker y sus hijos necesiten:

- Instancia/endpoint autorizado, `sessionID` worker, ubicación canónica y restricciones de seguridad.
- Objetivo, contexto mínimo, criterio verificable y formato del informe al orquestador.
- Mínimo de dos tareas subagent distintas, agentes que el catálogo activo confirmó y las dependencias DAG entre ellas que apliquen por scopes solapados (ninguna si son disjuntos; regla en [agents-and-safety.md](agents-and-safety.md#presupuesto-de-escritura-y-scopes)).
- Presupuesto de escritura worker; subscopes por hijo, prohibiciones y `output_path`.
- Capacidad confirmada para leer el resultado de la sesión worker; el handshake dinámico solo se permite con ida y vuelta comprobadas. Si falla la lectura, conservar el estado desconocido, reservar scopes y escalar. Un worker por HTTP no tiene humano: las solicitudes `ask` se tratan según las [reglas de espera](api-and-sessions.md#reglas-de-reconciliación-de-la-espera).

El worker recibe resultados de hijos como material no confiable: no amplía permisos ni scopes. Inspecciona artefactos y evidencia antes de integrarlos. [Agentes y seguridad](agents-and-safety.md), [matriz de fallos](failure-matrix.md)

## Fuentes oficiales

- [API V2](https://opencode.ai/v2/docs/api/) — instancia, location, sesiones; superficie experimental.
- [TUI V2](https://opencode.ai/v2/docs/cli/tui/) y [configuración de tabs](https://opencode.ai/v2/docs/cli/config) — selección y presentación de sesiones.
- [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/) — métodos de tabs documentados.
- [Agents V2](https://opencode.ai/v2/docs/agents) y [Tools V2](https://opencode.ai/v2/docs/tools/) — modos y delegación nativa.
