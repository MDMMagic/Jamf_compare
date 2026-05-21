# jamf_compare

Compare two Jamf Pro computer records side-by-side and generate a self-contained HTML report showing which policies, computer groups, and configuration profiles each machine has — and what differs between them.

---

## What it does

Given two Jamf Pro computer IDs, the script:

1. Authenticates against your Jamf Pro server (Bearer token with Basic auth fallback)
2. Fetches both computer records via the Classic API
3. Scans **every policy** in your instance and evaluates scope live — direct assignment, group membership, and exclusions — so the policy list reflects what Jamf would actually deliver
4. Resolves configuration profile names from the full profile library
5. Produces a styled, self-contained `.html` report you can open in any browser, share, or archive

The HTML report includes:

- Side-by-side computer identity cards (serial, model, macOS version, IP, user, department, last check-in, MDM status)
- Summary stat bar showing shared vs. unique counts for policies, groups, and profiles
- Filterable, searchable tables for each category — filter by "shared", "Computer A only", or "Computer B only"
- Collapsible sections
- Colour-coded rows and badges for quick visual diffing

---

## Requirements

- `bash` 3.2+ (ships with macOS)
- `curl`
- `jq`

Both `curl` and `jq` must be on your `PATH`. Install `jq` via Homebrew if needed:

```bash
brew install jq
```

---

## Usage

```bash
chmod +x jamf_compare.sh
./jamf_compare.sh
```

The script will prompt you interactively for:

| Prompt | Description |
|---|---|
| Jamf Pro URL | e.g. `https://acme.jamfcloud.com` |
| Username | Jamf Pro account with read access |
| Password | |
| Computer 1 ID | Numeric Jamf computer ID |
| Computer 2 ID | Numeric Jamf computer ID |

### Skip prompts with environment variables

Export any or all of the following to pre-fill values:

```bash
export JAMF_URL="https://acme.jamfcloud.com"
export JAMF_USER="apiuser"
export JAMF_PASS="hunter2"
export ID1="42"
export ID2="99"

./jamf_compare.sh
```

### Debug output

Verbose debug lines are printed to stderr by default (`DEBUG=true`). To silence them:

```bash
DEBUG=false ./jamf_compare.sh
```

---

## Output

The report is written to the current directory:

```
jamf_compare_<ID1>_vs_<ID2>_<YYYYMMDD_HHMMSS>.html
```

On macOS the file opens automatically in your default browser on completion. On Linux, `xdg-open` is used if available.

---

## Permissions required

The Jamf Pro account used needs **read** access to:

- Computers
- Policies
- macOS Configuration Profiles

A dedicated read-only API role is recommended — the script never writes to Jamf.

---

## Limitations

- **Policy scope evaluation is client-side.** The script replicates Jamf's scoping logic (all computers, direct membership, group membership, exclusions) but does not account for advanced criteria-based scope targets (e.g. LDAP groups, department/building targets).
- **Configuration profiles with negative IDs** (MDM-managed, not in the profile library) are intentionally skipped.
- Large environments with hundreds of policies will take longer to scan — each policy requires an individual API call.

---

## Example report

![Report screenshot showing two computer cards, stat bar, and filterable policy table](https://github.com/user-attachments/assets/placeholder)

> Replace the placeholder above with an actual screenshot once uploaded to GitHub.

---

## License

See [LICENSE](LICENSE).
