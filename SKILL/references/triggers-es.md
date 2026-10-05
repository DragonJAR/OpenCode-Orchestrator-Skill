# Spanish-language activation triggers

The canonical trigger list (positive and negative examples) lives in
`SKILL.md`'s frontmatter `description` field and in `trigger-tests.md`.
This file holds the same coverage in Spanish so a Spanish-speaking agent
recognises the skill from prompts phrased in Spanish.

## Positive examples (the skill SHOULD activate)

- *"Orquesta varias sesiones de OpenCode: crea dos workers y que cada uno lance al menos dos subagents para revisar los módulos auth y billing, y luego integra los resultados."*
- *"Necesito delegar en OpenCode una migración grande: gestiona las sesiones, reparte scopes de escritura sin solapes y dime qué worker quedó verificado."*
- *"Lanza workers y subagents en mi servidor OpenCode para un run multi-agente, hazles seguimiento en un ledger y valida el DAG antes de cerrar."*
- *"Gestiona una ejecución multiagente en OpenCode y valida el ledger YAML al terminar."*

## Negative examples (the skill should NOT activate)

- *"Explícame qué es un agente de IA y en qué se diferencia de un chatbot."* (concepto general)
- *"Corrige el bug de este componente React que rompe el submit del formulario."* (tarea de un solo agente)
- *"Orquesta un nightly Airflow pipeline que carga CSVs."* (pipeline de datos, otro runtime)

## Mapping to the canonical English list

Every Spanish example above has a direct English counterpart in `SKILL.md`'s
frontmatter and in `trigger-tests.md`. They activate the same skill with the
same arguments; the Spanish wording is only a hint for routing.