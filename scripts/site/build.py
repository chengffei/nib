#!/usr/bin/env python3
"""从 index.template.html 生成介绍页，八种语言，与 app 一致。

模板里只写英文和简体中文（<span lang="en"> / <span lang="zh">）；其余六种语言在
scripts/site/i18n/<lang>.json 里按英文原文查译文，缺一条就报错，不会悄悄退回英文。
头部（标题、描述、OG、hreflang、JSON-LD）按语言生成；FAQ 结构化数据直接解析页面里的 FAQ；
sitemap 一并生成。改页面请改模板和译文表，然后运行：python3 scripts/site/build.py
"""
import datetime
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent
TEMPLATE = HERE / "index.template.html"
SITE = "https://chengffei.github.io/nib/"
DOWNLOAD = "https://github.com/chengffei/nib/releases/latest/download/Nib.dmg"

VERSION = re.search(r'CFBundleShortVersionString: "([^"]+)"', (ROOT / "project.yml").read_text()).group(1)
TODAY = datetime.date.today()

MONTHS = {
    "fr": ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
    "de": ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"],
    "es": ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
}
DATES = {
    "en": f"{TODAY:%-d %B %Y}",
    "zh": f"{TODAY.year} 年 {TODAY.month} 月 {TODAY.day} 日",
    "zh-Hant": f"{TODAY.year} 年 {TODAY.month} 月 {TODAY.day} 日",
    "ja": f"{TODAY.year}年{TODAY.month}月{TODAY.day}日",
    "ko": f"{TODAY.year}년 {TODAY.month}월 {TODAY.day}일",
    "fr": f"{TODAY.day} {MONTHS['fr'][TODAY.month - 1]} {TODAY.year}",
    "de": f"{TODAY.day}. {MONTHS['de'][TODAY.month - 1]} {TODAY.year}",
    "es": f"{TODAY.day} de {MONTHS['es'][TODAY.month - 1]} de {TODAY.year}",
}

# 顺序 = 语言菜单的顺序。dir 是 docs 下的目录（英文在根）。
# 英文与简中的标题、描述写在这里；其余六种在 i18n/<lang>.json 的 "__meta__" 里。
PAGES = {
    "en": dict(dir="", html_lang="en", og_locale="en_US", name="English",
        title="Nib — Free Markdown Reader and Editor for Mac, Typora-Style",
        description="A free, open-source Markdown app for Mac. Files open rendered, like a page; press ⌘E to edit in place with syntax shown only on the current line. Saves back only your edits. Reloads files that agents and scripts rewrite. Native, macOS 15+.",
        og_description="Open a .md. Read it as a page. Edit in place, Typora-style. A native Mac app, free and open source.",
        app_description="A free, open-source Markdown reader and editor for Mac. Opens files rendered, edits in place, and saves back only what you changed."),
    "zh": dict(dir="zh/", html_lang="zh-Hans", og_locale="zh_CN", name="简体中文",
        title="Nib — 免费开源的 Mac Markdown 阅读编辑器，Typora 式就地编辑",
        description="免费开源的 Mac Markdown 应用。打开即渲染成排好版的文档，⌘E 就地编辑，只有光标所在行露出语法。存盘只写回你的改动。Agent 和脚本改写文件后自动刷新。原生应用，macOS 15+。",
        og_description="打开 .md，看到的就是成品。Typora 式就地编辑，原生 Mac 应用，免费开源。",
        app_description="免费开源的 Mac Markdown 阅读编辑器。打开即渲染，就地编辑，存盘只写回你改过的地方。"),
    "zh-Hant": dict(dir="zh-hant/", html_lang="zh-Hant", og_locale="zh_TW", name="繁體中文"),
    "ja": dict(dir="ja/", html_lang="ja", og_locale="ja_JP", name="日本語"),
    "ko": dict(dir="ko/", html_lang="ko", og_locale="ko_KR", name="한국어"),
    "fr": dict(dir="fr/", html_lang="fr", og_locale="fr_FR", name="Français"),
    "de": dict(dir="de/", html_lang="de", og_locale="de_DE", name="Deutsch"),
    "es": dict(dir="es/", html_lang="es", og_locale="es_ES", name="Español"),
}
# 调试：NIB_SITE_ONLY=en,zh 只生成这几种语言
import os
if os.environ.get("NIB_SITE_ONLY"):
    PAGES = {k: v for k, v in PAGES.items() if k in os.environ["NIB_SITE_ONLY"].split(",")}
