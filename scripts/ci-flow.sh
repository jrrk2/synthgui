#!/bin/bash
# Run the flow of each project headless, every step but programming (no board in CI), and say which steps failed.
#
#   scripts/ci-flow.sh PROJECT...           e.g. sonata_johnson johnson (projects/NAME.json)
#   SYNTHGUI=path  ARTIFACTS=dir            the synthgui to run (default build/synthgui); where to copy each project's
#                                           logs and bitstream (default none)
#
# The step table goes to stdout and, under GitHub Actions, to the job summary. Exits 1 if any step of any project failed.
set -u
cd "$(dirname "$0")/.."
bin=${SYNTHGUI:-build/synthgui}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
export QT_QPA_PLATFORM=offscreen
failed=()

printf '| project | step | result | seconds |\n| --- | --- | --- | --- |\n' | tee -a "$summary"
for name in "$@"; do
    p=projects/$name.json
    ids=$(jq -r '[.steps[].id | select(startswith("program") | not)] | join(",")' "$p")
    work=$(jq -r .work "$p"); work=${work/#\~/$HOME}
    rm -rf "$work"                         # every run from scratch
    echo "::group::$name: $ids"
    t0=$(date +%s)
    "$bin" --project "$p" --run "$ids"
    rc=$?
    echo "::endgroup::"
    for id in ${ids//,/ }; do
        if [ -f "$work/$id.status" ]; then
            read -r code secs < "$work/$id.status"
            if [ "$code" = 0 ]; then res=ok; else res="**FAILED** ($code)"; failed+=("$name/$id"); fi
        else
            res="not run"; secs=
        fi
        printf '| %s | %s | %s | %s |\n' "$name" "$id" "$res" "$secs" | tee -a "$summary"
    done
    # a failure that left no .status (synthgui itself failed) still fails the run
    [ $rc = 0 ] || [ ${#failed[@]} -gt 0 ] || failed+=("$name (synthgui exit $rc after $(( $(date +%s) - t0 )) s)")
    if [ -n "${ARTIFACTS:-}" ] && [ -d "$work" ]; then
        mkdir -p "$ARTIFACTS/$name"
        cp "$work"/*.log "$work"/*.status "$ARTIFACTS/$name/" 2>/dev/null
        cp "$work"/*.bit "$work"/*.uf2 "$ARTIFACTS/$name/" 2>/dev/null
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    printf '\nFailed: %s\n' "${failed[*]}" | tee -a "$summary"
    for f in "${failed[@]}"; do echo "::error::$f failed"; done
    exit 1
fi
