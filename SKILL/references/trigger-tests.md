# Consultas de prueba de activación

Conjunto mínimo para comprobar que la skill se activa cuando corresponde y no sobreactiva. Úsalo al editar el `description` de [SKILL.md](../SKILL.md): lanza cada consulta sin mencionar la skill y anota si se carga. Método y objetivo (activar en la gran mayoría de las consultas relevantes y en ninguna de las no relacionadas): ejecuta 10–20 consultas y registra el resultado; este archivo es la semilla de seis casos.

## Deben activar la skill

1. "Orquesta varias sesiones de OpenCode: crea dos workers y que cada uno lance al menos dos subagents para revisar los módulos `auth` y `billing`, y luego integra los resultados."
2. "Necesito delegar en OpenCode una migración grande: gestiona las sesiones, reparte scopes de escritura sin solapes y dime qué worker quedó verificado."
3. "Spawn workers and subagents in my OpenCode server for a multi-agent run, track them in a ledger and validate the DAG before closing."

## No deben activar la skill

1. "Explícame qué es un agente de IA y en qué se diferencia de un chatbot." (concepto general, sin OpenCode)
2. "Corrige el bug de este componente React que rompe el submit del formulario." (tarea de un solo agente)
3. "Orchestrate a nightly Airflow pipeline that loads CSV files into a warehouse." (orquestación de datos, otro runtime)

## Cómo interpretar un fallo

- Una consulta "debe activar" que no carga la skill indica subactivación: añade al `description` la frase literal del usuario.
- Una consulta "no debe activar" que la carga indica sobreactivación: añade o refuerza un negativo en el `description`.
- Tras cambiar el `description`, repite como mínimo las seis consultas semilla (y el conjunto completo de 10–20 si el cambio afecta a los negativos) y conserva el resultado en el historial del cambio.
