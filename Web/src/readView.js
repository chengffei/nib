// 选了 Typora 主题时的阅读模式：把 md 渲染成和 Typora 导出一样结构的 HTML（#write 里的 h1、p、pre.md-fences、
// figure.table-figure……），主题 CSS 才能原样生效。编辑和源码模式仍走 CodeMirror。

import MarkdownIt from 'markdown-it'
import { keepShortColumns } from './tableColumns.js'
import { highlightCode, tagHighlighter, tags as t } from '@lezer/highlight'
import { t as tr } from './i18n.js'

// 代码块按 Typora（CodeMirror 5）的类名上色，主题里写的 .cm-s-inner .cm-keyword 之类才认得。
const cm5 = tagHighlighter([
  { tag: t.keyword, class: 'cm-keyword' },
  { tag: [t.atom, t.bool, t.null], class: 'cm-atom' },
  { tag: t.number, class: 'cm-number' },
  { tag: [t.definition(t.variableName), t.function(t.definition(t.variableName))], class: 'cm-def' },
  { tag: t.standard(t.variableName), class: 'cm-builtin' },
  { tag: t.function(t.variableName), class: 'cm-variable-2' },
  { tag: t.variableName, class: 'cm-variable' },
  { tag: [t.propertyName, t.function(t.propertyName)], class: 'cm-property' },
  { tag: [t.typeName, t.className, t.namespace], class: 'cm-variable-3 cm-type' },
  { tag: t.operator, class: 'cm-operator' },
  { tag: t.comment, class: 'cm-comment' },
  { tag: [t.regexp, t.special(t.string)], class: 'cm-string-2' },
  { tag: t.string, class: 'cm-string' },
  { tag: t.meta, class: 'cm-meta' },
  { tag: t.tagName, class: 'cm-tag' },
  { tag: t.attributeName, class: 'cm-attribute' },
  { tag: t.bracket, class: 'cm-bracket' },
  { tag: t.heading, class: 'cm-header' },
  { tag: t.link, class: 'cm-link' },
])

const slug = (text) =>
  text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, '-')

const escape = (text) => text.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])

