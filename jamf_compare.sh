#!/usr/bin/env bash
# =============================================================================
#  jamf_compare.sh  —  Compare two Jamf Pro computer records side-by-side
#  Policies: fetched via full policy scan + scope matching (Option A)
#  Outputs a self-contained HTML report.
# =============================================================================
set -euo pipefail
trap 'echo -e "\033[0;31m✖  Script exited at line $LINENO (exit code $?)\033[0m" >&2' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

err()      { echo -e "${RED}✖  $*${RESET}" >&2; }
info()     { echo -e "${CYAN}→  $*${RESET}"; }
ok()       { echo -e "${GREEN}✔  $*${RESET}"; }
progress() { echo -ne "${CYAN}   $*${RESET}\r"; }

# ── Hardcoded defaults — fill these in to skip all prompts ────────────────────
JAMF_URL="${JAMF_URL:-}"
JAMF_USER="${JAMF_USER:-}"
JAMF_PASS="${JAMF_PASS:-}"
ID1="${ID1:-}"
ID2="${ID2:-}"
DEBUG="${DEBUG:-true}"   # set to true (or export DEBUG=true) for verbose output

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl jq; do
  command -v "$cmd" &>/dev/null || { err "Required command not found: $cmd"; exit 1; }
done

# ── Credentials ───────────────────────────────────────────────────────────────
echo -e "\n${BOLD}╔══════════════════════════════════════╗"
echo    "║   Jamf Pro  •  Computer Comparator   ║"
echo -e "╚══════════════════════════════════════╝${RESET}\n"

