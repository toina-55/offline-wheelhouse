<#
.SYNOPSIS
  옮겨온 wheelhouse를 폐쇄망 uv 프로젝트에 설치한다.

.DESCRIPTION
  기존 main/tabular는 `uv add --offline --find-links`로 추가한다.
  automl312는 별도 Python 3.12 프로젝트를 만들고 wheelhouse만으로 동기화한다.
  기존 프로젝트에 대한 변경은 실패 시 백업(.bak)으로 복구한다.

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

$profileFile = Join-Path $Wheelhouse 'profile.txt'
$Profile = 'main'  # 이전 버전의 wheelhouse는 main으로 취급
if (Test-Path $profileFile) { $Profile = (Get-Content $profileFile -Encoding ASCII | Select-Object -First 1).Trim() }
if ($Profile -notin @('main', 'tabular', 'automl312')) {
    Die "알 수 없는 프로필: $Profile"
}
if (-not $EnvPath) { $EnvPath = Join-Path $HOME "code\local-llm-setup\envs\$Profile" }
if ($Profile -ne 'automl312') {
    $projectFile = Join-Path $EnvPath 'pyproject.toml'
    if (-not (Test-Path $projectFile)) {
        Die "pyproject.toml 이 없다: $EnvPath`n       -EnvPath 로 올바른 경로를 지정할 것"
    }
    if (-not (Select-String -Path $projectFile -Pattern ('^name\s*=\s*"field-' + $Profile + '"') -Quiet)) {
        Die "$Profile 프로필과 설치 대상 프로젝트 이름이 다르다: $projectFile"
    }
    $EnvPath = (Resolve-Path $EnvPath).Path
} else {
    $template = Join-Path $Wheelhouse 'pyproject.toml'
    if (-not (Test-Path $template)) { Die 'automl312 프로젝트 템플릿이 없다' }
    $parent = Split-Path $EnvPath -Parent
    if (-not (Test-Path $parent)) { Die "envs 폴더가 없다: $parent" }
    $existing = Join-Path $EnvPath 'pyproject.toml'
    if (Test-Path $existing) {
        if ((Get-FileHash $template -Algorithm SHA256).Hash -ne (Get-FileHash $existing -Algorithm SHA256).Hash) {
            Die "기존 automl312 프로젝트 설정이 다르다: $existing"
        }
    }
}
Note "프로필      : $Profile"
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
    foreach ($a in $actual) {
        if (-not ($expected | Where-Object { $_.Name -eq $a.Name })) {
            $bad += "$($a.Name) : 해시 목록에 없는 wheel"
        }
    }
    if ($bad.Count -gt 0) {
        $bad | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        Die '무결성 확인 실패 — 다시 복사할 것'
    }
    Note "$($expected.Count)개 모두 일치"
}

