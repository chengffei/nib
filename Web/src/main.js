// Nib 编辑器内核：CodeMirror 6。文档就是文本本身，渲染全部是装饰层。
import { Annotation, Compartment, EditorSelection, EditorState } from '@codemirror/state'
import { EditorView, keymap } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, indentWithTab, redo, undo } from '@codemirror/commands'
import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { HighlightStyle, LanguageDescription, StreamLanguage, syntaxHighlighting } from '@codemirror/language'
import { highlightSelectionMatches, openSearchPanel, search, searchKeymap } from '@codemirror/search'
import { tags as t } from '@lezer/highlight'
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
import { livePreview, post, reading } from './livePreview.js'
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

const FONT_KEY = 'nib.fontSize'
function setFontSize(px) {
  const size = Math.max(11, Math.min(28, px))
  document.documentElement.style.setProperty('--fs', `${size}px`)
  try {
    localStorage.setItem(FONT_KEY, String(size))
  } catch {}
  view?.requestMeasure()
  return true
}
const fontSize = () => parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--fs')) || 16

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
  if (mode !== 'read') view.focus()
  post({ type: 'mode', mode })
  return true
}
const toggleEdit = () => setMode(mode === 'read' ? 'edit' : 'read')
const toggleSource = () => setMode(mode === 'source' ? 'edit' : 'source')

// ---- 启动 ----

const initial = typeof window.__nibInitialText === 'string' ? window.__nibInitialText : ''
if (initial.includes('\r\n')) lineBreak = '\r\n'
// 空文档没什么可读的，直接进编辑
if (initial.trim() === '') mode = 'edit'
document.body.dataset.mode = mode
try {
  const saved = parseFloat(localStorage.getItem(FONT_KEY))
  if (saved) document.documentElement.style.setProperty('--fs', `${saved}px`)
} catch {}
measureMono()

const view = new EditorView({
  parent: document.body,
  state: EditorState.create({
    doc: initial,
    extensions: [
      history(),
      EditorView.lineWrapping,
      EditorState.tabSize.of(4),
      markdown({ base: markdownLanguage, codeLanguages, extensions: [frontmatter] }),
      syntaxHighlighting(highlight),
      search({ top: true }),
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
          post({ type: 'open', url: link.dataset.href })
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
  }),
})

window.nib = {
  /** 外部改动（Versions 回滚、磁盘重载）才会调；不回传 change。 */
  setText(text) {
    lineBreak = text.includes('\r\n') ? '\r\n' : '\n'
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: text },
      annotations: external.of(true),
    })
  },
  getText: currentText,
  undo: () => undo(view),
  redo: () => redo(view),
  setMode,
  toggleEdit,
  toggleSource,
  mode: () => mode,
  zoom: (delta) => setFontSize(delta === 0 ? 16 : fontSize() + delta),
  find: () => openSearchPanel(view),
  /** 文档另存或移动后，相对路径的图片要按新目录重新解析。 */
  setBaseDir(dir) {
    window.__nibBaseDir = dir
    view.dispatch({ selection: view.state.selection })
  },
  view,
}

if (mode !== 'read') view.focus()
post({ type: 'ready', mode })
