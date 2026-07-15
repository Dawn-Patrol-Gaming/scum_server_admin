{
NOTE: in the manifest it's designated to run with elevated privileges, this is
because the app can't attach to another console without it in most cases. In order
to debug either drop the requirement (therefore may not be able to attach to a
console) or run the IDE as admin/elevated
}
program ScumServerRestart;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Winapi.Windows, Winapi.TlHelp32, System.SysUtils, System.DateUtils, System.IOUtils,
  System.IniFiles, System.SyncObjs, System.Classes, System.Zip, System.Masks;

const
  ATTACH_PARENT_PROCESS = DWORD(-1);

var
  LogFileName: string; // date-stamped log file, set in InitLogging
  LogCriticalSection: TCriticalSection;

  {
  Reattach our process to its original (parent / cmd) console after we've been
  attached to the server's console. Falls back to a fresh console only if there
  is no parent console (e.g. launched non-interactively by Task Scheduler).
  }
procedure RestoreOwnConsole;
begin
  if not AttachConsole(ATTACH_PARENT_PROCESS) then
    AllocConsole;
  // After FreeConsole/AttachConsole the console's std handles change, but the
  // RTL's Input/Output/ErrOutput text files still cache the original (now
  // invalid) handles — the next Writeln would raise I/O error 6. Rebind them.
  TTextRec(Input).Handle := GetStdHandle(STD_INPUT_HANDLE);
  TTextRec(Output).Handle := GetStdHandle(STD_OUTPUT_HANDLE);
  TTextRec(ErrOutput).Handle := GetStdHandle(STD_ERROR_HANDLE);
end;

{
---------------------------------------------------------------------------
Configuration — loaded at runtime from ScumServerRestart.ini (next to the exe)
file name of the ini is deterimined by executable name, default "ScumServerRestart"
---------------------------------------------------------------------------
}
var
  SERVER_EXE_NAME: string; // Executable name as shown in Task Manager
  SERVER_EXE_PATH: string; // Full path to the server executable
  SERVER_WORK_DIR: string; // Working directory for the server process
  SERVER_ARGS: string; // Command-line arguments on restart ('' if none)
  SHUTDOWN_TIMEOUT: Integer; // Seconds to wait for clean shutdown
  RESTART_DELAY: Integer; // Seconds to wait between stop and start
  DB_DIR: string; // Folder containing the database to back up ('' = skip backup)
  BACKUP_DIR: string; // Folder where the zipped backup is written
  DB_PREFIX: string; // Prefix on the database backup file name (may be blank)
  DB_SUFFIX: string; // Suffix on the database backup file name, before .zip (may be blank)
  SETTINGS_DIR: string; // Folder of server .ini settings to back up ('' = skip)
  SETTINGS_PREFIX: string; // Prefix on the settings backup file name (may be blank)
  SETTINGS_SUFFIX: string; // Suffix on the settings backup file name, before .zip (may be blank)
  EXCLUDE_MASKS: string; // Semicolon-separated name masks excluded from the regular backups (e.g. *.old;*.tmp); '' = exclude nothing
  SERVER_LOG_DIR: string; // SCUM server log folder to purge after a successful backup ('' = skip)
  ENABLE_UPDATE: Boolean; // Whether to run a SteamCMD update before restart
  STEAMCMD_PATH: string; // Full path to steamcmd.exe
  STEAM_APP_ID: string; // Steam app id for the SCUM dedicated server (configurable)
  STEAM_INSTALL_DIR: string; // +force_install_dir target (server root)
  AUTO_ARCHIVE_DIR: string; // Destination folder for /autoarchive zips ('' = mode disabled)
  AUTO_FILE_MASK: string; // Mask matching SCUM's rolling .db-backup files in DbDir
  AUTO_PREFIX: string; // Prefix on the auto-backup archive file name (may be blank)
  AUTO_SUFFIX: string; // Suffix on the auto-backup archive file name, before .zip (may be blank)
  AUTO_DELETE: Boolean; // Whether /autoarchive deletes the originals after a successful zip

function ConfigPath: string;
begin
  // Same folder as the exe, regardless of the current working directory.
  Result := TPath.ChangeExtension(ParamStr(0), '.ini');
end;

{
Reads a key, but if it does not yet exist in the file, writes the supplied
default back first. This makes the config self-healing: when an existing user
upgrades to a build with new options, those options are appended to their .ini
with sensible defaults rather than silently using them in-memory only.
}
function EnsureString(Ini: TIniFile; const Section, Key, Default: string): string;
begin
  if not Ini.ValueExists(Section, Key) then
    Ini.WriteString(Section, Key, Default);
  Result := Ini.ReadString(Section, Key, Default);
end;

function EnsureInteger(Ini: TIniFile; const Section, Key: string; Default: Integer): Integer;
begin
  if not Ini.ValueExists(Section, Key) then
    Ini.WriteInteger(Section, Key, Default);
  Result := Ini.ReadInteger(Section, Key, Default);
end;

{
Loads configuration, creating the file if missing and filling in any missing
keys with defaults (see EnsureString/EnsureInteger). Returns False if the file
was just created (so the caller stops and lets the user edit it) or if a
required value is missing.
}
function LoadConfig: Boolean;
var
  Ini: TIniFile;
  Path: string;
  FreshFile: Boolean;
