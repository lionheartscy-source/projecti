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
    [string]$Root   = (Split-Path -Parent $PSScriptRoot),
    [string]$GitExe = 'git'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

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

# 같은 뜻인데 표기가 갈리는 태그를 하나로 모은다. 필요하면 여기에 추가.
$TagAliases = @{
    'windows' = 'PC'; '윈도우' = 'PC'; '스팀' = 'PC'; 'steam' = 'PC'
    'playstation' = '콘솔'; 'xbox' = '콘솔'; 'switch' = '콘솔'; '닌텐도 스위치' = '콘솔'
}

function Normalize-Tag([string]$Tag) {
    $t = $Tag.Trim()
    # "PC (Windows)" → "PC" · 괄호 부연은 필터를 쪼개기만 한다
    $stripped = ([regex]'\s*[（(][^）)]*[）)]\s*$').Replace($t, '').Trim()
    if ($stripped) { $t = $stripped }
    $k = $t.ToLowerInvariant()
    if ($TagAliases.ContainsKey($k)) { return $TagAliases[$k] }
    return $t
}

function Split-TagValues([string]$Text) {
    $sep = '[' + [char]0x00B7 + ',/]|\s\|\s'
    return @($Text -split $sep | ForEach-Object { Normalize-Tag $_ } | Where-Object { $_ })
}

function Normalize-Status([string]$Raw) {
    if (-not $Raw) { return '' }
    $low = $Raw.ToLowerInvariant()
    if ($Raw -match '미출시|예정|출시 전' -or $low -match 'pre-launch') { return '출시예정' }
    if ($Raw -match '데모' -or $low -match 'demo')                      { return '데모' }
    if ($Raw -match '출시' -or $low -match 'released')                  { return '출시' }
    return $Raw.Trim()
}

function Get-ReportDate([string]$Path) {
    try {
        $d = & $GitExe -C $Root log -1 --format=%cs -- $Path 2>$null
        if ($LASTEXITCODE -eq 0 -and $d) {
            $d = ($d | Select-Object -First 1).ToString().Trim()
            if ($d -match '^\d{4}-\d{2}-\d{2}$') { return $d }
        }
    } catch {}
    return (Get-Item -LiteralPath $Path).LastWriteTime.ToString('yyyy-MM-dd')
}

# ─────────────────────────── 본체 ───────────────────────────

function Build-Entry([System.IO.FileInfo]$File) {
    $slug = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $src  = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

    $meta  = Read-ReportMeta $src
    $rep   = $meta.report
    $og    = $meta.og
    $chips = Get-Chips $src

    $ts = Get-TitleAndStudio $src $slug
    $title  = if ($rep['title'])  { $rep['title'] }  else { $ts[0] }
    $studio = if ($rep['studio']) { $rep['studio'] } elseif ($chips['개발사']) { $chips['개발사'] } else { $ts[1] }

    $desc = if ($rep['desc']) { $rep['desc'] } elseif ($og['description']) { $og['description'] } else { Get-Description $src }
    $thumb = if ($rep['thumb']) { $rep['thumb'] } elseif ($og['image']) { $og['image'] } else { Get-Thumbnail $src }

    if ($rep['tags']) {
        $tags = Split-TagValues $rep['tags']
    } else {
        $collected = New-Object System.Collections.Generic.List[string]
        foreach ($label in '장르', '플랫폼', '태그') {
            if ($chips[$label]) {
                foreach ($v in (Split-TagValues $chips[$label])) {
                    if (-not $collected.Contains($v)) { [void]$collected.Add($v) }
                }
            }
        }
        $tags = $collected.ToArray()
    }

    $statusRaw = if ($chips['상태']) { $chips['상태'] } elseif ($chips['출시']) { $chips['출시'] } else { '' }
    $status = if ($rep['status']) { $rep['status'] } else { Normalize-Status $statusRaw }
    $date   = if ($rep['date'])   { $rep['date'] }   else { Get-ReportDate $File.FullName }

    return [pscustomobject][ordered]@{
        title  = [string]$title
        studio = [string]$studio
        desc   = [string]$desc
        href   = 'reports/' + $File.Name
        thumb  = [string]$thumb
        tags   = @($tags)
        status = [string]$status
        date   = [string]$date
        slug   = $slug
    }
}

if (-not (Test-Path -LiteralPath $ReportsDir)) {
    Write-Error "reports/ 폴더가 없습니다: $ReportsDir"
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $ReportsDir -File |
           Where-Object { $_.Extension -match '^\.html?$' -and -not $_.Name.StartsWith('_') } |
           Sort-Object Name)

$entries = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    try {
        $e = Build-Entry $f
        [void]$entries.Add($e)
        $tagText = if ($e.tags.Count) { ($e.tags -join ', ') } else { '-' }
        Write-Host ("  [OK] {0,-34} {1}  [{2}]  {3}" -f $e.slug, $e.title, $e.status, $tagText)
    } catch {
        # 한 파일이 깨져도 전체가 죽지 않게
        Write-Host ("  [!!] {0} 파싱 실패: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Yellow
    }
}

$sorted = @($entries | Sort-Object -Property @{Expression = 'date'; Descending = $true},
                                             @{Expression = 'title'; Descending = $false})

if ($sorted.Count -eq 0) {
    # 리포트가 하나도 없을 때 ConvertTo-Json 은 null 을 뱉는다
    $json = '[]'
} else {
    $json = ConvertTo-Json -InputObject ([object[]]$sorted) -Depth 6
    # 항목이 1개면 배열이 아닌 객체로 직렬화되는 경우가 있어 감싸준다
    if (-not $json.TrimStart().StartsWith('[')) { $json = "[`r`n$json`r`n]" }
}

# PowerShell 5.1 은 비ASCII를 \uXXXX 로 escape 한다. 한글이 그대로 보이도록 되돌린다.
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
    param($m)
    $code = [Convert]::ToInt32($m.Groups[1].Value, 16)
    if ($code -gt 127) { [string][char]$code } else { $m.Value }
})

# BOM 없는 UTF-8 로 저장 (BOM 이 붙으면 브라우저 JSON 파싱이 깨진다)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutPath, $json + "`r`n", $utf8NoBom)

$js = @"
/* 자동 생성 파일 — 직접 수정하지 마세요. tools/build-reports.ps1 이 만듭니다. */
window.__REPORTS__ = $json;
"@
[System.IO.File]::WriteAllText($OutJsPath, $js + "`r`n", $utf8NoBom)

Write-Host ''
Write-Host ("  리포트 {0}편 -> reports.json / reports.js" -f $sorted.Count) -ForegroundColor Green
exit 0
