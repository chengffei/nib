// 即时渲染：光标所在行显示源码，其余行隐藏语法标记。
// 只改显示（装饰），不改文档，所以保存出去的永远是原文。
import { Decoration, ViewPlugin, WidgetType } from '@codemirror/view'
import { syntaxTree } from '@codemirror/language'
import { Facet } from '@codemirror/state'

/** 阅读模式：没有「正在编辑」的行，整篇都渲染。 */
export const reading = Facet.define({ combine: (values) => values.some(Boolean) })

/** 选区按整行外扩后的范围；与它相交的节点算「正在编辑」。 */
export function activeRanges(state) {
  if (state.facet(reading)) return []
  return state.selection.ranges.map((r) => ({
    from: state.doc.lineAt(r.from).from,
    to: state.doc.lineAt(r.to).to,
  }))
}

export const touches = (act, from, to) => act.some((r) => r.from <= to && r.to >= from)

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

class CheckboxWidget extends WidgetType {
  /** 替换整段「- [ ]」；offset 是方括号相对列表符号的偏移。 */
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

/** 把 md 里的图片地址换成能加载的地址；本地文件走 nib-file，由外壳读盘。网络图片不加载。 */
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
    // 外面包一层：编辑器只认这层根节点，里面的 <img> 才能在加载失败时换成文字
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
      note.textContent = `图片无法显示：${this.alt || decodeURI(this.url.replace(/^nib-file:\/\/local/, ''))}`
      img.replaceWith(note)
      view.requestMeasure()
    })
    img.src = this.url
    wrap.appendChild(img)
    return wrap
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
    tree.iterate({
      from: range.from,
      to: range.to,
      enter(n) {
        const name = n.name

        // 跨多行的块：按可见范围逐行加样式，不去重
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

        const key = `${name}:${n.from}`
        if (seen.has(key)) return
        seen.add(key)

        if (name.startsWith('ATXHeading') || name.startsWith('SetextHeading')) {
          const level = name[name.length - 1]
          lineDeco(doc.lineAt(n.from).from, `nib-h nib-h${level}`)
          return
        }
        if (name === 'HeaderMark') {
          const parent = n.node.parent
          if (!parent || !parent.name.startsWith('ATXHeading') || touches(act, n.from, n.to)) return
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
          // 没有地址也没有引用标签的 [文字] 不是链接，原样显示
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
          // 只有行首是纯缩进时才做悬挂缩进（引用里的列表不做）
          if (/^[ \t]*$/.test(lead)) {
            // 未编辑的任务项把「- [ ]」收成一个两格宽的勾选框
            const shown = isTask && !active ? `${lead}xx ` : doc.sliceString(line.from, end)
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
      // 中文输入法组字期间不重排：只把现有装饰跟着文字平移，组字结束再重建
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
