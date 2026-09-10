#Requires -Version 5.1
<#
  reports/ 폴더의 리포트 HTML을 스캔해 reports.json 을 생성한다.

  메타데이터 우선순위
    1) <meta name="report:*"> 태그   ← 명시하면 그 값이 무조건 이김
    2) 리포트 HTML에서 자동 추출     ← 아무것도 안 해도 웬만하면 잡힘
    3) git 커밋일 / 파일 수정일      ← date 한정

  Windows PowerShell 5.1 과 PowerShell 7(pwsh) 양쪽에서 동작한다.
  별도 설치가 필요 없다.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$GitExe = 'git'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# $PSScriptRoot 는 PowerShell 5.1 의 param() 기본값 자리에서 비어 있을 수 있으므로
# 본문에서 계산한다. 호출 측이 -Root 를 넘기면 그 값을 그대로 쓴다.
if (-not $Root) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $Root = Split-Path -Parent $scriptDir
}
if (-not $Root) { $Root = (Get-Location).Path }
$Root = (Resolve-Path -LiteralPath $Root).Path

$ReportsDir = Join-Path $Root 'reports'
$OutPath    = Join-Path $Root 'reports.json'
# reports.js 는 같은 내용을 <script> 로 읽을 수 있게 감싼 것.
# file:// 로 열어도 동작하므로 index.html 은 이쪽을 읽는다.
$OutJsPath  = Join-Path $Root 'reports.js'

$RxIS = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline'
$RxI  = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase'

# ─────────────────────────── 텍스트 유틸 ───────────────────────────

# 블록 태그는 공백으로, 인라인 태그(b/span/a 등)는 공백 없이 제거해야
# "Crimson Blade와" 가 "Crimson Blade 와" 로 벌어지지 않는다.
$BlockRe = [regex]::new(
    '</?(?:p|div|section|article|br|hr|li|ul|ol|h[1-6]|td|th|tr|table|' +
    'blockquote|figure|figcaption|header|footer|nav)\b[^>]*>', $RxI)
$TagRe = [regex]::new('<[^>]+>')
$WsRe  = [regex]::new('\s+')

function ConvertTo-PlainText([string]$Fragment) {
    if ([string]::IsNullOrEmpty($Fragment)) { return '' }
    $s = $BlockRe.Replace($Fragment, ' ')
    $s = $TagRe.Replace($s, '')
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    return $WsRe.Replace($s, ' ').Trim()
}

function Get-TagAttribute([string]$Tag, [string]$Name) {
    $pattern = '\b' + [regex]::Escape($Name) + '\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))'
    $m = [regex]::Match($Tag, $pattern, $RxI)
    if (-not $m.Success) { return $null }
    foreach ($i in 1, 2, 3) {
        if ($m.Groups[$i].Success) {
            return [System.Net.WebUtility]::HtmlDecode($m.Groups[$i].Value)
        }
    }
    return $null
}

function Limit-Text([string]$Text, [int]$Limit = 190) {
    $Text = $Text.Trim()
    if ($Text.Length -le $Limit) { return $Text }
    $cut = $Text.Substring(0, $Limit)
    foreach ($sep in '다. ', '. ', '! ', '? ') {
        $i = $cut.LastIndexOf($sep)
        if ($i -gt [int]($Limit * 0.5)) { return $cut.Substring(0, $i + $sep.Length).Trim() }
    }
    return $cut.TrimEnd() + [char]0x2026
}

# ─────────────────────────── 추출기 ───────────────────────────

function Read-ReportMeta([string]$Src) {
    $report = @{}
    $og     = @{}
    foreach ($m in [regex]::Matches($Src, '<meta\b[^>]*>', $RxI)) {
        $tag = $m.Value
        $key = Get-TagAttribute $tag 'name'
        if (-not $key) { $key = Get-TagAttribute $tag 'property' }
        $val = Get-TagAttribute $tag 'content'
        if (-not $key -or $null -eq $val) { continue }
        $key = $key.Trim().ToLowerInvariant()
        if ($key.StartsWith('report:')) { $report[$key.Substring(7)] = $val.Trim() }
        elseif ($key.StartsWith('og:'))  { $og[$key.Substring(3)]    = $val.Trim() }
    }
    return @{ report = $report; og = $og }
}

function Get-TitleAndStudio([string]$Src, [string]$Slug) {
    $m = [regex]::Match($Src, '<title[^>]*>(.*?)</title>', $RxIS)
    $raw = if ($m.Success) { ConvertTo-PlainText $m.Groups[1].Value } else { '' }
    if (-not $raw) {
        $h1 = [regex]::Match($Src, '<h1[^>]*>(.*?)</h1>', $RxIS)
        $raw = if ($h1.Success) { ConvertTo-PlainText $h1.Groups[1].Value } else { $Slug -replace '-', ' ' }
    }
    # 부제 분리 (em dash / en dash / hyphen)
    $head = ([regex]::Split($raw, '\s+[—–-]\s+'))[0].Trim()
    # 게임명 · 개발사 분리
    $parts = @($head -split [char]0x00B7 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -ge 2) { return @($parts[0], $parts[1]) }
    return @($head, '')
}

function Get-Description([string]$Src) {
    $m = [regex]::Match($Src, '<p[^>]*class="[^"]*\bsub\b[^"]*"[^>]*>(.*?)</p>', $RxIS)
    if ($m.Success) { return Limit-Text (ConvertTo-PlainText $m.Groups[1].Value) }
    $m = [regex]::Match($Src, '<p[^>]*>(.{40,}?)</p>', $RxIS)
    if ($m.Success) { return Limit-Text (ConvertTo-PlainText $m.Groups[1].Value) }
    return ''
}

