// Tables: when the cursor is outside, the whole block renders as an HTML table; clicking in or entering with the arrow keys returns to source.
import { Decoration, EditorView, WidgetType, keymap } from '@codemirror/view'
import { Prec, StateField } from '@codemirror/state'
import { syntaxTree } from '@codemirror/language'
import { activeRanges, imageSize, links, reading, resolveImage, touches } from './livePreview.js'
import { autoFit, keepShortColumns } from './tableColumns.js'

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
      const size = url && imageSize(url)
      const dims = size ? ` width="${size[0]}" height="${size[1]}"` : ''
      return url ? `<img class="nib-img" alt="${alt}"${dims} src="${escapeHTML(url)}">` : source
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
    // Structure follows Typora (thead / tbody, md-table) so theme header and zebra styles match.
    const table = document.createElement('table')
    table.className = 'md-table'
    const thead = document.createElement('thead')
    const tbody = document.createElement('tbody')
    table.append(thead, tbody)
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
      ;(index === 0 ? thead : tbody).appendChild(tr)
    })
    keepShortColumns(table)
    wrap.appendChild(table)
    autoFit(table, wrap, () => view.requestMeasure())
    wrap.addEventListener('mousedown', (event) => {
      const isReading = view.state.facet(reading)
      const link = event.target.closest?.('[data-href]')
      if (link && (event.metaKey || isReading)) {
        event.preventDefault()
        links.open(link.dataset.href)
        return
      }
      // In read mode do not enter source; leave it to the system for text selection
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

/** Up/down arrows would normally skip the whole table; changed to land in the table's first or last row. */
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
