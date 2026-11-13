# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project has no release tags yet: the version numbers below group the history
by date and are meant to be used when tagging.

## [Unreleased]

### Fixed (2026-11-13)

- A scheduled map wipe skipped a 6-day-old map: the minimum age was `7·N − 1` days, so a
  server launched on a Saturday did not wipe on the next Friday. The minimum is now
  `7·N − 5` days (`map_min_days`, 2 for weekly), which still skips the Friday right after
  a Thursday wipe. The browser wipe timer uses the same rule.

Work of 2026-11-07.

### Added
- `SERVERNAME_BASE` and `SERVERNAME_WIPE_DATE`: on every wipe the LGSM `servername`
  becomes `BASE | WIPE dd.mm`. A name containing `"`, `$` or a backtick is refused
  (LGSM sources its config file).
- Readiness check shared by the post-start wait and the opening gate: RCON answers
  **and** LGSM's console log of the current start contains `Server startup complete`.
  A missing console log, a log older than the running process, or a process older
  than `OXIDE_LOAD_TIMEOUT` without the line fall back to RCON alone, so a reworded
  line can never keep the gate closed for good.
- `config.env.example` documents every setting the script reads, including the
  optional `LGSM_SELFNAME` and `LGSM_LOCK_DIR`.
- Documentation rewritten in English and Russian: quick start, step-by-step
  installation, full configuration reference, flow diagrams, message catalogue
  and troubleshooting (including SteamCMD under cron); this changelog.
- `.gitignore` entries for `.state/`, `.manager.lock` and `.poweroff-once`.

### Changed
- A server crash while loading is no longer treated as an Oxide failure: the
  manager restarts the server up to twice and leaves `Managed/` alone. Only a
  server that answers RCON without Oxide is rolled back.
- The readiness wait uses a wall-clock timeout (a silent RCON call takes up to
  30 s itself, so summing sleeps could stretch 15 minutes to 45) and runs even
  with `OXIDE_CHECK_ENABLED="false"`.
- "New wipe is live" is announced only for a server that is running and loaded;
  "daily restart completed" only when the post-start check passed (loaded, with Oxide). Otherwise the
  gate stays closed and `tick` opens it later.
- The opening gate opens only with the process up, startup complete and
  `server.maxplayers` read back over RCON; otherwise the gate file is kept and
  the next tick retries.
- The `+N` opening mark is counted from the moment the server has loaded.
- The browser wipe timer honours `MAPWIPE_INTERVAL_WEEKS`, so it no longer shows a
  Map Wipe that `tick` will skip.

- A wipe cancelled before anything was wiped (no Facepunch update within
  `FULLWIPE_UPDATE_WAIT_MAX`, or `lgsm update` still failing after one retry 60 s
  later) now starts the server again
  unwiped, runs the Oxide check and sends a `wipe_resumed` alert, instead of
  leaving the server down.
- `FULLWIPE_ENABLED` gates only the scheduled and the legacy `fullwipe` runs;
  `fullwipe-now` always runs.
- `SKIP_DAILY_RESTART_ON_FULLWIPE_DAY` applies only while `FULLWIPE_ENABLED` is `true`.
- The browser wipe timer handles `MAPWIPE_OPEN_TIME="+N"`: it shows
  `MAPWIPE_TIME` + `FULLWIPE_COUNTDOWN` + N minutes instead of failing with a date error.
- `check-update` exits 0 for an update, 1 for none and 2 when the build numbers
  cannot be read, each with its own text (it used to report "No update" for the last case).
- A crash loop while loading sends its own `load_give_up` alert instead of reusing
  the watchdog's "keeps crashing" message.

### Fixed
- Full Wipe window: `FULLWIPE_LONDON_HOUR` is taken on the VM's local date, not on
  London's "today". East of London the local day starts while London is still on
  the previous date, and the wipe could start at midnight with the update still
  hours away.
- `is_first_thursday` read days `08` and `09` as invalid octal numbers (an error on
  every tick).
