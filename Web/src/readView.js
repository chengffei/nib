// Read mode with a Typora theme selected: renders markdown into HTML with the same structure as a Typora export (h1, p, pre.md-fences inside #write,
// figure.table-figure, ...) so the theme CSS applies as-is. Edit and source modes still use CodeMirror.

import MarkdownIt from 'markdown-it'
import { autoFit, keepShortColumns } from './tableColumns.js'
import { sizeImage } from './livePreview.js'
import { highlightCode, tagHighlighter, tags as t } from '@lezer/highlight'
import { t as tr } from './i18n.js'
import { isDarkAt, isMermaid, mountMermaid, renderMermaid } from './mermaid.js'

// Code blocks are coloured with Typora's (CodeMirror 5) class names, which is what selectors like .cm-s-inner .cm-keyword in themes recognise.
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
  // Raw HTML in markdown is not allowed through: a web view can run scripts, and opening an untrusted document must not execute its contents.
  const md = new MarkdownIt({ html: false, linkify: true, typographer: false })

  const languageFor = (name) => {
    if (!name) return null
    const key = name.toLowerCase()
    return codeLanguages.find((d) => d.name === key || d.alias.includes(key)) || null
  }

  // Code blocks: following Typora's export structure, one pre.CodeMirror-line per line.
  md.renderer.rules.fence = (tokens, idx) => {
    const token = tokens[idx]
    const name = token.info.trim().split(/\s+/)[0] || ''
    const code = token.content.replace(/\n$/, '')
    // Same wrapper Typora exports for diagrams; the SVG is filled in by decorate (or awaited in renderHTML).
    if (isMermaid(name)) return `<div class="md-diagram-panel md-fences-adv-panel nib-mermaid" data-code="${escape(code)}"></div>\n`
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
  // Paragraphs are pre-wrap (as in Typora), and markdown-it follows a <br> with a newline character, so a hard break would render as two lines.
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
    const { source, meta } = split(text)
    write.innerHTML = toHTML(source, meta)
    decorate(write)
    for (const box of write.querySelectorAll('.nib-mermaid')) mountMermaid(box, box.dataset.code, { themeFrom: write })
  }

  function split(text) {
    let source = text.replace(/\r\n?/g, '\n')
    let meta = ''
    const front = /^---[ \t]*\n([\s\S]*?)\n(---|\.\.\.)[ \t]*(\n|$)/.exec(source)
    if (front) {
      meta = `<pre class="md-meta-block md-end-block">${escape(front[1])}</pre>`
      source = source.slice(front[0].length)
    }
    return { source, meta }
  }

  const toHTML = (source, meta) => meta + md.render(source)

  /** The whole document as HTML with the Typora export structure, for Print and Export (never touches the visible layer).
   *  themed: exporting with the Typora theme, so diagrams follow its light or dark text; otherwise the light export style. */
  async function renderHTML(text, themed) {
    const { source, meta } = split(text)
    const root = document.createElement('div')
    root.innerHTML = toHTML(source, meta)
    decorate(root)
    for (const img of root.querySelectorAll('.nib-img-pending')) img.classList.remove('nib-img-pending')
    const dark = themed && isDarkAt(write)
    await Promise.all(
      [...root.querySelectorAll('.nib-mermaid')].map(async (box) => {
        try {
          box.innerHTML = await renderMermaid(box.dataset.code, dark)
        } catch {
          const pre = document.createElement('pre')
          pre.textContent = box.dataset.code
          box.replaceChildren(pre)
        }
        box.removeAttribute('data-code')
      }),
    )
    return root.innerHTML
  }

  // Adds structures present in Typora exports but missing from markdown-it: task lists, table wrappers, heading anchors, local image URLs.
  function decorate(write) {
    // Typora always wraps list item content in <p>, and theme spacing and task checkbox positioning assume it; markdown-it does not wrap in tight lists, so it is added here.
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
      // The attribute, not the property: exports serialise innerHTML, which only carries attributes.
      if (done) box.setAttribute('checked', '')
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
      autoFit(table, figure)
    }
    for (const heading of write.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
      heading.id = slug(heading.textContent)
      heading.classList.add('md-end-block', 'md-heading')
    }
    for (const img of write.querySelectorAll('img')) {
      const url = resolveImage(img.getAttribute('src') || '')
      if (url) {
        sizeImage(img, url)
        img.src = url
      } else img.removeAttribute('src')
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
    findAt: (query, nth) => find.show(query, nth),
    renderHTML,
  }
}

// Find in read mode: looks the same as the edit-mode bar (same nib-find styles); matches are marked with CSS highlights and the body DOM is left untouched.
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
    // Start from the first match visible on screen instead of jumping back to the top.
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
    /** Open with a query and go to the nth match (0-based), used when coming from workspace search. */
    show(query, nth) {
      bar.hidden = false
      input.value = query
      search()
      if (matches.length) {
        current = Math.min(Math.max(nth, 0), matches.length - 1)
        paint(true)
      }
    },
    close,
  }
}