if [[ -z "${JAMF_URL:-}" ]]; then
  read -rp "$(echo -e "${YELLOW}Jamf Pro URL${RESET} (e.g. https://acme.jamfcloud.com): ")" JAMF_URL
fi
JAMF_URL="${JAMF_URL%/}"

if [[ -z "${JAMF_USER:-}" ]]; then
  read -rp "$(echo -e "${YELLOW}Username${RESET}: ")" JAMF_USER
fi

if [[ -z "${JAMF_PASS:-}" ]]; then
  read -rsp "$(echo -e "${YELLOW}Password${RESET}: ")" JAMF_PASS
  echo
fi

# ── Computer IDs ──────────────────────────────────────────────────────────────
if [[ -z "${ID1:-}" ]]; then
  read -rp "$(echo -e "\n${YELLOW}Computer 1 ID${RESET}: ")" ID1
fi
if [[ -z "${ID2:-}" ]]; then
  read -rp "$(echo -e "${YELLOW}Computer 2 ID${RESET}: ")" ID2
fi

[[ "$ID1" =~ ^[0-9]+$ ]] || { err "Computer 1 ID must be numeric"; exit 1; }
[[ "$ID2" =~ ^[0-9]+$ ]] || { err "Computer 2 ID must be numeric"; exit 1; }

# ── Auth ──────────────────────────────────────────────────────────────────────
info "Authenticating with Jamf Pro…"
info "  URL : ${JAMF_URL}"
info "  User: ${JAMF_USER}"

_JAMF_TMP=$(mktemp)
_TOKEN_HTTP=$(curl -s -o "$_JAMF_TMP" -w "%{http_code}" \
  --request POST \
  --url "${JAMF_URL}/api/v1/auth/token" \
  --user "${JAMF_USER}:${JAMF_PASS}" \
  --header "Accept: application/json" 2>/dev/null) || _TOKEN_HTTP="000"

TOKEN_JSON=""
if [[ "$_TOKEN_HTTP" == "200" ]]; then
  TOKEN_JSON=$(cat "$_JAMF_TMP")
fi
rm -f "$_JAMF_TMP"

if [[ -n "$TOKEN_JSON" ]]; then
  TOKEN=$(echo "$TOKEN_JSON" | jq -r '.token // empty')
  if [[ -n "$TOKEN" ]]; then
    AUTH_HEADER="Authorization: Bearer ${TOKEN}"
    ok "Bearer token obtained (HTTP ${_TOKEN_HTTP})."
  else
    err "Token endpoint returned 200 but no token in response — check credentials."; exit 1
  fi
else
  if [[ "$_TOKEN_HTTP" == "401" ]]; then
    err "Authentication failed (HTTP 401) — wrong username or password."; exit 1
  elif [[ "$_TOKEN_HTTP" == "000" ]]; then
    err "Could not reach ${JAMF_URL} — check the URL and network."; exit 1
  else
    info "Bearer token unavailable (HTTP ${_TOKEN_HTTP}), falling back to HTTP Basic auth."
    AUTH_HEADER="Authorization: Basic $(echo -n "${JAMF_USER}:${JAMF_PASS}" | base64)"
  fi
fi

# ── API helper ────────────────────────────────────────────────────────────────
_JAMF_REQ_TMP=$(mktemp)
jamf_get() {
  local http_code body
  http_code=$(curl -s -o "$_JAMF_REQ_TMP" -w "%{http_code}" \
    --request GET \
    --url "${JAMF_URL}/JSSResource/${1}" \
    --header "$AUTH_HEADER" \
    --header "Accept: application/json" 2>/dev/null) || http_code="000"
  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    cat "$_JAMF_REQ_TMP"
  else
    err "HTTP ${http_code} fetching /JSSResource/${1}" >&2
    return 1
  fi
}

parse_value() { echo "$1" | jq -r "$2 // \"N/A\"" 2>/dev/null; }
parse_names()  { echo "$1" | jq -r "try ([$2 // []] | flatten | .[] | if type == \"string\" then . else (.name? // empty) end) catch empty" 2>/dev/null | grep -v '^$' | sort || true; }
dbg() { if [[ "$DEBUG" == "true" ]]; then echo -e "${YELLOW}  [DBG] $*${RESET}" >&2; fi; }
safe_jq() { echo "$1" | jq -r "$2" 2>/dev/null || true; }

# ── Fetch computer records ────────────────────────────────────────────────────
info "Fetching computer ${ID1}…"
RAW1=$(jamf_get "computers/id/${ID1}") || { err "Could not fetch computer ID ${ID1}."; exit 1; }
ok "Computer ${ID1} retrieved."
dbg "Groups type for ${ID1}: $(safe_jq "$RAW1" '.computer.groups_accounts.computer_group_memberships | type')"

info "Fetching computer ${ID2}…"
RAW2=$(jamf_get "computers/id/${ID2}") || { err "Could not fetch computer ID ${ID2}."; exit 1; }
ok "Computer ${ID2} retrieved."
dbg "Groups type for ${ID2}: $(safe_jq "$RAW2" '.computer.groups_accounts.computer_group_memberships | type')"

# ── Extract computer identity info needed for scope matching ──────────────────
NAME1=$(parse_value "$RAW1" '.computer.general.name')
NAME2=$(parse_value "$RAW2" '.computer.general.name')

# Get group memberships as newline-separated lists (used for scope matching)
GROUPS1_RAW=$(echo "$RAW1" | jq -r '.computer.groups_accounts.computer_group_memberships // [] | .[] | if type == "string" then . else (.name? // empty) end' 2>/dev/null) || GROUPS1_RAW=""
GROUPS2_RAW=$(echo "$RAW2" | jq -r '.computer.groups_accounts.computer_group_memberships // [] | .[] | if type == "string" then . else (.name? // empty) end' 2>/dev/null) || GROUPS2_RAW=""
dbg "Groups for ${ID1}: $(echo "$GROUPS1_RAW" | tr '\n' ',' || true)"
dbg "Groups for ${ID2}: $(echo "$GROUPS2_RAW" | tr '\n' ',' || true)"

# ── Policy scan ───────────────────────────────────────────────────────────────
info "Fetching all policy IDs (this may take a moment)…"
ALL_POLICIES_JSON=$(jamf_get "policies") || { err "Could not fetch policy list."; exit 1; }
POLICY_IDS=$(echo "$ALL_POLICIES_JSON" | jq -r '.policies // [] | .[].id' 2>/dev/null)
TOTAL_POLICIES=$(echo "$POLICY_IDS" | grep -c '[0-9]' || echo 0)
ok "Found ${TOTAL_POLICIES} policies to scan."

# Function: check if a computer is in scope for a given policy JSON
# Args: policy_json  computer_id  groups_newline_separated
computer_in_scope() {
  local pjson="$1"
  local cid="$2"
  local cgroups="$3"

  # Check if policy is enabled
  local enabled
  enabled=$(echo "$pjson" | jq -r '.policy.general.enabled // "false"')
  if [[ "$enabled" == "false" ]]; then return 1; fi

  local all_computers
  all_computers=$(echo "$pjson" | jq -r '.policy.scope.all_computers // "false"')
  if [[ "$all_computers" == "true" ]]; then return 0; fi

  # Check direct computer membership
  local direct_ids
  direct_ids=$(echo "$pjson" | jq -r '.policy.scope.computers // [] | .[].id' 2>/dev/null)
  if echo "$direct_ids" | grep -qx "$cid"; then return 0; fi

  # Check computer group membership
  local scoped_groups
  scoped_groups=$(echo "$pjson" | jq -r '.policy.scope.computer_groups // [] | .[].name' 2>/dev/null)
  while IFS= read -r grp; do
    if [[ -z "$grp" ]]; then continue; fi
    if echo "$cgroups" | grep -qxF "$grp"; then return 0; fi
  done <<< "$scoped_groups"

  # Check exclusions — if excluded, not in scope
  local excl_ids
  excl_ids=$(echo "$pjson" | jq -r '.policy.scope.exclusions.computers // [] | .[].id' 2>/dev/null)
  if echo "$excl_ids" | grep -qx "$cid"; then return 1; fi

  local excl_groups
  excl_groups=$(echo "$pjson" | jq -r '.policy.scope.exclusions.computer_groups // [] | .[].name' 2>/dev/null)
  while IFS= read -r grp; do
    if [[ -z "$grp" ]]; then continue; fi
    if echo "$cgroups" | grep -qxF "$grp"; then return 1; fi
  done <<< "$excl_groups"

  return 1
}

# Scan every policy
POLICIES1=""
POLICIES2=""
IDX=0

while IFS= read -r pid; do
  if [[ -z "$pid" ]]; then continue; fi
  IDX=$((IDX + 1))
  progress "Scanning policy ${IDX}/${TOTAL_POLICIES} (ID: ${pid})…"

  PJSON=$(jamf_get "policies/id/${pid}" 2>/dev/null) || continue
  PNAME=$(echo "$PJSON" | jq -r '.policy.general.name // empty' 2>/dev/null)
  if [[ -z "$PNAME" ]]; then continue; fi

  IN1=false; IN2=false
  computer_in_scope "$PJSON" "$ID1" "$GROUPS1_RAW" && IN1=true || true
  computer_in_scope "$PJSON" "$ID2" "$GROUPS2_RAW" && IN2=true || true

  if [[ "$IN1" == "true" ]]; then POLICIES1="${POLICIES1}${PNAME}"$'\n'; fi
  if [[ "$IN2" == "true" ]]; then POLICIES2="${POLICIES2}${PNAME}"$'\n'; fi

done <<< "$POLICY_IDS"

echo -e "\n"  # clear progress line
ok "Policy scan complete."

# Sort them
POLICIES1=$(echo "$POLICIES1" | sort | grep -v '^$' || true)
POLICIES2=$(echo "$POLICIES2" | sort | grep -v '^$' || true)

# ── Groups & Profiles ─────────────────────────────────────────────────────────
GROUPS1=$(parse_names "$RAW1" '.computer.groups_accounts.computer_group_memberships')
GROUPS2=$(parse_names "$RAW2" '.computer.groups_accounts.computer_group_memberships')

# Build profile ID→name map from the full profile library
info "Fetching configuration profile names…"
ALL_CFG_JSON=$(jamf_get "osxconfigurationprofiles") || ALL_CFG_JSON=""
PROFILE_NAME_MAP=$(echo "$ALL_CFG_JSON" | jq -r '
  .os_x_configuration_profiles // [] |
  map({key: (.id | tostring), value: .name}) | from_entries
' 2>/dev/null) || PROFILE_NAME_MAP="{}"
dbg "Profile name map entries: $(echo "$PROFILE_NAME_MAP" | jq -r 'keys | length' 2>/dev/null || true)"

# Resolve names via the map; skip negative IDs (MDM-managed, not in library)
PROF_RAW1=$(jamf_get "computers/id/${ID1}/subset/ConfigurationProfiles") || PROF_RAW1=""
PROF_RAW2=$(jamf_get "computers/id/${ID2}/subset/ConfigurationProfiles") || PROF_RAW2=""

resolve_profiles() {
  local raw="$1"
  echo "$raw" | jq -r --argjson map "$PROFILE_NAME_MAP" '
    .computer.configuration_profiles // [] |
    .[] | select(.id > 0) |
    .id | tostring | $map[.] // empty
  ' 2>/dev/null | grep -v '^$' | sort || true
}

PROFILES1=$(resolve_profiles "$PROF_RAW1") || PROFILES1=""
PROFILES2=$(resolve_profiles "$PROF_RAW2") || PROFILES2=""
dbg "Profiles resolved for ${ID1}: $(echo "$PROFILES1" | head -3 | tr '\n' '|' || true)"
dbg "Profiles resolved for ${ID2}: $(echo "$PROFILES2" | head -3 | tr '\n' '|' || true)"

# ── Diff helpers ──────────────────────────────────────────────────────────────
only_in() { comm -23 <(echo "$1" | sort) <(echo "$2" | sort) 2>/dev/null || true; }
in_both()  { comm -12 <(echo "$1" | sort) <(echo "$2" | sort) 2>/dev/null || true; }

POLICIES_BOTH=$(in_both "$POLICIES1" "$POLICIES2")
POLICIES_ONLY1=$(only_in "$POLICIES1" "$POLICIES2")
POLICIES_ONLY2=$(only_in "$POLICIES2" "$POLICIES1")

GROUPS_BOTH=$(in_both "$GROUPS1" "$GROUPS2")
GROUPS_ONLY1=$(only_in "$GROUPS1" "$GROUPS2")
GROUPS_ONLY2=$(only_in "$GROUPS2" "$GROUPS1")

PROFILES_BOTH=$(in_both "$PROFILES1" "$PROFILES2")
PROFILES_ONLY1=$(only_in "$PROFILES1" "$PROFILES2")
PROFILES_ONLY2=$(only_in "$PROFILES2" "$PROFILES1")

# ── General info ──────────────────────────────────────────────────────────────
SERIAL1=$(parse_value "$RAW1" '.computer.general.serial_number')
SERIAL2=$(parse_value "$RAW2" '.computer.general.serial_number')
MODEL1=$(parse_value  "$RAW1" '.computer.hardware.model')
MODEL2=$(parse_value  "$RAW2" '.computer.hardware.model')
OS1=$(parse_value     "$RAW1" '.computer.hardware.os_version')
OS2=$(parse_value     "$RAW2" '.computer.hardware.os_version')
LASTSEEN1=$(parse_value "$RAW1" '.computer.general.last_contact_time')
LASTSEEN2=$(parse_value "$RAW2" '.computer.general.last_contact_time')
USER1=$(parse_value   "$RAW1" '.computer.location.username')
USER2=$(parse_value   "$RAW2" '.computer.location.username')
DEPT1=$(parse_value   "$RAW1" '.computer.location.department')
DEPT2=$(parse_value   "$RAW2" '.computer.location.department')
IP1=$(parse_value     "$RAW1" '.computer.general.ip_address')
IP2=$(parse_value     "$RAW2" '.computer.general.ip_address')
MANAGED1=$(parse_value "$RAW1" '.computer.general.remote_management.managed')
MANAGED2=$(parse_value "$RAW2" '.computer.general.remote_management.managed')

managed_badge() {
  if [[ "$1" == "true" ]]; then echo '<span class="managed-yes">✔ Managed</span>'
  else echo '<span class="managed-no">✖ Unmanaged</span>'; fi
}
MB1=$(managed_badge "$MANAGED1")
MB2=$(managed_badge "$MANAGED2")

# ── Counts ────────────────────────────────────────────────────────────────────
count_lines() { echo "$1" | grep -c '[^[:space:]]' 2>/dev/null || true; }

pc_both=$(count_lines "$POLICIES_BOTH"); pc_1=$(count_lines "$POLICIES_ONLY1"); pc_2=$(count_lines "$POLICIES_ONLY2")
gc_both=$(count_lines "$GROUPS_BOTH");   gc_1=$(count_lines "$GROUPS_ONLY1");   gc_2=$(count_lines "$GROUPS_ONLY2")
prc_both=$(count_lines "$PROFILES_BOTH"); prc_1=$(count_lines "$PROFILES_ONLY1"); prc_2=$(count_lines "$PROFILES_ONLY2")

REPORT_DATE=$(date "+%Y-%m-%d %H:%M:%S %Z")
OUTPUT_FILE="jamf_compare_${ID1}_vs_${ID2}_$(date +%Y%m%d_%H%M%S).html"

# ── HTML row builders ─────────────────────────────────────────────────────────
build_rows_split() {
  local both="$1" only1="$2" only2="$3" label1="$4" label2="$5"
  local rows=""
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    rows+="<tr class=\"row-both\"><td><span class=\"dot dot-both\"></span>$(echo "$line" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</td><td><span class=\"badge badge-both\">Both</span></td></tr>"
  done <<< "$both"
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    rows+="<tr class=\"row-only1\"><td><span class=\"dot dot-only1\"></span>$(echo "$line" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</td><td><span class=\"badge badge-only1\">${label1} only</span></td></tr>"
  done <<< "$only1"
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    rows+="<tr class=\"row-only2\"><td><span class=\"dot dot-only2\"></span>$(echo "$line" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</td><td><span class=\"badge badge-only2\">${label2} only</span></td></tr>"
  done <<< "$only2"
  if [[ -z "$rows" ]]; then
    echo '<tr><td colspan="2" class="empty-row">No data found</td></tr>'
  else
    echo "$rows"
  fi
}

POLICY_ROWS=$(build_rows_split  "$POLICIES_BOTH" "$POLICIES_ONLY1" "$POLICIES_ONLY2" "$NAME1" "$NAME2")
GROUP_ROWS=$(build_rows_split   "$GROUPS_BOTH"   "$GROUPS_ONLY1"   "$GROUPS_ONLY2"   "$NAME1" "$NAME2")
PROFILE_ROWS=$(build_rows_split "$PROFILES_BOTH" "$PROFILES_ONLY1" "$PROFILES_ONLY2" "$NAME1" "$NAME2")

info "Generating HTML report…"

# ── Write HTML ────────────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Jamf Compare — ${NAME1} vs ${NAME2}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@300;400;600;700&display=swap');

  :root {
    --bg:        #0d0f14;
    --surface:   #13161e;
    --surface2:  #1a1e28;
    --border:    #252a36;
    --text:      #cdd6f4;
    --muted:     #6c7086;
    --accent:    #89b4fa;
    --green:     #a6e3a1;
    --red:       #f38ba8;
    --yellow:    #f9e2af;
    --mauve:     #cba6f7;
    --teal:      #94e2d5;
    --both:      #89b4fa;
    --only1:     #a6e3a1;
    --only2:     #f38ba8;
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    font-family: 'IBM Plex Sans', sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    line-height: 1.6;
  }

  header {
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    padding: 2rem 3rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 2rem;
    flex-wrap: wrap;
  }
  .header-logo { display: flex; align-items: center; gap: 1rem; }
  .header-logo svg { width: 42px; height: 42px; }
  .header-title h1 { font-size: 1.4rem; font-weight: 700; letter-spacing: -0.02em; color: #fff; }
  .header-title p  { font-size: 0.78rem; color: var(--muted); font-family: 'IBM Plex Mono', monospace; }
  .header-meta { font-family: 'IBM Plex Mono', monospace; font-size: 0.72rem; color: var(--muted); text-align: right; }

  main { max-width: 1300px; margin: 0 auto; padding: 2.5rem 3rem; }

  .computer-grid {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    gap: 1.5rem;
    align-items: center;
    margin-bottom: 3rem;
  }
  .vs-divider { font-family: 'IBM Plex Mono', monospace; font-size: 1.5rem; font-weight: 600; color: var(--muted); text-align: center; }

  .computer-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 1.75rem;
    position: relative;
    overflow: hidden;
  }
  .computer-card::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 3px; }
  .computer-card.card-1::before { background: linear-gradient(90deg, var(--only1), transparent); }
  .computer-card.card-2::before { background: linear-gradient(90deg, var(--only2), transparent); }
  .computer-card h2 { font-size: 1.1rem; font-weight: 700; color: #fff; margin-bottom: 1rem; display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; }
  .id-chip { font-family: 'IBM Plex Mono', monospace; font-size: 0.7rem; background: var(--surface2); border: 1px solid var(--border); padding: 2px 8px; border-radius: 999px; color: var(--muted); }
  .detail-grid { display: grid; grid-template-columns: auto 1fr; gap: 0.35rem 1.2rem; font-size: 0.83rem; }
  .detail-grid .label { color: var(--muted); white-space: nowrap; }
  .detail-grid .value { color: var(--text); font-family: 'IBM Plex Mono', monospace; font-size: 0.78rem; word-break: break-all; }
  .managed-yes { color: var(--green); font-weight: 600; font-size: 0.78rem; }
  .managed-no  { color: var(--red);   font-weight: 600; font-size: 0.78rem; }

  .stat-bar { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; margin-bottom: 3rem; }
  .stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 1.25rem 1.5rem; }
  .stat-card h3 { font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); margin-bottom: 0.75rem; }
  .stat-numbers { display: flex; gap: 1rem; align-items: baseline; flex-wrap: wrap; }
  .stat-num { font-family: 'IBM Plex Mono', monospace; font-size: 1.6rem; font-weight: 600; }
  .stat-num.n-both  { color: var(--both); }
  .stat-num.n-only1 { color: var(--only1); }
  .stat-num.n-only2 { color: var(--only2); }
  .stat-label { font-size: 0.68rem; color: var(--muted); white-space: nowrap; }
  .stat-sub { display: flex; flex-direction: column; gap: 0.15rem; }

  .note-banner {
    background: rgba(249,226,175,0.08);
    border: 1px solid rgba(249,226,175,0.2);
    border-radius: 8px;
    padding: 0.75rem 1.25rem;
    font-size: 0.8rem;
    color: var(--yellow);
    margin-bottom: 2rem;
    display: flex;
    gap: 0.6rem;
    align-items: flex-start;
  }

  .section { margin-bottom: 2.5rem; }
  .section-header {
    display: flex; align-items: center; gap: 0.75rem;
    padding-bottom: 0.6rem; border-bottom: 1px solid var(--border);
    cursor: pointer; user-select: none;
  }
  .section-header:hover { opacity: 0.85; }
  .section-header h2 { font-size: 1rem; font-weight: 700; color: #fff; flex: 1; }
  .section-chevron {
    margin-left: auto; color: var(--muted); font-size: 0.75rem;
    transition: transform 0.2s ease;
  }
  .section.collapsed .section-chevron { transform: rotate(-90deg); }
  .section-body { margin-top: 1rem; }
  .section.collapsed .section-body { display: none; }
  .icon { width: 28px; height: 28px; border-radius: 7px; display: grid; place-items: center; font-size: 0.9rem; }
  .icon-policy  { background: rgba(137,180,250,0.15); }
  .icon-group   { background: rgba(166,227,161,0.15); }
  .icon-profile { background: rgba(203,166,247,0.15); }

  .table-wrap { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; overflow: hidden; }
  table { width: 100%; border-collapse: collapse; }
  thead th { background: var(--surface2); font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); padding: 0.65rem 1.25rem; text-align: left; border-bottom: 1px solid var(--border); }
  tbody tr { border-bottom: 1px solid var(--border); transition: background 0.15s; }
  tbody tr:last-child { border-bottom: none; }
  tbody tr:hover { background: var(--surface2); }
  td { padding: 0.65rem 1.25rem; font-size: 0.85rem; vertical-align: middle; }
  td:last-child { width: 140px; text-align: right; }
  .empty-row { color: var(--muted); font-style: italic; text-align: center !important; padding: 1.5rem !important; }

  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 0.6rem; flex-shrink: 0; vertical-align: middle; }
  .dot-both  { background: var(--both); }
  .dot-only1 { background: var(--only1); }
  .dot-only2 { background: var(--only2); }

  .badge { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 0.72rem; font-weight: 600; font-family: 'IBM Plex Mono', monospace; letter-spacing: 0.02em; }
  .badge-both  { background: rgba(137,180,250,0.15); color: var(--both);  border: 1px solid rgba(137,180,250,0.3); }
  .badge-only1 { background: rgba(166,227,161,0.15); color: var(--only1); border: 1px solid rgba(166,227,161,0.3); }
  .badge-only2 { background: rgba(243,139,168,0.15); color: var(--only2); border: 1px solid rgba(243,139,168,0.3); }

  .legend { display: flex; gap: 1.5rem; margin-bottom: 2rem; flex-wrap: wrap; }
  .legend-item { display: flex; align-items: center; gap: 0.5rem; font-size: 0.8rem; color: var(--muted); }

  .filter-bar { display: flex; gap: 0.5rem; margin-bottom: 0.75rem; flex-wrap: wrap; }
  .filter-btn { background: var(--surface2); border: 1px solid var(--border); color: var(--muted); padding: 4px 14px; border-radius: 999px; font-size: 0.75rem; font-family: 'IBM Plex Mono', monospace; cursor: pointer; transition: all 0.15s; }
  .filter-btn:hover, .filter-btn.active { border-color: var(--accent); color: var(--accent); background: rgba(137,180,250,0.1); }

  .search-box { width: 100%; background: var(--surface2); border: 1px solid var(--border); color: var(--text); padding: 0.5rem 1rem; border-radius: 8px; font-size: 0.85rem; font-family: 'IBM Plex Sans', sans-serif; margin-bottom: 0.75rem; outline: none; transition: border-color 0.15s; }
  .search-box:focus { border-color: var(--accent); }
  .search-box::placeholder { color: var(--muted); }

  footer { border-top: 1px solid var(--border); padding: 1.5rem 3rem; text-align: center; font-size: 0.75rem; color: var(--muted); font-family: 'IBM Plex Mono', monospace; }

  .row-only1 td:first-child { border-left: 2px solid var(--only1); }
  .row-only2 td:first-child { border-left: 2px solid var(--only2); }
  .row-both  td:first-child { border-left: 2px solid var(--both); }
