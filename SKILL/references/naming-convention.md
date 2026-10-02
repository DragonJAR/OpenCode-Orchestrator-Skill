# Nomenclatura de títulos de sesión

Referencia canónica del patrón `[NN] Nombre`. `SKILL.md` la resume; aquí vive el detalle, la justificación y los límites.

## `[00]` es la ranura del orquestador, siempre

El ordinal `00` está reservado para la sesión raíz. No es una convención de paperwork: **el código lo garantiza**.

- `init-run` crea la raíz siempre, con o sin `--title`.
- El nombre por defecto es `Orquestador`, así que la raíz se llama `[00] Orquestador` sin que tengas que escribirlo.
- `ensure-root` normaliza con `title_normalize 0`, que **fuerza** el ordinal: `--title "Mi Run"` produce `[00] Mi Run`, y un `[07]` explícito se corrige a `[00]`. `--title` cambia el nombre, nunca el número.
- Los workers empiezan en `01`, y `worker_list` **reesigna un `[00]` explícito** al siguiente ordinal libre. Dos ranuras `[00]` harían ambigua la identidad del run: no se permite.

Motivo: si el `00` dependiera de que el operador se acuerde, la primera sesión del run sería tan probable como cualquier otra y la convención se degradaría al primer uso. Centralizarlo en `title_normalize 0` lo hace inevitable.

```sh
orchestrate.sh init-run --worker "Vermithrax"
# root=[00] Orquestador -> ses_...
# created [01] Vermithrax -> ses_...

orchestrate.sh init-run --title "Auditoria Q3" --worker "Vermithrax"
# root=[00] Auditoria Q3 -> ses_...     (mismo slot 00, otro nombre)
```

## Patrón

**`[NN] Nombre`** — ordinal secuencial de dos dígitos, un espacio, nombre legible.

```
[00] Orquestador      raíz / orquestador
[01] Vermithrax       worker 1
[02] Glacielle        worker 2
[03] Tempestad        worker 3
```

## Por qué esta forma

- **Ordinal con cero a la izquierda, correlativo.** El orden léxico coincide con el numérico: `[00] < [01] < [20]` ordena bien en la TUI, en `orchestrate.sh sessions` y con `sort`. Un `[9]` sin cero se intercalaría mal.
- **`[00]` reservado a la raíz.** Distingue el orquestador de sus workers de un vistazo, y el correlativo de workers arranca en `01`.
- **Un espacio, no un punto ni guion.** La TUI renderiza el título y el espacio es el separador más legible; `[01]Vermithrax` y `01-Vermithrax` se leen peor.
- **El nombre propio carga el alcance.** `[01] Vermithrax` dice algo del worker sin abrir nada; `[W1]20261001-t3t3` no dice nada. El ID del run ya vive en el ledger y en `runs/<run>/`, así que el título no lo repite (DRY).
- **El `task_id` del ledger (`W1`, `S1a`) no cambia.** Es la clave estable; el título es la identidad legible. Renombrar no invalida el ledger ni sus validaciones.

## Límites conocidos

No son defectos ocultos, son el precio de las decisiones de arriba:

- **Por encima de `[99]`** el ancho crece a tres dígitos y el orden léxico deja de coincidir con el numérico (`"100" < "99"`). Divide el run en vez de seguir numerando.
- **Al ser correlativo sin huecos**, insertar un worker en medio obliga a renumerar los siguientes. Si esperas crecer a lo largo del run, reserva huecos a mano (`[01]`, `[05]`, `[10]`) en vez de dejar que el correlativo los llene.
- **Un título con espacios rompe la lista separada por espacios.** No es defecto del patrón: es la razón por la que existe `--worker` (ver abajo).

## El espacio no es delimitador de lista

Un título contiene un espacio por diseño, así que la lista de workers **no puede** separarse por espacios: `--workers "W1 Vermithrax"` es ambiguo y crearía dos sesiones.

```sh
orchestrate.sh init-run --worker "Vermithrax" --worker "Glacielle"   # ok, inequívoco
orchestrate.sh init-run --workers "Vermithrax, Glacielle"            # ok, delimitado por comas
orchestrate.sh init-run --workers "W1 Vermithrax"                    # MAL: 2 sesiones
```

