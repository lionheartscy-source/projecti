# Indie Game Reports

인디게임 개발사 · 게임 · 시장성 분석 리포트 아카이브.

**Live:** https://lionheartscy-source.github.io/projecti/

---

## 리포트 추가하기

1. 리포트 HTML을 지역에 맞는 폴더에 넣는다
   - 국내 → `reports/kr/`
   - 국외 → `reports/global/`
2. **`업로드.bat` 더블클릭**

reports.json 갱신 → 커밋 → 푸시까지 한 번에 처리합니다.
확인만 하고 싶으면 `미리보기.bat` 을 먼저 실행하세요.

웹에서 직접 올려도 됩니다 — 그때는 GitHub Actions가 대신 reports.json을 갱신합니다.

`index.html` 은 손댈 필요가 없습니다.

```
reports/kr 또는 reports/global 에 파일 추가
   ↓
tools/build-reports.ps1 이 스캔        ← 업로드.bat 또는 GitHub Actions
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
| 상태 | `chip` 의 `상태` · `출시` 항목 |
| 날짜 | 본문의 `작성일` · `기준일` → 없으면 파일이 추가된 커밋일 |
| 지역 | 파일이 들어 있는 폴더 (`kr` → 국내, `global` → 국외) |

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

`status` 는 `출시`(초록) / `앞서 해보기`(금색) / `데모`(파랑) / `출시예정`(크림슨) 배지로 나옵니다.
`Coming Soon`, `Early Access`, `2026.03.03` 같은 표기도 알아서 이 넷 중 하나로 정리됩니다.
`PC (Windows)` 처럼 괄호가 붙은 표기는 `PC` 로 정리됩니다. 플랫폼 표기 통일은
`tools/build-reports.ps1` 의 `$PlatformAliases`, 장르 필터 키워드는 `$TopicRules` 에서 수정하세요.

카드에는 원문 장르 구절(`3인칭 슈터 로그라이트`)이 그대로 나가고,
필터 레일에는 거기서 뽑은 키워드(`슈터`, `로그라이크`)만 씁니다.

---

## 팀 평점

`ratings.csv` 에 한 줄씩 적으면 메인 페이지 카드에 평균 점수가 붙습니다.
엑셀에서 편집하거나 복사해 붙여넣어도 됩니다.

```csv
게임,평가자,완성도,차별화,적합성,검증,역량,확장성
SURA_Blade_of_Eternity,창연,8,9,7,,6,8
SURA_Blade_of_Eternity,민수,7,8,7,,5,7
```

- **게임** — 파일명(슬러그) 또는 리포트 제목. 둘 다 인식합니다
- **평가자** — 사람마다 한 줄. 같은 게임에 여러 줄이 있으면 평균을 냅니다
- **점수** — 1~10. **판단 근거가 없는 축은 비워두세요.** 그 사람의 평균에서 빠집니다
  (미출시작의 `검증` 축이 대표적입니다. 0을 넣으면 부당하게 점수가 깎입니다)

| 축 | 무엇을 보는가 |
|---|---|
| 완성도 | 지금 잘 만들어졌는가 |
| 차별화 | 고유한 훅이 있는가 |
| 적합성 | 시장과 타이밍이 맞는가 |
| 검증 | 지표로 확인됐는가 |
| 역량 | 개발사가 완주하고 다음을 낼 수 있는가 |
| 확장성 | 더 커질 여지가 있는가 |

카드에는 평균 점수와 참여 인원이 표시되고, 정렬에 **평점순**이 추가됩니다.
평가자들의 종합 점수 편차가 1.5 이상이면 카드에 편차가 함께 뜹니다 — 의견이 갈린 게임입니다.

지금 들어 있는 `샘플A/B/C` 행은 예시입니다. **실제 평가를 넣기 전에 지우세요.**

---

## 구조

```
/
├─ index.html                    네비게이션 허브 (히어로 + 그리드 + 필터 레일)
├─ reports.js                    ← 자동 생성. index.html 이 읽는 목록
├─ reports.json                  ← 자동 생성. 같은 내용의 JSON 판
├─ ratings.csv                   팀 평점 (손으로 편집)
├─ 업로드.bat                     목록 갱신 + 커밋 + 푸시
├─ 미리보기.bat                   목록 갱신 + 브라우저로 열기
├─ .nojekyll
├─ reports/
│  ├─ kr/         국내 리포트 → 인덱스의 '국내' 탭
│  └─ global/     국외 리포트 → 인덱스의 '국외' 탭
├─ tools/
│  └─ build-reports.ps1          리포트 스캔 → reports.js / reports.json
└─ .github/workflows/
   └─ build-index.yml            push 시 같은 스크립트를 실행
```

파서는 **PowerShell** 로 되어 있습니다. `fps-radar` 와 마찬가지로 별도 설치가 필요 없습니다.
GitHub Actions 도 같은 `build-reports.ps1` 을 실행하므로 로직이 한 곳에만 있습니다.

`reports.js` 와 `reports.json` 은 내용이 같습니다. `index.html` 이 `.js` 쪽을 읽는 이유는
`file://` 로 열어도 동작하기 때문입니다 — 로컬 서버 없이 더블클릭만으로 확인됩니다.

---

## 로컬에서 확인하기

**`미리보기.bat`** 을 실행하면 목록을 갱신하고 브라우저를 엽니다.

수동으로 하려면:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-reports.ps1
```

---

## 지역 추가하기

`reports/` 아래에 폴더를 만들고 `tools/build-reports.ps1` 의 `$RegionMap` 에 한 줄 추가하면
인덱스에 탭이 자동으로 생깁니다.

```powershell
$RegionMap = @{
    'kr' = '국내'; 'global' = '국외'
    'jp' = '일본'          # ← 이런 식
}
```

---

## 테마

상단바 오른쪽 아이콘으로 다크 / 라이트를 전환합니다. 기본은 다크이고,
선택은 그 브라우저에만 기억됩니다.

---

## 최초 설정

1. **Settings → Actions → General** → Workflow permissions:
   `Read and write permissions` 선택 (Actions가 목록 파일을 커밋해야 함)
2. `업로드.bat` 실행 — 저장소에 내용이 올라가야 Pages 설정이 열립니다
3. **Settings → Pages** → Source: `Deploy from a branch`, Branch: `main` / `(root)`