function Get-Thumbnail([string]$Src) {
    $fig = [regex]::Match($Src, '<div[^>]*class="[^"]*hero-figure[^"]*"[^>]*>(.*?)</div>', $RxIS)
    if ($fig.Success) {
        $img = [regex]::Match($fig.Groups[1].Value, '<img\b[^>]*>', $RxI)
        if ($img.Success) {
            $src = Get-TagAttribute $img.Value 'src'
            if ($src) { return $src }
        }
    }
    $img = [regex]::Match($Src, '<img\b[^>]*>', $RxI)
    if ($img.Success) {
        $src = Get-TagAttribute $img.Value 'src'
        if ($src) { return $src }
    }
    return ''
}

function Get-Chips([string]$Src) {
    $chips = @{}
    foreach ($m in [regex]::Matches($Src, '<span[^>]*class="[^"]*\bchip\b[^"]*"[^>]*>(.*?)</span>', $RxIS)) {
        $inner = $m.Groups[1].Value
        $b = [regex]::Match($inner, '<b[^>]*>(.*?)</b>', $RxIS)
        if (-not $b.Success) { continue }
        $value = ConvertTo-PlainText $b.Groups[1].Value
        $label = ConvertTo-PlainText $inner.Substring(0, $b.Index)
        if ($label -and $value) { $chips[$label] = $value }
    }
    return $chips
}

# 플랫폼 표기를 소수의 값으로 모은다. 필요하면 여기에 추가.
$PlatformAliases = @{
    'windows' = 'PC'; '윈도우' = 'PC'; '스팀' = 'PC'; 'steam' = 'PC'
    'steamos' = 'PC'; 'linux' = 'PC'; 'pc' = 'PC'
    'deck' = 'PC'; 'steam deck' = 'PC'; '스팀덱' = 'PC'; '스팀 덱' = 'PC'
    'macos' = 'Mac'; 'mac' = 'Mac'; 'osx' = 'Mac'
    'playstation' = '콘솔'; 'ps4' = '콘솔'; 'ps5' = '콘솔'; 'xbox' = '콘솔'
    'switch' = '콘솔'; '닌텐도 스위치' = '콘솔'; '스위치' = '콘솔'; '콘솔' = '콘솔'
    '모바일' = '모바일'; 'ios' = '모바일'; 'android' = '모바일'
}

# 'Switch 2', 'Xbox Series X', 'PS5 Pro' 처럼 세대·기종이 뒤에 붙는 표기가 흔하다.
# 정확히 일치하지 않으면 앞부분 키워드로 한 번 더 본다.
$PlatformPatterns = @(
    @{ Pattern = '^(?:pc|windows|steam|steamos|linux|deck)\b'; Value = 'PC' }
    @{ Pattern = '^(?:mac|osx)';                               Value = 'Mac' }
    @{ Pattern = '^(?:switch|스위치|xbox|playstation|ps[3-9])'; Value = '콘솔' }
    @{ Pattern = '^(?:ios|android|모바일)';                     Value = '모바일' }
)

# 장르 구절에서 필터용 키워드를 뽑는다. 카드에는 원문 구절이 그대로 나가고,
# 필터 레일에는 여기서 나온 키워드만 쓴다. 위에서부터 순서대로 검사한다.
$TopicRules = @(
    @{ Pattern = '로그라이크|로그라이트|로그바니아'; Topics = @('로그라이크') }
    @{ Pattern = '소울라이크';                      Topics = @('소울라이크') }
    @{ Pattern = '슈터|불릿헬|트윈스틱';             Topics = @('슈터') }
    @{ Pattern = '플랫포머';                        Topics = @('플랫포머') }
    @{ Pattern = 'SRPG';                            Topics = @('전략', 'RPG') }
    @{ Pattern = 'RPG';                             Topics = @('RPG') }
    @{ Pattern = '전략|택티컬';                      Topics = @('전략') }
    @{ Pattern = '퍼즐';                            Topics = @('퍼즐') }
    @{ Pattern = '액션';                            Topics = @('액션') }
    @{ Pattern = '어드벤처';                        Topics = @('어드벤처') }
    @{ Pattern = '시뮬';                            Topics = @('시뮬레이션') }
    @{ Pattern = '호러';                            Topics = @('호러') }
    @{ Pattern = '리듬';                            Topics = @('리듬') }
    @{ Pattern = '캐주얼';                          Topics = @('캐주얼') }
    @{ Pattern = '코지';                            Topics = @('코지') }
    @{ Pattern = '서바이버';                        Topics = @('서바이버') }
    @{ Pattern = '보스 러시';                       Topics = @('보스 러시') }
    @{ Pattern = '픽셀';                            Topics = @('픽셀 아트') }
    @{ Pattern = '턴제';                            Topics = @('턴제') }
    @{ Pattern = '시티빌더|시티 빌더|도시 건설|건설'; Topics = @('건설') }
    @{ Pattern = '콜로니|타이쿤|경영';               Topics = @('경영', '시뮬레이션') }
    @{ Pattern = '샌드박스';                        Topics = @('샌드박스') }
    @{ Pattern = '메트로배니아';                     Topics = @('메트로배니아') }
    @{ Pattern = '덱빌딩|덱 빌딩|카드';              Topics = @('덱빌딩') }
    @{ Pattern = '생존|서바이벌';                    Topics = @('생존') }
    @{ Pattern = '오픈월드|오픈 월드';               Topics = @('오픈월드') }
    @{ Pattern = '타워 디펜스|디펜스';               Topics = @('디펜스') }
    @{ Pattern = '농장|파밍';                       Topics = @('농장') }
    @{ Pattern = '내러티브|비주얼 노벨|스토리';       Topics = @('내러티브') }
    @{ Pattern = '레이싱';                          Topics = @('레이싱') }
    @{ Pattern = '격투';                            Topics = @('격투') }
)