`--worker` es la vía recomendada: una flag por sesión, sin ambigüedad posible.

## Automatización (DRY)

No escribas el patrón a mano: los scripts ya lo aplican. Ambos viven en `scripts/os/_common.sh` y son la única implementación del patrón.

- **`title_normalize ORDINAL NAME`** — produce `[NN] Name`. Es idempotente: un título que ya trae `[NN]` se devuelve intacto.
- **`worker_list LIST`** — divide por comas o newlines (**nunca** por espacios), aplica el correlativo `01, 02, 03...` a las entradas sin número, respeta un `[NN]` explícito y adelanta el contador para que un automático nunca colisione, y deduplica por slug.

Comportamiento verificado:

| Entrada | Salida |
|---|---|
| `Vermithrax, Glacielle, Tempestad` | `[01] Vermithrax`, `[02] Glacielle`, `[03] Tempestad` |
| `Uno, [05] Quinto, Dos` | `[01] Uno`, `[05] Quinto`, `[06] Dos` |
| `[01] Vermithrax, [01]Vermithrax` | `[01] Vermithrax` (dedup por slug, ordinal ignorado) |
| `[00] Worker` | `[01] Worker` (el 00 se reasigna; está reservado a la raíz) |

## Catálogo de dragones

El catálogo de nombres vive en `scripts/dragon_name.sh`, que es su fuente única: la documentación no repite los 100 nombres. Cinco familias de 20, y el ordinal comunica el elemento sin abrir la sesión:

| Ordinales | Familia |
|---|---|
| `01`–`20` | Fuego (`Vermithrax`, `Pyreclaw`, `Cinderfang`, ...) |
| `21`–`40` | Hielo (`Glacielle`, `Frostfang`, `Wintermaw`, ...) |
| `41`–`60` | Tormenta (`Tempestad`, `Stormwing`, `Thundercoil`, ...) |
| `61`–`80` | Abisal/primordial (`Eldryth`, `Abysswing`, `Voidmaw`, ...) |
| `81`–`100` | Arcano (`Dracolith`, `Wyrmbinder`, `Soulforge`, ...) |

```sh
sh scripts/dragon_name.sh list     # catálogo completo: "NN Name" por línea
sh scripts/dragon_name.sh N        # nombre para el ordinal N
sh scripts/dragon_name.sh count    # 100
sh scripts/dragon_name.sh --json   # catálogo como JSON
```

**Si se agotan, se generan dinámicamente.** Para un ordinal `N > 100` el script sintetiza determinísticamente con la morfología del mundo de los dragones — linaje + naturaleza + epíteto, las tres raíces del lore (draco/wyrm/serpentes griegas y latinas; vritra, nidhogg, tiamat, shesha y vasuki mitológicas; y los epítetos anatómicos de todo draco):

```sh
sh scripts/dragon_name.sh 101   # Jorm-aetherfang
sh scripts/dragon_name.sh 102   # Nidh-aetherfang
sh scripts/dragon_name.sh 112   # Vritr-pyromaw
sh scripts/dragon_name.sh 5000  # el mismo N produce siempre el mismo nombre
```

Determinístico, no aleatorio: el mismo ordinal produce siempre el mismo nombre en cualquier máquina, que es lo que necesita un run reanudable. La capacidad antes de cualificar con el ciclo es el producto de las tres familias de morfemas (12 × 9 × 12 = 1.296 combinaciones).

Dos invariantes que el script comprueba al cargar y por las que falla con exit 2 si no se cumplen: exactamente 100 nombres y todos distintos. Se añadieron porque un duplicado (`Dracolith` en los ordinales 66 y 81) pasó inadvertido hasta que una verificación lo detectó.

## Renombrar una sesión existente

```sh
orchestrate.sh attach-tabs --session <ID> --title "[01] Vermithrax"
```

El merge actualiza el título si el `sessionID` ya existe, en vez de deduplicar en silencio (comportamiento corregido: antes el renombrado se perdía). Verifica con `tabs_status=ok-verificada-title`.

Para renombrar solo la sesión, sin tocar la tab, existe `session_rename` en el API del CLI. Prefiere `attach-tabs` cuando quieras que ambas superficies queden alineadas: una sesión con un título y una tab con otro es estado inconsistente.
