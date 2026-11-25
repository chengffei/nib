// Live preview: the cursor line shows source, other lines hide syntax markers.
// Only the display (decorations) changes, never the document, so what gets saved is always the original text.
import { Decoration, EditorView, ViewPlugin, WidgetType } from '@codemirror/view'
import { syntaxTree } from '@codemirror/language'
import { Facet, StateField } from '@codemirror/state'
import { t } from './i18n.js'
import { isMermaid, mountMermaid } from './mermaid.js'

/** Read mode: no line is "being edited"; the whole document is rendered. */
export const reading = Facet.define({ combine: (values) => values.some(Boolean) })

/** The selection expanded to whole lines; nodes intersecting it count as "being edited". */
export function activeRanges(state) {
  if (state.facet(reading)) return []
  return state.selection.ranges.map((r) => ({
    from: state.doc.lineAt(r.from).from,
    to: state.doc.lineAt(r.to).to,
  }))
}

export const touches = (act, from, to) => act.some((r) => r.from <= to && r.to >= from)

/** Called when a link is clicked; main.js swaps in a version that handles in-document anchors. */
export const links = { open: (href) => post({ type: 'open', url: href }) }

export function post(message) {
  window.webkit?.messageHandlers?.nib?.postMessage(message)
}

class BulletWidget extends WidgetType {
  constructor(cols) {
    super()
    this.cols = cols
  }
  eq(other) {
    return other.cols === this.cols
  }
  toDOM() {
    const span = document.createElement('span')
    span.className = 'nib-bullet'
    span.style.width = `calc(${this.cols} * var(--mono-w))`
    span.textContent = '•'
    return span
  }
}

// Nested ordered lists are numbered 1. / a. / i. by depth (display only; the source keeps digits, as CommonMark requires).
const ROMAN = [['m', 1000], ['cm', 900], ['d', 500], ['cd', 400], ['c', 100], ['xc', 90], ['l', 50], ['xl', 40], ['x', 10], ['ix', 9], ['v', 5], ['iv', 4], ['i', 1]]
function levelNumber(num, depth) {
  const style = depth % 3
  if (style === 0 || num < 1) return String(num)
  if (style === 1) {
    let s = ''
    for (let n = num; n > 0; n = Math.floor((n - 1) / 26)) s = String.fromCharCode(97 + ((n - 1) % 26)) + s
    return s
  }
  let s = ''
  for (let n = num, k = 0; n > 0; ) if (n >= ROMAN[k][1]) { s += ROMAN[k][0]; n -= ROMAN[k][1] } else k++
  return s
}

/** Ordered item marker for the item's nesting depth and position, or null at the top level. */
function orderedLabel(item, doc) {
  const list = item.parent
  let depth = 0
  for (let p = list; p; p = p.parent) if (p.name === 'OrderedList') depth++
  if (depth < 2) return null
  const first = list.firstChild?.getChild('ListMark')
  const start = first ? parseInt(doc.sliceString(first.from, first.to), 10) || 1 : 1
  let index = 0
  for (let c = item.prevSibling; c; c = c.prevSibling) if (c.name === 'ListItem') index++
  return levelNumber(start + index, depth - 1)
}

class OrderedWidget extends WidgetType {
  constructor(text, cols) {
    super()
    this.text = text
    this.cols = cols
  }
  eq(other) {
    return other.text === this.text && other.cols === this.cols
  }
  toDOM() {
    const span = document.createElement('span')
    span.className = 'nib-onum'
    span.style.width = `calc(${this.cols} * var(--mono-w))`
    span.textContent = this.text
    return span
  }
}

class CheckboxWidget extends WidgetType {
  /** Replaces the whole "- [ ]" span; offset is the bracket's offset relative to the list marker. */
  constructor(checked, offset) {
    super()
    this.checked = checked
    this.offset = offset
  }
  eq(other) {
    return other.checked === this.checked && other.offset === this.offset
  }
  toDOM(view) {
    const wrap = document.createElement('span')
    wrap.className = 'nib-task'
    wrap.style.width = 'calc(2 * var(--mono-w))'
    const box = document.createElement('input')
    box.type = 'checkbox'
    box.checked = this.checked
    box.addEventListener('mousedown', (event) => {
      event.preventDefault()
      if (view.state.facet(reading)) return
      const pos = view.posAtDOM(wrap) + this.offset
      const marker = view.state.doc.sliceString(pos, pos + 3)
      if (!/^\[[ xX]\]$/.test(marker)) return
      view.dispatch({ changes: { from: pos + 1, to: pos + 2, insert: marker[1] === ' ' ? 'x' : ' ' } })
    })
    wrap.appendChild(box)
    return wrap
  }
  ignoreEvent() {
    return true
  }
}

