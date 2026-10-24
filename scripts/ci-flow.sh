#!/bin/bash
# Run the flow of each project headless, every step but programming (no board in CI), and say which steps failed.
#
#   scripts/ci-flow.sh PROJECT...           e.g. sonata_johnson johnson (projects/NAME.json)
#   SYNTHGUI=path  ARTIFACTS=dir            the synthgui to run (default build/synthgui); where to copy each project's
#                                           logs and bitstream (default none)
#   WORKDIR=dir                             where the projects run (default ci-work/): never the project's own work directory
#   CI_BASELINE=check|update|off            see below (default check)
#
# ci/skip-steps.txt lists steps to leave out of a project (PROJECT STEP reason): each shows in the table as skipped, with its reason.
#
# The step table goes to stdout and, under GitHub Actions, to the job summary. Exits 1 if any step of any project failed.
#
# Besides the steps, two things are checked, because a step exiting 0 does not say the result is still the right one:
#   timing    nextpnr meets every clock target: the last "Max frequency" line of each clock says PASS (nextpnr exits 0 when it
#             does not, as the projects pass --timing-allow-fail);
#   baseline  the FASM and frames are the ones recorded in ci/expected/<platform>.txt (<platform> is `uname -s`-`uname -m`).
#             The same inputs give the same output on one machine, so a change in the hashes is a change in the flow: a tool,
#             a project, a submodule.  If it is intended, CI_BASELINE=update scripts/ci-flow.sh PROJECT... rewrites those
#             projects' lines (the CI job uploads hashes.txt, in the same format, for refreshing a platform from its runner).
#             Floating point in the placer can differ between platforms, hence one file each; a platform or project with no
#             recorded line is not checked and says so.
set -u
cd "$(dirname "$0")/.."
bin=${SYNTHGUI:-build/synthgui}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
base=${WORKDIR:-$PWD/ci-work}
mode=${CI_BASELINE:-check}
platform=$(uname -s)-$(uname -m)
expected=ci/expected/$platform.txt
export QT_QPA_PLATFORM=offscreen
failed=()
mkdir -p "$base"
: > "$base/hashes.txt"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# every clock's last report (nextpnr prints each before and after routing) must say PASS; prints what it found
timing_check() {
    local log=$1/pnr.log final
    [ -f "$log" ] || { echo "no pnr.log"; return 1; }
    final=$(grep -h "Max frequency for clock" "$log" | awk -F"'" '{last[$2]=$0} END {for (c in last) print last[c]}')
    [ -n "$final" ] || { echo "no clock report"; return 1; }
    if echo "$final" | grep -q "FAIL"; then
        echo "$final" | grep FAIL | sed "s/.*clock *'\\([^']*\\)': \\([0-9.]*\\) MHz (FAIL at \\([0-9.]*\\) MHz)/\\1 \\2 MHz, target \\3/" | tr '\n' ';'
        return 1
    fi
    echo "$final" | sed "s/.*clock *'\\([^']*\\)': \\([0-9.]*\\) MHz (PASS at \\([0-9.]*\\) MHz)/\\1 \\2 MHz (target \\3)/" | tr '\n' ';'
}

skipped_steps() { [ -f ci/skip-steps.txt ] && awk -v p="$1" '!/^#/ && $1==p {print $2}' ci/skip-steps.txt; }
skip_reason() { awk -v p="$1" -v s="$2" '!/^#/ && $1==p && $2==s {$1=$2=""; sub(/^ +/, ""); print}' ci/skip-steps.txt; }

recorded() { [ -f "$expected" ] && awk -v p="$1" -v a="$2" '$1==p && $2==a {print $3}' "$expected"; }

