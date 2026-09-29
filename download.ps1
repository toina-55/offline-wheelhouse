<#
.SYNOPSIS
  폐쇄망으로 옮길 Python wheel을 내려받는다.

.DESCRIPTION
  이 노트북에는 아무것도 영구 설치하지 않는다 — 임시 가상환경만 만들어 쓰고 지운다.
  결과물은 wheelhouse\ 폴더 하나이며, 이것만 옮기면 된다.

.EXAMPLE
  .\download.ps1
  .\download.ps1 -PyVersion 311 -OutDir D:\wheelhouse-automl
#>
[CmdletBinding()]
param(
    # 결과 wheel을 모을 폴더
    [string]$OutDir    = (Join-Path $PSScriptRoot 'wheelhouse'),
    # 대상 환경의 Python 버전. envs\main = 312, envs\automl = 311
    [string]$PyVersion = '312',
    # 대상 환경의 플랫폼. 64비트 윈도우 = win_amd64
    [string]$Platform  = 'win_amd64',
    # 임시 가상환경을 지우지 않고 남긴다 (디버깅용)
    [switch]$KeepVenv
)

$ErrorActionPreference = 'Stop'
function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Note([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }

function Read-List([string]$name) {
    $p = Join-Path $PSScriptRoot $name
    if (-not (Test-Path $p)) { throw "$name 을 찾을 수 없다 ($p)" }
    Get-Content $p |
        ForEach-Object { ($_ -split '#')[0].Trim() } |
        Where-Object   { $_ -ne '' }
}

# ---------------------------------------------------------------- 0. 목록
$targets = Read-List 'packages.txt'
$extras  = Read-List 'extra-deps.txt'
$sdists  = Read-List 'sdist-only.txt'
$binary  = @($targets) + @($extras)

Step "대상: Python $PyVersion / $Platform"
Note "wheel 내려받기 : $($binary -join ', ')"
Note "sdist에서 빌드 : $($sdists -join ', ')"

# ---------------------------------------------------------------- 1. Python
Step 'Python 확인'
$py = $null
foreach ($c in @('py', 'python', 'python3')) {
    $found = Get-Command $c -ErrorAction SilentlyContinue
    if ($found) { $py = $found.Source; break }
}
if (-not $py) {
    throw "Python을 찾지 못했다. https://www.python.org/downloads/windows/ 에서 설치 후 새 창에서 다시 실행할 것. (버전은 아무거나 무관 — 대상 버전은 -PyVersion 으로 지정한다)"
}
Note $py
& $py -V

# ---------------------------------------------------------------- 2. 임시 가상환경
Step '임시 가상환경 생성 (이 노트북에 영구 설치 없음)'
$venv = Join-Path $PSScriptRoot '.venv-dl'
if (Test-Path $venv) { Remove-Item $venv -Recurse -Force }
& $py -m venv $venv
$vpy = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $vpy)) { throw "가상환경 python을 찾을 수 없다 ($vpy)" }
& $vpy -m pip install --upgrade pip --quiet --disable-pip-version-check
Note (& $vpy -m pip --version)

try {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    # ------------------------------------------------------------ 3. wheel 내려받기
    Step "wheel 내려받기 → $OutDir"
    Note "--no-deps 이므로 필요한 것은 목록에 모두 있어야 한다"
    & $vpy -m pip download @binary `
        -d $OutDir `
        --no-deps `
        --only-binary=:all: `
        --platform $Platform `
        --python-version $PyVersion `
        --implementation cp `
        --abi "cp$PyVersion"
    if ($LASTEXITCODE -ne 0) { throw "pip download 실패 (종료코드 $LASTEXITCODE)" }

    # ------------------------------------------------------------ 4. sdist → wheel
    if ($sdists.Count -gt 0) {
        Step 'sdist에서 wheel 빌드'
        Note '순수 Python·데이터 패키지 전제 (결과는 py3-none-any)'
        foreach ($s in $sdists) {
            & $vpy -m pip wheel $s --no-deps -w $OutDir
            if ($LASTEXITCODE -ne 0) { throw "pip wheel $s 실패 (종료코드 $LASTEXITCODE)" }
        }
    }

    # ------------------------------------------------------------ 5. 해시·요약
    Step '해시 기록'
    $whl = Get-ChildItem -Path $OutDir -Filter '*.whl'
    if ($whl.Count -eq 0) { throw "wheel이 하나도 없다" }
    $whl | Get-FileHash -Algorithm SHA256 |
        Select-Object @{n='Name'; e={ Split-Path $_.Path -Leaf }}, Hash |
        Sort-Object Name |
        Export-Csv (Join-Path $OutDir 'hashes.csv') -NoTypeInformation -Encoding UTF8

    Copy-Item (Join-Path $PSScriptRoot 'verify-imports.txt') $OutDir -Force
    Copy-Item (Join-Path $PSScriptRoot 'packages.txt')       $OutDir -Force

    Step '결과'
    $sum = ($whl | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("  wheel {0}개 · 합계 {1:N1} MB" -f $whl.Count, $sum) -ForegroundColor Green
    $whl | Sort-Object Length -Descending | ForEach-Object {
        Write-Host ("  {0,9:N1} MB  {1}" -f ($_.Length / 1MB), $_.Name)
    }

    Write-Host ""
    Write-Host "다음: 아래 폴더 전체를 폐쇄망 노트북으로 옮긴 뒤 install.ps1 을 실행한다." -ForegroundColor Yellow
    Write-Host "  $OutDir"
}
finally {
    if (-not $KeepVenv) {
        if (Test-Path $venv) { Remove-Item $venv -Recurse -Force }
        Note '임시 가상환경 삭제됨'
    } else {
        Note "임시 가상환경 유지: $venv"
    }
}
