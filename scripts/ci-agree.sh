#!/bin/bash
# Do the platforms of one CI run produce the same bitstreams?
#
#   scripts/ci-agree.sh DIR      DIR holds the run's flow artifacts, one directory each (flow-<project> from the Linux
#                                matrix, flow-macos, flow-windows ...), each with <project>/hashes.txt as scripts/ci-flow.sh
#                                writes it: "<project> frames <sha256> <tools key>"
#   AGREE_GATE=1                 exit 1 when two platforms disagree on a project (default: report only)
#
# This is the cross-platform check, independent of ci/expected: every platform in the run built the same commit with the
# same submodules, so the same project should give the same frames everywhere.  A project only one platform ran is listed
# and not compared.  The table goes to stdout and, under GitHub Actions, to the job summary.
set -u
dir=${1:?usage: ci-agree.sh DIR}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

# artifact directory name -> platform: flow-macos -> macos, flow-windows -> windows, flow-<project> -> linux
platform_of() {
    case "$1" in
        flow-macos*) echo macos ;;
        flow-windows*) echo windows ;;
        *) echo linux ;;
    esac
}

table=$(mktemp)
for f in "$dir"/*/*/hashes.txt; do
    [ -f "$f" ] || continue
    art=$(basename "$(dirname "$(dirname "$f")")")
    plat=$(platform_of "$art")
    awk -v p="$plat" '$2 == "frames" {print $1, p, $3, $4}' "$f" >> "$table"
done

if [ ! -s "$table" ]; then
    echo "agree: no hashes found under $dir" | tee -a "$summary"
    exit 0
fi

out=$(mktemp)
printf '| project | platforms | frames | result |\n| --- | --- | --- | --- |\n' > "$out"
for proj in $(cut -d' ' -f1 "$table" | sort -u); do
    rows=$(awk -v n="$proj" '$1 == n' "$table" | sort -u -k2,2)
    plats=$(echo "$rows" | awk '{print $2}' | paste -sd' ' -)
    hashes=$(echo "$rows" | awk '{print $2 "=" substr($3, 1, 12)}' | paste -sd' ' -)
    n=$(echo "$rows" | wc -l)
    distinct=$(echo "$rows" | awk '{print $3}' | sort -u | wc -l)
    if [ "$n" -lt 2 ]; then res="one platform only"
    elif [ "$distinct" -eq 1 ]; then res="agree"
    else res="**DIFFER**"
    fi
    printf '| %s | %s | %s | %s |\n' "$proj" "$plats" "$hashes" "$res" >> "$out"
done
tee -a "$summary" < "$out"
disagree=$(grep -c '\*\*DIFFER\*\*' "$out")
rm -f "$table" "$out"

if [ "$disagree" -gt 0 ]; then
    printf '\n%d project(s) differ between platforms\n' "$disagree" | tee -a "$summary"
    [ "${AGREE_GATE:-0}" = 1 ] && exit 1
fi
exit 0
