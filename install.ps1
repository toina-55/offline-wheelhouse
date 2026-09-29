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
  .\install.ps1 -Wheelhouse C:\transfer\wheelhouse -EnvPath D:\code\local-llm-setup\envs\main
#>
[CmdletBinding()]
param(
    # 옮겨온 wheelhouse 폴더. 생략하면 이 스크립트가 있는 폴더를 쓴다
    [string]$Wheelhouse = '',
    # 설치 대상 uv 프로젝트 (pyproject.toml 이 있는 폴더)
    [string]$EnvPath = '',
    # 해시 확인을 건너뛴다 (권장하지 않음)
    [switch]$SkipHashCheck
)

# 🔴 'Stop' 을 쓰지 않는다 — uv 는 정상 진행 상황을 stderr 로 출력하고,
#    PowerShell 5.1 은 그것을 에러로 만든다. 'Stop' 이면 성공했는데도 죽는다.
#    대신 단계마다 종료코드·파일 존재를 직접 확인한다.
$ErrorActionPreference = 'Continue'

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Note([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn([string]$m) { Write-Host "    $m" -ForegroundColor Yellow }

# 🔴 $PSScriptRoot 는 실행 방식에 따라 빈 값일 수 있다 → Join-Path 가 빈 문자열 오류를 낸다
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir)  { $ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir)  { $ScriptDir  = (Get-Location).Path }
if (-not $Wheelhouse) { $Wheelhouse = $ScriptDir }
if (-not $EnvPath)    { $EnvPath    = Join-Path $HOME 'code\local-llm-setup\envs\main' }

# 복구용 상태
$script:pyproj = $null
$script:lock   = $null
$script:pushed = $false

function Restore-Backup {
    if ($script:pyproj -and (Test-Path "$($script:pyproj).bak")) {
        Copy-Item "$($script:pyproj).bak" $script:pyproj -Force
        Warn 'pyproject.toml 복구'
    }
    if ($script:lock -and (Test-Path "$($script:lock).bak")) {
        Copy-Item "$($script:lock).bak" $script:lock -Force
        Warn 'uv.lock 복구'
    }
    Warn '환경도 되돌리려면: uv sync --offline'
}

function Die([string]$m) {
    Write-Host "`n실패: $m" -ForegroundColor Red
    if ($script:pyproj) { Step '복구'; Restore-Backup }
    if ($script:pushed) { Pop-Location -ErrorAction SilentlyContinue }
    exit 1
}

function Read-List([string]$path) {
    if (-not (Test-Path $path)) { Die "$path 를 찾을 수 없다" }
    # -Encoding UTF8 명시 — PowerShell 5.1 은 BOM 없는 파일을 ANSI(한국어는 CP949)로 읽는다
    Get-Content $path -Encoding UTF8 |
        ForEach-Object { ($_ -split '#')[0].Trim() } |
        Where-Object   { $_ -ne '' }
}

# ---------------------------------------------------------------- 0. 사전 확인
Step '사전 확인'
if (-not (Test-Path $Wheelhouse)) { Die "wheelhouse 폴더가 없다: $Wheelhouse" }
$Wheelhouse = (Resolve-Path $Wheelhouse).Path
Note "wheelhouse : $Wheelhouse"

if (-not (Test-Path (Join-Path $EnvPath 'pyproject.toml'))) {
    Die "pyproject.toml 이 없다: $EnvPath`n       -EnvPath 로 올바른 경로를 지정할 것"
}
$EnvPath = (Resolve-Path $EnvPath).Path
Note "설치 대상   : $EnvPath"

if (-not (Get-Command uv -CommandType Application -ErrorAction SilentlyContinue)) {
    Die 'uv 를 찾을 수 없다'
}

$whl = @(Get-ChildItem -Path $Wheelhouse -Filter '*.whl')
if ($whl.Count -eq 0) { Die "wheel이 없다: $Wheelhouse" }
$mb = [math]::Round((($whl | Measure-Object Length -Sum).Sum / 1MB), 1)
Note "wheel $($whl.Count)개 · $mb MB"

# ---------------------------------------------------------------- 1. 무결성
$hashFile = Join-Path $Wheelhouse 'hashes.csv'
if ($SkipHashCheck) {
    Warn '해시 확인 건너뜀 (-SkipHashCheck)'
} elseif (-not (Test-Path $hashFile)) {
    Warn 'hashes.csv 가 없어 무결성 확인을 못 한다'
} else {
    Step '무결성 확인 (전송 중 잘린 wheel은 설치 직전에야 터진다)'
    $expected = @(Import-Csv $hashFile)
    $actual   = $whl | Get-FileHash -Algorithm SHA256 |
                Select-Object @{n='Name'; e={ Split-Path $_.Path -Leaf }}, Hash
    $bad = @()
    foreach ($e in $expected) {
        $a = $actual | Where-Object { $_.Name -eq $e.Name }
        if (-not $a)                 { $bad += "$($e.Name) : 파일 없음" }
        elseif ($a.Hash -ne $e.Hash) { $bad += "$($e.Name) : 해시 불일치" }
    }
    if ($bad.Count -gt 0) {
        $bad | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        Die '무결성 확인 실패 — 다시 복사할 것'
    }
    Note "$($expected.Count)개 모두 일치"
}

# ---------------------------------------------------------------- 2. 백업
Step '백업'
$script:pyproj = Join-Path $EnvPath 'pyproject.toml'
$script:lock   = Join-Path $EnvPath 'uv.lock'
Copy-Item $script:pyproj "$($script:pyproj).bak" -Force
if (-not (Test-Path "$($script:pyproj).bak")) {
    $script:pyproj = $null          # 백업이 없으면 복구도 시도하지 않는다
    Die '백업을 만들지 못했다 — 쓰기 권한을 확인할 것'
}
Note "$($script:pyproj).bak"
if (Test-Path $script:lock) {
    Copy-Item $script:lock "$($script:lock).bak" -Force
    Note "$($script:lock).bak"
} else {
    $script:lock = $null
    Warn 'uv.lock 이 없다 (첫 동기화 전 상태로 보인다)'
}

# ---------------------------------------------------------------- 3. 설치
$pkgList = Join-Path $Wheelhouse 'packages.txt'
if (-not (Test-Path $pkgList)) { $pkgList = Join-Path $ScriptDir 'packages.txt' }
$targets = @(Read-List $pkgList)
if ($targets.Count -eq 0) { Die 'packages.txt 가 비어 있다' }

Push-Location $EnvPath
if ((Get-Location).Path -ne $EnvPath) { Die "작업 폴더를 옮기지 못했다: $EnvPath" }
$script:pushed = $true

Step "uv add --offline ($($targets -join ', '))"
Note '전이 의존성은 --find-links 에서 자동으로 끌어간다'
& uv add --offline --find-links $Wheelhouse @targets
if ($LASTEXITCODE -ne 0) { Die "uv add 실패 (종료코드 $LASTEXITCODE)" }

# ---------------------------------------------------------------- 4. import 확인
Step 'import 확인'
$impFile = Join-Path $Wheelhouse 'verify-imports.txt'
if (-not (Test-Path $impFile)) { $impFile = Join-Path $ScriptDir 'verify-imports.txt' }
$mods = @(Read-List $impFile)
# 🔴 파이썬 코드에 이중인용부호를 쓰지 않는다 — PowerShell 5.1 이 네이티브 명령에
#    인자를 넘길 때 안쪽 " 를 잃어버려 SyntaxError 가 난다
$code = 'import ' + ($mods -join ', ') + "; print('import OK')"
& uv run python -c $code
if ($LASTEXITCODE -ne 0) { Die 'import 실패' }

# ---------------------------------------------------------------- 5. 회귀 확인
Step '회귀 확인 (lock 재해석으로 기존 패키지가 밀리지 않았는지)'
Note '여기서 실패하면 설치는 끝났지만 기존 환경이 흔들렸다는 뜻이다'
& uv run python -c "import numpy, pandas, sklearn; print('base OK', numpy.__version__, sklearn.__version__)"
$baseOk = ($LASTEXITCODE -eq 0)
& uv run python -c "import torch; print('torch OK', torch.__version__, torch.cuda.is_available())"
$torchOk = ($LASTEXITCODE -eq 0)

Pop-Location -ErrorAction SilentlyContinue
$script:pushed = $false

Step '결과'
if ($baseOk -and $torchOk) {
    Write-Host '  설치 성공 · 기존 환경 정상. 백업은 그대로 남겨 두었다 (.bak)' -ForegroundColor Green
} else {
    Write-Host '  설치는 됐지만 기존 패키지 확인에서 실패했다.' -ForegroundColor Yellow
    Write-Host '  되돌리려면:' -ForegroundColor Yellow
    Write-Host "    Copy-Item `"$($script:pyproj).bak`" `"$($script:pyproj)`" -Force"
    if ($script:lock) { Write-Host "    Copy-Item `"$($script:lock).bak`" `"$($script:lock)`" -Force" }
    Write-Host '    uv sync --offline'
}
Write-Host '  기존 노트북이 더 의심되면 cookbook 03 노트북을 재실행해 볼 것:'
Write-Host '    uv run jupyter nbconvert --to notebook --execute --output-dir $env:TEMP ..\..\cookbook\03-ml-supervised-unsupervised.ipynb'