</style>
</head>
<body>

<header>
  <div class="header-logo">
    <svg viewBox="0 0 42 42" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="42" height="42" rx="10" fill="#1a1e28"/>
      <rect x="7" y="10" width="28" height="18" rx="3" stroke="#89b4fa" stroke-width="1.5"/>
      <rect x="14" y="28" width="14" height="3" fill="#89b4fa" rx="1"/>
      <rect x="11" y="30" width="20" height="2" fill="#6c7086" rx="1"/>
      <circle cx="30" cy="30" r="7" fill="#0d0f14" stroke="#a6e3a1" stroke-width="1.5"/>
      <line x1="27" y1="30" x2="33" y2="30" stroke="#a6e3a1" stroke-width="1.5" stroke-linecap="round"/>
      <line x1="30" y1="27" x2="30" y2="33" stroke="#f38ba8" stroke-width="1.5" stroke-linecap="round"/>
    </svg>
    <div class="header-title">
      <h1>Jamf Pro — Computer Comparison</h1>
      <p>Generated ${REPORT_DATE} &nbsp;•&nbsp; ${TOTAL_POLICIES} policies scanned</p>
    </div>
  </div>
  <div class="header-meta">
    <div>Server: ${JAMF_URL}</div>
    <div>IDs: ${ID1} &amp; ${ID2}</div>
  </div>