- `set_wipe_name` escapes `/`, `&` and `\` for `sed` and leaves a config without a
  `servername` line alone; the wipe timer guards against a vanished process.

## [0.3.0] - 2026-10-03

### Added
- `MAPWIPE_MONTH_DAYS`: Map Wipes only on chosen days of the month. `16-22` with
  `MAPWIPE_DAY=5` gives exactly two wipes a month, avoiding a third one in
  five-week months.
- Opening gate: `MAPWIPE_OPEN_TIME` and `FULLWIPE_OPEN_TIME`. The wiped server
  starts with `maxplayers 0`, players wait in Rust's own queue, and at the
  opening time the queue joins. State in `.state/gate`; `tick` reopens the server
  if the wipe run dies.
- `+N` opening mode: open at the next N-minute mark once the server is up, for
  the Full Wipe whose start depends on Facepunch's update.
- `WIPETIMER_ENABLED`: show the real next wipe in the server browser through
  `wipetimer.wipeunixtimestampoverride`.

## [0.2.0] - 2026-10-02

### Added
- `tick`, a single cron entry (every minute) that runs the whole schedule from
  `config.env`: daily restart at `DAILY_RESTART_TIME`, Full Wipe on the first
  Thursday, Map Wipes on `MAPWIPE_DAY` / `MAPWIPE_TIME` every
  `MAPWIPE_INTERVAL_WEEKS`. Each event fires once a day inside a window, never
  hours late.
- Optional Map Wipes (`MAPWIPE_*`) and the `mapwipe-now` command.
- Watchdog (`watchdog` command, also run by `tick`): restarts a crashed or hung
  server, respects a clean stop through LGSM's `started.lock`, gives up after
  `WATCHDOG_MAX_RESTARTS` per hour.
- Oxide check after every start (`OXIDE_CHECK_ENABLED`): wait for RCON, verify
  `oxide.version`, roll `Managed/` back to the pre-update copy if Oxide did not load.
- OS maintenance in the daily restart window: `unattended-upgrade`
  (`SYSTEM_UPDATE_ENABLED`), reboot instead of starting the server when the OS
  asks for it (`REBOOT_IF_REQUIRED`), a one-time power-off flag (`.poweroff-once`),
  and the `post-boot` command for an `@reboot` cron entry.
- Russian Telegram messages (`MESSAGES_LANG=en|ru`).
- One run at a time through `flock`; LGSM and rcon get file descriptor 9 closed so
  tmux never holds the lock.
- Log cleanup (`LOG_KEEP_DAYS`) and `cron.log` rotation at 10 MB.

### Changed
- Telegram text is sent as URL-encoded plain text: a raw `+` used to arrive as a
  space and `_` could break Markdown.
- `config.env.example` rewritten with a comment above every setting.
- Settings added since the first release have built-in defaults, so an older
  `config.env` keeps working.

### Fixed
- `manager.sh` changes into its own directory at startup. Under `sudo -u` from
  another home, LGSM's `find` calls failed on the unreadable working directory
  and a wipe aborted halfway.
- A manual `fullwipe-now` no longer waits up to two hours for a Facepunch update
  that may not be coming: it updates if a build is out and wipes either way. The
  scheduled first-Thursday run still waits.

## [0.1.0] - 2026-04-10

### Added
- Initial release: `manager.sh` with daily restart (RCON countdown, Rust and Oxide
  updates), Full Wipe on the first Thursday synchronised with Facepunch's update
  (waits for the update to appear in Steam), `fullwipe-now`, `check-update` and
  `test-telegram` commands.
- Telegram notifications with three log levels (`full`, `success_error`, `error_only`).
- `Managed/` backup before an Oxide update.
- `config.env.example`, `secrets.env.example`, the `rustserver.service` systemd
  unit, MIT license, English and Russian README.

[Unreleased]: https://github.com/wobujidao/rust-wipe-manager/compare/main...hydra-weekly
