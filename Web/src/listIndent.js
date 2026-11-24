// Tab / Shift-Tab on list items. CodeMirror's indentMore adds a fixed indent unit, but a nested list only nests in
// CommonMark when it starts at the parent item's content column ("1. " needs 3 columns, "- " needs 2), so ordered
// sub-lists silently fell back to the parent level. Here an item moves to its previous sibling's content column
// (Tab) or its parent's marker column (Shift-Tab), drags its children along, and its number is reset for the new level.

import { indentLess, indentMore } from '@codemirror/commands'

const ITEM = /^([ \t]*)([-*+]|(\d{1,9})([.)]))( +|$)/

const width = (lead) => {
  let cols = 0
  for (const ch of lead) cols += ch === '\t' ? 4 - (cols % 4) : 1
  return cols
}
const indentOf = (text) => width(/^[ \t]*/.exec(text)[0])

function parse(text) {
  const m = ITEM.exec(text)
  if (!m) return null
  const indent = width(m[1])
  return { indent, num: m[3] ? +m[3] : null, delim: m[4], content: indent + m[2].length + Math.max(m[5].length, 1) }
}

// Nearest earlier item at exactly `indent` within the same list (stops at a shallower item or unindented text).
function siblingAbove(lines, i, indent) {
  for (let j = i - 1; j >= 0; j--) {
    if (!lines[j].trim()) continue
    const item = parse(lines[j])
    if (item && item.indent === indent) return item
    if (indentOf(lines[j]) < indent || (item && item.indent < indent)) return null
  }
  return null
}

function parentAbove(lines, i, indent) {
  for (let j = i - 1; j >= 0; j--) {
    if (!lines[j].trim()) continue
    const item = parse(lines[j])
    if (item && item.indent < indent) return item
    if (indentOf(lines[j]) === 0) return null
  }
  return null
}

// Index after the last line belonging to item i (continuation lines and nested items).
function subtreeEnd(lines, i, indent) {
  let end = i + 1
  for (let j = i + 1; j < lines.length; j++) {
    if (!lines[j].trim()) continue
    if (indentOf(lines[j]) <= indent) break
    end = j + 1
  }
  return end
}

const reindent = (text, delta) => {
  const lead = /^[ \t]*/.exec(text)[0]
  return ' '.repeat(Math.max(0, width(lead) + delta)) + text.slice(lead.length)
}

function move(lines, i, deeper) {
  const item = parse(lines[i])
  let target
  if (deeper) {
    const sib = siblingAbove(lines, i, item.indent)
    if (!sib) return // first item of its list cannot nest
    target = sib.content
  } else {
    if (item.indent === 0) return
    target = parentAbove(lines, i, item.indent)?.indent ?? 0
  }
  const end = subtreeEnd(lines, i, item.indent)
  const delta = target - item.indent
  for (let j = i; j < end; j++) if (lines[j].trim()) lines[j] = reindent(lines[j], delta)
  if (item.num != null) {
    const prev = siblingAbove(lines, i, target)
    const num = prev?.num != null ? prev.num + 1 : 1
    lines[i] = lines[i].replace(/^([ \t]*)\d{1,9}/, `$1${num}`)
  }
  return end
}

// Renumbers ordered items from line `from` to the end of the surrounding list so numbers stay consecutive at every level.
function renumber(lines, from) {
  for (let i = from; i < lines.length; i++) {
    if (!lines[i].trim()) continue
    const item = parse(lines[i])
    if (!item) {
      if (indentOf(lines[i]) === 0) break
      continue
    }
    if (item.num == null) continue
    const prev = siblingAbove(lines, i, item.indent)
    // A nested list restarts at 1; a top-level list keeps its own start number.
    const num = prev?.num != null ? prev.num + 1 : item.indent > 0 ? 1 : item.num
    if (num !== item.num) lines[i] = lines[i].replace(/^([ \t]*)\d{1,9}/, `$1${num}`)
  }
}

function listShift(deeper) {
  return (view) => {
    const { state } = view
    const { doc } = state
    const sel = state.selection.main
    const first = doc.lineAt(sel.from).number - 1
    const last = doc.lineAt(sel.to).number - 1
    const lines = doc.toString().split('\n')
    if (!lines.slice(first, last + 1).some((l) => parse(l))) return false

    const before = lines.slice()
    let skipUntil = -1
    for (let i = first; i <= last; i++) {
      if (i < skipUntil || !parse(lines[i])) continue
      skipUntil = move(lines, i, deeper) ?? subtreeEnd(lines, i, parse(lines[i]).indent)
    }
    renumber(lines, first)

    // Minimal per-line edits so the cursor stays put relative to the text.
    const changes = []
    for (let i = 0; i < lines.length; i++) {
      const a = before[i], b = lines[i]
      if (a === b) continue
      let p = 0
      while (p < a.length && p < b.length && a[p] === b[p]) p++
      let s = 0
      while (s < a.length - p && s < b.length - p && a[a.length - 1 - s] === b[b.length - 1 - s]) s++
      const from = doc.line(i + 1).from
      changes.push({ from: from + p, to: from + a.length - s, insert: b.slice(p, b.length - s) })
    }
    if (changes.length) view.dispatch({ changes, scrollIntoView: true, userEvent: deeper ? 'input.indent' : 'delete.dedent' })
    return true
  }
}

export const listIndentKeymap = [
  { key: 'Tab', run: (v) => listShift(true)(v) || indentMore(v) },
  { key: 'Shift-Tab', run: (v) => listShift(false)(v) || indentLess(v) },
]
