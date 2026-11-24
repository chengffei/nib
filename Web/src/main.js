// Nib editor core: CodeMirror 6. The document is the text itself; all rendering is a decoration layer.
import { Annotation, Compartment, EditorSelection, EditorState } from '@codemirror/state'
import { EditorView, keymap } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, redo, undo } from '@codemirror/commands'
import { listIndentKeymap } from './listIndent.js'
import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { HighlightStyle, LanguageDescription, StreamLanguage, ensureSyntaxTree, syntaxHighlighting } from '@codemirror/language'
import { SearchQuery, findNext, highlightSelectionMatches, openSearchPanel, search, searchKeymap, setSearchQuery } from '@codemirror/search'
import { tags as t } from '@lezer/highlight'
import { attachScrollbar } from './scrollbar.js'
import { createFindPanel } from './findPanel.js'
import { javascript } from '@codemirror/lang-javascript'
import { python } from '@codemirror/lang-python'
import { json } from '@codemirror/lang-json'
import { html } from '@codemirror/lang-html'
import { css } from '@codemirror/lang-css'
import { sql } from '@codemirror/lang-sql'
import { yaml } from '@codemirror/lang-yaml'
import { rust } from '@codemirror/lang-rust'
import { go } from '@codemirror/lang-go'
import { java } from '@codemirror/lang-java'
import { cpp } from '@codemirror/lang-cpp'
import { shell } from '@codemirror/legacy-modes/mode/shell'
import { swift } from '@codemirror/legacy-modes/mode/swift'
import { links, livePreview, post, reading, resolveImage } from './livePreview.js'
import { createReadView } from './readView.js'
import { createTyporaTheme } from './typoraTheme.js'
import { phrases } from './i18n.js'
import { createWordCounter } from './wordCount.js'
import { createOutline } from './outline.js'
import { focusModes, setFocusModes } from './focusModes.js'
import { tables } from './table.js'
import { htmlToMarkdown, inCode } from './htmlPaste.js'
import { EXPORT_CSS } from './exportStyle.js'

const lang = (name, alias, support) => LanguageDescription.of({ name, alias, support })
const legacy = (mode) => ({ language: StreamLanguage.define(mode), extension: StreamLanguage.define(mode) })
const codeLanguages = [
  lang('javascript', ['js', 'jsx'], javascript({ jsx: true })),
  lang('typescript', ['ts', 'tsx'], javascript({ jsx: true, typescript: true })),
  lang('python', ['py'], python()),
  lang('json', ['jsonc', 'json5'], json()),
  lang('html', ['xml', 'svg'], html()),
  lang('css', ['scss'], css()),
  lang('sql', [], sql()),
  lang('yaml', ['yml'], yaml()),
  lang('rust', ['rs'], rust()),
  lang('go', ['golang'], go()),
  lang('java', ['kotlin'], java()),
  lang('cpp', ['c', 'c++', 'objc', 'h'], cpp()),
  lang('shell', ['bash', 'sh', 'zsh', 'fish'], legacy(shell)),
  lang('swift', [], legacy(swift)),
]

// YAML front matter: left unhandled, the parser would read it as a thematic break plus a level-2 heading.
const frontmatter = {
  defineNodes: [{ name: 'Frontmatter', block: true }],
  parseBlock: [
    {
      name: 'Frontmatter',
      before: 'HorizontalRule',
      parse(cx, line) {
        if (cx.lineStart !== 0 || !/^---[ \t]*$/.test(line.text)) return false
        const head = cx.input?.read ? cx.input.read(0, Math.min(cx.input.length, 16384)) : ''
        if (!/^---[ \t]*\r?\n[\s\S]*?\r?\n(---|\.\.\.)[ \t]*(\r?\n|$)/.test(head)) return false
        let end = 0
        while (cx.nextLine()) {
          if (/^(---|\.\.\.)[ \t]*$/.test(line.text)) {
            end = cx.lineStart + line.text.length
            cx.nextLine()
            break
          }
        }
        cx.addElement(cx.elt('Frontmatter', 0, end))
        return true
      },
    },
  ],
}

