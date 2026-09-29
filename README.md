# offline-wheelhouse

인터넷이 없는 Windows 머신에 Python 패키지를 넣기 위해, **다른 Windows 머신에서 wheel만 받아 파일로 옮기는** 절차와 스크립트. 먼저 `local-llm-setup`의 기존 환경을 설치한 뒤 사용한다.

- **받는 쪽**(인터넷 있음) — `download.ps1`. 그 머신에 아무것도 영구 설치하지 않는다(임시 가상환경만 쓰고 지움).
- **설치하는 쪽**(인터넷 없음) — `install.ps1`. `uv` 프로젝트에 넣는다.
- 프로필마다 생성된 **wheelhouse 폴더 하나**만 옮기면 된다. 여러 환경에 설치하려면 해당 폴더를 각각 옮긴다.

## 빠른 사용

```powershell
# ── 인터넷 있는 Windows 머신
PS> git clone https://github.com/toina-55/offline-wheelhouse.git
PS> cd offline-wheelhouse
PS> .\download.ps1                    # main → .\wheelhouse\
PS> .\download.ps1 -Profile tabular   # → .\wheelhouse-tabular\
PS> .\download.ps1 -Profile automl312 # → .\wheelhouse-automl312\

# ── wheelhouse 폴더를 옮긴 뒤, 인터넷 없는 Windows 머신
PS> cd C:\transfer\wheelhouse
PS> .\install.ps1           # main에 설치
PS> cd C:\transfer\wheelhouse-tabular
PS> .\install.ps1           # tabular에 설치
PS> cd C:\transfer\wheelhouse-automl312
PS> .\install.ps1           # 새 envs\automl312 생성 (PyCaret 4 / Python 3.12)
```

**`download.ps1`이 설치 스크립트·패키지 목록·프로필 정보·해시를 각 wheelhouse 안에 함께 담는다.** `automl312`에는 새 프로젝트의 `pyproject.toml`과 전체 전이 의존성 wheel도 담는다.

설치 대상 경로가 다르면:

```powershell
PS> .\install.ps1 -EnvPath D:\somewhere\envs\main
```

`PowerShell 실행 정책`에 막히면:

```powershell
PS> powershell -ExecutionPolicy Bypass -File .\download.ps1
```

### 🔴 *"문자열에 종결자 '가 없습니다"* 오류가 나면

**인코딩 문제이고 스크립트 문법 문제가 아니다.** 윈도우 기본 PowerShell 5.1은 **BOM 없는 `.ps1`을 ANSI(한국어 윈도우 = CP949)로 읽는다.** 이 스크립트에는 한글 주석이 많아서, UTF-8 바이트가 CP949로 잘못 해독되면 생긴 쓰레기 바이트를 파서가 따옴표로 인식해 **엉뚱한 구문 오류**를 낸다.

이 저장소의 `.ps1`은 **UTF-8 BOM + CRLF**로 커밋돼 있어 정상이라면 나지 않는다. 그래도 났다면:

```powershell
# 1) BOM 확인 — EF BB BF 로 시작해야 한다
PS> Format-Hex .\download.ps1 -Count 3

# 2) 없으면 다시 저장
PS> $t = Get-Content .\download.ps1 -Raw -Encoding UTF8
PS> [System.IO.File]::WriteAllText("$PWD\download.ps1", $t, (New-Object System.Text.UTF8Encoding $true))
```

편집기로 열어 고쳤다면 **"UTF-8 with BOM"으로 저장**해야 한다(VS Code: 하단 인코딩 → `Save with Encoding` → `UTF-8 with BOM`).

그래도 막히면 아래 **"스크립트 없이 손으로 하기"**를 쓰면 된다 — 한글이 없는 명령뿐이라 인코딩과 무관하다.

## 무엇을 받는가

`main`·`tabular` 프로필은 각 대상의 기존 `uv.lock`을 기준으로 부족한 패키지만 받는다. `automl312`는 새 독립 환경이므로 pip으로 전체 전이 의존성 wheel을 받는다.

| 프로필 | 설치 대상 | Python | 추가 목표 |
| --- | --- | --- | --- |
| `main` (기본값) | 기존 `envs/main` | 3.12 | 이 저장소의 기존 분석 패키지 12종 |
| `tabular` | 기존 `envs/tabular` | 3.12 | CatBoost, Tabulate, LightGBM, XGBoost |
| `automl312` | 새 `envs/automl312` | 3.12 | PyCaret 4.0.0a8, CatBoost, XGBoost, LightGBM, Optuna, Tabulate, 노트북 실행 도구 |

