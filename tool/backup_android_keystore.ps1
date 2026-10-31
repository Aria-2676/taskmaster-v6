# Packs the Android signing material into a single backup archive.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool\backup_android_keystore.ps1
#
# Why: losing the keystore OR its password makes it impossible to ever update
# an already-installed build again -- users would have to uninstall and
# reinstall, losing their data. Neither can be recovered from anywhere else.
# So keep at least two copies, on different media, off this machine.
#
# The archive contains the keystore and the password. Treat it like a house key:
# never commit it, never email it, never put it in a public cloud folder.
# Copy it to a password manager, an encrypted USB stick, or a private vault.

$ErrorActionPreference = 'Stop'

$keystoreDir = 'D:\Dev\keystore'
$keystoreFile = Join-Path $keystoreDir 'taskmaster-release.jks'
$passwordFile = Join-Path $keystoreDir 'PASSWORD.txt'
$keyPropsFile = Join-Path $keystoreDir 'key.properties'

Write-Host ''
Write-Host '=== Android signing material backup ===' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path -LiteralPath $keystoreFile)) {
    throw "Keystore not found at $keystoreFile. Run tool/setup_android_keystore_auto.ps1 first."
}
if (-not (Test-Path -LiteralPath $passwordFile)) {
    throw "Password file not found at $passwordFile. It is part of the backup -- recreate the keystore if it is gone."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $keystoreDir 'backups'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$zipPath = Join-Path $outDir "taskmaster-signing-$stamp.zip"

# Stage into a temp folder so the archive has a flat, predictable layout.
$stage = Join-Path $env:TEMP "tm-signing-$stamp"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -LiteralPath $keystoreFile -Destination $stage -Force
Copy-Item -LiteralPath $passwordFile -Destination $stage -Force
if (Test-Path -LiteralPath $keyPropsFile) {
    Copy-Item -LiteralPath $keyPropsFile -Destination $stage -Force
}

# A restore note travels with the archive so the recipient is not guessing.
$readme = @"
TaskMaster Android signing backup
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Contents
  taskmaster-release.jks   the signing keystore (keep forever)
  PASSWORD.txt             the keystore password (keep forever)
  key.properties           config consumed by android/app/build.gradle.kts

How to restore on a new machine
  1. Copy taskmaster-release.jks  ->  D:\Dev\keystore\taskmaster-release.jks
  2. Copy key.properties          ->  <repo>\android\key.properties
     (fix the storeFile= path inside it if the drive letter differs)
  3. Verify:  flutter build apk --release
     A release build must NOT print "falling back to the DEBUG key" in the log.

  !! storeFile must use DOUBLED backslashes, e.g.
       storeFile=D:\\Dev\\keystore\\taskmaster-release.jks
     java.util.Properties.load() (used by android/app/build.gradle.kts) treats
     backslash as an escape character, so a path written with single backslashes
     gets silently corrupted ('\t' becomes a TAB) and the build fails with
     "Keystore file ... not found" pointing at a mangled path.
     If you hand-edit the path, double every backslash.

  Note: if the keystore is regenerated (rather than restored), the password in
  PASSWORD.txt no longer applies -- keytool cannot change a keystore's password
  in place without the old one. Keep the .jks and its password together.

Why this matters
  Android refuses to update an installed app unless the new APK is signed with
  the SAME key. Lose this keystore or its password and every existing user must
  uninstall and reinstall, losing their local data. There is no recovery path.
"@
Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Value $readme -Encoding UTF8

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force
Remove-Item -LiteralPath $stage -Recurse -Force

$sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)

Write-Host "Backup written:" -ForegroundColor Green
Write-Host "  $zipPath  ($sizeKb KB)"
Write-Host ''
Write-Host 'NEXT -- do this now, it is the whole point:' -ForegroundColor Yellow
Write-Host '  Copy that .zip somewhere OFF this machine:'
Write-Host '    - a password manager attachment, or'
Write-Host '    - an encrypted USB stick / private vault'
Write-Host ''
Write-Host 'Do NOT put it in the git repo. The repo is public.' -ForegroundColor Red
Write-Host 'Do NOT put it in a shared/public cloud folder.' -ForegroundColor Red
Write-Host ''
