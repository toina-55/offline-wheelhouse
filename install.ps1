<#
.SYNOPSIS
  옮겨온 wheelhouse를 폐쇄망 uv 프로젝트에 설치한다.

.DESCRIPTION
  `uv add --offline --find-links` 를 쓴다 — pyproject.toml·uv.lock·설치를 한 번에 처리해야
  이후 `uv run` 의 자동 동기화에서 지워지지 않는다.
  실패하면 백업(.bak)으로 자동 복구한다.

.EXAMPLE
  # wheelhouse 폴더 안에서 (download.ps1 이 이 스크립트를 거기 복사해 둔다)
  .\install.ps1

.EXAMPLE
  .\install.ps1 -Wheelhouse C:\transfer\wheelhouse
  .\install.ps1 -Wheelhouse C:\transfer\wheelhouse -EnvPath $HOME\code\local-llm-setup\envs\main
#>
[CmdletBinding()]
param(
    # 옮겨온 wheelhouse 폴더. 생략하면 이 스크립트가 있는 폴더를 쓴다
    [string]$Wheelhouse = $PSScriptRoot,
    # 설치 대상 uv 프로젝트 (pyproject.toml 이 있는 폴더)
    [string]$EnvPath = "$HOME\code\local-llm-setup\envs\main",
    # 해시 확인을 건너뛴다 (권장하지 않음)
    [switch]$SkipHashCheck
)

$ErrorActionPreference = 'Stop'
function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Note([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn([string]$m) { Write-Host "    $m" -ForegroundColor Yellow }

function Read-List([string]$path) {
    if (-not (Test-Path $path)) { throw "$path 를 찾을 수 없다" }
    Get-Content $path |
        ForEach-Object { ($_ -split '#')[0].Trim() } |
        Where-Object   { $_ -ne '' }
}

# ---------------------------------------------------------------- 0. 사전 확인
Step '사전 확인'
if (-not $Wheelhouse) { throw "wheelhouse 경로를 알 수 없다. -Wheelhouse 로 지정할 것" }
if (-not (Test-Path $Wheelhouse)) { throw "wheelhouse 폴더가 없다: $Wheelhouse" }
$Wheelhouse = (Resolve-Path $Wheelhouse).Path
Note "wheelhouse: $Wheelhouse"
if (-not (Test-Path (Join-Path $EnvPath 'pyproject.toml'))) {
    throw "pyproject.toml 이 없다: $EnvPath  (-EnvPath 로 올바른 경로를 지정할 것)"
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw "uv 를 찾을 수 없다" }

$whl = Get-ChildItem -Path $Wheelhouse -Filter '*.whl'
Note "wheel $($whl.Count)개 · $([math]::Round((($whl | Measure-Object Length -Sum).Sum / 1MB), 1)) MB"
if ($whl.Count -eq 0) { throw "wheel이 없다" }

# ---------------------------------------------------------------- 1. 무결성
$hashFile = Join-Path $Wheelhouse 'hashes.csv'
if ($SkipHashCheck) {
    Warn '해시 확인 건너뜀 (-SkipHashCheck)'
} elseif (-not (Test-Path $hashFile)) {
    Warn "hashes.csv 가 없어 무결성 확인을 못 한다"
} else {
    Step '무결성 확인 (전송 중 잘린 wheel은 설치 직전에야 터진다)'
    $expected = Import-Csv $hashFile
    $actual   = $whl | Get-FileHash -Algorithm SHA256 |
                Select-Object @{n='Name'; e={ Split-Path $_.Path -Leaf }}, Hash
    $bad = @()
    foreach ($e in $expected) {
        $a = $actual | Where-Object { $_.Name -eq $e.Name }
        if (-not $a)                  { $bad += "$($e.Name) : 파일 없음" }
        elseif ($a.Hash -ne $e.Hash)  { $bad += "$($e.Name) : 해시 불일치" }
    }
    if ($bad.Count -gt 0) {
        $bad | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "무결성 확인 실패 — 다시 복사할 것"
    }
    Note "$($expected.Count)개 모두 일치"
}

# ---------------------------------------------------------------- 2. 백업
Step '백업'
$pyproj = Join-Path $EnvPath 'pyproject.toml'
$lock   = Join-Path $EnvPath 'uv.lock'
Copy-Item $pyproj "$pyproj.bak" -Force
if (Test-Path $lock) { Copy-Item $lock "$lock.bak" -Force }
Note "$pyproj.bak"
if (Test-Path $lock) { Note "$lock.bak" }

# ---------------------------------------------------------------- 3. 설치
$pkgList = Join-Path $Wheelhouse 'packages.txt'
if (-not (Test-Path $pkgList)) { $pkgList = Join-Path $PSScriptRoot 'packages.txt' }
$targets = Read-List $pkgList

try {
    Step "uv add --offline ($($targets -join ', '))"
    Note '전이 의존성은 --find-links 에서 자동으로 끌어간다'
    Push-Location $EnvPath
    & uv add --offline --find-links $Wheelhouse @targets
    if ($LASTEXITCODE -ne 0) { throw "uv add 실패 (종료코드 $LASTEXITCODE)" }

    # ------------------------------------------------------------ 4. import 확인
    Step 'import 확인'
    $impFile = Join-Path $Wheelhouse 'verify-imports.txt'
    if (-not (Test-Path $impFile)) { $impFile = Join-Path $PSScriptRoot 'verify-imports.txt' }
    $mods = Read-List $impFile
    $code = 'import ' + ($mods -join ', ') + '; print("import OK")'
    & uv run python -c $code
    if ($LASTEXITCODE -ne 0) { throw "import 실패" }

    # ------------------------------------------------------------ 5. 회귀 확인
    Step '회귀 확인 (lock 재해석으로 기존 패키지가 밀리지 않았는지)'
    Note '실패해도 설치는 유지된다 — 아래 복구 안내를 보고 판단할 것'
    & uv run python -c "import numpy, pandas, sklearn; print('base OK', numpy.__version__, sklearn.__version__)"
    & uv run python -c "import torch; print('torch OK', torch.__version__, torch.cuda.is_available())"

    Step '완료'
    Write-Host "  설치 성공. 백업은 그대로 남겨 두었다 (.bak)" -ForegroundColor Green
    Write-Host "  기존 노트북이 의심되면: uv run jupyter nbconvert --to notebook --execute --output-dir `$env:TEMP ..\..\cookbook\03-ml-supervised-unsupervised.ipynb"
}
catch {
    Write-Host "`n실패: $_" -ForegroundColor Red
    Step '복구 — pyproject.toml / uv.lock 되돌리기'
    Copy-Item "$pyproj.bak" $pyproj -Force
    if (Test-Path "$lock.bak") { Copy-Item "$lock.bak" $lock -Force }
    Warn '파일은 복구했다. 환경도 되돌리려면: uv sync --offline'
    throw
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
}