기존 `envs/automl`(Python 3.11, PyCaret 3.3.2)은 그대로 둔다. `automl312`는 [PyCaret 4의 사전 릴리스](https://pypi.org/project/pycaret/4.0.0a8/)를 고정한 별도 실험 환경이다. 기존 `cookbook/06-automl-pycaret.ipynb`는 PyCaret 3 API용이므로 새 환경에서 그대로 실행하는 검증 대상은 아니다.

`automl312`에서 새 API를 확인하려면:

```powershell
PS> cd $HOME\code\local-llm-setup\envs\automl312
PS> uv run --offline python -c "from pycaret.tasks import ClassificationExperiment; print('PyCaret 4 OK')"
```

PyCaret 4 예제는 `from pycaret.tasks import ClassificationExperiment`로 시작한다. [공식 릴리스 설명](https://pypi.org/project/pycaret/4.0.0a8/)의 실험 API를 사용해야 한다.

기존 `main` 목록은 세 파일로 나뉜다. **대상 환경에 이미 있는 패키지는 일부러 제외**했다 — `--no-deps`로 받기 때문에 목록에 없으면 받지 않는다.

| 파일 | 뜻 |
| --- | --- |
| `packages.txt` | 설치 목표. `install.ps1`이 `uv add`에 넘긴다 |
| `extra-deps.txt` | 목표의 전이 의존성 중 **대상 환경에 없는 것만**. 받기만 하고 `uv add`엔 안 넘긴다 |
| `sdist-only.txt` | PyPI에 wheel이 없어 **온라인에서 `pip wheel`로 빌드**해야 하는 것 |
| `verify-imports.txt` | 설치 후 import 확인용 모듈명(pip 이름과 다른 것이 있다) |

`main`의 기존 목록(2026-09-29 기준, wheel 18개 · 합계 약 **229MB**):

| wheel | 구분 | 크기 |
| --- | --- | --- |
| `catboost` | 목표 — 순서형 타깃 통계(타깃 인코딩 누수 대조군) | 95.6MB |
| **`interpret-core`** | 목표 — EBM glass-box 모델. 🔴 메타패키지 `interpret` 이 아니다(그쪽은 dash·flask·gevent·aplr·SALib 를 끌고 온다). 네이티브 라이브러리를 플랫폼별로 wheel 안에 담고 있다(`libebm_win_x64.dll` 확인) | 14.9MB |
| `imodels` | 목표 — 규칙 학습(RuleFit 등) | 0.33MB |
| `sweetviz` | 목표 — EDA 리포트, `compare(train, test)` | 14.4MB |
| `kiwipiepy` | 목표 — 한국어 형태소 (cp39-abi3, Python 3.9+ 공용) | 3.7MB |
| `phik` | 목표 — 혼합형 변수 상관 | 0.6MB |
| `category-encoders` · `xlrd` · `umap-learn` · `crepes` · `metric-learn` · `tabulate` | 목표 | 각 0.1MB 미만 |
| `plotly` | catboost 의존 | 9.2MB |
| `mlxtend` | imodels 의존 | 1.3MB |
| `graphviz` · `pynndescent` · `importlib-resources` | catboost · umap-learn · sweetviz 의존 | 각 0.1MB 미만 |
| **`kiwipiepy_model`** | kiwipiepy 의존 · **sdist만 있어 빌드 필요** | **88MB** |

> `tabulate`는 용량이 0.04MB인데 없으면 **`df.to_markdown()` 자체가 동작하지 않는다.** 분석 결과를 마크다운 표로 옮길 일이 있으면 필수.

## 🔴 알아둘 것 다섯

**1. Python 버전·플랫폼이 정확히 맞아야 한다.** wheel은 `cp312`·`win_amd64` 같은 태그로 묶여 있다. 세 프로필 모두 **Python 3.12 / 64비트 Windows**를 대상으로 한다. 스크립트는 프로필과 다른 `-PyVersion`을 거부한다.

```powershell
PS> .\download.ps1 -Profile automl312 -OutDir D:\wheelhouse-automl312
```

받는 머신의 Python 버전은 **무관하다** — 대상 버전의 wheel을 고르도록 지정하므로. 단 `kiwipiepy_model`처럼 wheel이 없는 sdist를 빌드하는 `main` 프로필은 순수 Python·데이터 패키지라는 전제가 있다.

**2. 기존 환경용 `main`·`tabular`는 `pip download --no-deps`로 돈다.** 대상 환경에 이미 있는 것을 다시 받지 않으려는 의도다. 그래서 **대상 환경이 바뀌면 `extra-deps.txt`를 다시 점검해야 한다.** 새 환경용 `automl312`는 전체 의존성을 받으므로 기존 캐시에 의존하지 않는다.

**3. sdist만 있는 패키지는 미리 wheel로 만든다.** `pip download --only-binary=:all:`은 sdist를 거부하고, `--platform`을 쓰면 `--only-binary`가 강제된다. 그래서 `sdist-only.txt`의 것은 `pip wheel`로 빌드한다. **순수 Python·데이터 패키지만** 이렇게 할 수 있다 — C 확장이 있으면 빌드 결과가 빌드한 OS에 묶이므로 Windows에서 빌드해야 한다.

**4. 기존 `main`·`tabular`에는 `uv pip install`이 아니라 `uv add`를 쓴다.** `uv run`은 실행 전에 환경을 `uv.lock`에 맞춰 자동 동기화하면서 **lock에 없는 패키지를 지운다.** `uv pip install`로 넣으면 다음 `uv run`에서 조용히 사라진다(실측 확인). 새 `automl312`는 동봉한 `pyproject.toml`에서 `uv sync --offline --no-index --find-links`로 만든다.

> 🔴 **단 `uv add --offline`은 프로젝트 전체를 다시 해석한다.** 새 패키지는 `--find-links`에서, **기존 패키지는 uv 캐시에서** 가져오는데, 캐시에 없는 버전이 하나라도 있으면 거기서 멈춘다(실측: 캐시에 없는 `scipy`에서 실패). 그래서 **기존 환경용 프로필은 대상 머신의 uv 캐시를 지우지 않는 것이 전제**다.

**5. 메타패키지에 `extras`가 걸려 있는지 본다.** `Requires-Dist`에 `pkg[extra1,extra2]==x.y` 형태가 있으면, 그 extras의 의존성까지 전부 딸려온다. 실제로 `interpret`(메타)가 `interpret-core[aplr,dash,debug,notebook,plotly,sensitivity,shap]`을 요구해 **dash·dash-cytoscape·flask·gevent·aplr·SALib**를 끌고 오려 했다. 그래서 이 저장소는 **`interpret-core`를 직접** 쓴다 — EBM은 core만으로 동작한다(실측 확인).

## 스크립트 없이 손으로 하기 (`main` 전용)

스크립트가 막히면 아래를 그대로 붙여 쓰면 된다.

```powershell
# ── 인터넷 있는 쪽
PS> python -m venv .venv-dl
PS> .\.venv-dl\Scripts\python.exe -m pip install --upgrade pip

PS> .\.venv-dl\Scripts\python.exe -m pip download `
      catboost category-encoders xlrd phik kiwipiepy umap-learn `
      crepes metric-learn tabulate interpret-core imodels sweetviz `
      plotly graphviz pynndescent mlxtend importlib-resources `
      -d wheelhouse --no-deps --only-binary=:all: `
      --platform win_amd64 --python-version 312 --implementation cp --abi cp312

PS> .\.venv-dl\Scripts\python.exe -m pip wheel kiwipiepy_model --no-deps -w wheelhouse

PS> Get-FileHash wheelhouse\*.whl | Export-Csv wheelhouse\hashes.csv -NoTypeInformation
PS> Remove-Item .venv-dl -Recurse -Force
```

```powershell
# ── 인터넷 없는 쪽
PS> cd C:\transfer\wheelhouse
PS> Get-FileHash *.whl | Export-Csv after.csv -NoTypeInformation
PS> Compare-Object (Import-Csv hashes.csv).Hash (Import-Csv after.csv).Hash   # 출력 없으면 정상

PS> cd $HOME\code\local-llm-setup\envs\main
PS> Copy-Item pyproject.toml pyproject.toml.bak; Copy-Item uv.lock uv.lock.bak
PS> uv add --offline --find-links C:\transfer\wheelhouse `
      catboost category-encoders xlrd phik kiwipiepy umap-learn `
      crepes metric-learn tabulate interpret-core imodels sweetviz
PS> uv run python -c "import catboost, category_encoders, xlrd, phik, kiwipiepy, umap, crepes, metric_learn, tabulate, interpret, imodels, sweetviz; print('OK')"
PS> uv run python -c "import torch, numpy, sklearn; print('base OK', torch.cuda.is_available())"
```

`uv add`가 실패하면 임시 우회(다음 `uv run`에서 지워지므로 임시용):

```powershell
PS> uv pip install --no-index --find-links C:\transfer\wheelhouse `
      catboost category-encoders xlrd phik kiwipiepy umap-learn `
      crepes metric-learn tabulate interpret-core imodels sweetviz
PS> uv run --no-sync python -c "import catboost; print('OK')"
```

되돌리기:

```powershell
PS> Copy-Item pyproject.toml.bak pyproject.toml -Force
PS> Copy-Item uv.lock.bak       uv.lock       -Force
PS> uv sync --offline
```

## 검증 상태

아래 기존 실행 기록은 **`main` 프로필**에 관한 것이다. 새 `tabular`·`automl312` 프로필은 패키지 메타데이터·기존 lock과 스크립트 구문을 검토했으며, Windows에서 wheel 다운로드와 폐쇄망 설치 실행은 아직 확인하지 않았다.

| | |
| --- | --- |
| ✅ | **`pip download` 명령 실측 통과** (2026-09-29) — **18종이 정확한 태그로 받아짐**(141MB): `catboost-1.2.10-cp312-cp312-win_amd64` · `phik-0.12.5-cp312-cp312-win_amd64` · `kiwipiepy-0.24.0-cp39-abi3-win_amd64` · 나머지 순수 Python |
| ✅ | `kiwipiepy`가 `cp39-abi3` wheel이라 `--abi cp312`로도 받아지는 것 실측 확인 |
| ✅ | `kiwipiepy_model`이 `--only-binary=:all:`에서 실패하는 것, `pip wheel`로 `py3-none-any` wheel(88MB)이 만들어지는 것 실측 확인 |
| ✅ | **`interpret-core`의 순수 Python wheel 안에 `libebm_win_x64.dll`(1.49MB)이 들어 있는 것 확인** — EBM 네이티브 부스터가 Windows에서 동작한다 |
| ✅ | **의존성 완전성 확인** — wheel **18종 전부**의 `Requires-Dist`를 대상 `uv.lock`과 교차 대조해 **빠진 필수 의존성 0건 · extras 요구 0건** |
| ✅ | **`uv add --offline --find-links` 를 실제로 실행해 확인** — 대상과 같은 기반 패키지를 깐 임시 프로젝트에서 설치 성공. **그 뒤 `--no-sync` 없는 맨 `uv run` 으로도 패키지가 살아남는 것**까지 확인(§알아둘 것 4의 근거) |
| ✅ | **`interpret-core` 만으로 EBM 학습·형태 함수 추출 성공** 실측 — 메타패키지 `interpret` 불필요 |
| 🔴 | **`uv add --offline` 은 프로젝트 전체를 다시 해석한다** — 기존 패키지 wheel이 **uv 캐시에 없으면 실패**한다(실측: 캐시에 없는 `scipy`에서 멈춤). `local-llm-setup` GUIDE §12의 *"uv 캐시는 지우지 않는다"*가 여기서 값을 한다 |
| ✅ | 두 스크립트에 **PowerShell 7 전용 문법이 없는 것** 확인 — 윈도우 기본 PowerShell 5.1에서 동작하는 구문만 씀(`??`·`?.`·`&&` 등 미사용) |
| ✅ | **`.ps1`을 UTF-8 BOM + CRLF로 저장**(2026-09-29 수정) — BOM이 없어 실제로 *"문자열에 종결자 '가 없습니다"* 오류가 났다. 원인은 PowerShell 5.1의 ANSI 해독. `.gitattributes`로 줄바꿈 고정, 스크립트의 `Get-Content`에도 `-Encoding UTF8` 명시 |
| ✅ | 변환 후 두 파일의 **따옴표 균형 0건 불균형 · 한글 정상 해독** 재확인 |
| ✅ | **두 스크립트를 PowerShell 파서에 직접 넣어 구문 오류 0건 확인** — `[Parser]::ParseFile()` (download 840토큰 · install 963토큰) |
| ✅ | **`download.ps1` 전체 실행 성공** — wheel 18개 · 224.4MB, Windows 태그 정확(`catboost-cp312-win_amd64`·`kiwipiepy-cp39-abi3-win_amd64`·`phik-cp312-win_amd64`), sdist 빌드, 해시 기록, `install.ps1` 동봉, 임시 가상환경 삭제까지 |
| ✅ | **`install.ps1` 전체 실행 성공** — 무결성 확인(8개 일치) → 백업 생성 → `uv add --offline` 13개 설치 → `import OK` → 회귀 확인. **회귀 실패 분기도 의도대로 동작**(복구 명령 안내) |
| ✅ | 설치 후 **맨 `uv run`(--no-sync 없이)으로 6종 전부 생존** · `pyproject.toml` 기록 · `.bak` 2개 생성 확인 |
| 🟡 | 실행 검증은 **macOS의 PowerShell 7**에서 했다(Windows·PowerShell 5.1 아님). `Scripts\python.exe` 경로만 macOS용으로 바꿔 돌렸고 나머지는 그대로다. **5.1 고유 동작**(ANSI 해독·네이티브 인자 인용부호·stderr 처리)은 이미 그 특성에 맞춰 고쳐 두었다 |

## 새 패키지를 추가할 때

1. 대상 환경의 `uv.lock`에서 그 패키지와 **의존성이 이미 있는지** 확인
   ```powershell
   PS> Select-String -Path uv.lock -Pattern '^name = "plotly"'
   ```
2. 없는 의존성만 `extra-deps.txt`에 추가
3. PyPI에 wheel이 없으면 `sdist-only.txt`로
4. import 이름이 다르면 `verify-imports.txt`에 반영
5. 🔴 `Requires-Dist` 에 `pkg[extras]` 형태가 없는지 확인 — 있으면 extras 의존성까지 전부 따라온다
