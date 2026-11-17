// Nib 编辑器内核：CodeMirror 6。文档就是文本本身，渲染全部是装饰层。
import { Annotation, Compartment, EditorSelection, EditorState } from '@codemirror/state'
import { EditorView, keymap } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, indentWithTab, redo, undo } from '@codemirror/commands'
import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { HighlightStyle, LanguageDescription, StreamLanguage, ensureSyntaxTree, syntaxHighlighting } from '@codemirror/language'
import { highlightSelectionMatches, openSearchPanel, search, searchKeymap } from '@codemirror/search'
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
import { tables } from './table.js'

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

// YAML front matter：不处理的话，解析器会把它认成分割线加二级标题。
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

const highlight = HighlightStyle.define([
  { tag: t.processingInstruction, color: 'var(--text3)' },
  { tag: [t.labelName, t.url], color: 'var(--text2)' },
  { tag: t.emphasis, fontStyle: 'italic' },
  { tag: t.strong, fontWeight: '600' },
  { tag: t.strikethrough, textDecoration: 'line-through', color: 'var(--text2)' },
  { tag: [t.keyword, t.operatorKeyword, t.modifier, t.controlKeyword, t.definitionKeyword], color: 'var(--c-keyword)' },
  { tag: [t.string, t.special(t.string), t.regexp], color: 'var(--c-string)' },
  { tag: [t.comment, t.lineComment, t.blockComment], color: 'var(--c-comment)' },
  { tag: [t.number, t.bool, t.null, t.atom], color: 'var(--c-number)' },
  { tag: [t.typeName, t.className, t.tagName, t.namespace], color: 'var(--c-type)' },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.attributeName], color: 'var(--c-func)' },
])

// ---- 与 Swift 外壳的桥 ----

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
    // 大文档每次按键都整篇传一遍太贵，停手 250 毫秒再传
    pending = true
    clearTimeout(timer)
    timer = setTimeout(flush, 250)
  }
}

// ---- 命令 ----

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

// ---- 偏好设置 ----

let defaultMode = 'read'

/** 外壳的 Settings 窗口改了什么都走这里：只改 CSS 变量和主题标记，不动文档。 */
function applySettings(s) {
  const root = document.documentElement
  const set = (name, value) => (value == null ? root.style.removeProperty(name) : root.style.setProperty(name, String(value)))
  root.dataset.theme = s.theme || 'system'
  set('--sans', s.bodyFont)
  set('--mono', s.monoFont)
  set('--fs', s.fontSize ? `${s.fontSize}px` : null)
  set('--lh', s.lineHeight)
  defaultMode = s.defaultMode === 'edit' ? 'edit' : 'read'
  measureMono()
  // Typora 主题自己定字号；Nib 的字号设置在阅读模式里按比例缩放整页。
  reader.scroller.style.zoom = s.fontSize ? String(s.fontSize / 16) : ''
  if (typora.setCSS(s.typoraCSS)) syncReader()
  if (typeof view !== 'undefined') view.requestMeasure()
}

/** 量出等宽字体的实际字宽，列表悬挂缩进靠它对齐。 */
function measureMono() {
  const probe = document.createElement('span')
  probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;font-family:var(--mono);font-size:100px'
  probe.textContent = '0'.repeat(50)
  document.body.appendChild(probe)
  const width = probe.getBoundingClientRect().width / 50 / 100
  probe.remove()
  if (width > 0.4 && width < 0.8) document.documentElement.style.setProperty('--mono-w', `${width}em`)
}

// 三种模式：read 整篇渲染且只读（默认）；edit 光标所在行露出源码；source 整篇等宽源码。
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
  return true
}
const toggleEdit = () => setMode(mode === 'read' ? 'edit' : 'read')
const toggleSource = () => setMode(mode === 'source' ? 'edit' : 'source')

// ---- 链接 ----

const slug = (text) =>
  text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, '-')

/** 文内锚点 #标题：滚到对应标题。 */
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

// ---- 启动 ----