export function createReadView({ codeLanguages, resolveImage, openLink, attachScrollbar }) {
  // 不放行 md 里的原始 HTML：网页视图里能跑脚本，打开来路不明的文稿不该执行里面的东西。
  const md = new MarkdownIt({ html: false, linkify: true, typographer: false })

  const languageFor = (name) => {
    if (!name) return null
    const key = name.toLowerCase()
    return codeLanguages.find((d) => d.name === key || d.alias.includes(key)) || null
  }

  // 代码块：照 Typora 导出的结构，一行一个 pre.CodeMirror-line。
  md.renderer.rules.fence = (tokens, idx) => {
    const token = tokens[idx]
    const name = token.info.trim().split(/\s+/)[0] || ''
    const code = token.content.replace(/\n$/, '')
    const lines = [[]]
    const desc = languageFor(name)
    const parser = desc?.support?.language?.parser
    if (parser) {
      highlightCode(
        code,
        parser.parse(code),
        cm5,
        (text, classes) => lines[lines.length - 1].push(classes ? `<span class="${classes}">${escape(text)}</span>` : escape(text)),
        () => lines.push([]),
      )
    } else {
      code.split('\n').forEach((line, i) => {
        if (i > 0) lines.push([])
        lines[lines.length - 1].push(escape(line))
      })
    }
    const body = lines
      .map((parts) => `<pre class="CodeMirror-line" role="presentation"><span role="presentation">${parts.join('') || '<span cm-text="">&#8203;</span>'}</span></pre>`)
      .join('')
    const lang = escape(name)
    return `<pre class="md-fences md-end-block ty-contain-cm modeLoaded" spellcheck="false" lang="${lang}"><div class="CodeMirror cm-s-inner cm-s-null-scroll CodeMirror-wrap" lang="${lang}"><div class="CodeMirror-scroll"><div class="CodeMirror-sizer"><div class="CodeMirror-lines" role="presentation"><div role="presentation" class="CodeMirror-code">${body}</div></div></div></div></div></pre>\n`
  }
  md.renderer.rules.code_block = (tokens, idx) => md.renderer.rules.fence(tokens, idx)
  // 段落是 pre-wrap（照 Typora），markdown-it 在 <br> 后面还跟一个换行符，硬换行就成了两行。
  md.renderer.rules.hardbreak = () => '<br>'

  const scroller = document.createElement('div')
  scroller.id = 'nib-typora'
  scroller.className = 'typora-export'
  scroller.innerHTML = '<div class="typora-export-content"><div id="write" class=""></div></div>'
  scroller.hidden = true
  document.body.appendChild(scroller)
  const write = scroller.querySelector('#write')
  attachScrollbar(scroller)

  let rendered = null

  function render(text) {
    if (text === rendered) return
    rendered = text
    let source = text.replace(/\r\n?/g, '\n')
    let meta = ''
    const front = /^---[ \t]*\n([\s\S]*?)\n(---|\.\.\.)[ \t]*(\n|$)/.exec(source)
    if (front) {
      meta = `<pre class="md-meta-block md-end-block">${escape(front[1])}</pre>`
      source = source.slice(front[0].length)
    }
    write.innerHTML = meta + md.render(source)
    decorate()
  }

  // 补上 Typora 导出里有、markdown-it 没有的结构：任务列表、表格外框、标题锚点、本地图片地址。
  function decorate() {
    // Typora 的列表项内容总包在 <p> 里，主题的间距和任务框定位都按这个写；紧凑列表里 markdown-it 不包，这里补上。
    for (const li of write.querySelectorAll('li')) {
      if (li.querySelector(':scope > p')) continue
      const p = document.createElement('p')
      while (li.firstChild && !(li.firstChild.nodeType === Node.ELEMENT_NODE && /^(UL|OL|PRE|BLOCKQUOTE|TABLE|FIGURE|HR|H[1-6])$/.test(li.firstChild.tagName))) {
        p.appendChild(li.firstChild)
      }
      if (p.textContent.trim() || p.children.length) li.insertBefore(p, li.firstChild)
      li.classList.add('md-list-item')
    }
    for (const li of write.querySelectorAll('li')) {
      const holder = li.firstElementChild?.tagName === 'P' ? li.firstElementChild : li
      const first = holder.firstChild
      if (!first || first.nodeType !== Node.TEXT_NODE) continue
      const match = /^\[([ xX])\]\s+/.exec(first.textContent)
      if (!match) continue
      const done = match[1] !== ' '
      first.textContent = first.textContent.slice(match[0].length)
      const box = document.createElement('input')
      box.type = 'checkbox'
      box.checked = done
      box.disabled = true
      li.insertBefore(box, li.firstChild)
      li.classList.add('md-task-list-item', 'task-list-item')
      if (done) li.classList.add('task-done')
      li.parentElement?.classList.add('contains-task-list', 'task-list')
    }
    for (const table of write.querySelectorAll('table')) {
      table.classList.add('md-table')
      keepShortColumns(table)
      const figure = document.createElement('figure')
      figure.className = 'table-figure'
      table.replaceWith(figure)
      figure.appendChild(table)
    }
    for (const heading of write.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
      heading.id = slug(heading.textContent)
      heading.classList.add('md-end-block', 'md-heading')
    }
    for (const img of write.querySelectorAll('img')) {
      const url = resolveImage(img.getAttribute('src') || '')
      if (url) img.src = url
      else img.removeAttribute('src')
    }
  }

  write.addEventListener('click', (event) => {
    const link = event.target.closest?.('a[href]')
    if (!link) return
    event.preventDefault()
    const href = link.getAttribute('href')
    if (href.startsWith('#')) {
      let want = href.slice(1)
      try {
        want = decodeURIComponent(want)
      } catch {}
      const target = write.querySelector(`[id="${CSS.escape(slug(want))}"]`)
      target?.scrollIntoView({ block: 'start', behavior: 'smooth' })
    } else openLink(href)
  })

  const find = createHtmlFind(scroller, write)

  return {
    scroller,
    render,
    invalidate() {
      rendered = null
    },
    show() {
      scroller.hidden = false
    },
    hide() {
      scroller.hidden = true
      find.close()
    },
    get visible() {
      return !scroller.hidden
    },
    find: () => find.open(),
  }
}