// Bold, italic and strikethrough only get class names (style props on entries with a class have no effect); styles live in style.css, and typoraEdit.js overrides them under a Typora theme.
const highlight = HighlightStyle.define([
  { tag: t.processingInstruction, color: 'var(--text3)' },
  { tag: [t.labelName, t.url], color: 'var(--text2)' },
  { tag: t.emphasis, class: 'nib-em' },
  { tag: t.strong, class: 'nib-strong' },
  { tag: t.strikethrough, class: 'nib-del' },
  { tag: [t.keyword, t.operatorKeyword, t.modifier, t.controlKeyword, t.definitionKeyword], color: 'var(--c-keyword)' },
  { tag: [t.string, t.special(t.string), t.regexp], color: 'var(--c-string)' },
  { tag: [t.comment, t.lineComment, t.blockComment], color: 'var(--c-comment)' },
  { tag: [t.number, t.bool, t.null, t.atom], color: 'var(--c-number)' },
  { tag: [t.typeName, t.className, t.tagName, t.namespace], color: 'var(--c-type)' },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.attributeName], color: 'var(--c-func)' },
])

// ---- Bridge to the Swift shell ----

const external = Annotation.define()
let lineBreak = '\n'
let pending = false
let timer = 0

const currentText = () => view.state.doc.sliceString(0, view.state.doc.length, lineBreak)

function flush() {
  pending = false
  clearTimeout(timer)
  post({ type: 'change', text: currentText() })
}

function scheduleFlush() {
  if (view.state.doc.length < 400000) {
    if (pending) return
    pending = true
    queueMicrotask(flush)
  } else {
    // Sending the whole document on every keystroke is too costly for large files; wait until typing pauses for 250 ms
    pending = true
    clearTimeout(timer)
    timer = setTimeout(flush, 250)
  }
}

// ---- Commands ----

function toggleWrap(mark) {
  return (view) => {
    if (view.state.readOnly) return false
    const n = mark.length
    const changes = view.state.changeByRange((range) => {
      const { from, to } = range
      const before = view.state.doc.sliceString(Math.max(0, from - n), from)
      const after = view.state.doc.sliceString(to, to + n)
      if (before === mark && after === mark) {
        return {
          changes: [
            { from: from - n, to: from },
            { from: to, to: to + n },
          ],
          range: EditorSelection.range(from - n, to - n),
        }
      }
      return {
        changes: [
          { from, insert: mark },
          { from: to, insert: mark },
        ],
        range: EditorSelection.range(from + n, to + n),
      }
    })
    view.dispatch(changes, { userEvent: 'input' })
    return true
  }
}

// ---- Preferences ----

let defaultMode = 'read'

/** Every change from the shell's Settings window comes through here: it only touches CSS variables and theme markers, never the document. */
function applySettings(s) {
  const root = document.documentElement
  const set = (name, value) => (value == null ? root.style.removeProperty(name) : root.style.setProperty(name, String(value)))
  root.dataset.theme = s.theme || 'system'
  set('--sans', s.bodyFont)
  set('--mono', s.monoFont)
  set('--fs', s.fontSize ? `${s.fontSize}px` : null)
  set('--lh', s.lineHeight)
  set('--para', s.paragraphSpacing)
  defaultMode = ['edit', 'source'].includes(s.defaultMode) ? s.defaultMode : 'read'
  measureMono()
  // Typora themes set their own font size; Nib's font-size setting scales the whole page proportionally in read mode.
  reader.scroller.style.zoom = s.fontSize ? String(s.fontSize / 16) : ''
  if (typora.setCSS(s.typoraCSS)) syncReader()
  setFocusModes(typeof view !== 'undefined' ? view : null, { focus: s.focusMode, typewriter: s.typewriterMode })
  if (typeof view !== 'undefined') view.requestMeasure()
}

