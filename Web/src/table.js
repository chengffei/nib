// 表格：光标不在表格里时整块渲染成 HTML 表格，点进去或方向键进入后回到源码。
import { Decoration, EditorView, WidgetType, keymap } from '@codemirror/view'
import { Prec, StateField } from '@codemirror/state'
import { syntaxTree } from '@codemirror/language'
import { activeRanges, links, reading, resolveImage, touches } from './livePreview.js'

function splitRow(line) {
  let s = line.trim()
  if (s.startsWith('|')) s = s.slice(1)
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1)
  const cells = []
  let cur = ''
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '\\' && s[i + 1] === '|') {
      cur += '|'
      i++
    } else if (s[i] === '|') {
      cells.push(cur.trim())
      cur = ''
    } else {
      cur += s[i]
    }
  }
  cells.push(cur.trim())
  return cells
}

const escapeHTML = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

function inline(source) {
  return escapeHTML(source)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>')
    .replace(/~~([^~]+)~~/g, '<del>$1</del>')
    .replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (source, alt, src) => {
      const url = resolveImage(src.replace(/&amp;/g, '&'))
      return url ? `<img class="nib-img" alt="${alt}" src="${escapeHTML(url)}">` : source
    })
    .replace(/(^|[^!])\[([^\]]+)\]\(([^)\s]+)\)/g, '$1<span class="nib-link" data-href="$3">$2</span>')
    .replace(/&lt;br\s*\/?&gt;/g, '<br>')
}

class TableWidget extends WidgetType {
  constructor(source) {
    super()
    this.source = source
  }
  eq(other) {
    return other.source === this.source
  }
  get estimatedHeight() {
    return this.source.split('\n').length * 34
  }
  toDOM(view) {
    const lines = this.source.split('\n')
    const aligns = splitRow(lines[1] || '').map((cell) =>
      /^:-+:$/.test(cell) ? 'center' : /-+:$/.test(cell) ? 'right' : '',
    )
    const wrap = document.createElement('div')
    wrap.className = 'nib-table-wrap'
    const table = document.createElement('table')
    lines.forEach((line, index) => {
      if (index === 1) return
      const tr = document.createElement('tr')
      tr.dataset.line = String(index)
      splitRow(line).forEach((cell, column) => {
        const el = document.createElement(index === 0 ? 'th' : 'td')
        if (aligns[column]) el.style.textAlign = aligns[column]
        el.innerHTML = inline(cell)
        tr.appendChild(el)
      })
      table.appendChild(tr)
    })
    wrap.appendChild(table)
    wrap.addEventListener('mousedown', (event) => {
      const isReading = view.state.facet(reading)
      const link = event.target.closest?.('[data-href]')
      if (link && (event.metaKey || isReading)) {
        event.preventDefault()
        links.open(link.dataset.href)
        return
      }
      // 阅读时不进源码，留给系统做文字选择
      if (isReading) return
      event.preventDefault()
      const row = event.target.closest?.('tr')
      const start = view.state.doc.lineAt(view.posAtDOM(wrap))
      const number = Math.min(view.state.doc.lines, start.number + (row ? Number(row.dataset.line) : 0))
      view.dispatch({ selection: { anchor: view.state.doc.line(number).from } })
      view.focus()
    })
    return wrap
  }
  ignoreEvent() {
    return true
  }
}

function buildTables(state) {
  const { doc } = state
  const act = activeRanges(state)
  const decos = []
  syntaxTree(state).iterate({
    enter(n) {
      if (n.name === 'Document') return true
      if (n.name === 'Table') {
        const from = n.from
        let to = n.to
        if (to > from && doc.lineAt(to).from === to) to--
        if (doc.lineAt(from).from === from && doc.lineAt(to).to === to && !touches(act, from, to)) {
          const widget = new TableWidget(doc.sliceString(from, to))
          decos.push(Decoration.replace({ widget, block: true }).range(from, to))
        }
      }
      return false
    },
  })
  return Decoration.set(decos)
}

const tableField = StateField.define({
  create: buildTables,
  update(value, tr) {
    if (tr.docChanged || tr.selection || tr.reconfigured || syntaxTree(tr.state) !== syntaxTree(tr.startState)) {
      return buildTables(tr.state)
    }
    return value
  },
  provide: (field) => EditorView.decorations.from(field),
})

/** 上下方向键本来会跳过整块表格；改成落进表格的首行或末行。 */
function enterTable(forward) {
  return (view) => {
    const { state } = view
    const sel = state.selection.main
    if (!sel.empty || !state.field(tableField, false)) return false
    const next = view.moveVertically(sel, forward)
    let found = null
    state
      .field(tableField)
      .between(Math.min(sel.head, next.head), Math.max(sel.head, next.head), (from, to) => {
        found = { from, to }
        return false
      })
    if (!found) return false
    const anchor = forward ? found.from : state.doc.lineAt(found.to).from
    view.dispatch({ selection: { anchor }, scrollIntoView: true })
    return true
  }
}

export const tables = [
  tableField,
  Prec.high(
    keymap.of([
      { key: 'ArrowDown', run: enterTable(true) },
      { key: 'ArrowUp', run: enterTable(false) },
    ]),
  ),
]