begin
  Result := False;
  Path := ConfigPath;
  FreshFile := not TFile.Exists(Path);

  Ini := TIniFile.Create(Path);
  try
    SERVER_EXE_NAME := EnsureString(Ini, 'Server', 'ExeName', 'SCUMServer.exe');
    SERVER_EXE_PATH := EnsureString(Ini, 'Server', 'ExePath', 'C:\SteamCMD\SCUM_Server\SCUM\Binaries\Win64\SCUMServer.exe');
    SERVER_WORK_DIR := EnsureString(Ini, 'Server', 'WorkDir', 'C:\SteamCMD\SCUM_Server\SCUM\Binaries\Win64\');
    SERVER_ARGS := EnsureString(Ini, 'Server', 'Args', '-log');
    SHUTDOWN_TIMEOUT := EnsureInteger(Ini, 'Restart', 'ShutdownTimeoutSec', 120);
    RESTART_DELAY := EnsureInteger(Ini, 'Restart', 'RestartDelaySec', 10);
    DB_DIR := EnsureString(Ini, 'Backup', 'DbDir', 'C:\SteamCMD\SCUM_Server\SCUM\Saved\SaveFiles');
    BACKUP_DIR := EnsureString(Ini, 'Backup', 'BackupDir', 'C:\SCUM_Backups');
    DB_PREFIX := EnsureString(Ini, 'Backup', 'DbBackupPrefix', '');
    DB_SUFFIX := EnsureString(Ini, 'Backup', 'DbBackupSuffix', '');
    SETTINGS_DIR := EnsureString(Ini, 'Backup', 'SettingsDir', 'C:\SteamCMD\SCUM_Server\SCUM\Saved\Config\WindowsServer');
    SETTINGS_PREFIX := EnsureString(Ini, 'Backup', 'SettingsBackupPrefix', 'settings_');
    SETTINGS_SUFFIX := EnsureString(Ini, 'Backup', 'SettingsBackupSuffix', '');
    EXCLUDE_MASKS := EnsureString(Ini, 'Backup', 'ExcludeMasks', '');
    SERVER_LOG_DIR := EnsureString(Ini, 'Cleanup', 'ServerLogDir', 'C:\SteamCMD\SCUM_Server\SCUM\Saved\SaveFiles\Logs');
    ENABLE_UPDATE := EnsureInteger(Ini, 'Update', 'EnableUpdate', 0) <> 0;
    STEAMCMD_PATH := EnsureString(Ini, 'Update', 'SteamCmdPath', 'C:\SteamCMD\steamcmd.exe');
    STEAM_APP_ID := EnsureString(Ini, 'Update', 'SteamAppId', '3792580');
    STEAM_INSTALL_DIR := EnsureString(Ini, 'Update', 'InstallDir', 'C:\SteamCMD\SCUM_Server');
    AUTO_ARCHIVE_DIR := EnsureString(Ini, 'AutoArchive', 'ArchiveDir', 'C:\SCUM_Backups\auto');
    AUTO_FILE_MASK := EnsureString(Ini, 'AutoArchive', 'FileMask', '*.db-backup');
    AUTO_PREFIX := EnsureString(Ini, 'AutoArchive', 'ArchivePrefix', 'auto_');
    AUTO_SUFFIX := EnsureString(Ini, 'AutoArchive', 'ArchiveSuffix', '');
    AUTO_DELETE := EnsureInteger(Ini, 'AutoArchive', 'DeleteAfterArchive', 1) <> 0;
  finally
    Ini.Free;
  end;

  if FreshFile then
  begin
    Writeln('A default configuration file was created:');
    Writeln('  ' + Path);
    Writeln('Edit it to match your server, then run this program again.');
    Exit;
  end;

  if (SERVER_EXE_NAME = '') or (SERVER_EXE_PATH = '') then
  begin
    Writeln('ERROR: ExeName and ExePath must be set in ' + Path);
    Exit;
  end;

  // Default the working directory to the exe's folder if not specified.
  if SERVER_WORK_DIR = '' then
    SERVER_WORK_DIR := ExtractFilePath(SERVER_EXE_PATH);

  Result := True;
end;
// ---------------------------------------------------------------------------

function FindProcessByName(const ExeName: string): DWORD;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := 0;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if SameText(string(Entry.szExeFile), ExeName) then
        begin
          Result := Entry.th32ProcessID;
          Break;
        end; //if SameText(string(Entry.szExeFile), ExeName) then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

function GetParentPID(PID: DWORD): DWORD;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := 0;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = PID then
        begin
          Result := Entry.th32ParentProcessID;
          Break;
        end; //if Entry.th32ProcessID = PID then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

function SessionOf(PID: DWORD): DWORD;
begin
  if not ProcessIdToSessionId(PID, Result) then
    Result := DWORD(-1);
end;

const
  // Redeclared locally so the code compiles regardless of Delphi version.
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;

// Not declared in every Delphi version's Winapi.Windows, so bind it directly.
function GetConsoleProcessList(lpdwProcessList: PDWORD; dwProcessCount: DWORD): DWORD; stdcall;
  external kernel32 name 'GetConsoleProcessList';

{
Executable name of a process, via the same Toolhelp snapshot the other process
helpers use. Returns '?' if the PID no longer exists.
}
function ExeNameOfPID(PID: DWORD): string;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
begin
  Result := '?';
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit;
  try
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = PID then
        begin
          Result := string(Entry.szExeFile);
          Break;
        end; //if Entry.th32ProcessID = PID then
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

{
Lists every process attached to the console we are CURRENTLY attached to, as
'name(PID)' pairs. These are exactly the processes a GenerateConsoleCtrlEvent
broadcast to group 0 will reach, so TrySignalViaConsole records this before
sending Ctrl+C: any unexpected entry in the logged list (a cmd.exe mid-batch,
BEC, ...) names an innocent bystander that took our signal. Never raises.
}
function DescribeConsoleProcesses: string;
var
  PIDs: array[0..63] of DWORD;
  Count: DWORD;
  i: Integer;
begin
  Count := GetConsoleProcessList(@PIDs[0], Length(PIDs));
  if Count = 0 then
    Exit('(GetConsoleProcessList failed: ' + SysErrorMessage(GetLastError) + ')');
  if Count > DWORD(Length(PIDs)) then
    Count := DWORD(Length(PIDs)); // more than 64 attached: report the first 64
  Result := '';
  for i := 0 to Integer(Count) - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + ExeNameOfPID(PIDs[i]) + '(' + PIDs[i].ToString + ')';
  end; //for i := 0 to Integer(Count) - 1 do
end;

{
Guards the parent-PID retry in ShutdownServerGracefully against PID reuse:
th32ParentProcessID is only a number - if the original launcher has exited,
the same PID may since have been recycled by a completely unrelated process
(e.g. the cmd.exe running another game's restart batch). Attaching to THAT
process's console and broadcasting Ctrl+C would signal every innocent process
on it. So the parent is only trusted if it (a) still exists, (b) lives in the
same session as the server, and (c) was created BEFORE the server - a recycled
PID is always younger than the child it supposedly spawned. Returns True when
the parent looks genuine; otherwise False with Reason for the caller to log.
}
function ParentLooksGenuine(ParentPID, ChildPID: DWORD; out Reason: string): Boolean;
var
  hParent, hChild: THandle;
  ParentCreate, ChildCreate, ftExit, ftKernel, ftUser: TFileTime;
begin
  Result := False;
  Reason := '';

  hParent := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ParentPID);
  if hParent = 0 then
  begin
    Reason := 'parent PID ' + ParentPID.ToString + ' cannot be opened (probably exited): ' + SysErrorMessage(GetLastError);
    Exit;
  end; //if hParent = 0 then
  try
    hChild := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ChildPID);
    if hChild = 0 then
    begin
      Reason := 'server PID ' + ChildPID.ToString + ' cannot be opened: ' + SysErrorMessage(GetLastError);
      Exit;
    end; //if hChild = 0 then
    try
      if SessionOf(ParentPID) <> SessionOf(ChildPID) then
      begin
        Reason := 'parent PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) + ') is in session ' +
          SessionOf(ParentPID).ToString + ' but the server is in session ' + SessionOf(ChildPID).ToString +
          ' - not the real launcher';
        Exit;
      end; //if SessionOf(ParentPID) <> SessionOf(ChildPID) then

      if not GetProcessTimes(hParent, ParentCreate, ftExit, ftKernel, ftUser) or
         not GetProcessTimes(hChild, ChildCreate, ftExit, ftKernel, ftUser) then
      begin
        Reason := 'GetProcessTimes failed: ' + SysErrorMessage(GetLastError);
        Exit;
      end; //if not GetProcessTimes(...) then

      if CompareFileTime(ParentCreate, ChildCreate) > 0 then
      begin
        Reason := 'parent PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) +
          ') was created AFTER the server - the PID was recycled by an unrelated process';
        Exit;
      end; //if CompareFileTime(ParentCreate, ChildCreate) > 0 then

      Result := True;
    finally
      CloseHandle(hChild);
    end;
  finally
    CloseHandle(hParent);
  end;