/** Measures the actual character width of the monospace font; list hanging indents are aligned with it. */
function measureMono() {
  const probe = document.createElement('span')
  probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;font-family:var(--mono);font-size:100px'
  probe.textContent = '0'.repeat(50)
  document.body.appendChild(probe)
  const width = probe.getBoundingClientRect().width / 50 / 100
  probe.remove()
  if (width > 0.4 && width < 0.8) document.documentElement.style.setProperty('--mono-w', `${width}em`)
}

// Three modes: read renders the whole document read-only (default); edit reveals source on the cursor line; source shows the whole document as monospace source.
const previewPart = new Compartment()
const readPart = new Compartment()
const previewFor = (mode) => (mode === 'source' ? [] : [livePreview, tables])
const readFor = (mode) =>
  mode === 'read' ? [reading.of(true), EditorView.editable.of(false), EditorState.readOnly.of(true)] : []
let mode = 'read'

function setMode(next) {
  if (!['read', 'edit', 'source'].includes(next) || next === mode) return true
  mode = next
  document.body.dataset.mode = mode
  view.dispatch({ effects: [previewPart.reconfigure(previewFor(mode)), readPart.reconfigure(readFor(mode))] })
  syncReader()
  if (mode !== 'read') view.focus()
  post({ type: 'mode', mode })
  requestAnimationFrame(() => outline.track())
  return true
}
const toggleEdit = () => setMode(mode === 'read' ? 'edit' : 'read')
const toggleSource = () => setMode(mode === 'source' ? 'edit' : 'source')

// ---- Links ----

const slug = (text) =>
  text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, '-')

/** In-document anchor #heading: scroll to the matching heading. */
function scrollToHeading(anchor) {
  let want
  try {
    want = slug(decodeURIComponent(anchor))
  } catch {
    want = slug(anchor)
  }
  const { state } = view
  const tree = ensureSyntaxTree(state, state.doc.length, 300)
  if (!tree) return
  let pos = -1
  tree.iterate({
    enter(n) {
      if (pos >= 0) return false
      if (!/^(ATX|Setext)Heading/.test(n.name)) return n.name === 'Document'
      const title = state.doc.sliceString(n.from, n.to).split('\n')[0].replace(/^#+\s*|\s*#+\s*$/g, '')
      if (slug(title) === want) pos = n.from
      return false
    },
  })
  if (pos >= 0) view.dispatch({ effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 24 }) })
}

links.open = (href) => {
  if (href.startsWith('#')) scrollToHeading(href.slice(1))
  else post({ type: 'open', url: href })
}

// ---- Startup ----