/** Rewrites image URLs in the markdown to loadable ones; local files go through nib-file and are read from disk by the shell. Remote images are not loaded. */
export function resolveImage(src) {
  const raw = src.trim().replace(/^<|>$/g, '')
  if (!raw || /^https?:/i.test(raw)) return null
  if (/^data:image\//i.test(raw)) return raw
  const base = window.__nibBaseDir
  try {
    if (/^file:/i.test(raw)) return 'nib-file://local' + new URL(raw).pathname
    if (raw.startsWith('/')) return new URL(raw, 'nib-file://local/').href
    if (!base) return null
    return new URL(raw, 'nib-file://local' + encodeURI(base).replace(/[?#]/g, encodeURIComponent) + '/').href
  } catch {
    return null
  }
}

class ImageWidget extends WidgetType {
  constructor(url, alt) {
    super()
    this.url = url
    this.alt = alt
  }
  eq(other) {
    return other.url === this.url && other.alt === this.alt
  }
  toDOM(view) {
    // Wrapped in an outer element: the editor only recognises this root node, which lets the inner <img> be swapped for text if loading fails
    const wrap = document.createElement('span')
    wrap.className = 'nib-img-wrap'
    const img = document.createElement('img')
    img.className = 'nib-img'
    img.alt = this.alt
    img.decoding = 'async'
    img.addEventListener('load', () => view.requestMeasure())
    img.addEventListener('error', () => {
      const note = document.createElement('span')
      note.className = 'nib-img-missing'
      note.textContent = `${t('Image unavailable: ')}${this.alt || decodeURI(this.url.replace(/^nib-file:\/\/local/, ''))}`
      img.replaceWith(note)
      view.requestMeasure()
    })
    img.src = this.url
    wrap.appendChild(img)
    return wrap
  }
}

/** Heading level badge in the left margin (as in Bear 2). Clicking it puts the cursor at line start and reveals the #, so the level can be changed. */
class LevelWidget extends WidgetType {
  constructor(level) {
    super()
    this.level = level
  }
  eq(other) {
    return other.level === this.level
  }
  toDOM() {
    const box = document.createElement('span')
    box.className = 'nib-hlevel'
    box.setAttribute('aria-hidden', 'true')
    const label = document.createElement('span')
    label.textContent = `H${this.level}`
    box.appendChild(label)
    return box
  }
  ignoreEvent() {
    return false
  }
}

class HrWidget extends WidgetType {
  eq() {
    return true
  }
  toDOM() {
    const span = document.createElement('span')
    span.className = 'nib-hr'
    return span
  }
}

const hidden = Decoration.replace({})
const codeMark = Decoration.mark({ class: 'nib-code' })
const imageMark = Decoration.mark({ class: 'nib-image' })
const listPrefix = Decoration.mark({ class: 'nib-li-prefix' })
const linkMark = (href) => Decoration.mark({ class: 'nib-link', attributes: { 'data-href': href } })

function eachLine(doc, from, to, f) {
  let line = doc.lineAt(from)
  for (;;) {
    f(line)
    if (line.to >= to || line.number >= doc.lines) break
    line = doc.line(line.number + 1)
  }
}

function build(view) {
  const { state } = view
  const { doc } = state
  const act = activeRanges(state)
  const tree = syntaxTree(state)
  const decos = []
  const seen = new Set()
  const lineSeen = new Set()

  const hide = (from, to) => {
    if (to > from) decos.push(hidden.range(from, to))
  }
  const lineDeco = (pos, cls, style) => {
    const key = `${pos}:${cls}`
    if (lineSeen.has(key)) return
    lineSeen.add(key)
    const attributes = style ? { class: cls, style } : { class: cls }
    decos.push(Decoration.line({ attributes }).range(pos))
  }
  const blockLines = (node, range, cls) => {
    const from = Math.max(node.from, range.from)
    const to = Math.min(node.to, range.to)
    if (from > to) return
    const first = doc.lineAt(node.from).from
    const last = doc.lineAt(node.to).from
    eachLine(doc, from, to, (line) => {
      let c = cls
      if (line.from === first) c += ` ${cls}-first`
      if (line.from === last) c += ` ${cls}-last`
      lineDeco(line.from, c)
    })
  }

  for (const range of view.visibleRanges) {
    // Blank lines: under a theme, blank lines between blocks are squeezed to the theme's block spacing.
    eachLine(doc, range.from, range.to, (line) => {
      if (!line.text.trim()) lineDeco(line.from, 'nib-blank')
    })
    tree.iterate({
      from: range.from,
      to: range.to,
      enter(n) {
        const name = n.name

        // Multi-line blocks: style each visible line individually, without deduplication
        if (name === 'FencedCode' || name === 'CodeBlock') {
          blockLines(n, range, 'nib-cb')
          if (name === 'FencedCode' && !seen.has(`f${n.from}`) && !touches(act, n.from, n.to)) {
            seen.add(`f${n.from}`)
            for (const mark of n.node.getChildren('CodeMark')) hide(mark.from, mark.to)
          }
          return false
        }
        if (name === 'Blockquote') {
          let depth = 1
          for (let p = n.node.parent; p; p = p.parent) if (p.name === 'Blockquote') depth++
          blockLines(n, range, depth > 1 ? 'nib-quote nib-quote-2' : 'nib-quote')
          return true
        }
        if (name === 'Frontmatter') {
          blockLines(n, range, 'nib-fm')
          return false
        }
        if (name === 'Table' || name === 'HTMLBlock') {
          blockLines(n, range, 'nib-mono')
          return false
        }

        // Top-level paragraphs and lists mark their first and last lines: under a Typora theme, block spacing depends on block type (typoraEdit.js).
        if (name === 'Paragraph' && n.node.parent?.name === 'Document') {
          blockLines(n, range, 'nib-p')
          return true
        }
        if ((name === 'BulletList' || name === 'OrderedList') && n.node.parent?.name === 'Document') {
          blockLines(n, range, 'nib-list')
          return true
        }

        const key = `${name}:${n.from}`
        if (seen.has(key)) return
        seen.add(key)

        if (name.startsWith('ATXHeading') || name.startsWith('SetextHeading')) {
          const level = name[name.length - 1]
          lineDeco(doc.lineAt(n.from).from, `nib-h nib-h${level}`)
          if (!state.facet(reading)) decos.push(Decoration.widget({ widget: new LevelWidget(level), side: -1 }).range(doc.lineAt(n.from).from))
          return
        }
        if (name === 'HeaderMark') {
          const parent = n.node.parent
          if (!parent || !parent.name.startsWith('ATXHeading')) return
          // As in Bear: the # stays hidden even with the cursor in the heading line, and only shows when the cursor touches the # itself (line start); the level is shown by the "H2" badge in the left margin.
          let markEnd = n.to
          while (markEnd < parent.to && /[ \t]/.test(doc.sliceString(markEnd, markEnd + 1))) markEnd++
          const revealTo = n.from === parent.from ? markEnd : n.to
          if (!state.facet(reading) && state.selection.ranges.some((r) => r.from <= revealTo && r.to >= n.from)) return
          if (n.from === parent.from) {
            let end = n.to
            while (end < parent.to && /[ \t]/.test(doc.sliceString(end, end + 1))) end++
            hide(n.from, end)
          } else {
            let start = n.from
            while (start > parent.from && /[ \t]/.test(doc.sliceString(start - 1, start))) start--
            hide(start, n.to)
          }
          return
        }
        if (name === 'EmphasisMark' || name === 'StrikethroughMark') {
          const parent = n.node.parent
          if (parent && !touches(act, parent.from, parent.to)) hide(n.from, n.to)
          return
        }
        if (name === 'InlineCode') {
          decos.push(codeMark.range(n.from, n.to))
          if (!touches(act, n.from, n.to)) {
            for (const mark of n.node.getChildren('CodeMark')) hide(mark.from, mark.to)
          }
          return false
        }
        if (name === 'Image') {
          decos.push(imageMark.range(n.from, n.to))
          const url = n.node.getChild('URL')
          const resolved = url && resolveImage(doc.sliceString(url.from, url.to))
          if (resolved) {
            const marks = n.node.getChildren('LinkMark')
            const alt = marks.length > 1 ? doc.sliceString(marks[0].to, marks[1].from) : ''
            decos.push(Decoration.widget({ widget: new ImageWidget(resolved, alt), side: 1 }).range(n.to))
            if (!touches(act, n.from, n.to)) hide(n.from, n.to)
          }
          return false
        }
        if (name === 'Link') {
          const node = n.node
          const marks = node.getChildren('LinkMark')
          const url = node.getChild('URL')
          const label = node.getChild('LinkLabel')
          // [text] with neither a URL nor a reference label is not a link and is shown as-is
          if (marks.length < 2 || (!url && !label)) return
          const open = marks[0]
          const close = marks[1]
          const href = url ? doc.sliceString(url.from, url.to).replace(/^<|>$/g, '') : ''
          if (close.from > open.to) decos.push(linkMark(href).range(open.to, close.from))
          if (!touches(act, n.from, n.to)) {
            hide(open.from, open.to)
            hide(close.from, n.to)
          }
          return
        }
        if (name === 'Autolink') {
          const url = n.node.getChild('URL')
          if (!url) return false
          decos.push(linkMark(doc.sliceString(url.from, url.to)).range(url.from, url.to))
          if (!touches(act, n.from, n.to)) {
            for (const mark of n.node.getChildren('LinkMark')) hide(mark.from, mark.to)
          }
          return false
        }
        if (name === 'URL') {
          const parent = n.node.parent
          if (parent && (parent.name === 'Link' || parent.name === 'LinkReference')) return
          decos.push(linkMark(doc.sliceString(n.from, n.to)).range(n.from, n.to))
          return
        }
        if (name === 'QuoteMark') {
          if (touches(act, n.from, n.to)) return
          hide(n.from, doc.sliceString(n.to, n.to + 1) === ' ' ? n.to + 1 : n.to)
          return
        }
        if (name === 'HorizontalRule') {
          lineDeco(doc.lineAt(n.from).from, 'nib-hrline')
          if (!touches(act, n.from, n.to)) {
            decos.push(Decoration.replace({ widget: new HrWidget() }).range(n.from, n.to))
          }
          return
        }
        if (name === 'ListMark') {
          const item = n.node.parent
          if (!item || item.name !== 'ListItem') return
          const line = doc.lineAt(n.from)
          const task = item.getChild('Task')
          const marker = task && task.getChild('TaskMarker')
          const isTask = !!marker && marker.from < line.to
          let end = isTask ? marker.to : n.to
          if (doc.sliceString(end, end + 1) === ' ') end++
          const active = touches(act, line.from, line.to)
          const lead = doc.sliceString(line.from, n.from)
          const markText = doc.sliceString(n.from, n.to)
          const label = !active && !isTask && /\d/.test(markText) ? orderedLabel(item, doc) : null
          const labelText = label && label + markText.slice(-1)
          const labelCols = label && Math.max(labelText.length, markText.length)
          // Hanging indent only applies when the line starts with pure indentation (not for lists inside blockquotes)
          if (/^[ \t]*$/.test(lead)) {
            // For task items not being edited, "- [ ]" collapses into a two-character-wide checkbox
            const shown = isTask && !active ? `${lead}xx ` : label ? `${lead}${'x'.repeat(labelCols)}${doc.sliceString(n.to, end)}` : doc.sliceString(line.from, end)
            let cols = 0
            for (const ch of shown) cols += ch === '\t' ? 4 - (cols % 4) : 1
            lineDeco(line.from, 'nib-li', `--nib-indent:${cols}`)
            decos.push(listPrefix.range(line.from, end))
          }
          if (active) return
          if (isTask) {
            const checked = /[xX]/.test(doc.sliceString(marker.from, marker.to))
            const widget = new CheckboxWidget(checked, marker.from - n.from)
            decos.push(Decoration.replace({ widget }).range(n.from, marker.to))
          } else if (/^[-*+]$/.test(doc.sliceString(n.from, n.to))) {
            decos.push(Decoration.replace({ widget: new BulletWidget(1) }).range(n.from, n.to))
          } else if (label) {
            decos.push(Decoration.replace({ widget: new OrderedWidget(labelText, labelCols) }).range(n.from, n.to))
          }
        }
      },
    })
  }
  return Decoration.set(decos, true)
}

export const livePreview = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.dirty = false
      this.decorations = build(view)
    }
    update(update) {
      // No relayout during IME composition (e.g. Chinese input): just shift the existing decorations along with the text, and rebuild once composition ends
      if (update.view.composing) {
        if (update.docChanged) this.decorations = this.decorations.map(update.changes)
        this.dirty = true
        return
      }
      if (
        this.dirty ||
        update.docChanged ||
        update.viewportChanged ||
        update.selectionSet ||
        update.startState.facet(reading) !== update.state.facet(reading) ||
        syntaxTree(update.startState) !== syntaxTree(update.state)
      ) {
        this.dirty = false
        this.decorations = build(update.view)
      }
    }
  },
  {
    decorations: (plugin) => plugin.decorations,
    eventHandlers: {
      compositionend(_event, view) {
        this.dirty = true
        setTimeout(() => view.dispatch({}), 20)
      },
    },
  },
)

/** A ```mermaid block shown as its diagram. Clicking it (outside read mode) puts the cursor inside, which reveals the source. */
class MermaidWidget extends WidgetType {
  constructor(code) {
    super()
    this.code = code
  }
  eq(other) {
    return other.code === this.code
  }
  get estimatedHeight() {
    return 240
  }
  toDOM(view) {
    const box = document.createElement('div')
    box.className = 'nib-mermaid'
    mountMermaid(box, this.code, { themeFrom: view.contentDOM, onChange: () => view.requestMeasure() })
    box.addEventListener('mousedown', (event) => {
      if (view.state.facet(reading)) return
      event.preventDefault()
      const start = view.posAtDOM(box)
      const line = view.state.doc.lineAt(start)
      const anchor = line.number < view.state.doc.lines ? view.state.doc.line(line.number + 1).from : line.to
      view.dispatch({ selection: { anchor } })
      view.focus()
    })
    return box
  }
  ignoreEvent() {
    return true
  }
}

// Leaf blocks that cannot contain a fence; skipping them keeps the whole-document walk cheap.
const LEAF = /^(Paragraph|ATXHeading\d|SetextHeading\d|Table|HTMLBlock|CodeBlock|Frontmatter|HorizontalRule|LinkReference)$/

function mermaidBlocks(state) {
  const { doc } = state
  const act = activeRanges(state)
  const decos = []
  syntaxTree(state).iterate({
    enter(n) {
      if (LEAF.test(n.name)) return false
      if (n.name !== 'FencedCode') return
      const info = n.node.getChild('CodeInfo')
      if (!info || !isMermaid(doc.sliceString(info.from, info.to)) || touches(act, n.from, n.to)) return false
      const first = doc.lineAt(n.from)
      const last = doc.lineAt(n.to)
      // Only fences that own their lines (indentation or quote markers before them are fine); "- ```mermaid" stays as code.
      if (!/^[\s>]*$/.test(doc.sliceString(first.from, n.from))) return false
      // An unclosed fence runs to the end of the document while it is still being typed; leave it as code.
      const marks = n.node.getChildren('CodeMark')
      if (marks.length < 2) return false
      const text = n.node.getChild('CodeText')
      let code = text ? doc.sliceString(text.from, text.to) : ''
      if (doc.sliceString(first.from, n.from).includes('>')) code = code.replace(/^[ \t]*(> ?)+/gm, '')
      decos.push(Decoration.replace({ widget: new MermaidWidget(code), block: true }).range(first.from, last.to))
      return false
    },
  })
  return Decoration.set(decos)
}

/** Block widgets must come from state, not from a view plugin, so diagrams live in their own field next to livePreview. */
export const mermaidPreview = StateField.define({
  create: mermaidBlocks,
  update(decos, tr) {
    // During IME composition just shift along with the text, as livePreview does.
    if (tr.isUserEvent('input.type.compose')) return decos.map(tr.changes)
    if (tr.docChanged || tr.selection || tr.startState.facet(reading) !== tr.state.facet(reading) || syntaxTree(tr.startState) !== syntaxTree(tr.state)) {
      return mermaidBlocks(tr.state)
    }
    return decos
  },
  provide: (field) => EditorView.decorations.from(field),
})
