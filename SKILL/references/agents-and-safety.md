# Agentes y seguridad

Prevalecen el catálogo, los permisos y el `/openapi.json` de la instancia confirmada. Los modos y permisos aquí descritos deben comprobarse en esa instancia antes de cada plan. La API HTTP de OpenCode V2 se describe como experimental. [Agents V2](https://opencode.ai/v2/docs/agents), [API V2](https://opencode.ai/v2/docs/api/)

## Selección de agentes para los dos niveles

El agente del worker raíz se selecciona según el contrato del endpoint que crea la sesión; la herramienta nativa `subagent` se usa después dentro de esa sesión. No confundas una API/session con la herramienta hija.

| Agente incorporado (si está servido) | Modo documentado | Uso documentado |
|---|---|---|
| `build` | `primary` | Implementación en sesión principal |
| `plan` | `primary` | Planificación en sesión principal |
| `general` | `subagent` | Trabajo de varios pasos con herramientas amplias; no anida otros subagents |
| `explore` | `subagent` | Lectura y exploración sin edición: no lo uses para una tarea cuyo `output_path` deba escribirse |

Para un subagent que debe escribir su `output_path` usa `general` (acceso amplio a herramientas; que pueda editar en tu instancia `requiere verificación` en el catálogo y los permisos efectivos) u otro agente cuya política efectiva permita editar ese scope; o define que el worker escribe esa salida a partir del informe de un `explore`. Estos nombres son referencias documentales, no prueba de disponibilidad ni de permisos. Confirma el ID y su modo en el catálogo activo. Para cada worker prepara al menos dos tareas subagent distintas y agentes válidos para ellas; no intentes lanzar `build` o `plan` como hijo salvo que la instancia los publique con modo permitido. [Agents V2](https://opencode.ai/v2/docs/agents), [Tools V2](https://opencode.ai/v2/docs/tools/)

## Reglas de permisos

Una regla de permiso incluye acción, recurso y efecto (`allow`, `ask` o `deny`). Revisa la política efectiva de cada sesión y recurso, incluyendo lectura, edición, shell y lanzamiento de subagents; el permiso del worker para invocar `subagent` no concede sus propias capacidades al hijo. La documentación describe que un hijo usa su configuración efectiva, que puede diferir de la del padre. [Agents V2](https://opencode.ai/v2/docs/agents), [Tools V2](https://opencode.ai/v2/docs/tools/), [Permissions V2](https://opencode.ai/v2/docs/permissions/)

No asumas que la falta de una regla concreta equivale a denegación ni que una instrucción de prompt reemplaza controles. Revisa el orden y el alcance de reglas, aprobaciones guardadas y policies publicadas por la instancia. Una aprobación pendiente conserva el recurso reservado y el estado local no es resultado terminal.

La herencia de permisos observada en el código `v2.0.19` es detalle histórico de implementación. Las páginas actuales no prometen que cada hijo herede las reglas del worker; confirma siempre la política efectiva. [Snapshot `session.ts` v2.0.19](https://github.com/anomalyco/opencode/blob/v2.0.19/packages/core/src/session.ts), [Agents V2](https://opencode.ai/v2/docs/agents)

## Presupuesto de escritura y scopes

**Esta es la definición única de las reglas de scopes** (R11 de [SKILL.md](../SKILL.md#hard-rules) la resume; el resto de los documentos enlazan aquí).

- Compartir servidor, sesión o tab no implica aislamiento del filesystem ni de workspaces; confirma location y permisos efectivos. Las fuentes consultadas no documentan un lock de archivos ni un límite de concurrencia global.
- Cada worker recibe del orquestador un presupuesto de escritura explícito; el scope de cada subagent es un subconjunto explícito de ese presupuesto (heredar el del padre no autoriza uno más amplio).
- Los siblings (hijos del mismo worker, o workers raíz) con scopes solapados se serializan con una dependencia del DAG: el segundo no empieza hasta el fin verificado del primero. El DAG expresa orden, no jerarquía de propiedad.
- Padre e hijo: el worker integra cuando el hijo terminó. Mientras un hijo esté activo o con resultado desconocido, el padre no escribe en su scope (un scope anidado es válido, la escritura simultánea no).
- Un timeout no libera scope ni capacidad: conserva el estado como incierto hasta reconciliar ejecución, efectos y sesión.

Ver también [patrones de asignación](agent-patterns.md), [Tools V2](https://opencode.ai/v2/docs/tools/) y [API V2](https://opencode.ai/v2/docs/api/).

## Evidencia de verificación

Un worker solo se marca `verified` con el gate de [ledger-template.md](ledger-template.md#gate-de-worker-verificado). El orquestador único mantiene el ledger y confirma la evidencia. `failed`, `blocked` y `partial` describen resultados legítimos y no obligan a inventar hijos faltantes.

## Ubicación portátil

El valor de `location.directory` corresponde al proyecto del servidor OpenCode. Consulta y valida la ubicación canónica del run en la misma instancia y pásala literalmente al crear la sesión worker raíz; para las hijas rige la [regla única de ubicación de hijas](subagent-contract.md#regla-única-de-ubicación-de-hijas) (heredada o pasada si el esquema de la herramienta la expone, y verificada mediante `GET /api/session/{childID}`). No la reconstruyas con un path local de Windows, Linux o macOS ni leas secretos desde ubicaciones específicas de cada sistema. Si la instancia no confirma que todas las sesiones comparten el directorio exacto, bloquea el despacho. [API V2](https://opencode.ai/v2/docs/api/)

Solo si el usuario pidió tabs y necesitas mostrarlas mediante estado local privado, usa solo el flujo versionado y sus gates de seguridad descritos en [recipe-tui-tabs.md](recipe-tui-tabs.md); prefiere la interfaz de tabs documentada cuando ya esté disponible.

## Fuentes oficiales

- [Agents V2](https://opencode.ai/v2/docs/agents) — modos, catálogo y selección.
- [Tools V2](https://opencode.ai/v2/docs/tools/) — herramienta nativa `subagent`.
- [Permissions V2](https://opencode.ai/v2/docs/permissions/) — permisos y aprobaciones.
- [API HTTP V2](https://opencode.ai/v2/docs/api/) — location y sesiones; superficie experimental.