function makeState(doc) {
  return EditorState.create({
    doc,
    extensions: [
      EditorState.phrases.of(phrases),
      history(),
      EditorView.lineWrapping,
      EditorState.tabSize.of(4),
      markdown({ base: markdownLanguage, codeLanguages, extensions: [frontmatter] }),
      syntaxHighlighting(highlight),
      search({ top: true, createPanel: createFindPanel }),
      highlightSelectionMatches(),
      previewPart.of(previewFor(mode)),
      readPart.of(readFor(mode)),
      focusModes,
      keymap.of([
        { key: 'Mod-b', run: toggleWrap('**') },
        { key: 'Mod-i', run: toggleWrap('*') },
        ...searchKeymap,
        ...historyKeymap,
        ...listIndentKeymap,
        ...defaultKeymap,
      ]),
      EditorView.domEventHandlers({
        mousedown(event) {
          // In read mode a single click opens the link; in edit mode ⌘ must be held, otherwise the cursor could not be placed inside a link
          const link = (event.metaKey || mode === 'read') && event.target.closest?.('[data-href]')
          if (!link) return false
          links.open(link.dataset.href)
          event.preventDefault()
          return true
        },
        blur() {
          if (pending) flush()
        },
        // Rich text from web pages and documents becomes markdown; ⌥⇧⌘V (Paste and Match Style) is the plain-text escape hatch, handled by the shell.
        paste(event, view) {
          if (view.state.readOnly || inCode(view.state)) return false
          const data = event.clipboardData
          const html = data?.getData('text/html')
          if (!html) return false
          let markdown = null
          try {
            markdown = htmlToMarkdown(html, data.getData('text/plain'))
          } catch (error) {
            post({ type: 'log', text: `html paste failed: ${error}` })
          }
          if (markdown == null) return false
          event.preventDefault()
          view.dispatch(view.state.replaceSelection(markdown), { userEvent: 'input.paste', scrollIntoView: true })
          return true
        },
      }),
      EditorView.updateListener.of((update) => {
        if (window.__nibDebug) {
          for (const tr of update.transactions) {
            if (tr.docChanged) post({ type: 'log', text: `tr ${tr.annotation(external) ? 'external' : 'user'} len=${tr.newDoc.length}` })
          }
        }
        if (update.docChanged || update.selectionSet) wordCounter.schedule()
        if (update.docChanged) outline.schedule()
        if (!update.docChanged) return
        if (update.transactions.some((tr) => tr.annotation(external))) return
        scheduleFlush()
      }),
    ],
  })
}

// With a Typora theme selected, read mode switches to HTML rendered by readView so the theme applies as-is; edit and source modes still use CodeMirror.
let reader = createReadView({ codeLanguages, resolveImage, openLink: (href) => links.open(href), attachScrollbar })
let typora = createTyporaTheme({ post })
// Word count: when text is selected, the selection is reported separately. The read layer is a plain web page, so the selection comes from the DOM.
const wordCounter = createWordCounter({
  post,
  getText: () => currentText(),
  getSelection: () => {
    if (reader.visible) return window.getSelection()?.toString() || ''
    const { state } = view
    return state.selection.ranges.filter((r) => !r.empty).map((r) => state.sliceDoc(r.from, r.to)).join('\n')
  },
})
// Outline: the heading list and the section currently being read are reported to the shell.
const outline = createOutline({ post, getView: () => view, reader })
let trackFrame = 0
document.addEventListener(
  'scroll',
  () => {
    if (trackFrame) return
    trackFrame = requestAnimationFrame(() => {
      trackFrame = 0
      outline.track()
    })
  },
  true,
)
document.addEventListener('selectionchange', () => {
  if (reader.visible) wordCounter.schedule()
})

/** The layer that is currently visible and scrollable. */
const activeScroller = () => (reader.visible ? reader.scroller : view.scrollDOM)

/** Picks the layer read mode uses based on mode and theme; when switching layers, the scroll position is carried over proportionally. */
function syncReader() {
  if (typeof view === 'undefined') return
  const want = mode === 'read' && typora.active
  if (want === reader.visible) {
    if (want) reader.render(currentText())
    return
  }
  const from = activeScroller()
  const ratio = from.scrollHeight > from.clientHeight ? from.scrollTop / (from.scrollHeight - from.clientHeight) : 0
  if (want) {
    reader.render(currentText())
    typora.setReading(true)
    document.body.classList.add('typora-reading')
    reader.show()
  } else {
    reader.hide()
    typora.setReading(false)
    document.body.classList.remove('typora-reading')
  }
  const to = activeScroller()
  requestAnimationFrame(() => {
    to.scrollTop = ratio * (to.scrollHeight - to.clientHeight)
  })
}

applySettings(window.__nibSettings || {})

// Create an empty editor first: the shell pre-warms it, so opening a document only needs load to fill in the content.
mode = 'edit'
document.body.dataset.mode = mode
const view = new EditorView({ parent: document.body, state: makeState('') })
attachScrollbar(view.scrollDOM)

/** Loads a document: fresh state (undo history cleared); a non-empty document opens in read mode, an empty one in edit mode.
 *  top is the scroll position to restore when waking from hibernation. */
