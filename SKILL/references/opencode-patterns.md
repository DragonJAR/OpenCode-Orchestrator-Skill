# Patrones operativos de OpenCode V2

Este índice resume el flujo de dos niveles. El orquestador posee el ledger y crea sesiones raíz `worker_session`; cada worker coordina al menos dos sesiones nativas `subagent`, integra evidencia y devuelve un informe al orquestador. Los campos y el criterio de verificación viven en la [plantilla canónica del ledger](ledger-template.md); el contrato de la herramienta hija, en [subagent-contract.md](subagent-contract.md).

| Necesidad | Mecanismo | Referencia canónica |
|---|---|---|
| Crear una sesión raíz para un worker | `POST /api/session` con `location.directory` explícito; la API HTTP V2 es experimental | [API y sesiones](api-and-sessions.md) |
| Mostrar la sesión raíz en la TUI (solo si el usuario pidió tabs) | Acción separada de abrir una sesión/tab ya creada; verifica la tab por `sessionID` con una interfaz cliente documentada que esté disponible | [API y sesiones](api-and-sessions.md), [árboles de decisión](decision-trees.md) |
| Delegar trabajo del worker | Herramienta nativa `subagent` dentro de la sesión worker; mínimo dos hijos distintos para un worker `verified` | [Contrato de subagent](subagent-contract.md), [patrones de asignación](agent-patterns.md) |
| Ordenar tareas | DAG del orquestador; dependencias expresan orden, no propiedad; workers raíz con scopes solapados van en orden | [Playbook](playbook.md), [árboles de decisión](decision-trees.md) |
| Esperar, conciliar o recuperar | Usa el mecanismo de resultado confirmado por la instancia; al perderlo verifica inbox, mensajes, aprobación, outcome y efectos según `/openapi.json` | [Contrato de subagent](subagent-contract.md), [matriz de fallos](failure-matrix.md) |

La creación HTTP no abre una tab ni llama a `subagent`. La TUI documenta `/sessions` y `Ctrl+X`, `L` para volver a sesiones; la CLI plugin API documenta `context.ui.tabs.open(sessionID)` y `context.ui.tabs.list()`. El paquete no incluye código de plugin. Si la interfaz disponible no permite verificar que la tab visible tiene el ID creado, registra la verificación como incompleta. [API V2](https://opencode.ai/v2/docs/api/), [TUI V2](https://opencode.ai/v2/docs/cli/tui/), [CLI plugin API](https://opencode.ai/v2/docs/build/plugins/cli/)

Para la alternativa local, versionada y no pública que escribe `tabs.json`, consulta [recipe-tui-tabs.md](recipe-tui-tabs.md); exige canal, scope, CWD y schema comprobados.

Usa el mismo `location.directory` canónico servido por la instancia para orquestador, workers y subagents, sin reescribir rutas según el sistema operativo del cliente. Las fuentes consultadas no publican un tope global de sesiones. No agregues un valor fijo de concurrencia: aplica la regla única de [ledger-template.md](ledger-template.md#límite-opcional-max_sessions_in_flight). [API V2](https://opencode.ai/v2/docs/api/)

Las reglas de scopes (presupuesto, solapes, padre/hijo, timeout) están en una sola sección: [Agentes y seguridad](agents-and-safety.md#presupuesto-de-escritura-y-scopes); ver también los [árboles de decisión](decision-trees.md).
