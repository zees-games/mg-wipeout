#!/usr/bin/env bash
# Render the game and look at it. The check no assertion in this repository makes.
#
#   tools/shot.sh                                      # a player's own eyes, a few seconds in
#   tools/shot.sh --view=course --wo-course-ids=wo_spin_cycle   # a course, from above
#   tools/shot.sh --view=tour --wo-course-ids=wo_spin_cycle   # an overview and three frames along the route (--out=res://screenshots/x.png writes x_overview.png, x_1..3)
#   tools/shot.sh --view=look --look=x,y,z,tx,ty,tz   # a free camera at the first point, facing the second
#   tools/shot.sh --view=start                         # the start pad, from behind the runners
#   tools/shot.sh --view=cover                         # the loading cover, before it lifts
#   tools/shot.sh --view=hazard --seconds=2            # the first thing that throws you, close
#   tools/shot.sh --view=knockout                      # a stand-in at 5 hp struck by a spinner: the body flung
#   --view=hurt      the local health bar after a hit
#   tools/shot.sh --view=third --seconds=8             # third person, on the course
#   tools/shot.sh --view=race --seconds=25             # the field mid-race, from over a runner's shoulder
#   tools/shot.sh --view=crowd --seconds=6             # a grandstand and its crowd, from the course
#   tools/shot.sh --view=duck --seconds=30 --wo-course-ids=wo_the_sweeper   # a stand-in ducking an arm, close
#   tools/shot.sh --view=falls --seconds=3             # the first water or slime fall, mid-pour
#   tools/shot.sh --view=arena --arena=wo_arena_pit    # an arena, from above
#   tools/shot.sh --view=finale                        # a real final death, a finisher's eyes
#   tools/shot.sh --view=course --out=res://screenshots/x.png   # any --wo-* is the game's config
#   tools/shot.sh --view=maps --seconds=0.5   # M: the solo course list with a Workshop fixture course (Name [Pack])
#   tools/shot.sh --view=third --board                 # with the Tab scoreboard held open
#   tools/shot.sh --view=third --ballot                # the course vote's ballot, mid-vote
#   tools/shot.sh --console="net_stat 3"               # a line typed at the player's console first
#
# xvfb-run because this needs a rendering context and the machines this runs on have no
# display. `--headless` is NOT a substitute: it gives a null renderer and saves a frame of
# nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

view="eyes"
seconds="4"
out=""
# A render wants the round running: no warmup and a short countdown, unless asked otherwise.
# Passed as the game's own flags, because the client reads its configuration as it loads and
# a value changed after that has already been copied into the round's rules.
config=("--wo-warmup-seconds=0" "--wo-countdown-seconds=1")

for arg in "$@"; do
    case "$arg" in
        --view=*)    view="${arg#*=}" ;;
        --seconds=*) seconds="${arg#*=}" ;;
        --out=*)     out="${arg#*=}" ;;
        --wo-*)      config+=("$arg") ;;
        --arena=*)   config+=("$arg") ;;
        --grid=*)    config+=("$arg") ;;
        --look=*)    config+=("$arg") ;;
        --board)     config+=("$arg") ;;
        --ballot)    config+=("$arg") ;;
        --workshop)  config+=("$arg") ;;
        --console=*) config+=("$arg") ;;
        *)           echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[ -n "$out" ] || out="res://screenshots/${view}.png"

scene="res://tools/shot.tscn"

exec xvfb-run -a "${GODOT:-godot}" --path . --resolution 1280x720 \
    "$scene" -- "--seconds=$seconds" "--view=$view" "--out=$out" "${config[@]}"