function load(text, baseDir, top) {
  window.__nibBaseDir = baseDir || null
  lineBreak = text.includes('\r\n') ? '\r\n' : '\n'
  mode = text.trim() === '' ? 'edit' : defaultMode
  document.body.dataset.mode = mode
  view.setState(makeState(text))
  view.scrollDOM.scrollTop = 0
  reader.invalidate()
  syncReader()
  activeScroller().scrollTop = 0
  if (mode !== 'read') view.focus()
  wordCounter.reset()
  outline.reset()
  if (!(top > 0)) {
    post({ type: 'ready', mode })
    return
  }
  // Line height is only accurate after layout has been measured: set it once on each of the next two frames, then report ready
  const restore = () => {
    activeScroller().scrollTop = top
  }
  restore()
  requestAnimationFrame(() => {
    restore()
    requestAnimationFrame(() => {
      restore()
      post({ type: 'ready', mode })
    })
  })
}

// Read-mode keyboard: Space pages, arrow keys scroll, no mouse needed.
window.addEventListener('keydown', (event) => {
  if (mode !== 'read' || event.ctrlKey || event.altKey) return
  if (event.target.closest?.('input, textarea, button')) return
  const scroller = activeScroller()
  const page = scroller.clientHeight * 0.9
  let top = null
  let smooth = true
  if (event.metaKey) {
    if (event.key === 'ArrowUp') top = 0
    else if (event.key === 'ArrowDown') top = scroller.scrollHeight
  } else if (event.key === ' ') top = scroller.scrollTop + (event.shiftKey ? -page : page)
  else if (event.key === 'PageDown') top = scroller.scrollTop + page
  else if (event.key === 'PageUp') top = scroller.scrollTop - page
  else if (event.key === 'Home') top = 0
  else if (event.key === 'End') top = scroller.scrollHeight
  else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    top = scroller.scrollTop + (event.key === 'ArrowDown' ? 64 : -64)
    smooth = false
  }
  if (top === null) return
  event.preventDefault()
  scroller.scrollTo({ top, behavior: smooth ? 'smooth' : 'auto' })
})

