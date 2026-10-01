# OpenCode Orchestrator Skill

> Skill de coordinación y auditoría en dos niveles para agentes y sesiones de OpenCode.

## Descripción

Esta skill permite a un agente orquestador coordinar múltiples workers y subagentes de OpenCode bajo una jerarquía estructurada de dos niveles (`worker_session` → `subagent`). Gestiona el ciclo de vida de las sesiones, seguimiento mediante ledger (versión de esquema 3), scopes de escritura y validación de evidencia de cierre.

## Estructura

- [`SKILL/SKILL.md`](SKILL/SKILL.md): Especificación principal de la skill, reglas duras (R1–R14), decision gates, pasos de ejecución y contrato de salida.
- [`SKILL/references/`](SKILL/references/): Guías operativas en profundidad:
  - `playbook.md`: Flujo operativo de 8 pasos y checklist de cierre.
  - `ledger-template.md`: Esquema YAML canónico del ledger, gates de verificación y reglas del validador.
  - `subagent-contract.md`: Contrato de la herramienta nativa `subagent`, preflight, reglas de ubicación y profundidad.
  - `prompt-templates.md`: Plantillas de prompt estructuradas para workers, subagents, forks y reportes.
  - `api-and-sessions.md`: Referencia de la API HTTP de OpenCode, lectura acotada de resultados y reglas de reconciliación.
  - `decision-trees.md`: Árboles de decisión para preflight, hijas, concurrencia y cierre.
  - `failure-matrix.md`: Modos de fallo observables, acciones de mitigación y qué evitar.
  - `agents-and-safety.md`: Selección del catálogo de agentes, presupuesto de escritura y aislamiento de scopes.
  - `recipe-tui-tabs.md`: Autenticación HTTP directa y receta local de tabs TUI.
- [`SKILL/scripts/`](SKILL/scripts/): Validadores POSIX shell:
  - `validate_dag.sh`: Validador de DAG estructural y esquema del ledger.
  - `validate_ledger_closed.sh`: Validador final del gate de cierre para ejecuciones completas o degradadas (`--allow-degraded`).

## Validación

Ejecuta los validadores desde la raíz del workspace:

```bash
# Validar DAG y estructura del ledger en curso:
sh SKILL/scripts/validate_dag.sh <ruta-al-ledger>

# Validar cierre del ledger (modo estricto verified):
sh SKILL/scripts/validate_ledger_closed.sh --require-evidence <ruta-al-ledger>

# Validar cierre del ledger con estados terminales degradados (partial, blocked, failed):
sh SKILL/scripts/validate_ledger_closed.sh --allow-degraded <ruta-al-ledger>
```

## Licencia

[MIT](SKILL/LICENSE) © 2026 DragonJAR.org
