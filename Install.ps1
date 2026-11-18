[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [string]$IniPath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\Skyrim Special Edition'),
    [string]$PluginListPath = (Join-Path $env:LOCALAPPDATA 'Skyrim Special Edition'),
    [switch]$Install,
    [switch]$Verify
)
$ErrorActionPreference = 'Stop'
if (!$Install -and !$Verify -and !$WhatIfPreference) { throw 'Для установки укажите -Install, для просмотра -WhatIf, для проверки -Verify.' }
if ($Install -and $Verify) { throw 'Запускайте установку и проверку отдельными командами.' }
$roots = @{ game = [IO.Path]::GetFullPath($GamePath); ini = [IO.Path]::GetFullPath($IniPath); loadorder = [IO.Path]::GetFullPath($PluginListPath) }
function Get-ChildPath ([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '[:*?]' -or
        ($Relative -split '[/\\]' | Where-Object { $_ -in '', '.', '..' })) {
        throw "Некорректный путь в манифесте $Relative"
    }
    Join-Path $Root $Relative
}
function Get-Hash ([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
$exe = Join-Path $roots.game 'SkyrimSE.exe'
if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'В указанной папке нет SkyrimSE.exe.' }
$actual = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
if ($actual -ne '1.7.104.0') { throw "Установлен Skyrim $actual. Для этой сборки нужен Skyrim 1.7.104.0." }
$platform = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LoadOrder/plugin_dependencies.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($entry in $platform) {
    if ($entry.official -and $entry.active -and !(Test-Path -LiteralPath (Get-ChildPath $roots.game ('Data/'+$entry.name)) -PathType Leaf)) {
        throw "Отсутствует официальный плагин $($entry.name). Проверьте установку Steam."
    }
}
if ($Install -and !$WhatIfPreference -and (Get-Process SkyrimSE,SkyrimTogether,Vortex -ErrorAction SilentlyContinue)) {
    throw 'Закройте Vortex и Skyrim перед записью.'
}
$map = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'InstallMap.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$problems = [Collections.Generic.List[string]]::new()
$work = [Collections.Generic.List[object]]::new()
$required = @{}
foreach ($item in $map) {
    $src = Get-ChildPath $PSScriptRoot $item.source
    $dst = Get-ChildPath $roots[$item.target] $item.destination
    if (!$paths.Add($dst)) { throw "Повтор назначения $dst" }
    $exists = Test-Path -LiteralPath $dst -PathType Leaf
    if ($exists -and ((Get-Item -LiteralPath $dst -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Назначение является ссылкой $dst"
    }
    if ($exists -and (Get-Hash $dst) -eq $item.sha256) { continue }
    if ($Verify) { $problems.Add($dst); continue }
    if (!(Test-Path -LiteralPath $src -PathType Leaf) -or (Get-Hash $src) -ne $item.sha256) {
        throw "Исходный файл отсутствует или повреждён $($item.source)"
    }
    if (!$exists -and (Test-Path -LiteralPath $dst)) { throw "Путь назначения занят $dst" }
    $volume = [IO.Path]::GetPathRoot($dst)
    $required[$volume] += (Get-Item -LiteralPath $src).Length
    $work.Add([pscustomobject]@{ Source=$src; Destination=$dst; Exists=$exists })
}
if ($Verify) {
    if ($problems.Count) {
        $problems | Select-Object -First 30 | ForEach-Object { Write-Warning $_ }
        throw "Файлов со статусом «отсутствует или отличается» — $($problems.Count)."
    }
    Write-Host "SHA-256 всех установленных файлов совпадает. Проверено $($map.Count)."
    return
}
foreach ($volume in $required.Keys) {
    if ([IO.DriveInfo]::new($volume).AvailableFreeSpace -lt $required[$volume]) { throw "Недостаточно места на $volume." }
}
foreach ($entry in $work) {
    if (!$PSCmdlet.ShouldProcess($entry.Destination,'Установить файл из архива')) { continue }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $entry.Destination)) | Out-Null
    $backup = $entry.Destination + '.modpack-backup-' + [guid]::NewGuid().ToString('N')
    $temp = $entry.Destination + '.modpack-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::Copy($entry.Source, $temp, $false)
        if ($entry.Exists) { [IO.File]::Replace($temp, $entry.Destination, $backup) }
        else { [IO.File]::Move($temp, $entry.Destination) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}
if (!$WhatIfPreference) { Write-Host "Установка завершена. Запустите проверку с -Verify, затем Data\SkyrimTogetherReborn\SkyrimTogether.exe." }