window.nib = {
  load,
  /** Only called for external changes (the file on disk rewritten, Versions rollback); does not echo a change back.
   *  Replaces only the changed range and keeps the scroll position; a view that was at the end keeps following the end. */
  setText(text) {
    lineBreak = text.includes('\r\n') ? '\r\n' : '\n'
    const next = text.replace(/\r\n?/g, '\n')
    const prev = view.state.doc.toString()
    if (prev === next) return
    const max = Math.min(prev.length, next.length)
    let start = 0
    while (start < max && prev.charCodeAt(start) === next.charCodeAt(start)) start++
    let endPrev = prev.length
    let endNext = next.length
    while (endPrev > start && endNext > start && prev.charCodeAt(endPrev - 1) === next.charCodeAt(endNext - 1)) {
      endPrev--
      endNext--
    }
    const scroller = view.scrollDOM
    const top = scroller.scrollTop
    const atBottom = top > 0 && top + scroller.clientHeight >= scroller.scrollHeight - 48
    view.dispatch({
      changes: { from: start, to: endPrev, insert: next.slice(start, endNext) },
      annotations: external.of(true),
    })
    const restore = () => {
      scroller.scrollTop = atBottom ? scroller.scrollHeight : top
    }
    restore()
    requestAnimationFrame(restore)
    // The Typora read layer updates its content too, keeping the original scroll position.
    reader.invalidate()
    if (reader.visible) {
      const readTop = reader.scroller.scrollTop
      reader.render(currentText())
      reader.scroller.scrollTop = readTop
    }
  },
  getText: currentText,
  /** A standalone HTML page of the document for Print / Export: the Typora theme if one is selected, else Nib's export style.
   *  Local images keep their nib-file URLs; the shell inlines them for HTML export. */
  exportHTML(title) {
    const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
    const css = typora.exportCSS || EXPORT_CSS
    const lang = document.documentElement.lang || 'zh-CN'
    return `<!doctype html>\n<html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">` +
      `<title>${esc(title || '')}</title><style>${css}</style></head>` +
      `<body class="typora-export"><div class="typora-export-content"><div id="write">${reader.renderHTML(currentText())}</div></div></body></html>`
  },
  /** Paste and Match Style: the clipboard's plain text exactly as it is. */
  insertPlain(text) {
    if (view.state.readOnly) return false
    view.dispatch(view.state.replaceSelection(text), { userEvent: 'input.paste', scrollIntoView: true })
    view.focus()
    return true
  },
  /** Test hook: what a paste of this HTML would insert. */
  htmlToMarkdown,
  /** Insert pasted images at the cursor as lines of their own (a link glued to other text would break that line's markdown); ignored in read mode. */
  insertText(text) {
    if (view.state.readOnly) return false
    const { state } = view
    const range = state.selection.main
    const line = state.doc.lineAt(range.from)
    const endLine = state.doc.lineAt(range.to)
    const before = range.from > line.from ? '\n' : ''
    const after = range.to < endLine.to ? '\n' : ''
    const insert = before + text + after
    view.dispatch({
      changes: { from: range.from, to: range.to, insert },
      selection: { anchor: range.from + before.length + text.length },
      userEvent: 'input.paste',
      scrollIntoView: true,
    })
    view.focus()
    return true
  },
  /** The heading at position index was clicked in the outline panel. */
  gotoHeading: (index) => outline.go(index),
  undo: () => undo(view),
  redo: () => redo(view),
  setMode,
  toggleEdit,
  toggleSource,
  mode: () => mode,
  applySettings,
  find: () => (reader.visible ? reader.find() : openSearchPanel(view)),
  /** From workspace search: open the find bar with the query and go to its first match on or after the given line (1-based). */
  findAt(query, line) {
    const { doc } = view.state
    const from = doc.line(Math.min(Math.max(line, 1), doc.lines)).from
    if (reader.visible) {
      // The read layer is HTML: count the matches before that line in the source and step to the same index there.
      const before = doc.sliceString(0, from).toLowerCase()
      const needle = query.toLowerCase()
      let nth = 0
      for (let at = before.indexOf(needle); at >= 0; at = before.indexOf(needle, at + needle.length)) nth++
      reader.findAt(query, nth)
      return
    }
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: query })), selection: { anchor: from } })
    openSearchPanel(view)
    findNext(view)
    const head = view.state.selection.main.from
    view.dispatch({ effects: EditorView.scrollIntoView(head, { y: 'center' }) })
  },
  /** The shell records the scroll position before hibernating a tab; the read layer and the editor each scroll independently. */
  scrollTop: () => activeScroller().scrollTop,
  /** After the document is saved elsewhere or moved, relative image paths must be re-resolved against the new directory. */
  setBaseDir(dir) {
    window.__nibBaseDir = dir
    view.dispatch({ selection: view.state.selection })
  },
  view,
}

// scripts/webcheck.swift uses this path: the body is injected before the page loads. The real app waits for the shell to call load.
if (typeof window.__nibInitialText === 'string') load(window.__nibInitialText, window.__nibBaseDir)
else post({ type: 'boot', ms: Math.round(performance.now()) })

// While ⌘ is held, links show an underline to signal they are clickable; it disappears on release or when the window loses focus
const setCmd = (on) => document.body.classList.toggle('nib-cmd', on)
window.addEventListener('keydown', (event) => setCmd(event.metaKey), true)
window.addEventListener('keyup', (event) => setCmd(event.metaKey), true)
window.addEventListener('mousemove', (event) => { if (event.metaKey !== document.body.classList.contains('nib-cmd')) setCmd(event.metaKey) }, true)
window.addEventListener('blur', () => setCmd(false))
