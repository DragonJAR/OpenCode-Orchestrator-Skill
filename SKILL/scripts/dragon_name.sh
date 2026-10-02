#!/bin/sh
# dragon_name.sh — catalogo y sintetizador de nombres del mundo de los dragones.
# Fuente unica de verdad: el catalogo de 100 y las morfemas de generacion viven
# aqui, no en la documentacion (DRY: SKILL.md y las references describen el
# contrato; este script lo implementa una sola vez).
#
# Uso:
#   dragon_name.sh list          -> catalogo completo, "NN Name" por linea
#   dragon_name.sh N             -> nombre para el ordinal N (1..N)
#   dragon_name.sh count         -> cuantos nombres hay antes de sintetizar
#   dragon_name.sh --json        -> catalogo como objeto JSON
#
# Sintesis determinista: el mismo N produce SIEMPRE el mismo nombre (no usa
# $RANDOM ni fecha). Se usa para un run con mas de 100 workers, donde el
# catalogo se agota; el ordinal [NN] del titulo es la identidad estable, asi
# que el nombre sintetizado solo necesita ser estable y distinto, no aleatorio.
#
# Dependencias: POSIX sh + awk. Exit: 0 ok, 2 uso incorrecto.
set -u

# --- catalogo: 100 nombres agrupados por naturaleza -----------------------------
# El grupo importa: el ordinal comunica el elemento aunque no se abra la sesion.
#   01-20 Fuego | 21-40 Hielo | 41-60 Tormenta | 61-80 Abisal | 81-100 Arcano
CATALOG=$(cat <<'EOF'
Vermithrax Pyreclaw Cinderfang Ashwing Magmaborn Blazehide Emberveil Infernalis
Scaldwing Searclaw Flaremaw Charhide Pyrelight Moltenveil Emberwing Ashborn
Firefang Blazecrest Cinderborn Searmaw
Glacielle Frostfang Rimewing Wintermaw Crystalthorn Hailspine Nivembria
Frostveil Icenail Rimeclaw Glacierscale Winterwing Frostborn Coldmaw Snowcoil
Crystalfang Hoarhide Periclaw Glacihorn Winterborn
Tempestad Stormwing Thundercoil Galewyrm Voltwing Lightningfang Squallclaw
Tempestmaw Thundercrest Stormscale Skyfang Galeborn Thunderwing Zephyrmaw
Voltclaw Stormclaw Cyclonehide Thunderborn Galecoil Voltcrest
Eldryth Abysswing Voidmaw Nyxwing Umbraclaw Dracolith Tidescale Drownwing
Abyssfang Voidcrest Nauticlaw Tidemaw Gloomwing Umbrascale Elderbane
Seafoamwing Voidborn Chasmclaw Duskmaw Tidesoul
Runebinder Wyrmbinder Runewing Soulforge Oathmaw Draconic Grimoirewing
Thornmaw Vowclaw Charscale Relicwing Codexmaw Sigilstone Runeclaw
Embercrest Grimoire Hierophant Sigilwing Vowcrest Archonwing
EOF
)

CATALOG_COUNT=$(printf '%s' "$CATALOG" | wc -w | tr -d ' ')

# Invariante del catalogo: 100 nombres, todos distintos. Se comprueba al cargar
# para que un duplicato futuro falle aqui y no se descubra al usar la skill (un
# agente encontro 'Dracolith' repetido en dos ordinales: 99 unicos, no 100).
CATALOG_UNIQUE=$(printf '%s' "$CATALOG" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' ')
if [ "$CATALOG_COUNT" -ne 100 ] || [ "$CATALOG_UNIQUE" -ne 100 ]; then
  printf 'ERROR: catalogo inconsistente: %s nombres, %s unicos (se esperan 100 de 100)\n' \
    "$CATALOG_COUNT" "$CATALOG_UNIQUE" >&2
  exit 2
fi

# --- morfemas para la sintesis ----------------------------------------------------
# Tres familias, como en la nomenclatura real de dragones: linaje (de donde
# viene) + naturaleza (que elemento) + epiteto (que distintivo). Las tres salen
# del lore: draco/wyrm/serpentes son las raices griegas, sajonas y latinas;
# vritra/nidhogg/tiamat/shesha/ananta/vasuki, las mitologicas; los epitetos,
# las partes anatomicas que todo draco tiene.
LINEAGES="Draco Wyrm Serp Vritr Jorm Nidh Tiam Shesh Anant Vasuk Rudr Nag"
NATURES="pyro cryo aqua aero terra void umbra lumen aether"
EPITHETS="fang maw wing scale coil claw crest breath heart hide horn soul"

die() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

# dragon_name N -> nombre sintetizado para N (> CATALOG_COUNT)
synthesize() {
  # El ordinal va por -v: dentro de BEGIN, $1 todavia no existe (awk no ha
  # leido stdin), asi que leerlo ahi producia un linaje vacio ("-pyrofang").
  awk -v n="$1" -v lineages="$LINEAGES" -v natures="$NATURES" -v epithets="$EPITHETS" '
    BEGIN {
      nl = split(lineages, L, " "); nn = split(natures, N, " "); ne = split(epithets, E, " ")
      total = nl * nn * ne
      i = n - 1                      # 0-based
      cycle = int(i / total); k = i % total
      li = k % nl; k = int(k / nl)
      ni = k % nn; ei = int(k / nn) % ne
      # Tras agotar el producto cartesiano, se cualifica el linaje con el ciclo,
      # de modo que los nombres siguen siendo distintos sin inventar otra lista.
      name = toupper(substr(L[li + 1], 1, 1)) substr(L[li + 1], 2) \
             "-" N[ni + 1] E[ei + 1]
      if (cycle > 0) name = name "-" cycle
      print name
    }'
}

# dragon_at N -> nombre del catalogo o sintetizado
dragon_at() {
  n=$1
  case "$n" in ''|*[!0-9]*) die "ordinal no numerico: $n" ;; esac
  [ "$n" -ge 1 ] || die "ordinal debe ser >= 1 (0 y negativo no existen)"
  name=$(printf '%s\n' "$CATALOG" | tr ' \t' '\n\n' | grep -v '^$' | sed -n "${n}p")
  if [ -n "$name" ]; then printf '%s\n' "$name"; return 0; fi
  synthesize "$n"
}

case "${1:-}" in
  list)
    i=0
    printf '%s\n' "$CATALOG" | tr ' \t' '\n\n' | grep -v '^$' | while IFS= read -r name; do
      i=$((i + 1)); printf '%02d %s\n' "$i" "$name"
    done
    ;;
  count) printf '%s\n' "$CATALOG_COUNT" ;;
  --json)
    printf '{"count":%s,"names":[' "$CATALOG_COUNT"
    printf '%s\n' "$CATALOG" | tr ' \t' '\n\n' | grep -v '^$' | awk 'BEGIN{first=1}
      { printf "%s\"%s\"", (first ? "" : ","), $0; first=0 } END { print "]}" }'
    ;;
  ''|-h|--help|help)
    cat <<'USAGE'
dragon_name.sh list     catalogo completo (NN Name)
dragon_name.sh N        nombre para el ordinal N (catalogo, o sintetizado si excede)
dragon_name.sh count    tamano del catalogo antes de sintetizar
dragon_name.sh --json   catalogo como JSON
USAGE
    ;;
  *) dragon_at "$1" ;;
esac