# 괄호 부연은 값을 쪼개기 전에 통째로 걷어낸다.
# 먼저 쉼표로 자르면 "전략 RPG (택티컬·레이드)" 가 "전략 RPG (택티컬" 로 깨진다.
function Split-TagValues([string]$Text) {
    if (-not $Text) { return @() }
    $cleaned = ([regex]'\s*[（(][^）)]*[）)]').Replace($Text, '')
    $sep = '[' + [char]0x00B7 + ',/]|\s\|\s'
    return @($cleaned -split $sep | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Normalize-Platform([string]$Value) {
    $v = $Value.Trim()
    $k = $v.ToLowerInvariant()
    if ($PlatformAliases.ContainsKey($k)) { return $PlatformAliases[$k] }
    foreach ($p in $PlatformPatterns) {
        if ($k -match $p.Pattern) { return $p.Value }
    }
    return $v
}

function Get-Topics($Phrases) {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Phrases)) {
        foreach ($rule in $TopicRules) {
            if ($p -match $rule.Pattern) {
                foreach ($t in $rule.Topics) {
                    if (-not $found.Contains($t)) { [void]$found.Add($t) }
                }
            }
        }
    }
    return $found.ToArray()
}

# 상태 표기가 리포트마다 제각각이라 다섯 가지로 모은다.
#   출시 / 앞서 해보기 / 데모 / 출시예정
# 날짜만 적힌 경우( "2026.03.03" )는 오늘과 비교해 판단한다.
function Normalize-Status([string]$Raw) {
    if (-not $Raw) { return '' }
    $low = $Raw.ToLowerInvariant()

    $notYet = ($Raw -match '미출시|예정|미정|출시 전') -or ($low -match 'coming soon|pre-launch|tba')

    if ($Raw -match '데모' -or $low -match 'demo')                     { return '데모' }
    if (($low -match 'early access' -or $Raw -match '앞서 해보기') -and -not $notYet) { return '앞서 해보기' }
    if ($notYet)                                                        { return '출시예정' }
    if ($Raw -match '출시' -or $low -match 'released|out now')          { return '출시' }

    # 날짜만 있는 경우
    $m = [regex]::Match($Raw, '(\d{4})[.\-/](\d{1,2})(?:[.\-/](\d{1,2}))?')
    if ($m.Success) {
        $y = [int]$m.Groups[1].Value
        $mo = [int]$m.Groups[2].Value
        $d = 1
        if ($m.Groups[3].Success) { $d = [int]$m.Groups[3].Value }
        try {
            $dt = Get-Date -Year $y -Month $mo -Day $d -Hour 0 -Minute 0 -Second 0
            if ($dt -le (Get-Date)) { return '출시' } else { return '출시예정' }
        } catch { }
    }
    if ($Raw -match '^\s*\d{4}\s*$') {
        if ([int]$Raw.Trim() -le (Get-Date).Year) { return '출시' } else { return '출시예정' }
    }
    return $Raw.Trim()
}

