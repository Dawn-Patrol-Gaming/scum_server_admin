# SCUM Server Restart

A small Windows console utility (Delphi) that **gracefully restarts a [SCUM](https://store.steampowered.com/app/513710/SCUM/) dedicated server** on a schedule. It sends a real `Ctrl+C` to the running server so it flushes and saves world state, waits for it to exit, zips the save database, purges the server's per-session log files, and relaunches the server — all driven by a simple `.ini` file.

Designed to be run from **Windows Task Scheduler** for unattended daily restarts. A second mode, [`/autoarchive`](#auto-backup-archiving-autoarchive), zips SCUM's rolling `*.db-backup` files out of the save folder on a frequent schedule (e.g. every 30 minutes) and removes the originals, without touching the running server.

---

## Why this exists

SCUM has **no native RCON** and no remote shutdown command. Closing the server window with the **X** button (or `Stop-Process -Force`) risks save corruption. The only safe way to stop a SCUM dedicated server is to send it a genuine **`Ctrl+C` console control signal**, which triggers its internal save-and-exit handler.

Doing that reliably from a separate process is fiddly (console attachment, integrity levels, sessions), so this tool packages the working approach into one scheduled executable.

---

## Features

- **Graceful shutdown** via `AttachConsole` + `GenerateConsoleCtrlEvent(CTRL_C_EVENT)` — the same thing as pressing Ctrl+C in the server window.
- **Waits for a clean exit** (configurable timeout) before continuing — save time scales with player count / world size.
- **Timestamped database backup** — zips the entire save folder to `yyyy_mm_dd_hh_nn_ss.zip` while the server is stopped (so files are flushed and unlocked).
- **Log purge** — clears the server's per-session log folder, but **only after a successful backup**.
- **Auto-backup archiving mode** (`/autoarchive`) — a second, independent schedulable mode that zips SCUM's rolling `*.db-backup` files out of the save folder and removes the originals, **without touching the running server**. Keeps `SaveFiles` from filling up while preserving every backup in timestamped archives.
- **Automatic restart** with your configured launch arguments.
- **All settings in an `.ini` file** — no recompilation to change paths, arguments, or timings.
- **Date-stamped logging** — every action is written to both the console and `logs\ScumServerRestart_yyyy-mm-dd.log`.
- **Self-documenting first run** — if no `.ini` exists, it writes one with default values and exits so you can edit it.

---

## Requirements

- Windows (tested on Windows Server 2019 / Windows 11).
- A SCUM dedicated server installed locally.
- **Delphi** (the project targets Delphi 12+/13; uses only the standard RTL — no third-party packages) to build from source, **or** just grab a prebuilt `ScumServerRestart.exe`.

---

## Building

1. Open `ScumServerRestart\ScumServerRestart.dpr` in Delphi (this generates the `.dproj` automatically).
2. Build the **Release / Win32** (or Win64) configuration.
3. The executable embeds a `requireAdministrator` manifest — see [Elevation](#elevation-required) below.

> **Debugging:** because the manifest requests elevation, the IDE must also be elevated to launch it under the debugger. Either run the Delphi IDE **as administrator**, or temporarily set the Debug config's execution level to *As invoker* (note: without elevation it cannot attach to an elevated server's console).

> **Prefer Free Pascal / Lazarus?** The code is Delphi-first, but it's plain Win32 + RTL and can be ported with a couple of small changes — see [docs/Building-with-Lazarus.md](docs/Building-with-Lazarus.md).

---

## Configuration

On first run, the tool looks for an `.ini` next to the executable (same base name, e.g. `ScumServerRestart.ini`). If it's missing, a default one is created and the program exits so you can edit it.

> The config is **self-healing**: when you upgrade to a build that adds new options, any keys missing from your existing `.ini` are appended with their defaults on the next run — so new sections like `[Update]` show up automatically. Review them before relying on them.

```ini
[Server]
; Executable name exactly as it appears in Task Manager
ExeName=SCUMServer.exe
; Full path to the server executable
ExePath=C:\SteamCMD\SCUM_Server\SCUM\Binaries\Win64\SCUMServer.exe
; Working directory for the server process (blank = folder of ExePath)
WorkDir=C:\SteamCMD\SCUM_Server\SCUM\Binaries\Win64\
; Command-line arguments passed on restart (blank for none)
Args=-multihome=0.0.0.0 -log

[Restart]
; Seconds to wait for the server to shut down cleanly before giving up
ShutdownTimeoutSec=120
; Seconds to wait after shutdown before relaunching
RestartDelaySec=10

[Backup]
; Folder containing the database to back up (zipped recursively). Blank = skip backup.
DbDir=C:\SteamCMD\SCUM_Server\SCUM\Saved\SaveFiles
; Folder where the timestamped backup zip is written.
; Keep this OUTSIDE the server install folder so a Steam update can't wipe it.
BackupDir=C:\SCUM_Backups
; Database backup file name = <prefix><timestamp><suffix>.zip. Both may be blank.
DbBackupPrefix=
DbBackupSuffix=
; Folder of server settings; all *.ini files are zipped. Blank = skip.
SettingsDir=C:\SteamCMD\SCUM_Server\SCUM\Saved\Config\WindowsServer
; Settings backup file name = <prefix><timestamp><suffix>.zip. Both may be blank.
SettingsBackupPrefix=settings_
SettingsBackupSuffix=

[Cleanup]
; SCUM server log folder, purged (all files deleted) only after a successful backup. Blank = skip.
; If this sits inside DbDir, the backup captures these logs before they are purged.
ServerLogDir=C:\SteamCMD\SCUM_Server\SCUM\Saved\SaveFiles\Logs

[Update]
; Set to 1 to run a SteamCMD update (after backup, before restart). 0 = skip.
EnableUpdate=0
; Full path to steamcmd.exe
SteamCmdPath=C:\SteamCMD\steamcmd.exe
; Steam app id for the SCUM dedicated server
SteamAppId=3792580
; Server install root passed to SteamCMD's +force_install_dir
InstallDir=C:\SteamCMD\SCUM_Server

[AutoArchive]
; Used only by the "/autoarchive" command-line mode (a separate scheduled task).
; Zips the rolling *.db-backup files out of DbDir into ArchiveDir, then deletes
; the originals. Does NOT touch the running server.
; Destination folder for the archive zips (created if missing). Blank = disabled.
ArchiveDir=C:\SCUM_Backups\auto
; Mask matching the rolling backup files in DbDir (do not point at live saves)
FileMask=*.db-backup
; Archive file name = <prefix><timestamp><suffix>.zip. Both may be blank.
ArchivePrefix=auto_
ArchiveSuffix=
; 1 = delete the originals after a successful zip; 0 = leave them in place
DeleteAfterArchive=1
```

> [!WARNING]
> **Put `BackupDir` on a different drive or path than the server install.** A SteamCMD / Steam app update can delete and recreate the entire install folder — if your backups live under it (e.g. `...\SCUM_Server\Backups`), they get wiped right when you'd need them. Use somewhere like `C:\SCUM_Backups` instead.

### Settings reference

| Section | Key | Meaning |
|---|---|---|
| `Server` | `ExeName` | Process image name used to find the running server. **Required.** |
| `Server` | `ExePath` | Full path used to relaunch the server. **Required.** |
| `Server` | `WorkDir` | Working directory for the new process. Defaults to `ExePath`'s folder if blank. |
| `Server` | `Args` | Launch arguments on restart. |
| `Restart` | `ShutdownTimeoutSec` | How long to wait for a clean exit before reporting failure. |
| `Restart` | `RestartDelaySec` | Pause between shutdown and relaunch. |
| `Backup` | `DbDir` | Folder zipped into the backup (recursive). Blank disables backup. |
| `Backup` | `BackupDir` | Destination folder for the zip (created if missing). **Point this *outside* the server install folder** — a Steam/SteamCMD update can wipe the install directory and take your backups with it. |
| `Backup` | `DbBackupPrefix` / `DbBackupSuffix` | Optional text before/after the timestamp in the database backup file name (`<prefix><timestamp><suffix>.zip`). Either may be blank. |
| `Backup` | `SettingsDir` | Folder whose `*.ini` files are zipped (recursively) to a separate settings backup. Blank disables. |
| `Backup` | `SettingsBackupPrefix` / `SettingsBackupSuffix` | Optional text before/after the timestamp in the settings backup file name. Either may be blank. |
| `Cleanup` | `ServerLogDir` | Folder whose files are deleted after a successful backup. Blank disables purge. |
| `AutoArchive` | `ArchiveDir` | Destination folder for `/autoarchive` zips (created if missing). Keep it outside the server install folder. Blank disables the mode. |
| `AutoArchive` | `FileMask` | Which files in `DbDir` count as auto-backups. Default `*.db-backup`. |
| `AutoArchive` | `ArchivePrefix` / `ArchiveSuffix` | Optional text before/after the timestamp in the archive file name. Either may be blank. |
| `AutoArchive` | `DeleteAfterArchive` | `1` (default) = delete the originals after a successful zip; `0` = archive only. |
| `Update` | `EnableUpdate` | `1` = run a SteamCMD update before restart; `0` = skip. |
| `Update` | `SteamCmdPath` | Full path to `steamcmd.exe`. |
| `Update` | `SteamAppId` | Steam app id of the SCUM dedicated server (configurable in case it ever changes). |
| `Update` | `InstallDir` | Server install root, passed to SteamCMD's `+force_install_dir`. |

---

## What it does, step by step

1. **Load config** and verify `ExePath` and `WorkDir` exist (errors out if not).
2. **Find** the running `SCUMServer.exe`.
3. **Shut down gracefully** — attach to the server's console and send `Ctrl+C`, then wait up to `ShutdownTimeoutSec` for it to exit.
4. **Archive rolling backups** — if `[AutoArchive] ArchiveDir` is set, run the same [`/autoarchive`](#auto-backup-archiving-autoarchive) step now, *before* the world backup. This pulls the `*.db-backup` files out of `DbDir` into the separate archive so they don't get swept into the world backup below — clean separation between the two. Skipped if `ArchiveDir` is blank.
5. **Back up the database** — zip all of `DbDir` to `BackupDir\yyyy_mm_dd_hh_nn_ss.zip` (now containing only the live save, not the rolling `.db-backup` copies).
6. **Purge logs** — delete everything in `ServerLogDir`, **only if the database backup succeeded**.
7. **Back up settings** — zip all `*.ini` under `SettingsDir` to `BackupDir\settings_<timestamp>.zip`.
8. **Update** — if `EnableUpdate=1`, run SteamCMD (`+force_install_dir … +login anonymous +app_update <SteamAppId> validate +quit`) and wait for it to finish. SteamCMD's output is captured line-by-line into the log file.
9. **Wait** `RestartDelaySec`, then **relaunch** the server with `Args`.

A failed/skipped backup is logged but **does not** stop the restart. A failed log purge is logged per-file and is never fatal. A failed/disabled SteamCMD update is logged and the restart still proceeds.

---

## Auto-backup archiving (`/autoarchive`)

SCUM writes rolling `*.db-backup` copies of the database into its `SaveFiles` folder, which pile up over time. This mode sweeps them into timestamped zips on their own schedule — the modern replacement for the old "move the `.db-backup` files to an archive folder" batch script (it **zips** instead of moving, then removes the originals):

```
ScumServerRestart.exe /autoarchive
```

It:

1. Finds files matching `[AutoArchive] FileMask` (default `*.db-backup`) in `DbDir` (top level only).
2. Zips them into `ArchiveDir\<prefix><timestamp><suffix>.zip`.
3. If `DeleteAfterArchive=1`, deletes **exactly the files that went into the zip** (never re-enumerated, so a backup created mid-run survives to the next pass).

It does **not** stop, restart, or attach to the server, so it's safe to run on a frequent trigger (e.g. every 30 minutes) while the server is up. If any file is locked, the zip fails as a whole and **nothing is deleted** — the next run picks everything up. Point `ArchiveDir` **outside** the install folder for the same reason as `BackupDir`.

The **nightly restart also performs this step automatically** (right after shutdown, before the world backup) whenever `ArchiveDir` is set — so the `.db-backup` files never end up inside the world backup zip. The separate frequent `/autoarchive` task is still worthwhile to keep `SaveFiles` trimmed *between* restarts; both write into the same `ArchiveDir` without conflict.

---

## Scheduling with Task Scheduler

> [!IMPORTANT]
> ### Elevation required
> The server typically runs **elevated**, and you can only attach to an elevated process's console if you are **also elevated**. The exe ships with a `requireAdministrator` manifest; in Task Scheduler also tick **Run with highest privileges**.
>
> ### Must run in the same session
> `AttachConsole` only works within the **same Windows session** as the server. The scheduled task must use **"Run only when user is logged on"** (`InteractiveToken`) as the **same account** the server runs under. The "Run whether user is logged on or not" option (`Password`) runs in session 0 and fails with *Access is denied*. Keep that account logged in (disconnect RDP rather than logging off).

> The `/autoarchive` task never attaches to the server's console, so the same-session rule doesn't strictly apply to it — but the exe's `requireAdministrator` manifest means it still needs **Run with highest privileges** to start without a UAC prompt.

### Option A — import the samples (fastest)

Two ready-to-edit sample tasks are included:

- [`SCUM Server Restart.sample.xml`](SCUM%20Server%20Restart.sample.xml) — the nightly restart cycle. It already has the two required options (`InteractiveToken` + `HighestAvailable`) set correctly.
- [`SCUM Archive Autobackups.sample.xml`](SCUM%20Archive%20Autobackups.sample.xml) — runs `/autoarchive` every 30 minutes (edit `<Repetition><Interval>PT30M</Interval>` to change the cadence; the `:15` start offset keeps it clear of a restart task on the hour).

1. Open the file in a text editor and change the two placeholders:
   - `<UserId>COMPUTERNAME\YourUser</UserId>` → the account the server runs under (or its SID).
   - `<Command>C:\SteamCMD\SCUM_Server\ScumServerRestart.exe</Command>` → the path to your built exe.
   - Optionally adjust `<StartBoundary>` for your preferred restart time.
2. In **Task Scheduler → Action → Import Task…**, select the file.
3. When prompted, confirm the account and enter credentials if asked.

> The sample is saved as **UTF-16 with a BOM** — the only encoding Task Scheduler's importer accepts. If you recreate it in another editor, preserve that encoding or the import fails with *"one root element"*.

### Option B — create it by hand in the GUI

- **General:** Run only when user is logged on · Run with highest privileges.
- **Triggers:** Daily, at your chosen restart time.
- **Actions:** Start a program → `C:\SteamCMD\SCUM_Server\ScumServerRestart.exe`.
- **Settings:** *Stop the task if it runs longer than 1 hour* (safety net).

For the auto-backup archive task, create a second task the same way but add `/autoarchive` in the action's **Add arguments** box, and set the trigger to *Daily* + *Repeat task every 30 minutes for a duration of 1 day*.

### Starting the server at boot

If the server isn't running, this tool starts it — so you can also use it to bring the server up after a reboot. The key is that it must run **in the same interactive session** the server should live in (so later restarts can attach to its console). Suggested approach: set the box to **auto-log-on** the server account, and trigger the start **at log on** of that account (a logon-triggered task, or a login batch that calls `schtasks /run /tn "SCUM Server Restart"`) — not an "At startup" trigger, which runs in the isolated session 0.

---

## Logging

Every run appends to a date-stamped file in a per-app subfolder next to the executable:

```
logs\ScumServerRestart\ScumServerRestart_2026-06-30.log
```

The `logs\<AppName>\` subfolder keeps this tool's logs separate when several of these utilities (SCUM, Valheim, Enshrouded) run from the **same folder**. Each line is timestamped. The same output is echoed to the console when run interactively.

The `/autoarchive` runs log here too, with the same `Found N file(s) matching …` line every run so there's never a question whether it did anything.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `2` | Server did not shut down cleanly within the timeout (restart aborted). |
| `3` | Configuration problem (missing/invalid `.ini`, or a default was just written). |
| `4` | Server executable or working directory not found. |
| `5` | `/autoarchive`: the archive failed (nothing was deleted). |

Task Scheduler can be configured to alert on non-zero exit codes.

---

## Troubleshooting

| Symptom (in the log) | Cause / Fix |
|---|---|
| `AttachConsole(...) failed: Access is denied` | Not elevated, **or** running in a different session than the server. Use highest privileges + "Run only when user is logged on" as the server's account. |
| `session=0` (server `session=1`) | Task is running non-interactively (`Password`). Switch to `InteractiveToken`. |
| `Server did not exit within Ns` | Increase `ShutdownTimeoutSec`; large worlds / many players take longer to save. |
| `Backup skipped: ... not set` / `folder not found` | Check `DbDir` / `BackupDir` paths in the `.ini`. |

---

## Notes

- This tool deliberately depends on **no remote-admin mods** (e.g. ggCON/UE4SS). The shutdown mechanism is pure Win32 and works whether or not such mods are installed.
- The graceful-shutdown behavior is inferred from consistent community tooling; a future SCUM build could change it. If restarts start corrupting saves after a game update, re-verify the Ctrl+C behavior.

---

## License

MIT — see [LICENSE](LICENSE).
