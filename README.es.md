# OpenCode Orchestrator Skill

[![Licencia](https://img.shields.io/badge/licencia-MIT-blue.svg)](LICENSE)
[![Versión](https://img.shields.io/badge/versión-1.8.0-green.svg)](CHANGELOG.md)
[![Plataforma](https://img.shields.io/badge/plataforma-OpenCode%20V2-8A2BE2.svg)](https://opencode.ai)
[![Autor](https://img.shields.io/badge/autor-DragonJAR%20SAS-orange.svg)](https://www.DragonJAR.org)
[![English](https://img.shields.io/badge/read%20in-English-blue.svg)](README.md)

> Orquestación multi-agente *fail-closed* en dos niveles para OpenCode V2. Proporciona un **pool reutilizable de workers `[NN] Name`**, una **capa determinista de comandos POSIX** (**17 subcomandos**), un **ledger YAML Schema 3** verificado por dos validadores `sh` + `awk`, y **16 reglas duras** que detienen la ejecución en lugar de adivinar.

## Arquitectura Central

`init-run` aprovisiona `[00] Orchestrator` e instala la [instrucción de router](SKILL/scripts/prompt-templates/router-orchestrator.md) como su primer mensaje. El orquestador se mantiene como un coordinador ligero con ventana de contexto limpia y ejecuta únicamente dos movimientos:

| Movimiento | Mecanismo | Garantía |
|---|---|---|
| **Monitorear** | `pool`, `wait-idle`, `watch` | Vigila el estado de cada worker (`empty`, `idle`, `running`), sus artefactos y transiciones `awaiting-approval` con tiempos acotados. |
| **Enrutar** | `dispatch --target NN`, `--count N`, `--auto-count` | Envía cada tarea al worker más conveniente (o en abanico) según alcance y disponibilidad; `[00]` jamás recibe tareas. |
| **Nunca implementar** | Prompt de router + compuerta R3 de dos niveles | Los workers ejecutan y coordinan al menos 2 subagentes nativos (`subagent`); el orquestador nunca escribe entregables. |

## Inicio Rápido

```sh
# 1. Descubrir endpoint, esquema OpenAPI 3.1, catálogos, par de modelo y compuerta TUI (una vez por proyecto)
sh SKILL/scripts/orchestrate.sh preflight .

# 2a. Corrida completa de dos niveles: crear root [00] + workers con nombre y adjuntar tabs TUI si gate=ready
# (en una corrida de dos niveles el fichero de prompt lleva las filas de hijos pre-registradas; R16 las omite)
sh SKILL/scripts/orchestrate.sh init-run --worker "Auditoría auth" --worker "Auditoría billing"
sh SKILL/scripts/orchestrate.sh dispatch --prompt-file ./tarea.md --target 01
sh SKILL/scripts/orchestrate.sh wait-idle --session ses_xxx --deadline 600
sh SKILL/scripts/orchestrate.sh verify-daughters --worker-id ses_xxx --expected-parent ses_xxx
sh SKILL/scripts/validate_ledger_closed.sh --require-evidence runs/<corrida>/ledger.yaml

# 2b. Comprobación rápida de disponibilidad (ruta ligera, R16 — etiquetada degraded, sin subagentes hijos)
sh SKILL/scripts/orchestrate.sh init-run --count 4
sh SKILL/scripts/orchestrate.sh dispatch --prompt-file ./ping.md --count 4 --wait
sh SKILL/scripts/orchestrate.sh pool
sh SKILL/scripts/orchestrate.sh clean --yes
```

Cada subcomando emite líneas `clave=valor` fáciles de parsear y códigos de salida con semántica fija:

```text
worker_id=ses_e9aaf9eafffeXYvpc190MAVeFY
location=/ruta/al/proyecto
parentID=null
```

## Capa de Comandos y Validadores

Ejecuta `sh SKILL/scripts/orchestrate.sh <subcomando> [args]` (los **17 subcomandos** aceptan tanto `--flag valor` como `--flag=valor`):

| Grupo | Subcomandos | Contrato Operativo |
|---|---|---|
| **Descubrir** | `preflight`, `self-check`, `sessions`, `pool`, `session-id` | Resuelve identidad viva del servidor, catálogos, inventario de sesiones, estado del pool `[NN]` (`empty`/`idle`/`running`) e IDs compactos (`01`, `01s02`). |
| **Aprovisionar** | `ensure-root`, `create-worker`, `init-run` | Creación protegida por lock (`lock_exec` vía `python3 fcntl`) y deduplicada por slug. Reusa sesiones `empty`/`idle`; rechaza colisiones `running` salvo `--force-new`. |
| **Ejecutar y Vigilar** | `dispatch`, `send-prompt`, `wait-idle`, `watch`, `verify-daughters` | Verifica `model.id` resuelto antes de enviar, bloquea envíos de tareas a `[00]`, detecta cuelgues (`exit 4`) y comprueba `parentID` + `location` de hijos (R14). |
| **Visibilidad TUI** | `tabs`, `attach-tabs` | Compuerta de solo lectura para TUI `2.x` (`tabs`) y fusión aditiva en `tabs.json` bajo lock con validación de esquema y lectura posterior (`attach-tabs`). |
| **Limpieza** | `delete-session`, `clean` | Borrado bajo aprobación R7: enumera hijos, exige `--yes` (o confirmación `yes`), purga claves de caché muertas y poda `tabs.json` en orden topológico (hojas primero). |

**Validadores Independientes del Ledger** (POSIX `sh` + `awk` puro, compartiendo `SKILL/scripts/_validators.awk`):
- `sh SKILL/scripts/validate_dag.sh LEDGER_PATH` — valida sintaxis YAML Schema 3, identidad de corrida/sesiones, DAG sin ciclos, disyunción de scopes de escritura y el mínimo de 2 subagentes por worker.
- `sh SKILL/scripts/validate_ledger_closed.sh [--require-evidence] [--allow-degraded] LEDGER_PATH` — ejecuta `validate_dag.sh` más cierre terminal, contención de rutas en el workspace y verificación de evidencia (`criterion`, `result: "pass"`, `observed`, `subagent_results_integrated`).

## Reglas Duras y Garantías Fail-Closed

Definidas en [`SKILL.md`](SKILL/SKILL.md) y respaldadas por **15 referencias** en [`SKILL/references/`](SKILL/references/):

| Regla | Principio | Aplicación Operativa |
|---|---|---|
| **R1–R2** | **Acceso y Background** | Jamás simular ejecución sin acceso real; usar background solo si figura en `/openapi.json` con ruta de lectura acotada. |
| **R3** | **Dos Niveles (`worker` → `≥2 subagents`)** | Los root workers tienen `parentID: null`; cada worker `verified` integra al menos 2 sesiones `subagent` hijas con IDs distintos (sin 3er nivel). |
| **R4–R5** | **Permisos y Política Hija** | Respetar reglas `ask`/`deny`; el permiso `subagent` del padre controla qué agentes lanza y la política del hijo gobierna sus herramientas. |
| **R6** | **Contexto Autocontenido** | Todo prompt incluye ID de tarea, `location.directory` canónico, scope de escritura, límites y criterio medible de aceptación. |
| **R7–R8** | **Compuerta Destructiva y Continuar/Fork** | Borrar exige aprobación explícita (`--yes`); continuar conserva `sessionID` tras reconciliar, mientras `fork` crea una sesión nueva. |
| **R9–R10** | **Interrupciones y No Idempotencia** | La falta de avisos no prueba éxito ni parada; inspeccionar estado de sesión, inbox y artefactos en disco antes de reintentar. |
| **R11–R12** | **Scopes Disjuntos y Estados Separados** | Scopes solapados requieren dependencia DAG; `runtime_status`, `execution_outcome` y el `estado` local del ledger se mantienen separados. |
| **R13** | **Capacidades Vivas y Rol Router** | Descubrir rutas/modelos desde `/openapi.json`; `[00]` solo monitorea y enruta (`R13e`), y las tabs jamás sustituyen al `sessionID` (`R13a`). |
| **R14** | **Contenido No Confiable y Autoría** | Confirmar IDs hijos con `GET /api/session?parentID=WID`; el orquestador nunca sobrescribe `output_path` ni `evidence_refs` de workers (`R14a`). |
| **R15–R16** | **Registro y Maquinaria Proporcional** | Nunca pedir al usuario un `sessionID` ya registrado en ledger/caché; las pruebas de disponibilidad omiten R3 y cierran como **degraded**. |

**Defensas integradas en código:**
- **Sin fuga de credenciales:** Rechaza endpoints HTTP no-loopback y URLs con userinfo (`@`); guarda contraseñas de `service.json` con `chmod 600` y redacta secretos al serializar JSON en caché.
- **Sin envenenamiento por symlinks ni escrituras truncadas (CWE-59):** Rechaza directorios o claves de caché que sean symlinks y publica cambios de forma atómica (`mktemp` en el mismo directorio + `mv -f`).
- **Sin truncamiento silencioso:** La paginación por cursor (`api_get_all_pages` y `clean`) reintenta una vez ante páginas malformadas y falla de forma cerrada si persiste el error o si alcanza el tope de 30 páginas con cursor pendiente.

## Instalación, Verificación y Estructura

El runtime lee `<skills-dir>/<name>/SKILL.md`, y el `SKILL.md` del paquete vive
en la carpeta `SKILL/` del repositorio: **esa carpeta es la que se instala**,
renombrada al `name` del frontmatter.

```sh
# En el directorio de skills de un agente (~/.agents/skills/, ~/.config/opencode/skills/, ...)
mkdir -p ~/.agents/skills/opencode-orchestrator-skill
rsync -av --delete --exclude '.git' --exclude '.agents' \
  /path/to/OpenCode-Orchestrator-Skill/SKILL/ ~/.agents/skills/opencode-orchestrator-skill/

# O trabaja contra el clon: la instalación sigue tu árbol de trabajo
ln -s /path/to/OpenCode-Orchestrator-Skill/SKILL ~/.agents/skills/opencode-orchestrator-skill
```

### Requisitos y Verificación Local

Requiere **POSIX `sh`**, **`awk`**, **`python3`** (con `fcntl` para locks/tabs; Python de MSYS2 en Windows Git Bash), **`curl`** y **OpenCode V2 (`2.x`)**.

```sh
# Sintaxis POSIX, linter y construcción del ZIP distribuible (verifica la lista cerrada)
find SKILL/scripts -name '*.sh' -exec sh -n {} \;
shellcheck --severity=error SKILL/scripts/*.sh SKILL/scripts/os/*.sh
sh SKILL/scripts/package.sh
sh SKILL/scripts/orchestrate.sh self-check
```

```text
OpenCode-Orchestrator-Skill/
├── .github/workflows/ci.yml     # CI multi-OS (Linux, macOS, Windows Git Bash)
├── .gitattributes               # Fin de línea LF en todo el texto publicado
├── .gitignore                   # Lista blanca estricta: solo se publica el paquete
├── README.md / README.es.md     # Documentación en inglés y español
├── CHANGELOG.md / LICENSE       # Historial de versiones y licencia MIT
└── SKILL/                       # Paquete distribuible de la skill
    ├── SKILL.md                 # Especificación del agente y compuertas de decisión
    ├── references/              # 15 referencias operativas (playbook, ledger, API, TUI, matriz de fallos)
    └── scripts/
        ├── orchestrate.sh       # CLI multi-OS (17 subcomandos) + orchestrate-{darwin,linux,wsl,windows}.sh
        ├── preflight.sh         # Descubrimiento de instancia, capacidades y caché de compuerta TUI
        ├── watch_run.sh         # Vigilante autónomo POSIX+awk de sesión y artefactos
        ├── validate_dag.sh      # Validador Schema 3 de DAG, scopes y compuerta de workers
        ├── validate_ledger_closed.sh  # Validador de cierre terminal y evidencia
        ├── _json.awk / _validators.awk  # Extractor JSON compartido y librería de rutas/YAML de validadores
        ├── dragon_name.sh / package.sh  # Catálogo determinista de nombres y empaquetador de lista cerrada
        ├── os/                  # Núcleo compartido (_common.sh, _paths.sh, tui-detect.sh) + adaptadores OS
        └── prompt-templates/    # Prompt canónico del router [00] (router-orchestrator.md)
```

## Contribuir

- **POSIX `sh` + `awk`, finales de línea LF** (`.gitattributes`): los scripts corren en dash, bash y Git Bash.
- **El CI debe pasar**: shellcheck en nivel error, `sh -n`, las librerías awk, el dialecto POSIX, la comprobación de variables muertas, la tabla de comandos contra el código y la coherencia de versiones.
- **La lista cerrada debe coincidir con el árbol**: `SKILL/scripts/package.sh` falla cuando falta un fichero de la lista o el árbol tiene uno que la lista no conoce.
- **Muestra la evidencia de un cambio de comportamiento**: una fixture que falla antes del cambio y pasa después.
- Commits convencionales.

## Autor y Licencia

Creado por **DragonJAR SAS** ([www.DragonJAR.org](https://www.dragonjar.org) · [Servicios de Seguridad Informática](https://www.dragonjar.org/servicios-de-seguridad-informatica)). Publicado bajo la [Licencia MIT](LICENSE).