end;

{
Appends a timestamped line to TheFile, creating it (and any missing parent
folders) as needed. Thread-safe and never raises — logging must not become a
new failure point.
}
procedure LogIt(const TheMsg, TheFile: string);
var
  fs: TFileStream;
  Buf: TBytes;
  TheDir, TheMessage: string;
begin
  try
    LogCriticalSection.Enter;
    try
      fs := nil;
      try
        TheDir := ExtractFilePath(TheFile);
        if (TheDir <> '') and not DirectoryExists(TheDir) then
          ForceDirectories(TheDir);
        try
          fs := TFileStream.Create(TheFile, fmOpenReadWrite or fmShareDenyNone);
        except
          fs := TFileStream.Create(TheFile, fmCreate);
        end;
        fs.Seek(0, soFromEnd);
        TheMessage := FormatDateTime('yyyy-mm-dd hh:nn:ssAM/PM', Now) + ' - ' + TheMsg + sLineBreak;
        Buf := TEncoding.Default.GetBytes(TheMessage);
        fs.Write(Buf[0], Length(Buf));
      finally
        fs.Free;
      end;
    finally
      LogCriticalSection.Leave;
    end;
  except
    // swallow any logging error so it never breaks the actual work.
  end;
end;

{
Sets up the date-stamped log file (logs\ScumServerRestart_yyyy-mm-dd.log next to
the exe) and creates the critical section LogIt requires.
}
procedure InitLogging;
var
  AppName, LogDir: string;
