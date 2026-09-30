<#
.SYNOPSIS
  폐쇄망으로 옮길 Python wheel을 내려받는다.

.DESCRIPTION
  이 노트북에는 아무것도 영구 설치하지 않는다 — 임시 가상환경만 만들어 쓰고 지운다.
  결과물은 wheelhouse\ 폴더 하나이며, 이것만 옮기면 된다.

  받는 쪽 Python 버전은 무관하다(3.14여도 된다). --python-version 으로 대상 버전을
  지정하므로 wheel 태그는 대상 기준으로 골라진다.

.EXAMPLE
  .\download.ps1
  .\download.ps1 -Profile tabular
  .\download.ps1 -Profile automl312
#>
[CmdletBinding()]
param(
    # 결과 wheel을 모을 폴더. 생략하면 프로필별 wheelhouse 폴더
    [string]$OutDir    = '',
    # 대상 설치 프로필
    [ValidateSet('main', 'tabular', 'automl312')]
    [string]$Profile   = 'main',
    # 대상 Python 버전. 생략하면 프로필에서 결정한다.
    [string]$PyVersion = '',
    # 대상 환경의 플랫폼. 64비트 윈도우 = win_amd64
    [string]$Platform  = 'win_amd64',
    # 임시 가상환경을 지우지 않고 남긴다 (디버깅용)
    [switch]$KeepVenv
)

