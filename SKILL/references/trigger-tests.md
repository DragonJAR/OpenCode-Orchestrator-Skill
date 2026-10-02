# Activation test queries

Minimal set to verify that the skill activates when appropriate and does not over-activate. Use it when editing the `description` of [SKILL.md](../SKILL.md): launch each query without mentioning the skill and record whether it loads. Method and goal (activate on the great majority of relevant queries and on none of the unrelated ones): execute 10–20 queries and record the result; this file is the seed of six cases.

## Should activate the skill

1. "Orquesta varias sesiones de OpenCode: crea dos workers y que cada uno lance al menos dos subagents para revisar los módulos `auth` y `billing`, y luego integra los resultados."
2. "Necesito delegar en OpenCode una migración grande: gestiona las sesiones, reparte scopes de escritura sin solapes y dime qué worker quedó verificado."
3. "Spawn workers and subagents in my OpenCode server for a multi-agent run, track them in a ledger and validate the DAG before closing."
4. "Orchestrate OpenCode sessions for a refactor: three workers, each with two subagents, and a validated ledger at the end." (literal phrase `orchestrate OpenCode sessions`)
5. "Manage OpenCode sessions for this pentest: reuse the deployed pool, assign tasks and reconcile the ledger." (literal phrase `manage OpenCode sessions`)
6. "Gestiona las sesiones OpenCode de esta auditoría: reparte tareas entre workers y cierra con validadores." (literal phrase `gestionar sesiones OpenCode`)
7. "Lanza workers o subagents en OpenCode para revisar estos dos módulos y trae los resultados integrados." (literal phrase `lanzar workers o subagents`)
8. "Necesito una ejecución multiagente en OpenCode V2 con ledger y validadores." (literal phrase `ejecución multiagente`)
9. "Spawn workers/subagents to review the auth module and integrate findings." (literal phrase `spawn workers/subagents`)

## Should not activate the skill

1. "Explícame qué es un agente de IA y en qué se diferencia de un chatbot." (general concept, no OpenCode)
2. "Corrige el bug de este componente React que rompe el submit del formulario." (single-agent task)
3. "Orchestrate a nightly Airflow pipeline that loads CSV files into a warehouse." (data orchestration, different runtime)

## How to interpret a failure

- A "should activate" query that does not load the skill indicates under-activation: add the user's literal phrase to the `description`.
- A "should not activate" query that loads it indicates over-activation: add or reinforce a negative in the `description`.
- After changing the `description`, repeat at least the six seed queries (and the full 10–20 set if the change affects the negatives) and keep the result in the change history.