printf '| project | step | result | seconds |\n| --- | --- | --- | --- |\n' | tee -a "$summary"
for name in "$@"; do
    p=projects/$name.json
    skip=$(skipped_steps "$name" | jq -R . | jq -sc .)
    ids=$(jq -r --argjson skip "$skip" '[.steps[].id | select(startswith("program") | not) | select(. as $i | ($skip | index($i)) == null)] | join(",")' "$p")
    top=$(jq -r .top "$p")
    work=$base/$name
    rm -rf "$work"                         # every run from scratch, in a directory of this script's own
    echo "::group::$name: $ids"
    t0=$(date +%s)
    "$bin" --project "$p" --work "$work" --run "$ids"
    rc=$?
    echo "::endgroup::"
    ok=1
    for id in ${ids//,/ }; do
        if [ -f "$work/$id.status" ]; then
            read -r code secs < "$work/$id.status"
            if [ "$code" = 0 ]; then res=ok; else res="**FAILED** ($code)"; failed+=("$name/$id"); ok=0; fi
        else
            res="not run"; secs=; ok=0
        fi
        printf '| %s | %s | %s | %s |\n' "$name" "$id" "$res" "$secs" | tee -a "$summary"
    done
    for id in $(skipped_steps "$name"); do
        printf '| %s | %s | skipped: %s | |\n' "$name" "$id" "$(skip_reason "$name" "$id")" | tee -a "$summary"
    done
    # a failure that left no .status (synthgui itself failed) still fails the run
    [ $rc = 0 ] || [ ${#failed[@]} -gt 0 ] || failed+=("$name (synthgui exit $rc after $(( $(date +%s) - t0 )) s)")

    # timing: only meaningful once place and route ran
    if [ -f "$work/pnr.status" ]; then
        if t=$(timing_check "$work"); then
            printf '| %s | timing | %s | |\n' "$name" "$t" | tee -a "$summary"
        else
            printf '| %s | timing | **FAILED** %s | |\n' "$name" "$t" | tee -a "$summary"
            failed+=("$name/timing")
        fi
    fi

    # baseline: the bit step wrote the frames from the FASM
    if [ "$mode" != off ] && [ $ok = 1 ] && [ -f "$work/$top.fasm" ] && [ -f "$work/$top.frames" ]; then
        res="ok"
        for a in fasm frames; do
            h=$(sha "$work/$top.$a")
            echo "$name $a $h" >> "$base/hashes.txt"
            r=$(recorded "$name" "$a")
            if [ "$mode" = check ]; then
                if [ -z "$r" ]; then res="none recorded"
                elif [ "$r" != "$h" ]; then
                    res="**CHANGED** $a (${h:0:12}, recorded ${r:0:12}; CI_BASELINE=update scripts/ci-flow.sh $name, if intended)"
                    failed+=("$name/baseline")
                fi
            fi
        done
        [ "$mode" = check ] && printf '| %s | baseline (%s) | %s | |\n' "$name" "$platform" "$res" | tee -a "$summary"
    fi

    if [ -n "${ARTIFACTS:-}" ] && [ -d "$work" ]; then
        mkdir -p "$ARTIFACTS/$name"
        cp "$work"/*.log "$work"/*.status "$ARTIFACTS/$name/" 2>/dev/null
        cp "$work"/*.bit "$work"/*.uf2 "$ARTIFACTS/$name/" 2>/dev/null
        grep "^$name " "$base/hashes.txt" > "$ARTIFACTS/$name/hashes.txt" 2>/dev/null
    fi
done

if [ "$mode" = update ]; then
    if [ -s "$base/hashes.txt" ]; then
        mkdir -p "$(dirname "$expected")"
        # replace the lines of the projects that produced new hashes; keep the others' (a project that failed keeps its line)
        { echo "# $platform: sha256 of each project's FASM and frames; CI_BASELINE=update scripts/ci-flow.sh PROJECT... rewrites those projects' lines"
          { [ -f "$expected" ] && grep -v '^#' "$expected" | awk 'NR==FNR {new[$1]=1; next} !($1 in new)' "$base/hashes.txt" -
            cat "$base/hashes.txt"; } | sort -u; } > "$expected.new" && mv "$expected.new" "$expected"
        echo "baseline: $expected has $(grep -vc '^#' "$expected") lines"
    else
        echo "baseline: no hashes to record (did the projects pass?)"
    fi
fi

if [ ${#failed[@]} -gt 0 ]; then
    printf '\nFailed: %s\n' "${failed[*]}" | tee -a "$summary"
    for f in "${failed[@]}"; do echo "::error::$f failed"; done
    exit 1
fi
