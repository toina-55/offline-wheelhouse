# offline-wheelhouse

인터넷이 없는 Windows 머신에 Python 패키지를 넣기 위해, **다른 Windows 머신에서 wheel만 받아 파일로 옮기는** 절차와 스크립트.

- **받는 쪽**(인터넷 있음) — `download.ps1`. 그 머신에 아무것도 영구 설치하지 않는다(임시 가상환경만 쓰고 지움).
- **설치하는 쪽**(인터넷 없음) — `install.ps1`. `uv` 프로젝트에 넣는다.
- 옮기는 것은 **`wheelhouse\` 폴더 하나**뿐이다. 저장소를 받는 쪽에 clone할 필요는 없다(원하면 이 저장소만 clone해서 스크립트를 쓴다).

## 빠른 사용

```powershell
# ── 인터넷 있는 Windows 머신
PS> git clone https://github.com/toina-55/offline-wheelhouse.git
PS> cd offline-wheelhouse
PS> .\download.ps1          # → .\wheelhouse\  (wheel + hashes.csv + install.ps1)

# ── wheelhouse 폴더를 옮긴 뒤, 인터넷 없는 Windows 머신
PS> cd C:\transfer\wheelhouse
PS> .\install.ps1           # 인자 없이 — 자기가 있는 폴더를 wheelhouse로 본다
```

**`download.ps1`이 `install.ps1`·`packages.txt`·`verify-imports.txt`를 `wheelhouse\` 안에 함께 담는다** — 폐쇄망에서는 clone을 못 하므로 그 폴더만 있으면 설치가 된다.

설치 대상 경로가 다르면:

```powershell
PS> .\install.ps1 -EnvPath D:\somewhere\envs\main
```

`PowerShell 실행 정책`에 막히면:

```powershell
PS> powershell -ExecutionPolicy Bypass -File .\download.ps1
```

## 무엇을 받는가

목록은 세 파일로 나뉘어 있다. **대상 환경에 이미 있는 패키지는 일부러 제외**했다 — `--no-deps`로 받기 때문에 목록에 없으면 받지 않는다.

| 파일 | 뜻 |
| --- | --- |
| `packages.txt` | 설치 목표. `install.ps1`이 `uv add`에 넘긴다 |
| `extra-deps.txt` | 목표의 전이 의존성 중 **대상 환경에 없는 것만**. 받기만 하고 `uv add`엔 안 넘긴다 |
| `sdist-only.txt` | PyPI에 wheel이 없어 **온라인에서 `pip wheel`로 빌드**해야 하는 것 |
| `verify-imports.txt` | 설치 후 import 확인용 모듈명(pip 이름과 다른 것이 있다) |

현재 목록(2026-09-29 기준, wheel 19개 · 합계 약 **229MB**):

| wheel | 구분 | 크기 |
| --- | --- | --- |
| `catboost` | 목표 — 순서형 타깃 통계(타깃 인코딩 누수 대조군) | 95.6MB |
| `interpret` | 목표 — EBM glass-box 모델 | 0.01MB |
| `imodels` | 목표 — 규칙 학습(RuleFit 등) | 0.33MB |
| `sweetviz` | 목표 — EDA 리포트, `compare(train, test)` | 14.4MB |
| `kiwipiepy` | 목표 — 한국어 형태소 (cp39-abi3, Python 3.9+ 공용) | 3.7MB |
| `phik` | 목표 — 혼합형 변수 상관 | 0.6MB |
| `category-encoders` · `xlrd` · `umap-learn` · `crepes` · `metric-learn` · `tabulate` | 목표 | 각 0.1MB 미만 |
| **`interpret-core`** | interpret 의존 — EBM 본체. **네이티브 라이브러리를 플랫폼별로 wheel 안에 담고 있다**(`libebm_win_x64.dll` 확인) | 14.9MB |
| `plotly` | catboost 의존 | 9.2MB |
| `mlxtend` | imodels 의존 | 1.3MB |
| `graphviz` · `pynndescent` · `importlib-resources` | catboost · umap-learn · sweetviz 의존 | 각 0.1MB 미만 |
| **`kiwipiepy_model`** | kiwipiepy 의존 · **sdist만 있어 빌드 필요** | **88MB** |

> `tabulate`는 용량이 0.04MB인데 없으면 **`df.to_markdown()` 자체가 동작하지 않는다.** 분석 결과를 마크다운 표로 옮길 일이 있으면 필수.

## 🔴 알아둘 것 넷

**1. Python 버전·플랫폼이 정확히 맞아야 한다.** wheel은 `cp312`·`win_amd64` 같은 태그로 묶여 있다. 기본값은 **Python 3.12 / 64비트 Windows**이고, 대상이 다르면 바꿔서 받는다.

```powershell
PS> .\download.ps1 -PyVersion 311 -OutDir D:\wheelhouse-311
```

받는 머신의 Python 버전은 **무관하다** — 플래그로 대상 버전을 지정하므로.

**2. `pip download`는 `--no-deps`로 돈다.** 대상 환경에 이미 있는 것을 다시 받지 않으려는 의도다. 그래서 **대상 환경이 바뀌면 `extra-deps.txt`를 다시 점검해야 한다.** 빠진 의존성은 설치 단계에서 *"No matching distribution"*으로 드러난다.

**3. sdist만 있는 패키지는 미리 wheel로 만든다.** `pip download --only-binary=:all:`은 sdist를 거부하고, `--platform`을 쓰면 `--only-binary`가 강제된다. 그래서 `sdist-only.txt`의 것은 `pip wheel`로 빌드한다. **순수 Python·데이터 패키지만** 이렇게 할 수 있다 — C 확장이 있으면 빌드 결과가 빌드한 OS에 묶이므로 Windows에서 빌드해야 한다.

**4. `uv pip install`이 아니라 `uv add`를 쓴다.** `uv run`은 실행 전에 환경을 `uv.lock`에 맞춰 자동 동기화하면서 **lock에 없는 패키지를 지운다.** `uv pip install`로 넣으면 다음 `uv run`에서 조용히 사라진다. `uv add`는 `pyproject.toml`·`uv.lock`·설치를 함께 처리해 살아남는다.

## 스크립트 없이 손으로 하기

스크립트가 막히면 아래를 그대로 붙여 쓰면 된다.

```powershell
# ── 인터넷 있는 쪽
PS> python -m venv .venv-dl
PS> .\.venv-dl\Scripts\python.exe -m pip install --upgrade pip