begin
  if not Assigned(LogCriticalSection) then
    LogCriticalSection := TCriticalSection.Create;
  // Log into logs\<AppName>\ so several of these utilities (SCUM, Valheim,
  // Enshrouded) can share one folder without their logs mixing together.
  AppName := TPath.GetFileNameWithoutExtension(ParamStr(0)); // e.g. ScumServerRestart
  LogDir := TPath.Combine(TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs'), AppName);
  LogFileName := TPath.Combine(LogDir, AppName + '_' + FormatDateTime('yyyy-mm-dd', Now) + '.log');
end;

{ Writes to both the console and the date-stamped log file. }
procedure Log(const Msg: string);
begin
  Writeln(Format('[%s] %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), Msg]));
  LogIt(Msg, LogFileName); // LogIt prepends its own timestamp
end;
{
Sends a real Ctrl+C (CTRL_C_EVENT) to the SCUM server console and waits for
the process to exit. SCUMServer.exe is a console-subsystem app: it has a
SetConsoleCtrlHandler callback that flushes/saves world state on Ctrl+C, then
exits cleanly. Window messages (WM_CLOSE etc.) do NOT trigger this — only a
genuine console control signal does.

Verified sequence:
  1. Open a handle to the target so we can wait on it afterwards.
  2. Detach our own console, attach to the server's console.
  3. Disable Ctrl handling for OURSELVES (the event broadcasts to every
     process on the console group, including this one — without this we'd
     kill ourselves before we could wait/restart).
  4. GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) — 0 = whole console group.
  5. Wait for the target to exit (while still attached). Save time scales
     with player count / world state, so poll up to the timeout in the ini.
     Increase the timeout if necessary in the ini file.
  6. Detach, re-enable our Ctrl handling, restore our own console.

NOTE: while attached to the server's console, Writeln goes to THAT console,
not ours — so we buffer status and log it only after we've restored our own.
Attaches to AttachPID's console, sends Ctrl+C to the whole group, then waits
for WaitPID (the actual server) to exit. AttachPID may be the server itself
or its console-owning parent. Returns True if the server exited in time.
StatusMsg / Attached report what happened (logged by the caller after the
console is restored — we must not Log() while attached to another console).
}
function TrySignalViaConsole(AttachPID, WaitPID: DWORD; TimeoutSec: Integer; out Attached: Boolean; out StatusMsg: string): Boolean;
var
  hProc: THandle;
  WaitResult, AttachErr: DWORD;
  SignalSent: Boolean;
  ConsoleProcs: string;
begin
  Result := False;
  Attached := False;

  hProc := OpenProcess(SYNCHRONIZE, False, WaitPID);
  if hProc = 0 then
  begin
    StatusMsg := 'ERROR: Cannot open server process (PID ' + WaitPID.ToString + '): ' + SysErrorMessage(GetLastError);
    Exit;
  end; //if hProc = 0 then

  try
    FreeConsole;
    if not AttachConsole(AttachPID) then
    begin
      AttachErr := GetLastError;
      RestoreOwnConsole;
      StatusMsg := 'AttachConsole(PID ' + AttachPID.ToString + ') failed: ' + SysErrorMessage(AttachErr);
      Exit;
    end; //if not AttachConsole(AttachPID) then
    Attached := True;

    // Do NOT Log() past this point — output would go to the attached console.
    // Record who shares this console BEFORE signalling: the CTRL_C_EVENT
    // broadcast below reaches every one of these processes, so this list
    // (appended to StatusMsg and logged by the caller) names any innocent
    // bystander that took the signal (a cmd.exe mid-batch, BEC, ...).
    ConsoleProcs := DescribeConsoleProcesses;

    SetConsoleCtrlHandler(nil, True); // don't let the signal kill us
    SignalSent := GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);

    if SignalSent then
    begin
      WaitResult := WaitForSingleObject(hProc, DWORD(TimeoutSec) * 1000);
      Result := (WaitResult = WAIT_OBJECT_0);
      if Result then
        StatusMsg := 'CTRL_C_EVENT sent via PID ' + AttachPID.ToString + ' - server exited cleanly.'
      else
        StatusMsg := 'CTRL_C_EVENT sent via PID ' + AttachPID.ToString + ', but server did not exit within ' + TimeoutSec.ToString + 's.';
    end //if SignalSent then
    else
      StatusMsg := 'GenerateConsoleCtrlEvent failed: ' + SysErrorMessage(GetLastError);

    StatusMsg := StatusMsg + ' [console group: ' + ConsoleProcs + ']';

    SetConsoleCtrlHandler(nil, False);
    FreeConsole;
    RestoreOwnConsole;
  finally
    CloseHandle(hProc);
  end;
end;

function ShutdownServerGracefully(PID: DWORD; TimeoutSec: Integer): Boolean;
var
  ParentPID: DWORD;
  Attached: Boolean;
  StatusMsg, Reason: string;
begin
  Log('Server session=' + SessionOf(PID).ToString + ', ' + ExtractFileName(ParamStr(0)) + ' session=' + SessionOf(GetCurrentProcessId).ToString +
    '.');

  // First attempt: attach to the server's own console.
  Result := TrySignalViaConsole(PID, PID, TimeoutSec, Attached, StatusMsg);
  Log(StatusMsg);
  if Result then
    Exit;

  // If the attach itself failed, the console is probably owned by a parent launcher (batch/Steam/wrapper). Try attaching to that instead.
  if not Attached then
  begin
    ParentPID := GetParentPID(PID);
    if (ParentPID <> 0) and (ParentPID <> PID) then
    begin
      // Vet the recorded parent before attaching: its PID may have been
      // recycled by an unrelated process since the server was launched (see
      // ParentLooksGenuine) - Ctrl+C into that console would hit innocents.
      if ParentLooksGenuine(ParentPID, PID, Reason) then
      begin
        Log('Retrying via parent process PID ' + ParentPID.ToString + ' (' + ExeNameOfPID(ParentPID) + ', session=' +
          SessionOf(ParentPID).ToString + ')...');
        Result := TrySignalViaConsole(ParentPID, PID, TimeoutSec, Attached, StatusMsg);
        Log(StatusMsg);
      end //if ParentLooksGenuine(ParentPID, PID, Reason) then
      else
        Log('NOT retrying via parent PID ' + ParentPID.ToString + ': ' + Reason);
    end //if (ParentPID <> 0) and (ParentPID <> PID) then
    else
      Log('No usable parent process to retry against.');
  end; //if not Attached then
end;

{ True when FileName matches ANY mask in the semicolon-separated Masks list
  (blank entries are ignored). Used for the [Backup] ExcludeMasks option. }
function MatchesAnyMask(const FileName, Masks: string): Boolean;
var
  Mask: string;
begin
  Result := False;
  for Mask in Masks.Split([';']) do
    if (Trim(Mask) <> '') and MatchesMask(FileName, Trim(Mask)) then
      Exit(True);
end;

{
Zips files matching FileMask under SourceDir (recursively, preserving folder
structure) into BACKUP_DIR as <Prefix>yyyy_mm_dd_hh_nn_ss<Suffix>.zip. Prefix and
Suffix may be blank. Files whose NAME matches any mask in the semicolon-separated
ExcludeMasks list are left out ('' = exclude nothing). Meant to run while the
server is stopped so files are flushed and unlocked. Returns False on any problem
(logged by the caller); a failed backup is non-fatal.
}
function ZipFolder(const Description, SourceDir, FileMask, Prefix, Suffix: string; const ExcludeMasks: string = ''): Boolean;
var
  Zip: TZipFile;
  Files: TArray<string>;
  SrcFile, ZipPath, RelName, BaseDir: string;
  i, Kept: Integer;
begin
  Result := False;

  if (SourceDir = '') or (BACKUP_DIR = '') then
  begin
    Log(Description + ' backup skipped: source or BackupDir not set in ' + ConfigPath + '.');
    Exit;
  end;//if (SourceDir = '') or (BACKUP_DIR = '') then

  if not TDirectory.Exists(SourceDir) then
  begin
    Log('WARNING: ' + Description + ' backup skipped - folder not found: ' + SourceDir);
    Exit;
  end;//if not TDirectory.Exists(SourceDir) then

  try
    if not TDirectory.Exists(BACKUP_DIR) then
      TDirectory.CreateDirectory(BACKUP_DIR);

    ZipPath := TPath.Combine(BACKUP_DIR, Prefix + FormatDateTime('yyyy_mm_dd_hh_nn_ss', Now) + Suffix + '.zip');

    BaseDir := IncludeTrailingPathDelimiter(SourceDir);
    Files := TDirectory.GetFiles(SourceDir, FileMask, TSearchOption.soAllDirectories);

    if ExcludeMasks <> '' then
    begin
      Kept := 0;
      for i := 0 to High(Files) do
        if not MatchesAnyMask(ExtractFileName(Files[i]), ExcludeMasks) then
        begin
          Files[Kept] := Files[i];
          Inc(Kept);
        end; //if not MatchesAnyMask(ExtractFileName(Files[i]), ExcludeMasks) then
      if Kept < Length(Files) then
        Log('  Excluded ' + (Length(Files) - Kept).ToString + ' ' + Description + ' file(s) matching "' + ExcludeMasks + '".');
      SetLength(Files, Kept);
    end; //if ExcludeMasks <> '' then

    if Length(Files) = 0 then
    begin
      Log('WARNING: No ' + Description + ' files found to back up in ' + SourceDir + '.');
      Exit;
    end;

    Log('Backing up ' + Length(Files).ToString + ' ' + Description + ' file(s) from ' + SourceDir + '...');

    Zip := TZipFile.Create;
    try
      Zip.Open(ZipPath, zmWrite);
      for SrcFile in Files do
      begin
        // Preserve the folder structure relative to SourceDir inside the zip.
        RelName := SrcFile;
        if RelName.StartsWith(BaseDir, True) then
          RelName := RelName.Substring(Length(BaseDir));
        Zip.Add(SrcFile, RelName);
      end; //for SrcFile in Files do
      Zip.Close;
    finally
      Zip.Free;
    end;

    Log(Description + ' backup written: ' + ZipPath);
    Result := True;
  except
    on E: Exception do
      Log('WARNING: ' + Description + ' backup failed: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

{ Backs up the entire save database folder (all files). }
function BackupDatabase: Boolean;
begin
  Result := ZipFolder('database', DB_DIR, '*', DB_PREFIX, DB_SUFFIX, EXCLUDE_MASKS);
end;

{ Backs up the server settings (*.ini files) into a separate zip. }
function BackupServerSettings: Boolean;
begin
  Result := ZipFolder('settings', SETTINGS_DIR, '*.ini', SETTINGS_PREFIX, SETTINGS_SUFFIX, EXCLUDE_MASKS);
end;

{
Runs a command line with its stdout+stderr captured through a pipe, relaying each
line to Log() (so it lands in both the console and the date-stamped log file).
Waits for the process to finish. Returns False only if the process failed to
launch; ExitCode receives the process exit code otherwise.

SteamCMD's progress is line-buffered with CR/LF, so each progress update becomes
its own logged line - exactly what we want for an unattended record.
}
function RunCapturedToLog(const ACmdLine, AWorkDir: string; out ExitCode: DWORD): Boolean;
var
  Sec: TSecurityAttributes;
  hReadOut, hWriteOut: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  LineBuf: AnsiString;
  i: Integer;

  procedure FlushLine;
  begin
    if LineBuf <> '' then
    begin
      Log(string(LineBuf));
      LineBuf := '';
    end;//if LineBuf <> '' then
  end;//procedure FlushLine;

begin
  Result := False;
  ExitCode := DWORD(-1);

  FillChar(Sec, SizeOf(Sec), 0);
  Sec.nLength := SizeOf(Sec);
  Sec.bInheritHandle := True; // child must inherit the pipe's write end

  if not CreatePipe(hReadOut, hWriteOut, @Sec, 0) then
  begin
    Log('WARNING: CreatePipe failed: ' + SysErrorMessage(GetLastError));
    Exit;
  end;//if not CreatePipe(hReadOut, hWriteOut, @Sec, 0) then

  // The parent's read end must NOT be inherited by the child.
  SetHandleInformation(hReadOut, HANDLE_FLAG_INHERIT, 0);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
  SI.hStdOutput := hWriteOut;
  SI.hStdError := hWriteOut;

  Cmd := ACmdLine;
  UniqueString(Cmd); // CreateProcessW may modify lpCommandLine in place

  if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(AWorkDir), SI, PI) then
  begin
    Log('WARNING: Failed to launch process: ' + SysErrorMessage(GetLastError));
    CloseHandle(hReadOut);
    CloseHandle(hWriteOut);
    Exit;
  end;//if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(AWorkDir), SI, PI) then

  // Close our copy of the write end so ReadFile sees EOF when the child exits.
  CloseHandle(hWriteOut);

  LineBuf := '';
  while ReadFile(hReadOut, Buffer, SizeOf(Buffer), BytesRead, nil) and (BytesRead > 0) do
    for i := 0 to Integer(BytesRead) - 1 do
      if CharInSet(Buffer[i], [#13, #10]) then
        FlushLine
      else
        LineBuf := LineBuf + Buffer[i];
  FlushLine; // anything left without a trailing newline

  WaitForSingleObject(PI.hProcess, INFINITE);
  if not GetExitCodeProcess(PI.hProcess, ExitCode) then
    ExitCode := DWORD(-1);

  CloseHandle(hReadOut);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
  Result := True;
end;

{
Runs SteamCMD to update the SCUM dedicated server, waiting for it to finish and
capturing its output to the log. Controlled by [Update] EnableUpdate. Non-fatal:
any problem is logged and the restart still proceeds. Returns True only if an
update actually ran and SteamCMD reported success (exit code 0).
}
function UpdateServer: Boolean;
var
  CmdLine, WorkDir: string;
  ExitCode: DWORD;
begin
  Result := False;

  if not ENABLE_UPDATE then
  begin
    Log('SteamCMD update skipped (EnableUpdate=0).');
    Exit;
  end; //if not ENABLE_UPDATE then

  if (STEAMCMD_PATH = '') or not TFile.Exists(STEAMCMD_PATH) then
  begin
    Log('WARNING: SteamCMD update skipped - steamcmd.exe not found: ' + STEAMCMD_PATH);
    Exit;
  end; //if (STEAMCMD_PATH = '') or not TFile.Exists(STEAMCMD_PATH) then

  if (STEAM_APP_ID = '') or (STEAM_INSTALL_DIR = '') then
  begin
    Log('WARNING: SteamCMD update skipped - SteamAppId or InstallDir not set in ' + ConfigPath + '.');
    Exit;
  end; //if (STEAM_APP_ID = '') or (STEAM_INSTALL_DIR = '') then

  // +force_install_dir must come BEFORE +login per SteamCMD's argument ordering.
  CmdLine := Format('"%s" +force_install_dir "%s" +login anonymous +app_update %s validate +quit', [STEAMCMD_PATH,
    ExcludeTrailingPathDelimiter(STEAM_INSTALL_DIR), STEAM_APP_ID]);
  WorkDir := ExtractFilePath(STEAMCMD_PATH);

  Log('Running SteamCMD update (app ' + STEAM_APP_ID + ')...');

  if not RunCapturedToLog(CmdLine, WorkDir, ExitCode) then
    Exit; // launch failure already logged

  if ExitCode = 0 then
  begin
    Log('SteamCMD update completed successfully.');
    Result := True;
  end //if ExitCode = 0 then
  else
    Log('WARNING: SteamCMD exited with code ' + Integer(ExitCode).ToString + ' - the server may not have updated. Restart will proceed anyway.');
end;

{
Deletes every file in SERVER_LOG_DIR (recursively), leaving the folder itself in
place. Intended to run only after a successful backup. Individual delete failures
(e.g. a file still locked) are logged and skipped, not fatal.
}
procedure PurgeServerLogs;
var
  Files: TArray<string>;
  AFile: string;
  Deleted, Failed: Integer;
begin
  if SERVER_LOG_DIR = '' then
    Exit;

  if not TDirectory.Exists(SERVER_LOG_DIR) then
  begin
    Log('Log purge skipped - folder not found: ' + SERVER_LOG_DIR);
    Exit;
  end;

  Deleted := 0;
  Failed := 0;
  try
    Files := TDirectory.GetFiles(SERVER_LOG_DIR, '*', TSearchOption.soAllDirectories);
    for AFile in Files do
    begin
      try
        TFile.Delete(AFile);
        Inc(Deleted);
      except
        on E: Exception do
        begin
          Inc(Failed);
          Log('  Could not delete ' + AFile + ': ' + E.Message);
        end;//on E: Exception do
      end;//try..except
    end;//for AFile in Files do
    Log(Format('Purged server logs in %s - %d deleted, %d skipped.',
      [SERVER_LOG_DIR, Deleted, Failed]));
  except
    on E: Exception do
      Log('WARNING: Log purge failed: ' + E.ClassName + ' - ' + E.Message);
  end;
end;

{
/autoarchive mode: zips SCUM's rolling .db-backup files out of DbDir into
[AutoArchive] ArchiveDir, then deletes the archived originals
(DeleteAfterArchive=1). Only files matching FileMask (default *.db-backup) are
touched - the live SCUM.db and other save files are never matched. This does NOT
stop, restart, or otherwise touch the server, so it is safe to run on its own
frequent schedule while the server is up: the .db-backup files are finished
copies the server is no longer writing. If a file happens to be locked, the zip
fails as a whole and NOTHING is deleted - the next scheduled run picks everything
up. Replaces the old move-to-archive batch script (zips instead of moving, and
removes the source). Returns the exit code (0 = archived or nothing to do,
5 = failed).
}
function AutoArchive: Integer;
var
  Zip: TZipFile;
  Files: TArray<string>;
  SrcFile, ZipPath: string;
  Deleted, Failed: Integer;
begin
  Result := 5;

  if (DB_DIR = '') or (AUTO_ARCHIVE_DIR = '') then
  begin
    Log('ERROR: Auto-backup archive skipped - DbDir or ArchiveDir not set in ' + ConfigPath + '.');
    Exit;
  end;//if (DB_DIR = '') or (AUTO_ARCHIVE_DIR = '') then

  if not TDirectory.Exists(DB_DIR) then
  begin
    Log('ERROR: Auto-backup archive skipped - folder not found: ' + DB_DIR);
    Exit;
  end;//if not TDirectory.Exists(DB_DIR) then

  try
    // Top level only: the .db-backup files sit directly in SaveFiles, and not
    // recursing means a stray subfolder can never be swept into the delete step.
    Files := TDirectory.GetFiles(DB_DIR, AUTO_FILE_MASK, TSearchOption.soTopDirectoryOnly);

    // Always state what was found, so a run is never ambiguous in the log.
    Log(Format('Found %d file(s) matching %s in %s.', [Length(Files), AUTO_FILE_MASK, DB_DIR]));
    if Length(Files) = 0 then
    begin
      Log('Nothing to archive - no auto-backup files to zip or remove.');
      Result := 0;
      Exit;
    end;//if Length(Files) = 0 then

    if not TDirectory.Exists(AUTO_ARCHIVE_DIR) then
      TDirectory.CreateDirectory(AUTO_ARCHIVE_DIR);

    ZipPath := TPath.Combine(AUTO_ARCHIVE_DIR, AUTO_PREFIX + FormatDateTime('yyyy_mm_dd_hh_nn_ss', Now) + AUTO_SUFFIX + '.zip');
    Log('Archiving ' + Length(Files).ToString + ' auto-backup file(s) from ' + DB_DIR + '...');

    Zip := TZipFile.Create;
    try
      Zip.Open(ZipPath, zmWrite);
      for SrcFile in Files do
        Zip.Add(SrcFile, ExtractFileName(SrcFile));
      Zip.Close;
    finally
      Zip.Free;
    end;
    Log('Auto-backup archive written: ' + ZipPath);
  except
    on E: Exception do
    begin
      Log('ERROR: Auto-backup archive failed: ' + E.ClassName + ' - ' + E.Message);
      Log('Nothing was deleted.');
      Exit;
    end;//on E: Exception do
  end;

  Result := 0;

  if not AUTO_DELETE then
  begin
    Log('DeleteAfterArchive=0 - archived files left in place.');
    Exit;
  end;//if not AUTO_DELETE then

  // Delete exactly the files that went into the zip - never re-enumerate, so a
  // .db-backup created after the snapshot above survives to the next run.
  Deleted := 0;
  Failed := 0;
  for SrcFile in Files do
  begin
    try
      TFile.Delete(SrcFile);
      Inc(Deleted);
    except
      on E: Exception do
      begin
        Inc(Failed);
        Log('  Could not delete ' + SrcFile + ': ' + E.Message);
      end;//on E: Exception do
    end;//try..except
  end;//for SrcFile in Files do
  Log(Format('Removed archived auto-backups - %d deleted, %d skipped.', [Deleted, Failed]));
end;

procedure RestartServer;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
begin
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_SHOWMINNOACTIVE; // Start minimised; change to SW_SHOW if preferred

  if SERVER_ARGS <> '' then
    CmdLine := '"' + SERVER_EXE_PATH + '" ' + SERVER_ARGS
  else
    CmdLine := '"' + SERVER_EXE_PATH + '"';

  // CreateProcessW may modify lpCommandLine in place, so it must point to a writable, uniquely-owned buffer — otherwise it can access-violate.
  UniqueString(CmdLine);

  if CreateProcess(nil, PChar(CmdLine), nil, nil, False, CREATE_NEW_CONSOLE, nil, PChar(SERVER_WORK_DIR), SI, PI) then
  begin
    Log('Server restarted successfully (PID ' + PI.dwProcessId.ToString + ').');
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end //if CreateProcess( nil, PChar(CmdLine), nil, nil, False, CREATE_NEW_CONSOLE, nil, PChar(SERVER_WORK_DIR), SI, PI) then
  else
    Log('ERROR: CreateProcess failed: ' + SysErrorMessage(GetLastError));
end;

var
  PID: DWORD;
  i: Integer;
  Mode: string;
begin
  Writeln('=== SCUM Server Restart Utility ===');
  Writeln;

  InitLogging;
  if not LoadConfig then
  begin
    ExitCode := 3;
    Exit;
  end;
  Log('=== SCUM Server Restart Utility started ===');

  // --- Alternate mode: /autoarchive - zip out the rolling .db-backup files ---
  // Does NOT stop, restart, or otherwise touch the server. Meant to be run on
  // its own (frequent) Task Scheduler trigger, independent of the restart job.
  Mode := ParamStr(1);
  if Mode <> '' then
  begin
    if SameText(Mode, '/autoarchive') or SameText(Mode, '-autoarchive') or SameText(Mode, '--autoarchive') then
    begin
      Log('=== Auto-backup archive mode (server is not touched) ===');
      ExitCode := AutoArchive;
      Log('=== Done ===');
      Exit;
    end;//if SameText(Mode, '/autoarchive') ...

    Writeln('Unknown parameter: ' + Mode);
    Writeln('Usage:');
    Writeln('  ' + ExtractFileName(ParamStr(0)) + '                restart cycle (shutdown, backup, update, relaunch)');
    Writeln('  ' + ExtractFileName(ParamStr(0)) + ' /autoarchive   zip .db-backup files to [AutoArchive] ArchiveDir and remove them');
    ExitCode := 3;
    Exit;
  end;//if Mode <> '' then

  // --- Step 0: verify the server executable exists before doing anything ---
  if not TFile.Exists(SERVER_EXE_PATH) then
  begin
    Log('ERROR: Server executable not found: ' + SERVER_EXE_PATH);
    Log('Check ExePath in ' + ConfigPath + ' and try again.');
    ExitCode := 4;
    Exit;
  end;//if not TFile.Exists(SERVER_EXE_PATH) then
  if not TDirectory.Exists(SERVER_WORK_DIR) then
  begin
    Log('ERROR: Working directory not found: ' + SERVER_WORK_DIR);
    Log('Check WorkDir in ' + ConfigPath + ' and try again.');
    ExitCode := 4;
    Exit;
  end;//if not TDirectory.Exists(SERVER_WORK_DIR) then

  // --- Step 1: find the running server ---
  Log('Looking for ' + SERVER_EXE_NAME + '...');
  PID := FindProcessByName(SERVER_EXE_NAME);
  if PID = 0 then
    Log('Server process not found. Skipping shutdown, proceeding to start.')
  else
  begin
    Log('Found server at PID ' + PID.ToString + '. Sending Ctrl+C and waiting up to ' + SHUTDOWN_TIMEOUT.ToString + 's for clean shutdown...');

    if not ShutdownServerGracefully(PID, SHUTDOWN_TIMEOUT) then
    begin
      Log('WARNING: Server did not shut down cleanly. It may still be running.');
      Log('Check manually before relying on the restart.');
      ExitCode := 2;
      Exit;
    end; //if not ShutdownServerGracefully(PID, SHUTDOWN_TIMEOUT) then
  end; //if..then..else PID = 0 then

  // --- Step 2: archive the rolling .db-backup files FIRST ---
  // Doing this before the database backup pulls SCUM's auto-generated
  // *.db-backup files out of DbDir (into the separate AutoArchive), so the
  // world backup below only contains the live save - clean separation between
  // the two archives. Skipped silently if AutoArchive isn't configured.
  if AUTO_ARCHIVE_DIR <> '' then
    AutoArchive;

  // --- Step 3: back up the database while the server is stopped ---
  // Non-fatal: a failed/skipped backup is logged but the restart still proceeds.
  // Only purge the server logs once we have a confirmed good backup.
  if BackupDatabase then
    PurgeServerLogs
  else
    Log('Skipping log purge because the backup did not complete.');

  // --- Step 4: back up the server settings (.ini files) ---
  BackupServerSettings;

  // --- Step 5: update the server via SteamCMD (if enabled) ---
  UpdateServer;

  // --- Step 6: wait before restarting ---
  Log('Waiting ' + RESTART_DELAY.ToString + 's before restart...');
  for i := RESTART_DELAY downto 1 do
  begin
    Write(#13 + '  Restarting in ' + i.ToString + 's...  ');
    Sleep(1000);
  end; //for i := RESTART_DELAY downto 1 do
  Writeln;

  // --- Step 7: launch the server ---
  Log('Starting ' + SERVER_EXE_PATH + '...');
  RestartServer;

  Writeln;
  Log('=== Done ===');
end.

