# Indie Game Reports

인디게임 개발사 · 게임 · 시장성 분석 리포트 아카이브.

**Live:** https://lionheartscy-source.github.io/projecti/

---

## 리포트 추가하기

1. `reports/` 에 리포트 HTML을 넣는다
2. **`업로드.bat` 더블클릭**

reports.json 갱신 → 커밋 → 푸시까지 한 번에 처리합니다.
확인만 하고 싶으면 `미리보기.bat` 을 먼저 실행하세요.

웹에서 직접 올려도 됩니다 — 그때는 GitHub Actions가 대신 reports.json을 갱신합니다.

`index.html` 은 손댈 필요가 없습니다.

```
reports/ 에 파일 추가
   ↓
scripts/build-reports.py 가 스캔        ← 업로드.bat 또는 GitHub Actions
   ↓
reports.json 재생성 후 커밋
   ↓
index.html 이 reports.json 을 읽어 카드·필터·히어로 생성
```

웹 업로드로 올린 경우 Actions 반영까지 1~2분 걸립니다. 진행 상황은 저장소의
**Actions** 탭에서 볼 수 있습니다.

파일명은 ASCII 슬러그(소문자·하이픈)를 쓰세요. 한글·공백은 URL에서 깨집니다.

---

## 메타데이터

파서가 리포트 HTML에서 알아서 뽑아냅니다.

| 항목 | 자동 추출 위치 |
|---|---|
| 제목 · 개발사 | `<title>게임명 · 개발사 — 부제</title>` |
| 설명 | `<p class="sub">` → `og:description` → 첫 문단 |
| 썸네일 | `.hero-figure img` → `og:image` → 첫 이미지 |
| 장르 · 플랫폼 | `<span class="chip">장르 <b>...</b></span>` |
| 상태 | `chip` 의 `상태` 항목 (미출시/예정 → 출시예정) |
| 날짜 | 해당 파일의 git 커밋일 |

### 값을 직접 지정하고 싶을 때

리포트 `<head>` 에 아래 태그를 넣으면 자동 추출을 덮어씁니다. 필요한 것만 넣으면 됩니다.

```html
<meta name="report:title"  content="SURA: Blade of Eternity">
<meta name="report:studio" content="Crimson Blade">
<meta name="report:desc"   content="중세 일본풍 소울라이크 로그라이크 출시 전 분석.">
<meta name="report:tags"   content="소울라이크, 액션 로그라이크, PC">
<meta name="report:status" content="출시예정">
<meta name="report:date"   content="2026-08-13">
<meta name="report:thumb"  content="https://example.com/header.jpg">
```

`status` 는 `출시` / `출시예정` / `데모` 세 값이 각각 초록 · 크림슨 · 파랑 배지로 나옵니다.
`PC (Windows)` 처럼 괄호가 붙은 태그는 `PC` 로 자동 정리됩니다. 표기 통일 규칙은
`scripts/build-reports.py` 의 `TAG_ALIASES` 에서 수정하세요.

---

## 구조

```
/
├─ index.html                    네비게이션 허브 (히어로 + 그리드 + 필터 레일)
├─ reports.json                  ← 자동 생성. 직접 수정 금지
├─ 업로드.bat                     reports.json 갱신 + 커밋 + 푸시
├─ 미리보기.bat                   로컬 서버로 실제 목록까지 확인
├─ .nojekyll
├─ reports/
│  └─ sura-blade-of-eternity.html
├─ scripts/
│  └─ build-reports.py           리포트 스캔 → reports.json
└─ .github/workflows/
   └─ build-index.yml            push 시 자동 실행
```

---

## 로컬에서 확인하기

`index.html` 을 더블클릭해 열면 브라우저가 `reports.json` 을 못 읽습니다(`file://` 제약).
이때는 `index.html` 안의 `FALLBACK_REPORTS` 목록이 대신 표시됩니다 — 레이아웃 확인용입니다.

실제 목록까지 보려면 **`미리보기.bat`** 을 실행하세요. 수동으로 하려면:

```bash
python scripts/build-reports.py
python -m http.server 8000
# → http://localhost:8000
```

---

## 최초 설정

1. **Settings → Pages** → Source: `Deploy from a branch`, Branch: `main` / `(root)`
2. **Settings → Actions → General** → Workflow permissions:
   `Read and write permissions` 선택 (Actions가 `reports.json` 을 커밋해야 함)