# ---------------------------------------------------------------- 2. 백업 또는 독립 프로젝트 생성
if ($Profile -eq 'automl312') {
    Step '독립 프로젝트 준비'
    if (-not (Test-Path $EnvPath)) { New-Item -ItemType Directory -Path $EnvPath -Force | Out-Null }
    if (-not (Test-Path $EnvPath)) { Die "프로젝트 폴더를 만들지 못했다: $EnvPath" }
    $newProject = Join-Path $EnvPath 'pyproject.toml'
    if (-not (Test-Path $newProject)) { Copy-Item $template $newProject -Force }
    if (-not (Test-Path $newProject)) { Die "프로젝트 설정을 복사하지 못했다: $newProject" }
    $EnvPath = (Resolve-Path $EnvPath).Path
} else {
    Step '백업'
    $script:pyproj = Join-Path $EnvPath 'pyproject.toml'
    $script:lock   = Join-Path $EnvPath 'uv.lock'
    Copy-Item $script:pyproj "$($script:pyproj).bak" -Force
    if (-not (Test-Path "$($script:pyproj).bak")) {
        $script:pyproj = $null
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
}

# ---------------------------------------------------------------- 3. 설치
$pkgList = Join-Path $Wheelhouse 'packages.txt'
if (-not (Test-Path $pkgList)) { $pkgList = Join-Path $ScriptDir 'packages.txt' }
$targets = @(Read-List $pkgList)
if ($targets.Count -eq 0) { Die 'packages.txt 가 비어 있다' }

Push-Location $EnvPath
if ((Get-Location).Path -ne $EnvPath) { Die "작업 폴더를 옮기지 못했다: $EnvPath" }
$script:pushed = $true

if ($Profile -eq 'automl312') {
    Step 'uv sync --offline (독립 Python 3.12 환경)'
    Note '모든 의존성을 wheelhouse에서만 해석·설치한다'
    & uv sync --offline --no-index --find-links $Wheelhouse
    if ($LASTEXITCODE -ne 0) { Die "uv sync 실패 (종료코드 $LASTEXITCODE)" }
} else {
    Step "uv add --offline ($($targets -join ', '))"
    Note '전이 의존성은 --find-links 에서 자동으로 끌어간다'
    $constraints = Join-Path $Wheelhouse 'constraints.txt'
    if (Test-Path $constraints) {
        & uv add --offline --find-links $Wheelhouse --constraints $constraints @targets
    } else {
        & uv add --offline --find-links $Wheelhouse @targets
    }
    if ($LASTEXITCODE -ne 0) { Die "uv add 실패 (종료코드 $LASTEXITCODE)" }
}

# ---------------------------------------------------------------- 4. import 확인
Step 'import 확인'
$impFile = Join-Path $Wheelhouse 'verify-imports.txt'
if (-not (Test-Path $impFile)) { $impFile = Join-Path $ScriptDir 'verify-imports.txt' }
$mods = @(Read-List $impFile)
# 🔴 파이썬 코드에 이중인용부호를 쓰지 않는다 — PowerShell 5.1 이 네이티브 명령에
#    인자를 넘길 때 안쪽 " 를 잃어버려 SyntaxError 가 난다
$code = 'import ' + ($mods -join ', ') + "; print('import OK')"
& uv run --offline python -c $code
if ($LASTEXITCODE -ne 0) { Die 'import 실패' }

# ---------------------------------------------------------------- 5. 회귀 확인
Step '환경 확인'
& uv run --offline python -c "import numpy, pandas, sklearn; print('base OK', numpy.__version__, sklearn.__version__)"
$baseOk = ($LASTEXITCODE -eq 0)
$specialOk = $false
if ($Profile -eq 'automl312') {
    & uv run --offline python -c "from pycaret.tasks import ClassificationExperiment; print('PyCaret 4 API OK')"
    $specialOk = ($LASTEXITCODE -eq 0)
} else {
    & uv run --offline python -c "import torch; print('torch OK', torch.__version__, torch.cuda.is_available())"
    $specialOk = ($LASTEXITCODE -eq 0)
}

Pop-Location -ErrorAction SilentlyContinue
$script:pushed = $false

Step '결과'
if ($baseOk -and $specialOk) {
    if ($Profile -eq 'automl312') {
        Write-Host '  독립 PyCaret 4 환경 설치 성공' -ForegroundColor Green
    } else {
        Write-Host '  설치 성공 · 기존 환경 정상. 백업은 그대로 남겨 두었다 (.bak)' -ForegroundColor Green
    }
} else {
    Write-Host '  설치는 됐지만 환경 확인에서 실패했다.' -ForegroundColor Yellow
    if ($script:pyproj) {
        Write-Host '  되돌리려면:' -ForegroundColor Yellow
        Write-Host "    Copy-Item `"$($script:pyproj).bak`" `"$($script:pyproj)`" -Force"
        if ($script:lock) { Write-Host "    Copy-Item `"$($script:lock).bak`" `"$($script:lock)`" -Force" }
        Write-Host '    uv sync --offline'
    }
    exit 1
}
