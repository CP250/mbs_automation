# what: the morning after the health jobs fixes (MyChart stable names and dedupe, oura-sync in the wrapper)
# due: 2026-10-17 10:45
# expires: 2026-10-17 15:00
# log: health/health_physical/_logs/log_2026-10-16_health_jobs_fixes.md
#
# Section 7 of admin/mbs_system/design/brief_health_jobs_fixes.md, automated.
# Due after oura-watch's 10:30 run; the expiry leaves room for a late wake.

# MyChart, 09:00: both institutions finished and the day stamped.
expect_log_line mychart_sync.log "msk: complete;"
expect_log_line mychart_sync.log "weillcornell: complete;"
expect_log_line mychart_sync.log "completed successfully; stamped $DUE_DAY"
# Stable names: a fetched line now means genuinely new documents, a handful at
# most. A regression to position-based names refetches hundreds.
expect_log_max mychart_sync.log "fetched [0-9]+ clinical" 5
expect_empty mychart_sync.err.log
A="$ASSETS/health/health_physical/medical/mychart_fhir_raw"
expect_file_count "$A/msk/attachments" ge 421
expect_file_count "$A/msk/attachments" le 440
expect_file_count "$A/weillcornell/attachments" ge 95
expect_file_count "$A/weillcornell/attachments" le 110

# Oura, 10:00, first scheduled run under the wrapper.
expect_loaded com.mbs.oura-sync
expect_log_line oura_sync.log "starting oura-sync for $DUE_DAY \(lookback 14\)"
expect_log_line oura_sync.log "endpoints: [0-9]+ ok; failed: none"
expect_log_line oura_sync.log "completed successfully; stamped $DUE_DAY"
expect_stamp last_oura_sync_run
expect_empty oura_sync.err.log

# oura-watch, 10:30, still runs off the archive the wrapper wrote.
expect_stamp last_oura_watch_run

# Yesterday's health note got its six Oura fields.
N="daily_notes/health/daily/daily_note_health_2026-10-16.md"
for FIELD in sleep_score readiness_score total_sleep_hr hrv_avg_ms rhr_min_bpm; do
  expect_frontmatter "$N" "$FIELD" '^[0-9]'
done
expect_frontmatter "$N" body_temp_dev '^-?[0-9]'