# "2026.07.15" / "2026-07-15" → "2026-07-15"
function ConvertTo-IsoDate([string]$Raw) {
    if (-not $Raw) { return '' }
    $m = [regex]::Match($Raw, '(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})')
    if ($m.Success) {
        return ('{0:0000}-{1:00}-{2:00}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value)
    }
    $m = [regex]::Match($Raw, '(\d{4})[.\-/](\d{1,2})')
    if ($m.Success) {
        return ('{0:0000}-{1:00}-01' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
    }
    return ''
}

# reports/ 아래 폴더 이름으로 지역을 판별한다.
# 새 지역을 추가하려면 폴더를 만들고 여기에 한 줄만 넣으면 된다.
$RegionMap = @{
    'kr' = '국내'; 'korea' = '국내'; 'domestic' = '국내'
    'global' = '국외'; 'overseas' = '국외'; 'intl' = '국외'
}

function Resolve-Region([string]$Folder) {
    if (-not $Folder) { return '국내' }   # reports/ 바로 아래 있는 파일
    $k = $Folder.ToLowerInvariant()
    if ($RegionMap.ContainsKey($k)) { return $RegionMap[$k] }
    return $Folder
}

function Get-ReportDate([string]$Path) {
    # 파일이 처음 추가된 커밋일. 마지막 커밋일을 쓰면 한 번 손댈 때마다 날짜가 밀린다.
    try {
        $d = & $GitExe -C $Root log --diff-filter=A --format=%cs -1 -- $Path 2>$null
        if ($LASTEXITCODE -eq 0 -and $d) {
            $d = ($d | Select-Object -First 1).ToString().Trim()
            if ($d -match '^\d{4}-\d{2}-\d{2}$') { return $d }
        }
    } catch {}
    return (Get-Item -LiteralPath $Path).LastWriteTime.ToString('yyyy-MM-dd')
}

# ─────────────────────── 아카이브 복귀 버튼 ───────────────────────
#
# 새 리포트에 버튼이 빠져 있으면 빌드할 때 넣는다.
# 리포트를 쓸 때마다 기억할 필요가 없도록 하기 위한 것이고,
# 이미 버튼이 있는 파일은 건드리지 않는다.

$HomeLinkCss = @'

  /* 아카이브(메인) 복귀 버튼 — build-reports.ps1 이 자동으로 넣습니다 */
  .navleft{display:flex; align-items:center; gap:12px; min-width:0}
  .homelink{display:inline-flex; align-items:center; gap:6px; flex:none;
    font-size:12.5px; font-weight:700; color:var(--muted);
    background:var(--surface); border:1px solid var(--line);
    padding:7px 12px; border-radius:8px; white-space:nowrap;
    transition:color .16s, background .16s, border-color .16s}
  .homelink:hover{color:var(--accent-ink); background:var(--accent-soft);
    border-color:transparent; text-decoration:none}
  .homelink svg{flex:none}
  @media(max-width:560px){ .homelink span{display:none} .homelink{padding:7px 9px} }
'@

function Add-HomeLink([System.IO.FileInfo]$File) {
    $src = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    if ($src -match 'class="homelink"') { return $false }   # 이미 있음
    if ($src -notmatch 'class="brand"')  { return $false }   # 상단바 구조가 다름

    # reports/ 기준 깊이만큼 거슬러 올라간다 (kr/x.html → ../../index.html)
    $rel   = $File.FullName.Substring($ReportsDir.Length).TrimStart('\', '/').Replace('\', '/')
    $depth = @($rel.Split('/')).Count - 1
    $href  = ('../' * ($depth + 1)) + 'index.html'

    $btn = '<a class="homelink" href="' + $href + '" title="리포트 아카이브로 돌아가기">' +
           '<svg width="13" height="13" viewBox="0 0 14 14" fill="none" aria-hidden="true">' +
           '<path d="M8.5 2.5 4 7l4.5 4.5" stroke="currentColor" stroke-width="1.8" ' +
           'stroke-linecap="round" stroke-linejoin="round"/></svg><span>아카이브</span></a>'

    $i = $src.IndexOf('</style>')
    if ($i -lt 0) { return $false }
    $src = $src.Substring(0, $i) + $HomeLinkCss + $src.Substring($i)

    $m = [regex]::Match($src, '(?s)([ \t]*)(<a\b[^>]*class="brand"[^>]*>.*?</a>)')
    if (-not $m.Success) { return $false }

    $ind  = $m.Groups[1].Value
    $wrap = $ind + '<div class="navleft">' + "`n" +
            $ind + '  ' + $btn + "`n" +
            $ind + '  ' + $m.Groups[2].Value + "`n" +
            $ind + '</div>'
    $src = $src.Substring(0, $m.Index) + $wrap + $src.Substring($m.Index + $m.Length)

    [System.IO.File]::WriteAllText($File.FullName, $src, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

# ─────────────────────── 리포트 안의 평가표 ───────────────────────
#
# 평가표는 리포트 HTML 자신이 갖는다. 점수를 적는 곳도, 결과가 나오는 곳도
# 그 리포트 한 곳뿐이라 따로 관리할 파일이 없다.
# 빌드는 이 표를 읽어 인덱스 카드와 랭킹에 쓸 평균을 낸다.

$RatingBlockCss = @'

  /* 팀 평가표 — build-reports.ps1 이 자동으로 넣습니다 */
  .rate-wrap{display:grid; grid-template-columns:1fr 300px; gap:18px; align-items:start}
  @media(max-width:820px){ .rate-wrap{grid-template-columns:1fr} }
  table.rating-input{width:100%; border-collapse:collapse; font-size:13.5px}
  table.rating-input th, table.rating-input td{border:1px solid var(--line); padding:7px 9px; text-align:center}
  table.rating-input th{background:var(--surface); font-weight:700; font-size:12px; color:var(--muted); white-space:nowrap}
  table.rating-input td:first-child, table.rating-input th:first-child{text-align:left; font-weight:600}
  table.rating-input td{font-variant-numeric:tabular-nums; color:var(--ink2)}
  table.rating-input tbody tr:nth-child(even){background:var(--surface2)}
  .rate-hint{font-size:12px; color:var(--dim); margin:9px 0 0; line-height:1.6}
  .rate-sum{background:var(--surface2); border:1px solid var(--line); border-radius:var(--r); padding:16px}
  .rate-big{display:flex; align-items:baseline; gap:8px; margin-bottom:2px}
  .rate-big b{font-size:34px; font-weight:800; letter-spacing:-.03em; color:var(--accent-ink);
    font-variant-numeric:tabular-nums; line-height:1}
  .rate-big span{font-size:13px; color:var(--dim); font-weight:600}
  .rate-n{font-size:12px; color:var(--muted); margin:0 0 14px}
  .rate-ax{display:flex; flex-direction:column; gap:7px}
  .rate-row{display:grid; grid-template-columns:52px 1fr 30px; align-items:center; gap:9px; font-size:12px}
  .rate-row span:first-child{color:var(--muted); font-weight:600}
  .rate-bar{height:5px; border-radius:3px; background:var(--surface); overflow:hidden}
  .rate-bar i{display:block; height:100%; border-radius:3px; background:var(--accent)}
  .rate-row b{text-align:right; font-weight:700; color:var(--ink); font-variant-numeric:tabular-nums}
  .rate-none{font-size:13px; color:var(--muted); margin:0}
'@

# 리포트에 넣을 평가표 + 요약 계산 스크립트
$RatingBlockHtml = @'

  <!-- TEAM RATING -->
  <section id="rating">
    <div class="shead"><span class="snum">★</span><h2>팀 평가</h2></div>
    <p class="lead">아래 표에 한 사람당 한 줄씩 1~10점으로 적습니다. 판단할 근거가 없는 축은 비워 두세요 — 그 사람의 평균에서 빠집니다.</p>
    <div class="card">
      <div class="rate-wrap">
        <div>
          <table class="rating-input">
            <thead>
              <tr><th>평가자</th><th>완성도</th><th>차별화</th><th>적합성</th><th>검증</th><th>역량</th><th>확장성</th></tr>
            </thead>
            <tbody>
              <tr><td>—</td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
            </tbody>
          </table>
          <p class="rate-hint">완성도 = 지금 잘 만들어졌는가 · 차별화 = 고유한 훅이 있는가 · 적합성 = 시장과 타이밍이 맞는가<br>
            검증 = 지표로 확인됐는가 · 역량 = 완주하고 다음을 낼 수 있는가 · 확장성 = 더 커질 여지가 있는가</p>
        </div>
        <div class="rate-sum" id="rateSum"></div>
      </div>
    </div>
  </section>

  <script>
  (function(){
    var AX = ["완성도","차별화","적합성","검증","역량","확장성"];
    var tb = document.querySelector("table.rating-input");
    var box = document.getElementById("rateSum");
    if (!tb || !box) return;

    var head = [].map.call(tb.querySelectorAll("thead th"), function(th){ return th.textContent.trim(); });
    var people = [], per = {};
    AX.forEach(function(a){ per[a] = []; });

    [].forEach.call(tb.querySelectorAll("tbody tr"), function(tr){
      var cells = tr.querySelectorAll("td");
      if (!cells.length) return;
      var name = cells[0].textContent.trim();
      if (!name || name === "—") return;
      var vals = [];
      for (var i = 1; i < cells.length && i < head.length; i++){
        var raw = cells[i].textContent.trim();
        if (!raw) continue;
        var v = parseFloat(raw);
        if (!isFinite(v) || v < 1 || v > 10) continue;
        vals.push(v);
        if (per[head[i]]) per[head[i]].push(v);
      }
      if (vals.length) people.push(vals.reduce(function(a,b){ return a+b; }, 0) / vals.length);
    });

    if (!people.length){
      box.innerHTML = '<p class="rate-none">아직 평가가 없습니다. 왼쪽 표에 한 줄 추가하면 여기에 평균이 나옵니다.</p>';
      return;
    }
    var avg = people.reduce(function(a,b){ return a+b; }, 0) / people.length;
    var rows = AX.map(function(a){
      var v = per[a];
      if (!v.length) return '<div class="rate-row"><span>' + a + '</span><span class="rate-bar"></span><b>—</b></div>';
      var m = v.reduce(function(x,y){ return x+y; }, 0) / v.length;
      return '<div class="rate-row"><span>' + a + '</span>' +
             '<span class="rate-bar"><i style="width:' + (m * 10) + '%"></i></span>' +
             '<b>' + m.toFixed(1) + '</b></div>';
    }).join("");

    box.innerHTML =
      '<div class="rate-big"><b>' + avg.toFixed(1) + '</b><span>/ 10</span></div>' +
      '<p class="rate-n">' + people.length + '명 평가 · 축별 평균</p>' +
      '<div class="rate-ax">' + rows + '</div>';
  })();
  </script>
'@

function Add-RatingBlock([System.IO.FileInfo]$File) {
    $src = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    if ($src -match 'class="rating-input"') { return $false }   # 이미 있음

    $i = $src.IndexOf('</style>')
    if ($i -lt 0) { return $false }
    $src = $src.Substring(0, $i) + $RatingBlockCss + $src.Substring($i)

    # 출처 섹션 바로 앞에 넣는다
    $m = [regex]::Match($src, '(?s)([ \t]*)(<!--[^>]*?-->\s*)?<section[^>]*id="sources"')
    if (-not $m.Success) { return $false }
    $src = $src.Substring(0, $m.Index) + $RatingBlockHtml + "`n" + $src.Substring($m.Index)

    # 목차에도 넣는다 (상단 네비 · 사이드 네비)
    $src = [regex]::Replace($src, '(<a href="#sources">)',
        '<a href="#rating">평가</a>$1')
    $src = [regex]::Replace($src, '(<a href="#sources"><span class="n">)',
        '<a href="#rating"><span class="n">★</span> 평가</a>$1')

    [System.IO.File]::WriteAllText($File.FullName, $src, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

# 리포트 안의 평가표를 읽어 사람별 점수로 만든다
function Get-ReportRatings([string]$Src) {
    $list = New-Object System.Collections.Generic.List[object]
    $t = [regex]::Match($Src, '(?s)<table[^>]*class="[^"]*rating-input[^"]*"[^>]*>(.*?)</table>')
    if (-not $t.Success) { return $list }
    $body = $t.Groups[1].Value

    # 헤더에서 열 순서를 읽는다 (열을 바꿔도 따라가도록)
    $cols = @()
    $h = [regex]::Match($body, '(?s)<tr[^>]*>(.*?)</tr>')
    if ($h.Success) {
        foreach ($c in [regex]::Matches($h.Groups[1].Value, '(?s)<th[^>]*>(.*?)</th>')) {
            $cols += (ConvertTo-PlainText $c.Groups[1].Value)
        }
    }
    if ($cols.Count -lt 2) { return $list }

    foreach ($tr in [regex]::Matches($body, '(?s)<tr[^>]*>(.*?)</tr>')) {
        $cells = @([regex]::Matches($tr.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>'))
        if ($cells.Count -lt 2) { continue }
        $name = ConvertTo-PlainText $cells[0].Groups[1].Value
        if (-not $name -or $name -eq '—' -or $name -eq '-') { continue }

        $scores = @{}
        for ($i = 1; $i -lt $cells.Count -and $i -lt $cols.Count; $i++) {
            $cell = ConvertTo-PlainText $cells[$i].Groups[1].Value
            if (-not $cell) { continue }
            $key = $AxisColumns[$cols[$i]]
            if (-not $key) { continue }
            $n = 0.0
            if ([double]::TryParse($cell, [ref]$n) -and $n -ge 1 -and $n -le 10) {
                $scores[$key] = [math]::Round($n, 2)
            }
        }
        if ($scores.Count -gt 0) {
            [void]$list.Add([pscustomobject]@{ rater = $name; scores = $scores })
        }
    }
    return $list
}

# ─────────────────────────── 팀 평점 ───────────────────────────
#
# ratings.csv 는 손으로 고치는 파일이다. 헤더는 다음과 같고,
# '게임' 칸에는 슬러그(파일명)나 리포트 제목 어느 쪽을 써도 된다.
#
#   게임,평가자,완성도,차별화,적합성,검증,역량,확장성
#   SURA_Blade_of_Eternity,창연,8,9,7,,6,8
#
# 판단할 근거가 없는 축은 비워두면 그 사람의 평균에서 빠진다.
# (미출시작의 '검증' 축이 대표적인 경우)

$AxisColumns = [ordered]@{
    '완성도' = 'quality'; '차별화' = 'unique'; '적합성' = 'fit'
    '검증'   = 'proof';   '역량'   = 'team';   '확장성' = 'scale'
}

function Get-Ratings([string]$Path) {
    $byKey = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $byKey }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return $byKey }
    $raw = $raw.TrimStart([char]0xFEFF)          # 엑셀이 붙이는 BOM

    $rows = @($raw | ConvertFrom-Csv)
    foreach ($r in $rows) {
        $game = ('' + $r.'게임').Trim()
        if (-not $game) { continue }
        $rater = ('' + $r.'평가자').Trim()
        if (-not $rater) { $rater = '익명' }

        $scores = @{}
        foreach ($col in $AxisColumns.Keys) {
            $cell = ('' + $r.$col).Trim()
            if (-not $cell) { continue }
            $n = 0.0
            if ([double]::TryParse($cell, [ref]$n) -and $n -ge 1 -and $n -le 10) {
                $scores[$AxisColumns[$col]] = [math]::Round($n, 2)
            } else {
                Write-Host ("  [!!] ratings.csv: '{0}' 의 {1} 값 '{2}' 을(를) 건너뜁니다 (1~10 숫자만)" -f $game, $col, $cell) -ForegroundColor Yellow
            }
        }
        if ($scores.Count -eq 0) { continue }

        $key = $game.ToLowerInvariant()
        if (-not $byKey.ContainsKey($key)) { $byKey[$key] = New-Object System.Collections.Generic.List[object] }
        [void]$byKey[$key].Add([pscustomobject]@{ rater = $rater; scores = $scores })
    }
    return $byKey
}

function Get-RatingSummary($Entries) {
    $overalls = New-Object System.Collections.Generic.List[double]
    $perAxis  = @{}
    foreach ($k in $AxisColumns.Values) { $perAxis[$k] = New-Object System.Collections.Generic.List[double] }

    foreach ($e in $Entries) {
        $vals = New-Object System.Collections.Generic.List[double]
        foreach ($k in $AxisColumns.Values) {
            if ($e.scores.ContainsKey($k)) {
                [void]$vals.Add([double]$e.scores[$k])
                [void]$perAxis[$k].Add([double]$e.scores[$k])
            }
        }
        if ($vals.Count -gt 0) {
            $mean = ($vals | Measure-Object -Average).Average
            [void]$overalls.Add($mean)
        }
    }
    if ($overalls.Count -eq 0) { return $null }

    $avg = ($overalls | Measure-Object -Average).Average
    $sd  = 0.0
    if ($overalls.Count -gt 1) {
        $sum = 0.0
        foreach ($v in $overalls) { $sum += [math]::Pow($v - $avg, 2) }
        $sd = [math]::Sqrt($sum / $overalls.Count)
    }
    $axes = [ordered]@{}
    foreach ($k in $AxisColumns.Values) {
        if ($perAxis[$k].Count -gt 0) {
            $axes[$k] = [math]::Round(($perAxis[$k] | Measure-Object -Average).Average, 2)
        }
    }
    return [pscustomobject][ordered]@{
        avg   = [math]::Round($avg, 2)
        sd    = [math]::Round($sd, 2)
        count = $overalls.Count
        axes  = $axes
    }
}

# ─────────────────────────── JSON 직렬화 ───────────────────────────
#
# ConvertTo-Json 을 쓰지 않는다. PowerShell 5.1 은 4칸 들여쓰기,
# PowerShell 7(Actions)은 2칸을 쓰기 때문에 로컬에서 만든 파일과
# Actions 가 만든 파일이 내용은 같은데 형식만 달라 매번 충돌이 났다.
# 형식을 직접 고정해 어디서 돌리든 같은 바이트가 나오게 한다.

function Format-JsonString([string]$Value) {
    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if     ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -eq 8)  { [void]$sb.Append('\b') }
        elseif ($code -eq 9)  { [void]$sb.Append('\t') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else                  { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# 숫자는 지역 설정과 무관하게 항상 '.' 소수점으로 쓴다.
function Format-JsonNumber($Value) {
    $d = [double]$Value
    if ([math]::Floor($d) -eq $d) { return [string][int]$d }
    return $d.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-ReportsJson($Items) {
    $list = @($Items)
    if ($list.Count -eq 0) { return '[]' }

    $keys      = 'title', 'studio', 'desc', 'href', 'region', 'thumb', 'tags', 'platforms', 'topics', 'status', 'date', 'rating', 'slug'
    $arrayKeys = 'tags', 'platforms', 'topics'
    $out       = New-Object System.Collections.Generic.List[string]
    [void]$out.Add('[')

    for ($i = 0; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        [void]$out.Add('  {')
        for ($k = 0; $k -lt $keys.Count; $k++) {
            $key   = $keys[$k]
            $comma = ''
            if ($k -lt $keys.Count - 1) { $comma = ',' }

            if ($key -eq 'rating') {
                $r = $e.rating
                if ($null -eq $r) {
                    [void]$out.Add('    "rating": null' + $comma)
                } else {
                    [void]$out.Add('    "rating": {')
                    [void]$out.Add('      "avg": '   + (Format-JsonNumber $r.avg)   + ',')
                    [void]$out.Add('      "sd": '    + (Format-JsonNumber $r.sd)    + ',')
                    [void]$out.Add('      "count": ' + (Format-JsonNumber $r.count) + ',')
                    $axKeys = @($r.axes.Keys)
                    if ($axKeys.Count -eq 0) {
                        [void]$out.Add('      "axes": {}')
                    } else {
                        [void]$out.Add('      "axes": {')
                        for ($x = 0; $x -lt $axKeys.Count; $x++) {
                            $xc = ''
                            if ($x -lt $axKeys.Count - 1) { $xc = ',' }
                            [void]$out.Add('        ' + (Format-JsonString $axKeys[$x]) + ': ' +
                                           (Format-JsonNumber $r.axes[$axKeys[$x]]) + $xc)
                        }
                        [void]$out.Add('      }')
                    }
                    [void]$out.Add('    }' + $comma)
                }
            }
            elseif ($arrayKeys -contains $key) {
                $vals = @($e.$key)
                if ($vals.Count -eq 0) {
                    [void]$out.Add('    ' + (Format-JsonString $key) + ': []' + $comma)
                } else {
                    [void]$out.Add('    ' + (Format-JsonString $key) + ': [')
                    for ($t = 0; $t -lt $vals.Count; $t++) {
                        $tc = ''
                        if ($t -lt $vals.Count - 1) { $tc = ',' }
                        [void]$out.Add('      ' + (Format-JsonString $vals[$t]) + $tc)
                    }
                    [void]$out.Add('    ]' + $comma)
                }
            } else {
                [void]$out.Add('    ' + (Format-JsonString $key) + ': ' + (Format-JsonString $e.$key) + $comma)
            }
        }
        $tail = ''
        if ($i -lt $list.Count - 1) { $tail = ',' }
        [void]$out.Add('  }' + $tail)
    }

    [void]$out.Add(']')
    return ($out -join "`n")
}

# ─────────────────────────── 본체 ───────────────────────────

function Build-Entry([System.IO.FileInfo]$File) {
    $slug = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $src  = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

    # reports/ 기준 상대 경로 → href 와 지역
    $rel = $File.FullName.Substring($ReportsDir.Length).TrimStart('\', '/').Replace('\', '/')
    $folder = ''
    if ($rel.Contains('/')) { $folder = $rel.Split('/')[0] }
    $region = Resolve-Region $folder

    $meta  = Read-ReportMeta $src
    $rep   = $meta.report
    $og    = $meta.og
    $chips = Get-Chips $src

    $ts = Get-TitleAndStudio $src $slug
    $title  = if ($rep['title'])  { $rep['title'] }  else { $ts[0] }
    $studio = if ($rep['studio']) { $rep['studio'] } elseif ($chips['개발사']) { $chips['개발사'] } else { $ts[1] }

    $desc = if ($rep['desc']) { $rep['desc'] } elseif ($og['description']) { $og['description'] } else { Get-Description $src }
    $thumb = if ($rep['thumb']) { $rep['thumb'] } elseif ($og['image']) { $og['image'] } else { Get-Thumbnail $src }

    # ── 장르(카드에 그대로 보일 원문 구절) ──
    if ($rep['tags']) {
        $tags = Split-TagValues $rep['tags']
    } else {
        $collected = New-Object System.Collections.Generic.List[string]
        foreach ($label in '장르', '태그') {
            if ($chips[$label]) {
                foreach ($v in (Split-TagValues $chips[$label])) {
                    if (-not $collected.Contains($v)) { [void]$collected.Add($v) }
                }
            }
        }
        $tags = $collected.ToArray()
    }

    # ── 플랫폼 (별도 필터 그룹) ──
    if ($rep['platforms']) {
        $platRaw = Split-TagValues $rep['platforms']
    } else {
        $platRaw = @()
        foreach ($key in $chips.Keys) {
            if ($key -match '플랫폼') { $platRaw += Split-TagValues $chips[$key] }
        }
    }
    $platforms = New-Object System.Collections.Generic.List[string]
    foreach ($p in $platRaw) {
        $n = Normalize-Platform $p
        if ($n -and -not $platforms.Contains($n)) { [void]$platforms.Add($n) }
    }
    # 플랫폼 chip 이 없어도 Steam 상점 링크가 있으면 PC 로 본다.
    if ($platforms.Count -eq 0 -and $src -match 'store\.steampowered\.com') {
        [void]$platforms.Add('PC')
    }

    # ── 장르 키워드 (필터 전용) ──
    if ($rep['topics']) { $topics = Split-TagValues $rep['topics'] }
    else                { $topics = Get-Topics $tags }

    # ── 상태 ──
    # 상태 chip 이 없으면 '출시' 가 들어간 라벨(정식 출시 / 1.0 출시 …)을 본다.
    $statusRaw = ''
    if ($chips['상태']) {
        $statusRaw = $chips['상태']
    } else {
        foreach ($key in $chips.Keys) {
            if ($key -match '출시') { $statusRaw = $chips[$key]; break }
        }
    }
    $status = if ($rep['status']) { $rep['status'] } else { Normalize-Status $statusRaw }

    # ── 날짜 ──
    # 리포트가 스스로 밝힌 작성일/기준일이 가장 정확하다.
    # git 커밋일에 기대면 파일을 한 번 커밋한 순간 전부 같은 날짜가 되어버린다.
    $date = ''
    if ($rep['date']) {
        $date = $rep['date']
    } else {
        # 1) chip 으로 들어간 경우
        foreach ($key in $chips.Keys) {
            if ($key -match '작성일|기준일|작성') {
                $date = ConvertTo-IsoDate $chips[$key]
                if ($date) { break }
            }
        }
        # 2) 본문 어딘가에 "기준일 2026.08.13" 형태로만 적힌 경우
        if (-not $date) {
            $plain = ConvertTo-PlainText $src
            $m = [regex]::Match($plain, '(?:기준일|작성일)\s*[:：]?\s*(\d{4}[.\-/]\d{1,2}[.\-/]\d{1,2})')
            if ($m.Success) { $date = ConvertTo-IsoDate $m.Groups[1].Value }
        }
    }
    # 3) 그래도 없으면 파일이 처음 추가된 커밋일
    if (-not $date) { $date = Get-ReportDate $File.FullName }

    # ── 팀 평점 ── 리포트 안의 평가표에서 읽는다
    $rating = $null
    $rateRows = Get-ReportRatings $src
    if ($rateRows.Count -gt 0) { $rating = Get-RatingSummary $rateRows }

    return [pscustomobject][ordered]@{
        title     = [string]$title
        studio    = [string]$studio
        desc      = [string]$desc
        href      = 'reports/' + $rel
        region    = [string]$region
        thumb     = [string]$thumb
        tags      = @($tags)
        platforms = @($platforms.ToArray())
        topics    = @($topics)
        status    = [string]$status
        date      = [string]$date
        rating    = $rating
        slug      = $slug
    }
}

if (-not (Test-Path -LiteralPath $ReportsDir)) {
    Write-Error "reports/ 폴더가 없습니다: $ReportsDir"
    exit 1
}

# 하위 폴더(kr / global …)까지 훑는다.
$files = @(Get-ChildItem -LiteralPath $ReportsDir -File -Recurse |
           Where-Object { $_.Extension -match '^\.html?$' -and -not $_.Name.StartsWith('_') } |
           Sort-Object FullName)

# 새 리포트에 빠져 있는 것들을 먼저 채운다
$linked = 0
$rated  = 0
foreach ($f in $files) {
    try { if (Add-HomeLink $f)    { $linked++ } }
    catch { Write-Host ("  [!!] {0} 에 아카이브 버튼을 넣지 못했습니다: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Yellow }
    try { if (Add-RatingBlock $f) { $rated++ } }
    catch { Write-Host ("  [!!] {0} 에 평가표를 넣지 못했습니다: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Yellow }
}
if ($linked -gt 0) { Write-Host ("  아카이브 버튼을 {0}편에 새로 넣었습니다" -f $linked) -ForegroundColor DarkGray }
if ($rated  -gt 0) { Write-Host ("  평가표를 {0}편에 새로 넣었습니다" -f $rated)      -ForegroundColor DarkGray }

$entries = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    try {
        $e = Build-Entry $f
        [void]$entries.Add($e)
        $tagText = if ($e.topics.Count) { ($e.topics -join ', ') } else { '-' }
        $stText  = if ($e.status) { $e.status } else { '-' }
        Write-Host ("  [OK] {0,-4} {1,-30} {2,-24} {3,-6} {4,-8} {5}" -f $e.region, $e.slug, $e.title, $stText, $e.date, $tagText)
    } catch {
        # 한 파일이 깨져도 전체가 죽지 않게
        Write-Host ("  [!!] {0} 파싱 실패: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Yellow
    }
}

$sorted = @($entries | Sort-Object -Property @{Expression = 'date'; Descending = $true},
                                             @{Expression = 'title'; Descending = $false})

$json = Format-ReportsJson $sorted

# BOM 없는 UTF-8, 줄바꿈은 LF 로 고정 (BOM 이 붙으면 브라우저 JSON 파싱이 깨진다)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutPath, $json + "`n", $utf8NoBom)

# here-string 을 쓰면 JSON 안의 $ 문자가 변수로 해석될 수 있어 문자열 연결로 만든다.
$jsHeader = '/* 자동 생성 파일 - 직접 수정하지 마세요. tools/build-reports.ps1 이 만듭니다. */'
$js = $jsHeader + "`n" + 'window.__REPORTS__ = ' + $json + ";`n"
[System.IO.File]::WriteAllText($OutJsPath, $js, $utf8NoBom)

Write-Host ''
$byRegion = @{}
foreach ($e in $sorted) {
    $r = if ($e.region) { $e.region } else { '미분류' }
    if ($byRegion.ContainsKey($r)) { $byRegion[$r]++ } else { $byRegion[$r] = 1 }
}
$summary = (($byRegion.Keys | Sort-Object | ForEach-Object { "$_ $($byRegion[$_])편" }) -join ' · ')
Write-Host ("  리포트 {0}편 ({1}) -> reports.json / reports.js" -f $sorted.Count, $summary) -ForegroundColor Green
exit 0