# 🔴 'Stop' 을 쓰지 않는다.
#    PowerShell 5.1 은 네이티브 명령이 stderr 로 쓴 것을 에러 레코드로 만드는데,
#    pip·uv 는 정상 진행 상황을 stderr 로 출력한다. 'Stop' 이면 성공했는데도 죽는다.
#    대신 아래에서 단계마다 종료코드·파일 존재를 직접 확인한다.
$ErrorActionPreference = 'Continue'

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Note([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn([string]$m) { Write-Host "    $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "`n실패: $m" -ForegroundColor Red; exit 1 }

# 🔴 $PSScriptRoot 는 실행 방식에 따라 빈 값일 수 있다(콘솔 붙여넣기·dot-sourcing 등).
#    param 기본값에서 Join-Path $PSScriptRoot 를 쓰면 "Path 매개 변수가 빈 문자열" 오류가 난다.
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$ProfileDir = $ScriptDir
$ExpectedPy = '312'
if ($Profile -eq 'tabular') {
    $ProfileDir = Join-Path $ScriptDir 'profiles\tabular'
} elseif ($Profile -eq 'automl312') {
    $ProfileDir = Join-Path $ScriptDir 'profiles\automl312'
}
if (-not (Test-Path $ProfileDir)) { Die "프로필 폴더가 없다: $ProfileDir" }
if (-not $PyVersion) { $PyVersion = $ExpectedPy }
if ($PyVersion -ne $ExpectedPy) {
    Die "$Profile 프로필은 Python $ExpectedPy 용이다. -PyVersion $PyVersion 과 맞지 않는다"
}
if (-not $OutDir) {
    $folder = 'wheelhouse'
    if ($Profile -ne 'main') { $folder = "wheelhouse-$Profile" }
    $OutDir = Join-Path $ScriptDir $folder
}
Note "스크립트 폴더: $ScriptDir"
Note "프로필: $Profile ($ProfileDir)"

function Read-List([string]$name) {
    $p = Join-Path $ProfileDir $name
    if (-not (Test-Path $p)) { Die "$name 을 찾을 수 없다 ($p)" }
    # -Encoding UTF8 명시 — PowerShell 5.1 은 BOM 없는 파일을 ANSI(한국어는 CP949)로 읽는다
    Get-Content $p -Encoding UTF8 |
        ForEach-Object { ($_ -split '#')[0].Trim() } |
        Where-Object   { $_ -ne '' }
}

# ---------------------------------------------------------------- 0. 목록
$targets = @(Read-List 'packages.txt')
$extras  = @()
$sdists  = @()
if (Test-Path (Join-Path $ProfileDir 'extra-deps.txt')) { $extras = @(Read-List 'extra-deps.txt') }
if (Test-Path (Join-Path $ProfileDir 'sdist-only.txt')) { $sdists = @(Read-List 'sdist-only.txt') }
$binary  = @($targets) + @($extras)
if ($binary.Count -eq 0) { Die 'packages.txt·extra-deps.txt 가 비어 있다' }

Step "대상: $Profile / Python $PyVersion / $Platform"
Note "wheel 내려받기 : $($binary -join ', ')"
Note "sdist에서 빌드 : $($sdists -join ', ')"

# ---------------------------------------------------------------- 1. Python
Step 'Python 확인'
$py = $null
foreach ($c in @('py', 'python', 'python3')) {
    $found = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found -and $found.Source) { $py = $found.Source; break }
}
if (-not $py) {
    Die "Python을 찾지 못했다. https://www.python.org/downloads/windows/ 에서 설치 후 새 창에서 다시 실행할 것 (버전은 무관 — 대상 버전은 -PyVersion 으로 지정한다)"
}
Note $py
& $py -V

# ---------------------------------------------------------------- 2. 임시 가상환경
Step '임시 가상환경 생성 (이 노트북에 영구 설치 없음)'
$venv = Join-Path $ScriptDir '.venv-dl'
if (Test-Path $venv) { Remove-Item $venv -Recurse -Force }
& $py -m venv $venv
$vpy = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $vpy)) { Die "가상환경 생성 실패 — python을 찾을 수 없다 ($vpy)" }

# pip 최신화는 실패해도 치명적이지 않다
& $vpy -m pip install --upgrade pip --disable-pip-version-check
if ($LASTEXITCODE -ne 0) { Warn 'pip 최신화 실패 — 기존 pip으로 계속한다' }

try {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    if (-not (Test-Path $OutDir)) { Die "출력 폴더를 만들 수 없다: $OutDir" }
    if (@(Get-ChildItem -Path $OutDir -Filter '*.whl').Count -gt 0) {
        Die "$OutDir 에 기존 wheel이 있다. 다른 -OutDir 를 쓰거나 기존 폴더를 정리할 것"
    }

    # ------------------------------------------------------------ 3. wheel 내려받기
    Step "wheel 내려받기 -> $OutDir"
    if ($Profile -eq 'automl312') {
        # 새 독립 환경은 기존 uv.lock이 없다. 모든 전이 의존성을 함께 받는다.
        Note '독립 환경: pip이 전체 의존성을 풀어 모든 wheel을 받는다'
        & $vpy -m pip download @targets `
            -d $OutDir `
            --only-binary=:all: `
            --platform $Platform `
            --python-version $PyVersion `
            --implementation cp `
            --abi "cp$PyVersion"
    } else {
        Note '--no-deps 이므로 필요한 것은 목록에 모두 있어야 한다'
        & $vpy -m pip download @binary `
            -d $OutDir `
            --no-deps `
            --only-binary=:all: `
            --platform $Platform `
            --python-version $PyVersion `
            --implementation cp `
            --abi "cp$PyVersion"
    }
    if ($LASTEXITCODE -ne 0) { Die "pip download 실패 (종료코드 $LASTEXITCODE)" }

    # ------------------------------------------------------------ 4. sdist -> wheel
    if ($sdists.Count -gt 0) {
        Step 'sdist에서 wheel 빌드'
        Note '순수 Python·데이터 패키지 전제 (결과는 py3-none-any 라 버전·OS 무관)'
        foreach ($s in $sdists) {
            & $vpy -m pip wheel $s --no-deps -w $OutDir
            if ($LASTEXITCODE -ne 0) { Die "pip wheel $s 실패 (종료코드 $LASTEXITCODE)" }
        }
    }

    # ------------------------------------------------------------ 5. 해시·요약
    Step '해시 기록'
    $whl = @(Get-ChildItem -Path $OutDir -Filter '*.whl')
    if ($whl.Count -eq 0) { Die 'wheel이 하나도 없다' }
    $hashCsv = Join-Path $OutDir 'hashes.csv'
    $whl | Get-FileHash -Algorithm SHA256 |
        Select-Object @{n='Name'; e={ Split-Path $_.Path -Leaf }}, Hash |
        Sort-Object Name |
        Export-Csv $hashCsv -NoTypeInformation -Encoding UTF8
    if (-not (Test-Path $hashCsv)) { Warn 'hashes.csv 를 만들지 못했다 — 무결성 확인 없이 옮기게 된다' }

    # 폐쇄망에서는 clone을 못 하므로, 설치에 필요한 것을 wheelhouse 안에 함께 담는다
    Step '설치 스크립트·목록 동봉'
    Copy-Item (Join-Path $ScriptDir 'install.ps1') $OutDir -Force
    foreach ($f in @('packages.txt', 'verify-imports.txt')) {
        $src = Join-Path $ProfileDir $f
        if (-not (Test-Path $src)) { Die "설치 목록이 없다: $src" }
        Copy-Item $src $OutDir -Force
        Note $f
    }
    if ($Profile -eq 'automl312') {
        Copy-Item (Join-Path $ProfileDir 'pyproject.toml') $OutDir -Force
        Note 'pyproject.toml'

        # 🔑 해석(lock)을 여기서 끝낸다.
        #    pip 과 uv 는 해석기가 달라, 폐쇄망에서 uv 가 다시 풀면 pip 이 받은 것과
        #    어긋나 실패할 수 있다. 지금 wheelhouse 만으로 lock 을 만들어 동봉하면
        #    설치 쪽은 "이미 정해진 것을 설치"만 하게 된다.
        if (Get-Command uv -CommandType Application -ErrorAction SilentlyContinue) {
            Step 'uv.lock 생성 (wheelhouse 만으로 해석)'
            $lockDir = Join-Path $ScriptDir '.lockgen'
            if (Test-Path $lockDir) { Remove-Item $lockDir -Recurse -Force }
            New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
            Copy-Item (Join-Path $ProfileDir 'pyproject.toml') $lockDir -Force
            Push-Location $lockDir
            & uv lock --offline --no-index --find-links $OutDir
            $lockCode = $LASTEXITCODE
            Pop-Location -ErrorAction SilentlyContinue
            $lockFile = Join-Path $lockDir 'uv.lock'
            if ($lockCode -eq 0 -and (Test-Path $lockFile)) {
                Copy-Item $lockFile $OutDir -Force
                Note 'uv.lock (동봉 — 폐쇄망에서 재해석 불필요)'
            } else {
                # 다운로드는 끝났다. lock 실패로 전체를 실패시키지 않는다.
                Warn "uv lock 실패 (종료코드 $lockCode) — uv.lock 없이 진행한다."
                Warn '폐쇄망에서 uv 가 다시 해석하며 실패할 수 있다. 위 오류를 먼저 해결할 것.'
            }
            Remove-Item $lockDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Warn 'uv 가 없어 uv.lock 을 만들지 못했다 — 폐쇄망에서 재해석을 시도하게 된다'
        }
    }
    Set-Content (Join-Path $OutDir 'profile.txt') $Profile -Encoding ASCII
    if ($Profile -ne 'automl312') {
        $pins = @($binary | Where-Object { $_ -match '==' })
        if ($pins.Count -gt 0) {
            Set-Content (Join-Path $OutDir 'constraints.txt') $pins -Encoding ASCII
            Note 'constraints.txt'
        }
    }
    Note 'profile.txt · install.ps1'

    Step '결과'
    $sum = ($whl | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("  wheel {0}개 · 합계 {1:N1} MB" -f $whl.Count, $sum) -ForegroundColor Green
    $whl | Sort-Object Length -Descending | ForEach-Object {
        Write-Host ("  {0,9:N1} MB  {1}" -f ($_.Length / 1MB), $_.Name)
    }

    Write-Host ''
    Write-Host '다음: 아래 폴더 전체를 폐쇄망 노트북으로 옮긴다 (install.ps1 이 안에 들어 있다).' -ForegroundColor Yellow
    Write-Host "  $OutDir"
    Write-Host ''
    Write-Host '  옮긴 뒤 그 폴더에서:' -ForegroundColor Yellow
    Write-Host '    .\install.ps1'
}
finally {
    if (-not $KeepVenv) {
        if (Test-Path $venv) { Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue }
        Note '임시 가상환경 삭제됨'
    } else {
        Note "임시 가상환경 유지: $venv"
    }
}
