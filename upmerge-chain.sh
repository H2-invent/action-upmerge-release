#!/usr/bin/env bash
#
# upmerge-chain.sh
#
# Zieht eine komplette Upmerge-Kette in EINEM Lauf durch:
#
#   main  -> release/<niedrigste>  -> release/<naechsthoehere> -> ...
#
# oder, wenn direkt ein release/X.Y Branch der Auslöser war:
#
#   release/X.Y -> release/<naechsthoehere> -> ...
#
# Läuft so lange weiter, bis entweder alle Branches durch sind, oder
# ein Hop fehlschlägt (Merge-Konflikt oder Push abgelehnt, z.B. durch
# Branch-Protection). In diesem Fall wird EIN Fallback-PR für genau
# diesen Hop erstellt (idempotent - kein Duplikat, wenn schon einer
# offen ist) und die Kette dort gestoppt.
#
# Anders als eine Lösung über mehrere Jobs/Workflow-Läufe ist das hier
# bewusst EIN Skript in einem Job: ein Push mit GITHUB_TOKEN löst
# keinen neuen Workflow-Lauf aus, daher darf die Kette nicht von einem
# zweiten Trigger abhängen.
#
# Ergebnis wird laufend in $GITHUB_STEP_SUMMARY protokolliert.
#
# Erwartete Umgebungsvariablen:
#   GITHUB_EVENT_NAME   "pull_request" oder "push"
#   PR_MERGED           nur bei pull_request: github.event.pull_request.merged
#   BASE_REF            bei pull_request: github.event.pull_request.base.ref
#                        bei push: github.ref_name
#   GH_TOKEN            Token für die gh CLI (Fallback-PR-Erstellung)
#
# Voraussetzung: actions/checkout mit fetch-depth: 0 und einem Token
# mit Push-Recht auf die Ziel-Branches; gh CLI verfügbar (ist auf
# GitHub-hosted Runnern vorinstalliert).

set -uo pipefail

MAIN_BRANCH_REGEX='^(main|master)$'
RELEASE_BRANCH_REGEX='^release/([0-9]+)\.([0-9]+)$'

: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME muss gesetzt sein}"
: "${BASE_REF:?BASE_REF muss gesetzt sein}"

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# --- Vorprüfung: nur bei echtem Merge weiterlaufen -------------------------
if [ "${GITHUB_EVENT_NAME}" = "pull_request" ]; then
  : "${PR_MERGED:?Bei pull_request muss PR_MERGED gesetzt sein}"
  if [ "${PR_MERGED}" != "true" ]; then
    echo "PR wurde geschlossen, aber nicht gemerged - keine Upmerge-Kette." >&2
    exit 0
  fi
elif [ "${GITHUB_EVENT_NAME}" != "push" ]; then
  echo "::error::Nur GITHUB_EVENT_NAME=pull_request oder push wird unterstützt." >&2
  exit 1
fi

git fetch --quiet origin --tags --force || true
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
# Verhindert, dass reine Datei-Mode-Änderungen (z.B. chmod +x auf dieses
# Skript selbst im Workflow) als "lokale Änderung" gewertet werden und
# spätere `git checkout -B` Aufrufe blockieren.
git config core.fileMode false
git reset --hard --quiet || true

# Liefert alle release/X.Y Versionen (nur "X.Y", ohne Prefix), aufsteigend sortiert.
all_release_versions() {
  git ls-remote --heads origin 'release/*' \
    | sed 's#.*refs/heads/##' \
    | grep -E '^release/[0-9]+\.[0-9]+$' \
    | sed 's#release/##' \
    | sort -t. -k1,1n -k2,2n
}

# Liefert alle Versionen strikt größer als $1 ("X.Y"), aufsteigend sortiert.
release_versions_greater_than() {
  local base="$1"
  all_release_versions | awk -v base="$base" '
    function ver(v,  a){split(v,a,"."); return a[1]*100000+a[2]}
    { if (ver($0) > ver(base)) print }
  '
}

# --- Kette aufbauen ---------------------------------------------------------
declare -a TARGETS=()
START_SOURCE=""

if [[ "$BASE_REF" =~ $MAIN_BRANCH_REGEX ]]; then
  START_SOURCE="$BASE_REF"
  lowest="$(all_release_versions | head -n1)"

  if [ -z "$lowest" ]; then
    {
      echo "## Upmerge-Kette"
      echo ""
      echo "Kein Branch im Format \`release/X.Y\` gefunden - nichts zu tun."
    } >> "$SUMMARY"
    echo "Kein release/X.Y Branch gefunden - nichts zu tun." >&2
    exit 0
  fi

  TARGETS+=("release/${lowest}")
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    TARGETS+=("release/${v}")
  done < <(release_versions_greater_than "$lowest")

elif [[ "$BASE_REF" =~ $RELEASE_BRANCH_REGEX ]]; then
  START_SOURCE="$BASE_REF"
  base_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"

  while IFS= read -r v; do
    [ -z "$v" ] && continue
    TARGETS+=("release/${v}")
  done < <(release_versions_greater_than "$base_version")

