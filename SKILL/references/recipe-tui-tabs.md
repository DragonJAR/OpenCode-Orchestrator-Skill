# Receta local: sesiones worker y tabs TUI en Windows, Linux y macOS

> **Fallback no soportado, fijado a una versión.** Esta receta solo se ejecuta tras el gate duro de [SKILL.md](../SKILL.md#decision-gates): autorización explícita del usuario, versión exacta instalada igual a la inspeccionada (`v2.0.21`), lock compatible o exclusión demostrada, y verificación por `sessionID`. Si algo falla, prefiere la API de tabs del CLI plugin o marca la tab como no verificada. Ver [versionado y fechas](research-evidence.md#versionado-y-fechas).

Esta receta combina una API HTTP de sesión con una escritura local del estado de tabs. **La API HTTP de OpenCode V2 es experimental. `tabs.json` es almacenamiento privado de la TUI, no una API pública ni un formato estable.** Los detalles privados de esta receta corresponden al snapshot del tag `v2.0.21`; antes de usar el fallback, confirma que la versión exacta instalada siga el mismo esquema y ubicación. Si no se puede validar, usa una interfaz oficial de tabs ya disponible; si tampoco puedes confirmar la tab por ID, marca la tab como no verificada. [API V2](https://opencode.ai/v2/docs/api/), [fuente upstream v2.0.21](https://github.com/anomalyco/opencode/tree/v2.0.21/packages/tui/src/context)

El contrato de tareas, incluido `schema_version: 3`, mínimo `run.min_subagents_per_worker: 2`, `parentID`, `location_directory`, scopes y evidencia, vive solo en [ledger-template.md](ledger-template.md). La TUI muestra una sesión; no es un tercer agente ni sustituye al worker o a los subagents.

## 1. Descubre la instancia sin depender del shell o el sistema operativo

En el mismo perfil de usuario donde corre la TUI, consulta `opencode service status` para obtener el URL del servicio de fondo activo y `opencode debug paths state` para obtener el directorio de estado real. Ambos comandos están publicados por la CLI V2; `debug paths state` localiza el estado y no informa la configuración de tabs de la TUI. Para inspeccionar esa configuración efectiva, abre `Settings` → `Tabs` en la TUI activa y lee `Mode` y `Scope` sin usar los controles que cambian valores. `opencode debug config` y `GET /api/config` consultan configuración del servidor y no sustituyen esa lectura local. Si el panel no está disponible, inspecciona en solo lectura los archivos locales que cargó esa TUI y el `HERDR_ENV` heredado por su proceso, usando el mismo ejecutable, perfil y directorio de trabajo; si no puedes confirmar un valor, falla cerrado. Nunca cambies ni guardes la configuración del usuario. No busques el puerto con `lsof`, PowerShell, procesos o PID: el comando de estado usa el registro del servicio y verifica disponibilidad. Si responde `stopped`, falta acceso o el servicio no es compatible, para aquí; no arranques, detengas ni reemplaces otro servicio como recuperación automática. [CLI V2: service y debug paths](https://opencode.ai/v2/docs/cli/commands/), [TUI settings](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/component/dialog-config.tsx), [resolución TUI](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/config/index.tsx), [debug config del servidor](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/commands/handlers/debug/config.ts)

El servicio de fondo corresponde a `opencode serve --service` en el upstream inspeccionado; la CLI publicada administra ese proceso mediante `opencode service start/status/stop`. Para esta receta solo se descubre/reutiliza el servicio activo; no se inicia ni detiene implícitamente. [service ensure](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/client/src/effect/service.ts), [CLI V2: service](https://opencode.ai/v2/docs/cli/commands/)

Verifica el URL con `GET /api/info` y consulta `/openapi.json` en ese mismo endpoint. Las rutas HTTP de sesión son experimentales. Reutiliza el cliente CLI/API autenticado cuando sea posible; `opencode api` es una interfaz documentada que habla con el servidor. [API V2](https://opencode.ai/v2/docs/api/), [CLI V2: api](https://opencode.ai/v2/docs/cli/commands/)

### Autenticación HTTP directa, solo si hace falta

La implementación upstream inspeccionada mantiene dos archivos distintos con el mismo nombre: la configuración bajo el directorio `config`, y el registro activo bajo el directorio `state`. La configuración admite `hostname`, `port`, `password`, `cors` y `env`; el registro activo contiene `id`, `version`, `url`, `pid` y un `password` opcional. El registro se deriva como `<state-root>/service.json` para canales `latest`, `dev`, `beta` y `next`, y `<state-root>/service-<channel>.json` para otros canales. Estas condiciones son la única excepción permitida a la regla de «no buscar secretos» de la [matriz de fallos](failure-matrix.md). Para autenticar una llamada directa, usa solo el registro activo que corresponde al URL, PID y versión confirmados; no confundas los dos archivos ni leas `~/.config/opencode/service.json` como ruta universal. [service-config.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-config.ts), [service-registration.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-registration.ts), [descubrimiento y auth](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/client/src/effect/service.ts)

La CLI obtiene el estado raíz con `opencode debug paths state`; el upstream usa `XDG_STATE_HOME` cuando está definido y, en su defecto, el home del usuario seguido de `.local/state/opencode`. La fuente inspeccionada no usa `%LOCALAPPDATA%` como regla universal. Por eso no hardcodees ninguna ruta por sistema operativo. En una llamada HTTP directa, el upstream usa HTTP Basic con el usuario `opencode` cuando el registro trae `password`; envía credenciales solo al URL activo que confirmaste como endpoint esperado y requiere loopback o HTTPS. Arma el encabezado en memoria y no lo pongas en argumentos del proceso, historial del shell, prompt, ledger ni logs. Si no puedes obtener la credencial activa sin exponerla, usa la CLI autenticada o bloquea la llamada. [global-roots.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/util/src/global-roots.ts), [service status](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/commands/handlers/service/status.ts), [API V2](https://opencode.ai/v2/docs/api/)

## 2. Crea una sesión raíz `worker_session`

Antes de crearla, toma `run.location.directory` de la ubicación canónica reportada por la instancia y la sesión del orquestador. Esa ubicación pertenece al servidor OpenCode: pásala literalmente, con el formato que el servidor devuelve, tanto en Windows como en Linux o macOS. No la reconstruyas con el directorio actual del programa cliente ni cambies separadores. [API V2: location y session.create](https://opencode.ai/v2/docs/api/)

Aunque el schema público de creación marca `agent` y `model` como opcionales, esta skill exige resolverlos de los catálogos activos y enviarlos explícitamente. Usa el ID exacto de un agente disponible y el par `id`/`providerID` de un modelo disponible; no fijes `build` como agente por defecto ni inventes modelo, proveedor o variante. Incluye `variant` solo si el catálogo activo la publica y la tarea la requiere. Si falta un catálogo o no puedes confirmar valores válidos justo antes de crear, bloquea el flujo antes de `POST /api/session`.

Envía `POST /api/session` con `location`, `agent` y `model` explícitos; este cuerpo es una plantilla: reemplaza cada `{{…}}` (incluidas las llaves dobles) por los valores confirmados; no es JSON válido hasta hacerlo:

```json
{
  "title": "{{título breve del worker}}",
  "agent": "{{id exacto del agente del catálogo activo}}",
  "model": {
    "id": "{{id exacto del modelo del catálogo activo}}",
    "providerID": "{{providerID exacto asociado al modelo}}"
  },
  "location": {
    "directory": "{{run.location.directory exacto}}"
  }
}
```

`agent` y `model` siguen siendo opcionales en el schema HTTP; enviarlos es una política de esta skill, no una afirmación sobre el contrato requerido por el servidor. La respuesta HTTP envuelve `Session.Info` en `data`; guarda `data.id` como `sessionID` (`response.data.id` con el cliente generado). La respuesta crea una sesión; no abre la tab. Vuelve a leer `Session.Info` y verifica `parentID: null` y el `location.directory` idéntico al run. No reintentes una creación incierta sin reconciliar primero. [API V2: create session](https://opencode.ai/v2/docs/api/)

Envía el prompt inicial a `POST /api/session/{sessionID}/prompt` con `text` requerido y solo campos opcionales publicados por `/openapi.json`. El prompt del worker debe transferir objetivo, contexto, restricciones, criterio y evidencia; ejecutar las filas `subagent` preautorizadas en el prompt (al menos dos distintas, con scopes hijos incluidos en su presupuesto); prohibir escrituras simultáneas en scopes solapados; exigir inspección e integración de ambos resultados y un informe legible por el orquestador. No pidas al worker que invente un canal de retorno. [API V2: session.prompt](https://opencode.ai/v2/docs/api/), [Tools V2](https://opencode.ai/v2/docs/tools/)

Cada hijo se lanza dentro de la sesión worker mediante la herramienta nativa `subagent`. Registra IDs reales distintos y verifica que cada hijo tenga `task_kind: subagent`, `parent_task_id` igual al `task_id` del worker, `parentID` igual al `sessionID` real del worker y `location_directory` igual a `run.location.directory`; el API `POST /api/session` no invoca esa herramienta. El worker raíz tiene `task_kind: worker_session`, `parent_task_id: null`, `parentID: null` y `location_directory` idéntico al run. El ledger exacto y el criterio de `verified` están en [ledger-template.md](ledger-template.md).

## 3. Resuelve la ruta de tabs a partir del cliente TUI real

La TUI v2.0.21 resuelve `tabs.mode=auto` y `tabs.scope=cwd` cuando no hay override. `tabs.mode` prevalece sobre el legado `tabs.enabled`; si falta `mode`, el legado `enabled` mapea `true` a `on` y `false` a `off`. El modo efectivo `auto` está habilitado salvo cuando `HERDR_ENV=1` en el entorno del proceso TUI; un `mode` efectivo `on` u `off` decide directamente. Obtén el canal exacto del cliente TUI; si una integración de plugin ya existente lo expone, la documentación define `context.app.channel` y `context.app.version`, pero este paquete no añade un plugin. En el tag verificado, el almacenamiento se crea bajo `state/<channel>/tui`, y el registro de servicio usa el directorio `state` con un nombre de archivo dependiente del canal. Nunca adivines `latest`; si la versión o el canal exactos no se pueden establecer, no edites el archivo. [Configuración CLI: tabs](https://opencode.ai/v2/docs/cli/config), [CLI plugin API: context](https://opencode.ai/v2/docs/build/plugins/cli/), [configuración TUI v2.0.21](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/config/index.tsx), [storage TUI](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/storage.tsx), [service-config.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-config.ts)

El tag `v2.0.21` guarda `tabs.json` con esta forma:

```json
{
  "global": {
    "tabs": [{ "sessionID": "ses_...", "title": "Worker" }],
    "unread": {}
  },
  "cwd": {
    "{{cwd exacto del proceso TUI}}": {
      "tabs": [{ "sessionID": "ses_...", "title": "Worker" }],
      "unread": {}
    }
  }
}
```

Cada fila admite `sessionID` y un `title` opcional. Si `tabs.scope` es `global`, modifica únicamente `global`; si es `cwd`, la clave se toma de `paths.cwd` del proceso TUI. Ese valor normalmente es el directorio desde el que se lanzó la TUI y **no se garantiza que sea igual** a `Session.Info.location.directory`. Usa `run.location.directory` como clave solo después de verificar que ambos valores son literalmente iguales. No crees una clave con la ruta del servidor bajo la suposición de que coincide con el CWD local. La TUI normaliza tab IDs al session root; añade solo los IDs de workers raíz. [session-tabs.tsx](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/session-tabs.tsx), [session-tabs-model.ts](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/session-tabs-model.ts)

## 4. Fusiona y escribe con verificación

El archivo TUI es privado y su esquema puede cambiar. Si ya existe, léelo justo antes de la actualización y valida la forma completa. Conserva todas las tabs, claves `cwd`, propiedades y mapas `unread`; agrega solo cada worker raíz faltante y deduplica por `sessionID`. Si no parsea, tiene un schema distinto o la ubicación/tab no concuerda, detente sin sobrescribirlo. Si no existe, inicializa únicamente el schema confirmado para la versión instalada.

El fallback solo puede escribir si mantiene durante la lectura, merge, temporal, rename y readback el mismo lock compatible con `Flock` que toma la TUI sobre `tabs.json`, o si puede demostrar exclusión efectiva del escritor TUI durante toda esa operación. Un lock distinto o una pausa no verificable no bastan. Si no puedes asegurar ese lock o esa exclusión, no edites `tabs.json`: usa una interfaz oficial de tabs ya disponible; si no existe una que permita confirmar el ID, falla cerrado y marca la tab como no verificada. Cuando el gate de concurrencia sí se cumple, escribe el JSON completo a un archivo temporal único en el mismo directorio y renómbralo sobre el destino de forma atómica; si la plataforma no permite reemplazo atómico, falla sin borrar primero el archivo original. Vuelve a leer el destino y comprueba que todos los IDs están una sola vez y que las otras entradas siguen presentes.

En el tag `v2.0.21`, la TUI usa `Flock.withLock` sobre el archivo `tabs.json` con el directorio de locks bajo `state/<channel>/locks`, escribe con temporal/rename y observa la carpeta para recargar el storage tras cambios externos. Un escritor externo que no toma el mismo lock puede competir con una actualización de la TUI y perder cambios; por eso el fallback anterior falla cerrado cuando no puede tomar un lock compatible ni demostrar exclusión del escritor. El watcher puede fallar y la recarga en vivo es detalle de implementación, no contrato público. [storage TUI](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/storage.tsx), [persistence TUI](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/util/persistence.ts)

## 5. Confirma el resultado visible y el trabajo

Comprueba el `sessionID` de cada fila en el estado local y verifica la tab real. La interfaz de plugins documenta `context.ui.tabs.open(sessionID)`, `context.ui.tabs.list()` y `context.ui.tabs.focus(sessionID)`; úsala si ya está disponible en el cliente. No se añade código de plugin a este paquete. En la TUI se puede abrir una sesión existente con `/sessions` o `Ctrl+X`, `L`. Antes del trabajo real, el `/openapi.json` activo debe confirmar una ruta de envío y una capacidad de lectura para la misma sesión; entonces el orquestador envía un nonce único de prueba y lee la respuesta del worker para validar el mismo `sessionID` y nonce exactos. En esta receta el handshake es obligatorio (la fila de `tabs.json` y la tab no prueban que el worker responda); en la ruta por defecto de [api-and-sessions.md](api-and-sessions.md#sesión-worker-raíz-crear-y-abrir-tab-son-acciones-distintas) es opcional (R3a). Sin ambos canales confirmados, no envíes el trabajo. Al terminar, el orquestador lee la salida integrada de la sesión worker mediante esa capacidad de lectura confirmada y verifica los resultados y la evidencia de sus subagents; no presupongas mensajería directa entre sesiones raíz. Que una fila esté escrita no prueba que la TUI la haya cargado ni que el worker haya respondido; si falta la ida y vuelta, la lectura del resultado o la confirmación de la tab por ID, conserva el estado desconocido/bloqueado y marca la tab como no verificada. [CLI plugin API: tabs](https://opencode.ai/v2/docs/build/plugins/cli/), [TUI V2](https://opencode.ai/v2/docs/cli/tui/)

El orquestador verifica la salida integrada del worker, los dos hijos subagent verificados, sus IDs/relaciones/ubicaciones y la evidencia de inspección. Solo el orquestador escribe el ledger. Si creación, identidad, ubicación, tab, scopes o canal de resultado fallan, conserva el estado desconocido/partial/blocked que corresponda; nunca finjas un mínimo o un éxito. [ledger-template.md](ledger-template.md), [matriz de fallos](failure-matrix.md)

## Fuentes consultadas

- [API HTTP V2](https://opencode.ai/v2/docs/api/) — superficie experimental, schemas de `session.create`/`session.prompt`, identity y location.
- [CLI V2](https://opencode.ai/v2/docs/cli/commands/) — `service status`, `debug paths` y `api`.
- [Configuración CLI](https://opencode.ai/v2/docs/cli/config) — `tabs.mode` y `tabs.scope`.
- [TUI V2](https://opencode.ai/v2/docs/cli/tui/) — abrir sesiones existentes.
- [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/) — métodos públicos de tabs para plugins.
- Fuentes privadas contrastadas con el tag exacto [`v2.0.21`](https://github.com/anomalyco/opencode/tree/v2.0.21): [roots](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/util/src/global-roots.ts), [service config](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-config.ts), [service registration](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/services/service-registration.ts), [debug config](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/cli/src/commands/handlers/debug/config.ts), [TUI config](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/config/index.tsx), [configuración TUI](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/component/dialog-config.tsx), [TUI tabs](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/session-tabs.tsx), [modelo de tabs](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/session-tabs-model.ts), [storage](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/context/storage.tsx) y [persistence](https://github.com/anomalyco/opencode/blob/v2.0.21/packages/tui/src/util/persistence.ts).