# 截图：中文两种页面用中文界面截图，其余用英文
SHOTS = {
    "en": dict(shot=("en-read.png", "Nib showing a rendered Markdown cheat sheet, with the workspace sidebar, tabs and git change dots"),
               edit=("en-edit.png", "Nib in edit mode, dark theme: the current line shows its # and the margin marks heading levels"),
               search=("en-search.png", "Nib searching every Markdown file in the workspace")),
    "zh": dict(shot=("zh-read.png", "Nib 打开一份排好版的 Markdown 速查，左侧是工作区与 git 改动圆点"),
               edit=("zh-edit.png", "Nib 编辑模式（深色）：当前行露出 #，左侧标出标题层级"),
               search=("zh-search.png", "Nib 搜索工作区里的全部 Markdown")),
}
for lang, page in PAGES.items():
    if "title" not in page:
        meta = json.loads((HERE / "i18n" / f"{lang}.json").read_text())["__meta__"]
        page.update(meta)
    shots = SHOTS["zh" if lang in ("zh", "zh-Hant") else "en"]
    page["shot"], page["shot_alt"] = shots["shot"]
    page["edit_shot"], page["edit_shot_alt"] = shots["edit"]
    page["search_shot"], page["search_shot_alt"] = shots["search"]
    page["url"] = SITE + page["dir"]
    page["out"] = ROOT / "docs" / page["dir"] / "index.html"
    page["base"] = "../" if page["dir"] else ""
    page["updated"] = DATES[lang]

LANG_SPAN = r'<span lang="{}">(.*?)</span>'


def localize(text, lang):
    """只留本语言的文案。英文、简中直接取模板；其他语言按英文原文查译文表。"""
    if lang == "en":
        text = re.sub(LANG_SPAN.format("zh"), "", text, flags=re.S)
        return re.sub(LANG_SPAN.format("en"), r"\1", text, flags=re.S)
    if lang == "zh":
        text = re.sub(LANG_SPAN.format("en"), "", text, flags=re.S)
        return re.sub(LANG_SPAN.format("zh"), r"\1", text, flags=re.S)
    table = json.loads((HERE / "i18n" / f"{lang}.json").read_text())
    missing = sorted({s for s in re.findall(LANG_SPAN.format("en"), text, re.S) if s not in table})
    assert not missing, f"{lang}: {len(missing)} untranslated, first: {missing[0][:60]!r}"
    text = re.sub(LANG_SPAN.format("zh"), "", text, flags=re.S)
    return re.sub(LANG_SPAN.format("en"), lambda m: table[m.group(1)], text, flags=re.S)


def language_menu(current):
    """导航里的语言菜单：当前语言作标题，展开列出其余七种；不依赖 JS"""
    links = []
    for lang, page in PAGES.items():
        if lang == current:
            continue
        href = page["base"] and "" or ""
        # 从当前页到目标页的相对路径：根页直接写目录名，子目录页先回上一级
        href = ("../" if PAGES[current]["dir"] else "") + page["dir"]
        if not href:
            href = "./" if not PAGES[current]["dir"] else "../"
        links.append(f'<a href="{href}" hreflang="{page["html_lang"]}" lang="{page["html_lang"]}">{page["name"]}</a>')
    return ('<details class="langs"><summary class="lang-toggle" aria-label="Language">'
            f'{PAGES[current]["name"]}</summary><div class="langs-menu">' + "".join(links) + "</div></details>")


def plain(fragment):
    return html.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def faq_items(page_html):
    pattern = r"<details><summary>(.*?)</summary><p>(.*?)</p></details>"
    return [(plain(q), plain(a)) for q, a in re.findall(pattern, page_html, re.S)]


