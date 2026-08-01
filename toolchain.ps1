[CmdletBinding()]
param(
    [ValidateSet('bootstrap', 'pub-get', 'analyze', 'test', 'build-windows', 'build-apk', 'doctor')]
    [string]$Command = 'bootstrap',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Prefer explicit, known locations, but allow a developer's PATH to supply a
# newer Flutter installation. Nothing here is persisted outside this process.
$flutterHomeCandidates = @(
    $env:FLUTTER_ROOT
) | Where-Object { $_ -and (Test-Path -LiteralPath "$_\bin\flutter.bat") }

if ($flutterHomeCandidates.Count -gt 0) {
    $flutterHome = $flutterHomeCandidates[0]
    $env:FLUTTER_ROOT = $flutterHome
    $env:Path = "$flutterHome\bin;$env:Path"
}

$androidSdkCandidates = @(
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

if ($androidSdkCandidates.Count -gt 0) {
    $env:ANDROID_SDK_ROOT = $androidSdkCandidates[0]
    $env:ANDROID_HOME = $androidSdkCandidates[0]
    $env:Path = "$env:ANDROID_SDK_ROOT\platform-tools;$env:ANDROID_SDK_ROOT\cmdline-tools\latest\bin;$env:Path"
}

if ($env:GRADLE_USER_HOME) {
    $env:GRADLE_USER_HOME = [Environment]::ExpandEnvironmentVariables($env:GRADLE_USER_HOME)
}

$javaCandidates = @(
    $env:JAVA_HOME,
    'C:\Program Files\Android\Android Studio\jbr'
) | Where-Object { $_ -and (Test-Path -LiteralPath "$_\bin\java.exe") }
if ((-not $env:JAVA_HOME -or
        -not (Test-Path -LiteralPath "$env:JAVA_HOME\bin\java.exe")) -and
    $javaCandidates.Count -gt 0) {
    $env:JAVA_HOME = $javaCandidates[0]
    $env:Path = "$env:JAVA_HOME\bin;$env:Path"
}

$flutter = Get-Command flutter.bat -ErrorAction SilentlyContinue
if (-not $flutter) { $flutter = Get-Command flutter -ErrorAction SilentlyContinue }
if (-not $flutter) {
    throw 'Flutter was not found. Set FLUTTER_ROOT or add Flutter\bin to PATH.'
}

Set-Location $projectRoot
switch ($Command) {
    'bootstrap' {
        Write-Host "Flutter: $($flutter.Source)"
        Write-Host "Android SDK: $env:ANDROID_SDK_ROOT"
        Write-Host "Java home: $env:JAVA_HOME"
    }
    'pub-get'       { & $flutter.Source pub get @Arguments }
    'analyze'       { & $flutter.Source analyze @Arguments }
    'test'          { & $flutter.Source test @Arguments }
    'build-windows' { & $flutter.Source build windows @Arguments }
    'build-apk'     { & $flutter.Source build apk @Arguments }
    'doctor'        { & $flutter.Source doctor -v @Arguments }
}

exit $LASTEXITCODE