// 阅读模式里的查找：长得和编辑模式那条一样（同一套 nib-find 样式），匹配用 CSS 高亮标出来，不改动正文的 DOM。
function createHtmlFind(scroller, root) {
  const bar = document.createElement('div')
  bar.className = 'nib-find nib-find-floating'
  bar.hidden = true
  bar.innerHTML = `
    <div class="nib-find-row">
      <label class="nib-find-field">
        <span class="nib-find-glass"><svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><circle cx="6.8" cy="6.8" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M10.2 10.2 14 14" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg></span>
        <input class="nib-find-input" type="text">
        <span class="nib-find-count"></span>
      </label>
      <span class="nib-find-segment">
        <button type="button" class="nib-find-icon" data-step="-1"><svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M10 3 5 8l5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
        <button type="button" class="nib-find-icon" data-step="1"><svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="m6 3 5 5-5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
      </span>
      <span class="nib-find-segment"><button type="button" class="nib-find-toggle" aria-pressed="false">Aa</button></span>
      <span class="nib-find-spacer"></span>
      <button type="button" class="nib-find-button nib-find-done"></button>
    </div>`
  document.body.appendChild(bar)
  const input = bar.querySelector('input')
  const count = bar.querySelector('.nib-find-count')
  const caseToggle = bar.querySelector('.nib-find-toggle')
  input.placeholder = tr('Find')
  bar.querySelector('.nib-find-done').textContent = tr('Done')
  bar.querySelector('[data-step="-1"]').title = tr('previous')
  bar.querySelector('[data-step="1"]').title = tr('next')
  caseToggle.title = tr('match case')

  let matches = []
  let current = -1
  const supported = typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight !== 'undefined'

  function search() {
    matches = []
    current = -1
    const query = input.value
    if (query) {
      const sensitive = caseToggle.getAttribute('aria-pressed') === 'true'
      const needle = sensitive ? query : query.toLowerCase()
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const hay = sensitive ? node.data : node.data.toLowerCase()
        for (let at = hay.indexOf(needle); at >= 0; at = hay.indexOf(needle, at + needle.length)) {
          const range = document.createRange()
          range.setStart(node, at)
          range.setEnd(node, at + needle.length)
          matches.push(range)
        }
      }
    }
    // 从屏幕上第一个可见的匹配开始，不跳回文首。
    const top = scroller.getBoundingClientRect().top
    current = matches.findIndex((r) => r.getBoundingClientRect().bottom > top)
    if (current < 0 && matches.length) current = 0
    paint(false)
  }

  function paint(scroll) {
    if (supported) {
      CSS.highlights.set('nib-find', new Highlight(...matches))
      if (current >= 0) CSS.highlights.set('nib-find-current', new Highlight(matches[current]))
      else CSS.highlights.delete('nib-find-current')
    }
    count.textContent = !input.value ? '' : matches.length === 0 ? tr('No results') : `${current + 1}/${matches.length}`
    if (scroll && current >= 0) {
      const rect = matches[current].getBoundingClientRect()
      const box = scroller.getBoundingClientRect()
      if (rect.top < box.top + 60 || rect.bottom > box.bottom - 40) scroller.scrollTop += rect.top - box.top - box.height / 3
    }
  }

  function step(delta) {
    if (!matches.length) return
    current = (current + delta + matches.length) % matches.length
    paint(true)
  }

  function close() {
    bar.hidden = true
    if (supported) {
      CSS.highlights.delete('nib-find')
      CSS.highlights.delete('nib-find-current')
    }
  }

  input.addEventListener('input', search)
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault()
      close()
    } else if (event.key === 'Enter') {
      event.preventDefault()
      step(event.shiftKey ? -1 : 1)
    }
  })
  for (const button of bar.querySelectorAll('[data-step]')) {
    button.addEventListener('mousedown', (event) => event.preventDefault())
    button.addEventListener('click', () => step(Number(button.dataset.step)))
  }
  caseToggle.addEventListener('click', () => {
    caseToggle.setAttribute('aria-pressed', String(caseToggle.getAttribute('aria-pressed') !== 'true'))
    search()
  })
  bar.querySelector('.nib-find-done').addEventListener('click', close)

  return {
    open() {
      bar.hidden = false
      input.focus()
      input.select()
      if (input.value) search()
    },
    close,
  }
}