def head(lang, page, faq):
    esc = lambda s: html.escape(s, quote=True)
    app = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "Nib",
        "description": page["app_description"],
        "applicationCategory": "DeveloperApplication",
        "applicationSubCategory": "Markdown editor",
        "operatingSystem": "macOS 15 or later",
        "softwareVersion": VERSION,
        "dateModified": TODAY.isoformat(),
        "inLanguage": page["html_lang"],
        "url": page["url"],
        "downloadUrl": DOWNLOAD,
        "fileFormat": ["text/markdown"],
        "screenshot": SITE + "images/" + page["shot"],
        "image": SITE + "images/icon.png",
        "license": "https://www.gnu.org/licenses/gpl-3.0.html",
        "isAccessibleForFree": True,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "author": {"@type": "Person", "name": "Felix", "url": "https://github.com/chengffei"},
        "codeRepository": "https://github.com/chengffei/nib",
    }
    faq_ld = {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "inLanguage": page["html_lang"],
        "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}}
            for q, a in faq
        ],
    }
    ld = lambda d: '<script type="application/ld+json">\n' + json.dumps(d, ensure_ascii=False, indent=2) + "\n</script>"
    alternates = [f'<link rel="alternate" hreflang="{p["html_lang"]}" href="{p["url"]}">' for p in PAGES.values()]
    alternates.append(f'<link rel="alternate" hreflang="x-default" href="{SITE}">')
    locales = [f'<meta property="og:locale:alternate" content="{p["og_locale"]}">' for l, p in PAGES.items() if l != lang]
    return "\n".join([
        f"<title>{esc(page['title'])}</title>",
        f'<meta name="description" content="{esc(page["description"])}">',
        f'<link rel="canonical" href="{page["url"]}">',
        *alternates,
        f'<link rel="alternate" type="text/plain" title="llms.txt" href="{SITE}llms.txt">',
        '<meta name="theme-color" content="#ffffff">',
        '<meta property="og:type" content="website">',
        '<meta property="og:site_name" content="Nib">',
        f'<meta property="og:url" content="{page["url"]}">',
        f'<meta property="og:title" content="{esc(page["title"])}">',
        f'<meta property="og:description" content="{esc(page["og_description"])}">',
        f'<meta property="og:image" content="{SITE}images/og.png">',
        '<meta property="og:image:width" content="1200">',
        '<meta property="og:image:height" content="630">',
        '<meta property="og:image:alt" content="Nib showing a rendered Markdown document">',
        f'<meta property="og:locale" content="{page["og_locale"]}">',
        *locales,
        '<meta name="twitter:card" content="summary_large_image">',
        f'<meta name="twitter:title" content="{esc(page["title"])}">',
        f'<meta name="twitter:description" content="{esc(page["og_description"])}">',
        f'<meta name="twitter:image" content="{SITE}images/og.png">',
        f'<link rel="icon" type="image/png" sizes="64x64" href="{page["base"]}images/favicon.png">',
        f'<link rel="apple-touch-icon" href="{page["base"]}images/apple-touch-icon.png">',
        ld(app),
        ld(faq_ld),
    ])


def sitemap():
    links = "".join(f'\n    <xhtml:link rel="alternate" hreflang="{p["html_lang"]}" href="{p["url"]}"/>' for p in PAGES.values())
    links += f'\n    <xhtml:link rel="alternate" hreflang="x-default" href="{SITE}"/>'
    urls = "".join(f"\n  <url>\n    <loc>{p['url']}</loc>\n    <lastmod>{TODAY.isoformat()}</lastmod>{links}\n  </url>" for p in PAGES.values())
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
            f'xmlns:xhtml="http://www.w3.org/1999/xhtml">{urls}\n</urlset>\n')


def main():
    template = TEMPLATE.read_text()
    for lang, page in PAGES.items():
        body = localize(template, lang)
        out = (body
               .replace("{{HTML_LANG}}", page["html_lang"])
               .replace("{{BASE}}", page["base"])
               .replace("{{LANG_TOGGLE}}", language_menu(lang))
               .replace("{{SHOT}}", page["shot"])
               .replace("{{SHOT_ALT}}", html.escape(page["shot_alt"], quote=True))
               .replace("{{EDIT_SHOT}}", page["edit_shot"])
               .replace("{{EDIT_SHOT_ALT}}", html.escape(page["edit_shot_alt"], quote=True))
               .replace("{{SEARCH_SHOT}}", page["search_shot"])
               .replace("{{SEARCH_SHOT_ALT}}", html.escape(page["search_shot_alt"], quote=True))
               .replace("{{VERSION}}", VERSION)
               .replace("{{UPDATED}}", TODAY.isoformat())
               .replace("{{UPDATED_L}}", page["updated"]))
        out = out.replace("{{HEAD}}", head(lang, page, faq_items(out)))
        assert "{{" not in out and "<span lang=" not in out, lang
        page["out"].parent.mkdir(parents=True, exist_ok=True)
        page["out"].write_text(out)
        print(f"{lang}: {page['out'].relative_to(ROOT)} ({len(out):,} bytes, {len(faq_items(out))} FAQ)")
    if not os.environ.get("NIB_SITE_ONLY"):
        (ROOT / "docs/sitemap.xml").write_text(sitemap())
    print("sitemap: docs/sitemap.xml")


if __name__ == "__main__":
    main()