// 查找条的文案。界面语言启动后不会变，所以建编辑器时定一次就够。
const zhPhrases = {
  Find: '查找',
  Replace: '替换',
  next: '下一个',
  previous: '上一个',
  all: '全部',
  'match case': '区分大小写',
  regexp: '正则',
  'by word': '全词',
  replace: '替换',
  'replace all': '全部替换',
  close: '关闭',
  Done: '完成',
  'No results': '无结果',
  '$1 of $2': '$1/$2',
  'current match': '当前匹配',
  'on line': '在第',
  'replaced $ matches': '已替换 $ 处',
  'replaced match on line $': '已替换第 $ 行的匹配',
}
const phrases = (window.__nibSettings?.lang || 'en').startsWith('zh') ? zhPhrases : {}

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
      keymap.of([
        { key: 'Mod-b', run: toggleWrap('**') },
        { key: 'Mod-i', run: toggleWrap('*') },
        ...searchKeymap,
        ...historyKeymap,
        indentWithTab,
        ...defaultKeymap,
      ]),
      EditorView.domEventHandlers({
        mousedown(event) {
          // 阅读时单击即开链接；编辑时要按住 ⌘，否则没法把光标点进链接里
          const link = (event.metaKey || mode === 'read') && event.target.closest?.('[data-href]')
          if (!link) return false
          links.open(link.dataset.href)
          event.preventDefault()
          return true
        },
        blur() {
          if (pending) flush()
        },
      }),
      EditorView.updateListener.of((update) => {
        if (window.__nibDebug) {
          for (const tr of update.transactions) {
            if (tr.docChanged) post({ type: 'log', text: `tr ${tr.annotation(external) ? 'external' : 'user'} len=${tr.newDoc.length}` })
          }
        }
        if (!update.docChanged) return
        if (update.transactions.some((tr) => tr.annotation(external))) return
        scheduleFlush()
      }),
    ],
  })
}

// 选了 Typora 主题时，阅读模式换成 readView 渲染的 HTML，主题才能原样生效；编辑和源码模式照旧用 CodeMirror。
let reader = createReadView({ codeLanguages, resolveImage, openLink: (href) => links.open(href), attachScrollbar })
let typora = createTyporaTheme({ post })

/** 当前正在显示、能滚动的那一层。 */
const activeScroller = () => (reader.visible ? reader.scroller : view.scrollDOM)

/** 按模式和主题决定阅读模式用哪一层；换层时按比例带过滚动位置。 */
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

// 先建一个空编辑器：外壳会提前把它预热好，开文档时只需要 load 填内容。
mode = 'edit'
document.body.dataset.mode = mode
const view = new EditorView({ parent: document.body, state: makeState('') })
attachScrollbar(view.scrollDOM)

/** 装入一篇文档：全新的状态（撤销历史清空），有内容进阅读，空文档进编辑。
 *  top 是从休眠回来时要恢复的滚动位置。 */
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
  if (!(top > 0)) {
    post({ type: 'ready', mode })
    return
  }
  // 行高要等排版量过才准，隔两帧各设一次，再报就绪
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

// 阅读模式的键盘：空格翻页，方向键滚动，不用碰鼠标。
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
  /** 外部改动（磁盘上的文件被改写、Versions 回滚）才会调；不回传 change。
   *  只替换变了的那一段，滚动位置不动；原本停在末尾的继续跟到末尾。 */
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
    // Typora 阅读层也跟着换内容，保持原来的滚动位置。
    reader.invalidate()
    if (reader.visible) {
      const readTop = reader.scroller.scrollTop
      reader.render(currentText())
      reader.scroller.scrollTop = readTop
    }
  },
  getText: currentText,
  undo: () => undo(view),
  redo: () => redo(view),
  setMode,
  toggleEdit,
  toggleSource,
  mode: () => mode,
  applySettings,
  find: () => (reader.visible ? reader.find() : openSearchPanel(view)),
  /** 外壳休眠标签前要记滚动位置；阅读层和编辑器各有各的滚动。 */
  scrollTop: () => activeScroller().scrollTop,
  /** 文档另存或移动后，相对路径的图片要按新目录重新解析。 */
  setBaseDir(dir) {
    window.__nibBaseDir = dir
    view.dispatch({ selection: view.state.selection })
  },
  view,
}

// scripts/webcheck.swift 走这条：正文在页面加载前就注入好了。正式的 app 等外壳来调 load。
if (typeof window.__nibInitialText === 'string') load(window.__nibInitialText, window.__nibBaseDir)
else post({ type: 'boot', ms: Math.round(performance.now()) })
