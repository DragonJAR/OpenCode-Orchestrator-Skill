#!/bin/sh
# dragon_name.sh — catalog and synthesizer of dragon-world names.
# Single source of truth: the 100-name catalog and the generation morphemes
# live here, not in the documentation (DRY: SKILL.md and the references
# describe the contract; this script implements it exactly once).
#
# Usage:
#   dragon_name.sh list          -> full catalog, "NN Name" per line
#   dragon_name.sh N             -> name for ordinal N (1..N)
#   dragon_name.sh count         -> how many names exist before synthesizing
#   dragon_name.sh --json        -> catalog as a JSON object
#
# Deterministic synthesis: the same N ALWAYS produces the same name (it does
# not use $RANDOM or the date). It is used for a run with more than 100
# workers, where the catalog is exhausted; the [NN] ordinal in the title is
# the stable identity, so the synthesized name only needs to be stable and
# distinct, not random.
#
# Dependencies: POSIX sh + awk. Exit: 0 ok, 2 wrong usage.
set -u

# --- catalog: 100 names grouped by nature -----------------------------------
# The group matters: the ordinal conveys the element even without opening the
# session.
#   01-20 Fire | 21-40 Ice | 41-60 Storm | 61-80 Abyssal | 81-100 Arcane
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

# Catalog invariant: 100 names, all distinct. Checked at load time so a future
# duplicate fails here instead of being discovered while using the skill (an
# agent found 'Dracolith' repeated in two ordinals: 99 unique, not 100).
CATALOG_UNIQUE=$(printf '%s' "$CATALOG" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' ')
if [ "$CATALOG_COUNT" -ne 100 ] || [ "$CATALOG_UNIQUE" -ne 100 ]; then
  printf 'ERROR: inconsistent catalog: %s names, %s unique (expected 100 of 100)\n' \
    "$CATALOG_COUNT" "$CATALOG_UNIQUE" >&2
  exit 2
fi

# --- morphemes for synthesis --------------------------------------------------
# Three families, as in real dragon nomenclature: lineage (where it comes
# from) + nature (which element) + epithet (which distinction). All three come
# from the lore: draco/wyrm/serpentes are the Greek, Saxon and Latin roots;
# vritra/nidhogg/tiamat/shesha/ananta/vasuki, the mythological ones; the
# epithets, the anatomical parts every draco has.
LINEAGES="Draco Wyrm Serp Vritr Jorm Nidh Tiam Shesh Anant Vasuk Rudr Nag"
NATURES="pyro cryo aqua aero terra void umbra lumen aether"
EPITHETS="fang maw wing scale coil claw crest breath heart hide horn soul"

die() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

# dragon_name N -> synthesized name for N (> CATALOG_COUNT)
synthesize() {
  # The ordinal goes via -v: inside BEGIN, $1 does not exist yet (awk has not
  # read stdin), so reading it there produced an empty lineage ("-pyrofang").
  awk -v n="$1" -v lineages="$LINEAGES" -v natures="$NATURES" -v epithets="$EPITHETS" '
    BEGIN {
      nl = split(lineages, L, " "); nn = split(natures, N, " "); ne = split(epithets, E, " ")
      total = nl * nn * ne
      i = n - 1                      # 0-based
      cycle = int(i / total); k = i % total
      li = k % nl; k = int(k / nl)
      ni = k % nn; ei = int(k / nn) % ne
      # Once the cartesian product is exhausted, the lineage is qualified with
      # the cycle, so names stay distinct without inventing another list.
      name = toupper(substr(L[li + 1], 1, 1)) substr(L[li + 1], 2) \
             "-" N[ni + 1] E[ei + 1]
      if (cycle > 0) name = name "-" cycle
      print name
    }'
}

# dragon_at N -> catalog or synthesized name
dragon_at() {
  n=$1
  case "$n" in ''|*[!0-9]*) die "non-numeric ordinal: $n" ;; esac
  [ "$n" -ge 1 ] || die "ordinal must be >= 1 (0 and negative do not exist)"
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
dragon_name.sh list     full catalog (NN Name)
dragon_name.sh N        name for ordinal N (catalog, or synthesized if exceeded)
dragon_name.sh count    catalog size before synthesizing
dragon_name.sh --json   catalog as JSON
USAGE
    ;;
  *) dragon_at "$1" ;;
esac