</header>

<main>

  <div class="computer-grid">
    <div class="computer-card card-1">
      <h2>${NAME1} <span class="id-chip">ID ${ID1}</span></h2>
      <div class="detail-grid">
        <span class="label">Serial</span>    <span class="value">${SERIAL1}</span>
        <span class="label">Model</span>     <span class="value">${MODEL1}</span>
        <span class="label">macOS</span>     <span class="value">${OS1}</span>
        <span class="label">IP</span>        <span class="value">${IP1}</span>
        <span class="label">User</span>      <span class="value">${USER1}</span>
        <span class="label">Dept</span>      <span class="value">${DEPT1}</span>
        <span class="label">Last Seen</span> <span class="value">${LASTSEEN1}</span>
        <span class="label">MDM</span>       <span class="value">${MB1}</span>
      </div>
    </div>
    <div class="vs-divider">VS</div>
    <div class="computer-card card-2">
      <h2>${NAME2} <span class="id-chip">ID ${ID2}</span></h2>
      <div class="detail-grid">
        <span class="label">Serial</span>    <span class="value">${SERIAL2}</span>
        <span class="label">Model</span>     <span class="value">${MODEL2}</span>
        <span class="label">macOS</span>     <span class="value">${OS2}</span>
        <span class="label">IP</span>        <span class="value">${IP2}</span>
        <span class="label">User</span>      <span class="value">${USER2}</span>
        <span class="label">Dept</span>      <span class="value">${DEPT2}</span>
        <span class="label">Last Seen</span> <span class="value">${LASTSEEN2}</span>
        <span class="label">MDM</span>       <span class="value">${MB2}</span>
      </div>
    </div>
  </div>

  <div class="stat-bar">
    <div class="stat-card">
      <h3>Policies (scoped)</h3>
      <div class="stat-numbers">
        <div class="stat-sub"><span class="stat-num n-both">${pc_both}</span><span class="stat-label">shared</span></div>
        <div class="stat-sub"><span class="stat-num n-only1">${pc_1}</span><span class="stat-label">${NAME1} only</span></div>
        <div class="stat-sub"><span class="stat-num n-only2">${pc_2}</span><span class="stat-label">${NAME2} only</span></div>
      </div>
    </div>
    <div class="stat-card">
      <h3>Groups</h3>
      <div class="stat-numbers">
        <div class="stat-sub"><span class="stat-num n-both">${gc_both}</span><span class="stat-label">shared</span></div>
        <div class="stat-sub"><span class="stat-num n-only1">${gc_1}</span><span class="stat-label">${NAME1} only</span></div>
        <div class="stat-sub"><span class="stat-num n-only2">${gc_2}</span><span class="stat-label">${NAME2} only</span></div>
      </div>
    </div>
    <div class="stat-card">
      <h3>Config Profiles</h3>
      <div class="stat-numbers">
        <div class="stat-sub"><span class="stat-num n-both">${prc_both}</span><span class="stat-label">shared</span></div>
        <div class="stat-sub"><span class="stat-num n-only1">${prc_1}</span><span class="stat-label">${NAME1} only</span></div>
        <div class="stat-sub"><span class="stat-num n-only2">${prc_2}</span><span class="stat-label">${NAME2} only</span></div>
      </div>
    </div>
  </div>

  <div class="note-banner">
    ℹ️ &nbsp;Policies are determined by live scope evaluation (direct assignment + group membership, minus exclusions). Only <strong>enabled</strong> policies are included. ${TOTAL_POLICIES} policies were scanned.
  </div>

  <div class="legend">
    <div class="legend-item"><span class="dot dot-both"></span> Present on both computers</div>
    <div class="legend-item"><span class="dot dot-only1"></span> ${NAME1} only</div>
    <div class="legend-item"><span class="dot dot-only2"></span> ${NAME2} only</div>
  </div>

  <!-- Policies -->
  <div class="section" id="sec-policies">
    <div class="section-header" onclick="toggleSection('sec-policies')">
      <div class="icon icon-policy">📋</div>
      <h2>Policies</h2>
      <span class="section-chevron">▼</span>
    </div>
    <div class="section-body">
      <input type="text" class="search-box" placeholder="Search policies…" oninput="searchTable('tbl-policies', this.value)">
      <div class="filter-bar">
        <button class="filter-btn active" onclick="filterTable('policies','all',this)">All</button>
        <button class="filter-btn" onclick="filterTable('policies','row-both',this)">Shared</button>
        <button class="filter-btn" onclick="filterTable('policies','row-only1',this)">${NAME1} only</button>
        <button class="filter-btn" onclick="filterTable('policies','row-only2',this)">${NAME2} only</button>
      </div>
      <div class="table-wrap">
        <table id="tbl-policies">
          <thead><tr><th>Policy Name</th><th>Scope</th></tr></thead>
          <tbody>${POLICY_ROWS}</tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- Groups -->
  <div class="section" id="sec-groups">
    <div class="section-header" onclick="toggleSection('sec-groups')">
      <div class="icon icon-group">👥</div>
      <h2>Computer Groups</h2>
      <span class="section-chevron">▼</span>
    </div>
    <div class="section-body">
      <input type="text" class="search-box" placeholder="Search groups…" oninput="searchTable('tbl-groups', this.value)">
      <div class="filter-bar">
        <button class="filter-btn active" onclick="filterTable('groups','all',this)">All</button>
        <button class="filter-btn" onclick="filterTable('groups','row-both',this)">Shared</button>
        <button class="filter-btn" onclick="filterTable('groups','row-only1',this)">${NAME1} only</button>
        <button class="filter-btn" onclick="filterTable('groups','row-only2',this)">${NAME2} only</button>
      </div>
      <div class="table-wrap">
        <table id="tbl-groups">
          <thead><tr><th>Group Name</th><th>Membership</th></tr></thead>
          <tbody>${GROUP_ROWS}</tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- Config Profiles -->
  <div class="section" id="sec-profiles">
    <div class="section-header" onclick="toggleSection('sec-profiles')">
      <div class="icon icon-profile">⚙️</div>
      <h2>Configuration Profiles</h2>
      <span class="section-chevron">▼</span>
    </div>
    <div class="section-body">
      <input type="text" class="search-box" placeholder="Search profiles…" oninput="searchTable('tbl-profiles', this.value)">
      <div class="filter-bar">
        <button class="filter-btn active" onclick="filterTable('profiles','all',this)">All</button>
        <button class="filter-btn" onclick="filterTable('profiles','row-both',this)">Shared</button>
        <button class="filter-btn" onclick="filterTable('profiles','row-only1',this)">${NAME1} only</button>
        <button class="filter-btn" onclick="filterTable('profiles','row-only2',this)">${NAME2} only</button>
      </div>
      <div class="table-wrap">
        <table id="tbl-profiles">
          <thead><tr><th>Profile Name</th><th>Assignment</th></tr></thead>
          <tbody>${PROFILE_ROWS}</tbody>
        </table>
      </div>
    </div>
  </div>