else
  echo "::error::Branch '${BASE_REF}' passt weder auf main/master noch auf release/X.Y." >&2
  exit 1
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  {
    echo "## Upmerge-Kette"
    echo ""
    echo "Kein höherer Release-Branch als \`${BASE_REF}\` gefunden - nichts zu tun."
  } >> "$SUMMARY"
  echo "Kein höherer Release-Branch als ${BASE_REF} - nichts zu tun." >&2
  exit 0
fi

# --- Einen Hop versuchen: setzt HOP_STATUS auf merged|uptodate|failed ------
attempt_hop() {
  local source="$1" target="$2"

  git reset --hard --quiet 2>/dev/null || true
  git fetch --quiet origin "${source}" "${target}"
  git checkout -B chain-work "origin/${target}" --quiet

  if git merge-base --is-ancestor "origin/${source}" "origin/${target}"; then
    HOP_STATUS="uptodate"
    return
  fi

  if git merge --no-ff "origin/${source}" -m "Merge ${source} into ${target} (upmerge-chain)" --quiet 2>/tmp/merge-error.log \
     && git push origin "HEAD:${target}" --quiet 2>>/tmp/merge-error.log; then
    HOP_STATUS="merged"
  else
    git merge --abort 2>/dev/null || true
    HOP_STATUS="failed"
  fi
}

# Idempotent: existierenden offenen PR wiederverwenden statt Duplikat zu erzeugen.
ensure_fallback_pr() {
  local tmp="$1" source="$2" target="$2"
  local url
  echo "Tmp Branch: $tmp"
  echo "Source Branch: $source"
  echo "Base Branch: $target"
  url="$(gh pr list --head "${tmp}" --base "${target}" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"

  if [ -n "$url" ]; then
    echo "$url"
    return
  fi

  gh pr create \
    --base "${target}" \
    --head "${tmp}" \
    --title "Upmerge ${source} -> ${target}" \
    --body "Automatischer Upmerge ist hier gestoppt (Konflikt oder Push nicht möglich, z.B. Branch-Protection). Bitte manuell auflösen und mergen - danach läuft die Kette beim nächsten Trigger automatisch weiter." \
    2>/dev/null | tail -n1
}

# --- Kette durchlaufen -------------------------------------------------------
{
  echo "## Upmerge-Kette"
  echo ""
  echo "Start: \`${START_SOURCE}\`"
  echo ""
  echo "| Hop | Von | Nach | Ergebnis |"
  echo "|---|---|---|---|"
} >> "$SUMMARY"

current_source="$START_SOURCE"
hop_number=0
stopped_at=""
exit_code=0

for target in "${TARGETS[@]}"; do
  hop_number=$((hop_number + 1))

  attempt_hop "$current_source" "$target"

  case "$HOP_STATUS" in
    uptodate)
      echo "| ${hop_number} | \`${current_source}\` | \`${target}\` | ✅ bereits aktuell (kein Merge nötig) |" >> "$SUMMARY"
      current_source="$target"
      ;;
    merged)
      echo "| ${hop_number} | \`${current_source}\` | \`${target}\` | ✅ gemerged & gepusht |" >> "$SUMMARY"
      current_source="$target"
      ;;
    failed)
      git checkout $current_source
      tmp=upmerge/$(date +%d%m%Y%H%M%S)
      git checkout -b "$tmp"
      git push -u origin "$tmp"
      pr_url="$(ensure_fallback_pr "$tmp" "$current_source" "$target")"
      if [ -n "$pr_url" ]; then
        echo "| ${hop_number} | \`${current_source}\` | \`${target}\` | ❌ Konflikt/Push abgelehnt - Fallback-PR: ${pr_url} |" >> "$SUMMARY"
      else
        echo "| ${hop_number} | \`${current_source}\` | \`${target}\` | ❌ Konflikt/Push abgelehnt - Fallback-PR konnte nicht erstellt werden |" >> "$SUMMARY"
      fi
      stopped_at="$target"
      exit_code=1
      break
      ;;
  esac
done

if [ -n "$stopped_at" ]; then
  remaining=()
  found_stop=false
  for t in "${TARGETS[@]}"; do
    if [ "$found_stop" = "true" ]; then
      remaining+=("$t")
    fi
    if [ "$t" = "$stopped_at" ]; then
      found_stop=true
    fi
  done
  if [ "${#remaining[@]}" -gt 0 ]; then
    {
      echo ""
      echo "Übersprungen (hängen von \`${stopped_at}\` ab): $(printf '\`%s\` ' "${remaining[@]}")"
    } >> "$SUMMARY"
  fi
  echo "Kette gestoppt bei ${stopped_at}." >&2
else
  echo "" >> "$SUMMARY"
  echo "Alle Hops erfolgreich durchgelaufen bis \`${current_source}\`." >> "$SUMMARY"
  echo "Kette komplett durchgelaufen." >&2
fi

exit "$exit_code"