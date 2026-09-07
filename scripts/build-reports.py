#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
reports/ 폴더의 리포트 HTML을 스캔해 reports.json을 생성한다.

메타데이터 우선순위
  1) <meta name="report:*"> 태그        ← 명시하면 그 값이 무조건 이김
  2) 리포트 HTML에서 자동 추출          ← 아무것도 안 해도 웬만하면 잡힘
  3) git 커밋일 / 파일 수정일           ← date 한정

표준 라이브러리만 사용한다. (GitHub Actions에서 pip install 불필요)
"""

import html
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORTS_DIR = os.path.join(ROOT, "reports")
OUT_PATH = os.path.join(ROOT, "reports.json")

# ─────────────────────────── 텍스트 유틸 ───────────────────────────

TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")
# 블록 태그는 공백으로, 인라인 태그(b/span/a 등)는 공백 없이 제거해야
# "Crimson Blade와" 가 "Crimson Blade 와" 로 벌어지지 않는다.
BLOCK_RE = re.compile(
    r"</?(?:p|div|section|article|br|hr|li|ul|ol|h[1-6]|td|th|tr|table|"
    r"blockquote|figure|figcaption|header|footer|nav)\b[^>]*>", re.I)


def strip_tags(frag: str) -> str:
    frag = BLOCK_RE.sub(" ", frag)
    frag = TAG_RE.sub("", frag)
    return WS_RE.sub(" ", html.unescape(frag)).strip()


def attr(tag: str, name: str):
    m = re.search(
        r'\b%s\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|([^\s>]+))' % re.escape(name),
        tag, re.I)
    if not m:
        return None
    return html.unescape(m.group(1) or m.group(2) or m.group(3) or "")


def truncate(text: str, limit: int = 190) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    cut = text[:limit]
    for sep in (". ", "다. ", "! ", "? "):
        i = cut.rfind(sep)
        if i > limit * 0.5:
            return cut[:i + len(sep)].strip()
    return cut.rstrip() + "…"


# ─────────────────────────── 추출기 ───────────────────────────

def read_meta(src: str) -> dict:
    """<meta name="report:xxx" content="..."> 및 og: 태그 수집"""
    meta, og = {}, {}
    for m in re.finditer(r"<meta\b[^>]*>", src, re.I):
        tag = m.group(0)
        key = attr(tag, "name") or attr(tag, "property") or ""
        val = attr(tag, "content")
        if val is None:
            continue
        key = key.strip().lower()
        if key.startswith("report:"):
            meta[key[7:]] = val.strip()
        elif key.startswith("og:"):
            og[key[3:]] = val.strip()
    return {"report": meta, "og": og}


def guess_title_studio(src: str, slug: str):
    """<title>「게임명 · 개발사 — 부제」 형태를 분해"""
    m = re.search(r"<title[^>]*>(.*?)</title>", src, re.S | re.I)
    raw = strip_tags(m.group(1)) if m else ""
    if not raw:
        h1 = re.search(r"<h1[^>]*>(.*?)</h1>", src, re.S | re.I)
        raw = strip_tags(h1.group(1)) if h1 else slug.replace("-", " ").title()

    # 부제 분리: em dash / hyphen
    head = re.split(r"\s+[—–-]\s+", raw)[0].strip()
    # 게임명 · 개발사 분리
    parts = [p.strip() for p in head.split("·") if p.strip()]
    if len(parts) >= 2:
        return parts[0], parts[1]
    return head, ""


def guess_desc(src: str) -> str:
    m = re.search(r'<p[^>]*class="[^"]*\bsub\b[^"]*"[^>]*>(.*?)</p>', src, re.S | re.I)
    if m:
        return truncate(strip_tags(m.group(1)))
    m = re.search(r"<p[^>]*>(.{40,}?)</p>", src, re.S | re.I)
    if m:
        return truncate(strip_tags(m.group(1)))
    return ""


def guess_thumb(src: str) -> str:
    m = re.search(r'<div[^>]*class="[^"]*hero-figure[^"]*"[^>]*>(.*?)</div>', src, re.S | re.I)
    if m:
        img = re.search(r"<img\b[^>]*>", m.group(1), re.I)
        if img:
            return attr(img.group(0), "src") or ""
    img = re.search(r"<img\b[^>]*>", src, re.I)
    return (attr(img.group(0), "src") or "") if img else ""


def parse_chips(src: str) -> dict:
    """<span class="chip">장르 <b>소울라이크 · 액션 로그라이크</b></span> → {"장르": "소울라이크 · 액션 로그라이크"}"""
    out = {}
    for m in re.finditer(r'<span[^>]*class="[^"]*\bchip\b[^"]*"[^>]*>(.*?)</span>', src, re.S | re.I):
        inner = m.group(1)
        b = re.search(r"<b[^>]*>(.*?)</b>", inner, re.S | re.I)
        if not b:
            continue
        value = strip_tags(b.group(1))
        label = strip_tags(inner[:b.start()])
        if label and value:
            out[label] = value
    return out


# 같은 뜻인데 표기가 갈리는 태그를 하나로 모은다. 필요하면 여기에 추가.
TAG_ALIASES = {
    "windows": "PC", "윈도우": "PC", "스팀": "PC", "steam": "PC",
    "playstation": "콘솔", "xbox": "콘솔", "닌텐도 스위치": "콘솔", "switch": "콘솔",
}


def norm_tag(t: str) -> str:
    t = t.strip()
    # "PC (Windows)" → "PC" · 괄호 부연은 필터를 쪼개기만 한다
    stripped = re.sub(r"\s*[（(][^）)]*[）)]\s*$", "", t).strip()
    if stripped:
        t = stripped
    return TAG_ALIASES.get(t.lower(), t)


def split_values(text: str):
    vals = (norm_tag(v) for v in re.split(r"[·,/]| \| ", text))
    return [v for v in vals if v]


def norm_status(raw: str) -> str:
    low = raw.lower()
    if any(k in raw for k in ("미출시", "예정", "출시 전")) or "pre-launch" in low:
        return "출시예정"
    if "데모" in raw or "demo" in low:
        return "데모"
    if "출시" in raw or "released" in low:
        return "출시"
    return raw.strip()


def git_date(path: str) -> str:
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%cs", "--", path],
            cwd=ROOT, capture_output=True, text=True, timeout=20)
        d = out.stdout.strip()
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", d):
            return d
    except Exception:
        pass
    ts = os.path.getmtime(path)
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")


# ─────────────────────────── 본체 ───────────────────────────

def build_entry(path: str) -> dict:
    fname = os.path.basename(path)
    slug = os.path.splitext(fname)[0]
    with open(path, encoding="utf-8", errors="replace") as f:
        src = f.read()

    tags_meta = read_meta(src)
    meta, og = tags_meta["report"], tags_meta["og"]
    chips = parse_chips(src)

    title, studio = guess_title_studio(src, slug)
    title = meta.get("title") or title
    studio = meta.get("studio") or chips.get("개발사") or studio

    desc = meta.get("desc") or og.get("description") or guess_desc(src)
    thumb = meta.get("thumb") or og.get("image") or guess_thumb(src)

    if meta.get("tags"):
        tags = split_values(meta["tags"])
    else:
        tags = []
        for label in ("장르", "플랫폼", "태그"):
            if label in chips:
                tags += split_values(chips[label])
        # 중복 제거, 순서 유지
        tags = list(dict.fromkeys(tags))

    status = meta.get("status") or norm_status(chips.get("상태", "") or chips.get("출시", ""))
    date = meta.get("date") or git_date(path)

    return {
        "title": title,
        "studio": studio,
        "desc": desc,
        "href": "reports/" + fname,
        "thumb": thumb,
        "tags": tags,
        "status": status,
        "date": date,
        "slug": slug,
    }


def main() -> int:
    if not os.path.isdir(REPORTS_DIR):
        print(f"[!] reports/ 폴더가 없습니다: {REPORTS_DIR}", file=sys.stderr)
        return 1

    files = sorted(
        os.path.join(REPORTS_DIR, f)
        for f in os.listdir(REPORTS_DIR)
        if f.lower().endswith((".html", ".htm")) and not f.startswith("_")
    )

    entries = []
    for p in files:
        try:
            e = build_entry(p)
            entries.append(e)
            print(f"  ✓ {e['slug']:<34} {e['title']}  [{e['status']}]  {', '.join(e['tags']) or '-'}")
        except Exception as exc:  # 한 파일이 깨져도 전체가 죽지 않게
            print(f"  ✗ {os.path.basename(p)} 파싱 실패: {exc}", file=sys.stderr)

    entries.sort(key=lambda e: (e["date"], e["title"]), reverse=True)

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"\n[+] 리포트 {len(entries)}편 → {os.path.relpath(OUT_PATH, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