</main>

<footer>jamf_compare.sh &nbsp;•&nbsp; ${NAME1} (ID ${ID1}) vs ${NAME2} (ID ${ID2}) &nbsp;•&nbsp; ${REPORT_DATE}</footer>

<script>
const tableMap = { policies: 'tbl-policies', groups: 'tbl-groups', profiles: 'tbl-profiles' };
const activeFilters = { policies: 'all', groups: 'all', profiles: 'all' };

function toggleSection(id) {
  document.getElementById(id).classList.toggle('collapsed');
}

function filterTable(section, cls, btn) {
  activeFilters[section] = cls;
  const sb = document.querySelector('#sec-' + section + ' .search-box');
  applyFilters(section, sb ? sb.value : '');
  btn.closest('.filter-bar').querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
}

function searchTable(tblId, query) {
  const section = Object.keys(tableMap).find(k => tableMap[k] === tblId);
  applyFilters(section, query);
}

function applyFilters(section, query) {
  const tbl = document.getElementById(tableMap[section]);
  const cls = activeFilters[section];
  const q = query.toLowerCase();
  tbl.querySelectorAll('tbody tr').forEach(r => {
    const matchClass = cls === 'all' || r.classList.contains(cls);
    const matchText  = !q || r.textContent.toLowerCase().includes(q);
    r.style.display = (matchClass && matchText) ? '' : 'none';
  });
}
</script>
</body>
</html>
HTMLEOF

FULL_OUTPUT_PATH="$(pwd)/${OUTPUT_FILE}"
ok "Report written to: ${FULL_OUTPUT_PATH}"

if command -v open &>/dev/null; then
  open "$FULL_OUTPUT_PATH"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$FULL_OUTPUT_PATH"
fi

rm -f "$_JAMF_REQ_TMP"
echo -e "\n${BOLD}${GREEN}Done!${RESET} Report saved to ${CYAN}${FULL_OUTPUT_PATH}${RESET}\n"