# OpenCode Orchestrator Skill

[![Licencia](https://img.shields.io/badge/licencia-MIT-blue.svg)](SKILL/LICENSE)
[![Versión](https://img.shields.io/badge/versi%C3%B3n-2.1.0-green.svg)](SKILL/SKILL.md)
[![Plataforma](https://img.shields.io/badge/plataforma-OpenCode%20V2-8A2BE2.svg)](https://opencode.ai)
[![Autor](https://img.shields.io/badge/autor-DragonJAR%20SAS-orange.svg)](https://www.DragonJAR.org)
[![English](https://img.shields.io/badge/read%20in-English-blue.svg)](README.md)

> Skill de orquestación multiagente determinista, verificable y en dos niveles para OpenCode V2. Coordina sesiones worker, delega subagentes hijos aislados, impone presupuestos de escritura disjuntos en el filesystem, mantiene un ledger canónico en YAML y provee validadores POSIX sin dependencias externas.

---

## 🎯 Qué hace esta Skill

Esta skill convierte a un agente de IA en un **Orquestador en Dos Niveles** de grado empresarial para OpenCode V2. Resuelve de raíz los problemas críticos de la coordinación multiagente: condiciones de carrera, IDs de sesión alucinados, tareas caídas en silencio y corrupción de workspaces:

- **Jerarquía en Dos Niveles (`worker_session` → `subagent`):** El orquestador crea sesiones worker raíz vía API HTTP, y cada worker coordina al menos dos subagents hijos distintos y preautorizados usando la herramienta nativa `subagent`.
- **Ledger Canónico en YAML (Esquema Versión 3):** Mantiene una bitácora de estado estructurada e inmutable que rastrea IDs de sesión, jerarquía de dependencias, outcomes de ejecución, marcas temporales y criterios verificables.
- **Aislamiento Estricto de Presupuesto y Scopes de Escritura:** Exige disyunción léxica entre los scopes de escritura paralelos (`scope_escritura`). Los hermanos con solapamiento se serializan automáticamente en el DAG para erradicar colisiones en disco.
- **Reglas Duras No Negociables (R1–R14):** Salvaguardas formales que prohíben dar por hecho éxitos no verificados, especular con rutas HTTP no publicadas, alucinar herramientas e IDs o ejecutar operaciones destructivas sin autorización humana.
- **Lectura Acotada y Reconciliación:** Sustituye el sondeo infinito por ventanas de espera acotadas, detección del marcador de inactividad (`time.idle`) y supervisión activa de bloqueos interactivos por permisos (`awaiting-approval`).
- **Validadores POSIX sin Dependencias:** Incluye `validate_dag.sh` y `validate_ledger_closed.sh`, desarrollados en puro POSIX `sh` + `awk`, capaces de validar la integridad del DAG, scopes y evidencia de cierre sin requerir Python, yq ni librerías externas.
- **Soporte de Cierre Degradado (`--allow-degraded`):** Permite auditar y cerrar formalmente ejecuciones que alcanzan estados terminales degradados legítimos (`partial`, `blocked`, `failed`), exigiendo documentación técnica de la causa.
- **Autenticación HTTP Directa e Integración TUI Tabs:** Descubre credenciales del servicio activo (HTTP Basic Auth vía `service.json`) y gestiona la visualización de pestañas en la TUI sin comprometer la seguridad.

---

## 📦 Instalación

Al instalar la skill en el directorio de habilidades de tu agente, la carpeta **debe llamarse `opencode-orchestrator-skill`** (coincidiendo con el atributo `name` del frontmatter):

### Opción 1: Instalar en el directorio de skills del agente

```bash
# Para agentes en Antigravity, OpenCode, Claude Code o Cursor
cd ~/.agents/skills/   # o ~/.gemini/config/skills/ o ~/.config/opencode/skills/
git clone https://github.com/DragonJAR/OpenCode-Orchestrator-Skill.git opencode-orchestrator-skill
```

### Opción 2: Clonar para desarrollo o inspección

```bash
git clone https://github.com/DragonJAR/OpenCode-Orchestrator-Skill.git
cd OpenCode-Orchestrator-Skill
```

---

## ⚙️ Requisitos y Entorno

La skill y su suite de validación han sido diseñadas con **cero dependencias externas**, aprovechando las utilidades estándar POSIX del sistema:

| Herramienta | Versión Requerida | Propósito |
|-------------|-------------------|-----------|
| **POSIX `sh`** | Estándar (`/bin/sh`) | Ejecución de validaciones y runner de scripts |
| **`awk`** | Estándar POSIX (nawk, gawk, mawk) | Parseo del ledger, validación léxica de scopes y gates de cierre |
| **OpenCode** | Serie 2.0.x (snapshot V2) | Runtime destino de ejecución de sesiones y herramienta `subagent` |
| **Git** | 2.0+ | Control de versiones con imposición de finales de línea LF |

### Verificación del Entorno

Ejecuta el validador estructural desde la raíz del repositorio:

```bash
bash .agents/maintenance/scripts/validate_skill.sh
```

Salida esperada:
```text
[OK]   SKILL.md existe y es UTF-8 legible
[OK]   Frontmatter válido dentro del subconjunto YAML documentado; claves únicas
[OK]   Campo name válido (opencode-orchestrator-skill)
[OK]   Campo description decodificado presente y <= 1024 caracteres (679)
[OK]   SKILL.md <= 5000 palabras (3161)
[OK]   references/ existe con archivos Markdown (13)
[OK]   Análisis Markdown completo: 44 enlaces inline encontrados (44 locales, 0 externos)
----------------------------------------
TOTAL: 7 passed, 0 failed
```

> **Entornos Windows:** Ejecuta los validadores y los scripts de orquestación (`orchestrate-windows.sh`) dentro de **Git Bash** o **WSL** — nunca directamente desde `cmd.exe` (requiere un `sh` en PATH). Los archivos `.sh` deben conservar finales de línea **LF**; el repositorio lo impone de forma automática mediante `.gitattributes` (`*.sh text eol=lf`). Para `attach-tabs` en Git Bash se requiere un python3 con `fcntl` (python de MSYS2); si falta, el script falla cerrado con instrucciones.

---

## 🧩 Arquitectura y Jerarquía

La orquestación multiagente en OpenCode opera rigurosamente en dos niveles:

```text
 ┌───────────────────────────────────────────────────────────────┐
 │                   ORQUESTADOR (Agente Raíz)                   │
 │  - Administra y custodia el ledger YAML (schema_version 3)    │
 │  - Crea las sesiones worker raíz (parentID: null)             │
 │  - Preautoriza tareas, presupuestos de escritura y criterios │
 │  - Sondea, reconcilia, verifica evidencia y cierra el ledger  │
 └───────────────────────────────┬───────────────────────────────┘
                                 │ HTTP POST /api/session (directory)
                                 ▼
 ┌───────────────────────────────────────────────────────────────┐
 │                 SESIÓN WORKER (Worker Raíz)                   │
 │  - Sesión nativa con parentID: null                           │
 │  - Recibe presupuesto de escritura y tareas preautorizadas    │
 │  - Coordina al menos 2 subagentes hijos distintos             │
 │  - NUNCA modifica ni edita el ledger compartido               │
 │  - Inspecciona entregables, integra hallazgos y reporta YAML  │
 └───────────────────────────────┬───────────────────────────────┘
                                 │ Llamada nativa a herramienta subagent
                ┌────────────────┴────────────────┐
                ▼                                 ▼
 ┌─────────────────────────────┐   ┌─────────────────────────────┐
 │     SUBAGENTE HIJO (S1)     │   │     SUBAGENTE HIJO (S2)     │
 │ - parentID: workerSessionID │   │ - parentID: workerSessionID │
 │ - Scope: artifacts/s1/      │   │ - Scope: artifacts/s2/      │
 │ - Genera S1-output.md       │   │ - Genera S2-output.md       │
 │ - Escribe S1-evidence.yml   │   │ - Escribe S2-evidence.yml   │
 └─────────────────────────────┘   └─────────────────────────────┘
```

### Reglas de Presupuesto y Scopes de Escritura

1. **Subconjuntos Disjuntos:** El `scope_escritura` de cada subagente debe ser un subconjunto explícito del presupuesto del worker padre.
2. **Sin Escrituras Simultáneas:** Tareas hermanas con rutas solapadas se serializan forzosamente mediante dependencias en el DAG (`dependencias: ["S1"]`).
3. **Silencio del Padre:** El worker padre nunca escribe en el scope de un hijo mientras este siga activo o con estado incierto.
4. **El Timeout no Libera Scopes:** Si vence una ventana de espera, el scope permanece bloqueado hasta reconciliar formalmente el estado de la sesión vía API.

---

## 🚀 Flujo Operativo de 8 Pasos (Playbook)

La skill implementa un ciclo de vida operativo riguroso, mapeado desde `SKILL.md` y detallado en [`SKILL/references/playbook.md`](SKILL/references/playbook.md):

1. **Detectar Intención y Alcance:** Concretar objetivos, entregables y asignar scopes de directorio independientes.
2. **Preflight de Capacidades Reales:** Consultar `GET /api/info`, `GET /api/location` y `/openapi.json` para validar endpoints HTTP y herramientas activas antes de despachar.
3. **Acceso e Identidad:** Confirmar autorización y directorio del proyecto. Sin acceso, parar e informar los permisos requeridos (Modo Degradado A).
4. **Borrador de Ledger y Preautorización:** Registrar en el ledger YAML Esquema 3 las filas de tareas en estado `pending`, preautorizando al menos dos tareas subagent por worker.
5. **Despachar Sesión Worker Raíz:** Crear la sesión vía `POST /api/session` con `location.directory` explícito. Verificar `parentID: null` y enviar el prompt estructurado.
6. **Coordinar Subagentes:** El worker ejecuta las hijas mediante la herramienta nativa `subagent`. Cada hija hereda y comprueba la ubicación canónica.
7. **Supervisar y Reconciliar:** El orquestador ejecuta lectura acotada (`GET /api/session/{id}`). Comprueba solicitudes pendientes de permisos (`GET /api/session/{id}/permission`) y re-arma plazos solo si hay actividad real.
8. **Inspeccionar, Verificar y Cerrar:** El orquestador inspecciona entregables, audita archivos de evidencia (`criterion`, `result: "pass"`, `observed`), integra hallazgos y ejecuta los validadores antes de cerrar.

---

## 🔍 Suite de Validación

El repositorio provee validadores independientes de alto rendimiento escritos en shell POSIX:

### 1. Validación de DAG y Ledger en Vuelo (`validate_dag.sh`)

Comprueba la sintaxis canónica YAML, identificadores de tareas, relaciones parentales, ausencia de ciclos en el DAG, scopes concurrentes no solapados y coherencia temporal:

```bash
sh SKILL/scripts/validate_dag.sh ruta/al/ledger.yml
```

### 2. Validación Estricta de Cierre (`validate_ledger_closed.sh`)

Exige que todas las tareas hayan finalizado exitosamente con `estado: verified`, `execution_outcome: succeeded`, artefacto en `output_path` y evidencia válida en `evidence_refs`:

```bash
sh SKILL/scripts/validate_ledger_closed.sh --require-evidence ruta/al/ledger.yml
```

### 3. Validación de Cierre en Ejecuciones Degradadas (`--allow-degraded`)

Cuando una ejecución multiagente se topa con bloqueos externos, denegaciones de permisos o tareas incompletas justificadas, debe cerrarse en un estado terminal auditado (`partial`, `blocked`, `failed`):

```bash
sh SKILL/scripts/validate_ledger_closed.sh --allow-degraded ruta/al/ledger.yml
```

`--allow-degraded` asegura que:
- Ninguna tarea quede en un estado activo o en vuelo (`pending`, `launching`, `running`, `awaiting-approval`, `outcome-unknown`).
- Toda tarea terminal no verificada contenga `notas` no vacías con la explicación técnica de la causa.
- Cualquier tarea marcada `verified` cumpla al 100% las exigencias de evidencia y resultado.

---

## 📁 Estructura del Repositorio

```text
OpenCode-Orchestrator-Skill/
├── .gitattributes                  # Impone finales LF en todos los scripts shell
├── .gitignore                      # Lista blanca estricta contra fugas accidentales
├── README.md                       # Guía completa en inglés
├── README.es.md                    # Guía completa en español
└── SKILL/                          # Paquete distribuible de la skill
    ├── LICENSE                     # Licencia MIT
    ├── SKILL.md                    # Especificación principal, R1-R14, decision gates
    ├── references/                 # Guías operativas de referencia
    │   ├── agent-patterns.md       # Reparto worker → subagents y fichas de despacho
    │   ├── agents-and-safety.md    # Catálogo de agentes, permisos y presupuestos
    │   ├── api-and-sessions.md     # API HTTP, lectura acotada y reconciliación
    │   ├── decision-trees.md       # Árboles de decisión para preflight, bifurcación y cierre
    │   ├── failure-matrix.md       # Modos de fallo observables, acciones y antipatrones
    │   ├── ledger-template.md      # Esquema canónico YAML, gates y formato de evidencia
    │   ├── opencode-patterns.md    # Índice maestro de mecanismos operativos
    │   ├── playbook.md             # Flujo operativo de 8 pasos y checklist de cierre
    │   ├── prompt-templates.md     # Plantillas de prompt estandarizadas (1 a 5)
    │   ├── recipe-tui-tabs.md      # Auth HTTP directa y receta local de tabs TUI
    │   ├── research-evidence.md    # Rastreo upstream, versiones y evidencia de auditoría
    │   ├── subagent-contract.md    # Contrato de la herramienta subagent y reglas de ubicación
    │   ├── naming-convention.md    # Patrón de títulos `[NN] Name`
    │   └── trigger-tests.md        # Banco de pruebas de activación y defensas
    └── scripts/                    # Validadores shell POSIX + orquestador (cero dependencias)
        ├── orchestrate.sh           # Navaja multi-OS (12 subcomandos)
        ├── orchestrate-{darwin,linux,wsl,windows}.sh  # Wrappers explícitos por OS
        ├── preflight.sh             # Descubrimiento endpoint + gate de tabs (cachea estado)
        ├── watch_run.sh             # Vigilante acotado POSIX+awk (idle + artefactos)
        ├── dragon_name.sh           # Catálogo de 100 nombres + síntesis determinista
        ├── validate_dag.sh         # Validador de DAG, sintaxis y scopes
        └── validate_ledger_closed.sh # Validador final del gate de cierre (--allow-degraded)
        └── os/                      # Adaptadores por OS: lock + normalización de paths
            ├── _common.sh        # Helpers compartidos (auth, cache, json, pool, tabs)
            ├── darwin.sh         # macOS: python3 fcntl
            ├── linux.sh          # Linux: flock(1)
            ├── wsl.sh            # WSL: flock(1), drvfs fail-closed
            ├── windows-gbash.sh  # Git Bash: python3 fcntl con sonda MSYS2
            └── tui-detect.sh     # Detector de TUI activa / gate de tabs (sólo lectura)

```

---

## 🎓 Frases Disparadoras (Triggers)

La skill está calibrada para activarse con intenciones claras de orquestación multiagente y permanecer inactiva en solicitudes individuales o genéricas:

### Casos que deben activar la Skill:
- *"Orquesta varias sesiones de OpenCode: crea dos workers y que cada uno lance al menos dos subagents para revisar los módulos auth y billing, y luego integra los resultados."*
- *"Necesito delegar en OpenCode una migración grande: gestiona las sesiones, reparte scopes de escritura sin solapes y dime qué worker quedó verificado."*
- *"Spawn workers and subagents in my OpenCode server for a multi-agent run, track them in a ledger and validate the DAG before closing."*
- *"Gestiona una ejecución multiagente en OpenCode y valida el ledger YAML al terminar."*

### Casos que NO deben activar la Skill:
- *"Explícame qué es un agente de IA y en qué se diferencia de un chatbot."* (Concepto general)
- *"Corrige el bug de este componente React que rompe el submit del formulario."* (Tarea de un solo agente)
- *"Orchestrate a nightly Airflow pipeline that loads CSV files."* (Pipeline de datos, otro runtime)

---

## ⚠️ Reglas Duras y Límites Operativos (R1–R14)

| Regla | Principio | Aplicación Operativa |
|-------|-----------|----------------------|
| **R1** | **Acceso Autorizado** | Sin acceso confirmado, limita el trabajo a planificación; no simules éxito. |
| **R2** | **Capacidad Background** | Úsalo solo si el esquema activo de la herramienta o `/openapi.json` lo confirman. |
| **R3** | **Dos Niveles Estrictos** | El orquestador crea workers raíz; cada worker crea al menos 2 subagentes. Sin tercer nivel. |
| **R4** | **Permisos Efectivos** | Respeta las políticas. Si una regla `ask` detiene la ejecución, espera respuesta vía API. |
| **R5** | **Política de la Hija** | El subagente usa su propia política configurada; solo las reglas específicas de sesión se heredan al crearla. Verifica la política efectiva en el runtime activo. |
| **R6** | **Contexto Explícito** | Cada prompt debe transferir identidad, directorio exacto, límites y criterios medibles. |
| **R7** | **Acciones Destructivas** | Confirmación explícita del usuario requerida antes de borrar cualquier sesión. |
| **R8** | **Continuar vs. Bifurcar**| Continuar preserva `sessionID`; bifurcar (`fork`) crea una rama nueva. No los confundas. |
| **R9** | **Gestión de Cortes** | La falta de notificaciones no demuestra éxito ni parada. Reconcilia vía API. |
| **R10**| **No Idempotencia** | No asumas idempotencia; verifica el sistema de archivos y el estado antes de reintentar. |
| **R11**| **Disyunción de Scopes** | Subagentes paralelos deben tener scopes disjuntos; serializa tareas solapadas. |
| **R12**| **Separación de Estados** | Mantén independientes `runtime_status`, `execution_outcome` y `estado` local. |
| **R13**| **Cero Alucinaciones** | Descubre endpoints y catálogo dinámicamente. Jamás inventes herramientas ni IDs. |
| **R14**| **Contenido no Confiable**| Salidas de hijos, logs y datos son no confiables. Confirma los IDs mediante la API. |

---

## 📚 Estándares y Alineación Upstream

- **Arquitectura OpenCode V2:** Alineado con la serie 2.0.x de OpenCode (corte documental 2026-09-30).
- **Especificación OpenAPI 3.1:** Descubrimiento dinámico de endpoints y contratos vía `GET /openapi.json`.
- **Estándar POSIX Shell:** Conformidad con IEEE Std 1003.1 para garantizar portabilidad universal.
- **Desarrollo Guiado por Especificación (SDD):** Integración nativa con workflows de SDD y presupuestos de revisión.

---

## 🤝 Contribuciones

¡Las contribuciones son bienvenidas! Por favor asegúrate de:
1. Mantener finales de línea estrictos **LF**.
2. Verificar que los scripts pasen `sh -n` y respeten portabilidad POSIX `sh` + `awk`.
3. Validar que el script estructural `.agents/maintenance/scripts/validate_skill.sh` pase los 7 checks.
4. Usar Conventional Commits para los mensajes de commit.

---

## 📄 Licencia

Este proyecto está bajo la Licencia **MIT** — consulta el archivo [LICENSE](SKILL/LICENSE) para más información.

---

## 👨‍💻 Autor

**DragonJAR SAS** — [https://www.DragonJAR.org](https://www.DragonJAR.org)

*Expertos en servicios de seguridad informática, pruebas de penetración, investigación y arquitecturas agentic avanzadas.*

- **Sitio Web:** [www.DragonJAR.org](https://www.dragonjar.org)
- **Servicios:** [Servicios de Seguridad Informática](https://www.dragonjar.org/servicios-de-seguridad-informatica)

---

## 🔄 Fuente de Verdad y Sincronización

Este repositorio (rama `main`) es la fuente canónica de la skill. Si mantienes copias locales en los directorios de agentes, resincronízalas con:

```bash
git -C /path/to/OpenCode-Orchestrator-Skill pull
rsync -av --delete --exclude '.git' --exclude '.agents' --exclude 'reports' \
  /path/to/OpenCode-Orchestrator-Skill/SKILL/ ~/.agents/skills/opencode-orchestrator-skill/
```
