# Deferred checks

A deferred check is the "verify this tomorrow" step of a build, committed as code so nobody has to remember it. `com.mbs.deferred-checks` (scripts/deferred_checks.sh, hourly, garm only) runs each check in `pending/` once its due time has passed. **A pass is silent.** A check that has not passed by its expiry, or that cannot run at all, puts one line in that day's tasks note and heartbeat check 41 repeats it for 3 days. Added 2026-10-16 at P's request.

## When to write one

Any time a session would otherwise end with "P, after 10:20 tomorrow run this and paste the output": a scheduled job's next run, a deploy that lands later, a file that should appear overnight. Things only P can judge (does the note read right, did the email arrive on his phone) stay as checkboxes for P.

## Writing one

One file per check: `pending/YYYY-MM-DD_<slug>.sh`, named for the due day. Commit it on hoest with the work it verifies; `com.mbs.deploy` brings it to garm within 5 minutes. Header lines, in any order at the top:

```bash
# what: one line saying what is being verified (it is the alert's text)
# due: 2026-10-17 10:45            # local time on garm; required
# expires: 2026-10-17 15:00        # optional; default due + 4 hours
# log: health/health_physical/_logs/log_2026-10-16_health_jobs_fixes.md   # optional, vault-relative
```

Between due and expiry a failing check is retried hourly (the job it checks may simply be late) and alerts nothing. At expiry it is judged. A check that errors (syntax error, unset variable, a header the runner cannot read, more than 120 seconds) is alerted at once and never retried: a broken check must never read as a pass. Each check gets exactly one verdict; it never runs again after that.

The body is bash 3.2, run with `set -u` in a fresh `/bin/bash`, with `lib_checks.sh` loaded. **Checks only read.** Never write, move, delete, kickstart or call the network from a check; the runner cannot stop you, so this is the author's rule.

Available: `$STATE_DIR` (~/.mbs_automation), `$VAULT`, `$ASSETS` (~/storage_mbs_assets) and `$DUE_DAY` (the due date, the default day for every "on the day" helper, so a check evaluated late still asks about the right day).

| Helper | Passes when |
|---|---|
| `expect_log_line [--day D] <log> <ERE>` | a line dated D (default `$DUE_DAY`) matches |
| `expect_no_log_line [--day D] <log> <ERE>` | no line dated D matches |
| `expect_log_max [--day D] <log> <ERE> <n>` | every number in matches dated D is at most n (e.g. `'fetched [0-9]+ clinical' 5`) |
| `expect_stamp [--day D] <file>` | the file's first line is D |
| `expect_empty <file>` | missing or zero bytes (an `.err.log`) |
| `expect_file <path>` | exists |
| `expect_file_count <dir> eq\|ge\|le <n>` | count of regular files directly in dir |
| `expect_md5 <path> <md5>` | exact content |
| `expect_frontmatter <note> <field> [ERE]` | the field has a non-empty value (matching ERE) in the note's frontmatter |
| `expect_vault_contains <note> <string>` | the note contains the fixed string |
| `expect_loaded <label>` | the launchd job is loaded |
| `expect_cmd "<what>" <cmd...>` | the command exits 0 (escape hatch; read-only commands only) |

Relative log and stamp names resolve in `$STATE_DIR`; relative note paths in `$VAULT`. Every helper records its own failure and the check carries on, so one run reports every broken assertion.

## Before committing

```
bash scripts/deferred_checks_drill.sh
```

Its last section parses every file in `pending/` and confirms a `# due:` header. To dry-run a check's assertions against garm's real state today (read-only):

```
ssh garm 'cd ~/dev/mbs_automation && F=$(mktemp) && STATE_DIR=~/.mbs_automation VAULT=~/Vaults/storage_mbs ASSETS=~/storage_mbs_assets DUE_DAY=$(date +%Y-%m-%d) CHECK_FAILS=$F /bin/bash -c "set -u; source scripts/lib_checks.sh; source checks/pending/<file>.sh"; cat $F; rm -f $F'
```

No output means every assertion held.

## Where results go

- `~/.mbs_automation/deferred_checks/<name>.result` on garm: `PASS|FAIL|ERROR<tab>when<tab>detail`. Never in this repo: garm's checkout must stay clean or every deploy stops.
- A dated line under `## Deferred check results` in the session log named by `# log:`.
- Only on FAIL or ERROR: one line under `## ⚠️ Automation alerts` in that day's tasks note, then heartbeat check 41 for 3 days.
- The runner's own log: `~/.mbs_automation/deferred_checks.log`.

Old check files can stay in `pending/`, since a check with a result never runs again. A hoest session may move judged ones into `done/` in a commit, as housekeeping.