PS> .\.venv-dl\Scripts\python.exe -m pip download `
      catboost category-encoders xlrd phik kiwipiepy umap-learn `
      crepes metric-learn tabulate interpret imodels sweetviz `
      plotly graphviz pynndescent interpret-core mlxtend importlib-resources `
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
      crepes metric-learn tabulate interpret imodels sweetviz
PS> uv run python -c "import catboost, category_encoders, xlrd, phik, kiwipiepy, umap, crepes, metric_learn, tabulate, interpret, imodels, sweetviz; print('OK')"
PS> uv run python -c "import torch, numpy, sklearn; print('base OK', torch.cuda.is_available())"
```

`uv add`가 실패하면 임시 우회(다음 `uv run`에서 지워지므로 임시용):

```powershell
PS> uv pip install --no-index --find-links C:\transfer\wheelhouse `
      catboost category-encoders xlrd phik kiwipiepy umap-learn `
      crepes metric-learn tabulate interpret imodels sweetviz
PS> uv run --no-sync python -c "import catboost; print('OK')"
```

되돌리기:

```powershell
PS> Copy-Item pyproject.toml.bak pyproject.toml -Force
PS> Copy-Item uv.lock.bak       uv.lock       -Force
PS> uv sync --offline
```

## 검증 상태

| | |
| --- | --- |
| ✅ | **`pip download` 명령 실측 통과** (2026-09-29) — **18종이 정확한 태그로 받아짐**(141MB): `catboost-1.2.10-cp312-cp312-win_amd64` · `phik-0.12.5-cp312-cp312-win_amd64` · `kiwipiepy-0.24.0-cp39-abi3-win_amd64` · 나머지 순수 Python |
| ✅ | `kiwipiepy`가 `cp39-abi3` wheel이라 `--abi cp312`로도 받아지는 것 실측 확인 |
| ✅ | `kiwipiepy_model`이 `--only-binary=:all:`에서 실패하는 것, `pip wheel`로 `py3-none-any` wheel(88MB)이 만들어지는 것 실측 확인 |
| ✅ | **`interpret-core`의 순수 Python wheel 안에 `libebm_win_x64.dll`(1.49MB)이 들어 있는 것 확인** — EBM 네이티브 부스터가 Windows에서 동작한다 |
| ✅ | **의존성 완전성 확인** — wheel **19종 전부**의 `Requires-Dist`를 대상 `uv.lock`과 교차 대조해 **빠진 필수 의존성 0건** |
| ✅ | 두 스크립트에 **PowerShell 7 전용 문법이 없는 것** 확인 — 윈도우 기본 PowerShell 5.1에서 동작하는 구문만 씀(`??`·`?.`·`&&` 등 미사용) |
| 🔴 | **`download.ps1`·`install.ps1`은 Windows에서 실행 검증하지 않았다** (작성 환경에 PowerShell 없음). 막히면 위 "손으로 하기"를 쓸 것 — 그쪽 명령은 위 실측에 쓴 것과 같다 |

## 새 패키지를 추가할 때

1. 대상 환경의 `uv.lock`에서 그 패키지와 **의존성이 이미 있는지** 확인
   ```powershell
   PS> Select-String -Path uv.lock -Pattern '^name = "plotly"'
   ```
2. 없는 의존성만 `extra-deps.txt`에 추가
3. PyPI에 wheel이 없으면 `sdist-only.txt`로
4. import 이름이 다르면 `verify-imports.txt`에 반영
