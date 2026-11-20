// Focus mode (F8) and typewriter mode (F9), as in Typora.
// Focus: the block under the cursor (paragraph, heading, list item, quote, code block, ...) is shown normally and the rest is dimmed; only active in edit and source modes.
// Typewriter: while typing or moving the cursor with the keyboard, the cursor line stays in the middle of the screen; mouse clicks do not scroll, so the page does not jump wherever you click.
import { Decoration, EditorView, ViewPlugin } from '@codemirror/view'
import { EditorState } from '@codemirror/state'
import { syntaxTree } from '@codemirror/language'

const flags = { focus: false, typewriter: false }
const on = Decoration.line({ class: 'nib-focus-on' })

/** The block under the cursor: search upward from the cursor, stopping at the list item for lists and at a direct child of the document otherwise. */
function currentBlock(state) {
  const pos = state.selection.main.head
  let node = syntaxTree(state).resolveInner(pos, -1)
  let block = null
  for (let n = node; n && n.name !== 'Document'; n = n.parent) {
    block = n
    if (n.name === 'ListItem') break
  }
  if (!block) {
    const line = state.doc.lineAt(pos)
    return { from: line.from, to: line.to }
  }
  return { from: block.from, to: block.to }
}

function build(view) {
  if (!flags.focus) return Decoration.none
  const { state } = view
  const { from, to } = currentBlock(state)
  const decos = []
  for (let line = state.doc.lineAt(from); ; line = state.doc.line(line.number + 1)) {
    decos.push(on.range(line.from))
    if (line.to >= to || line.number >= state.doc.lines) break
  }
  return Decoration.set(decos)
}

const focusPlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = build(view)
    }
    update(update) {
      if (update.docChanged || update.selectionSet || update.transactions.some((tr) => tr.reconfigured) || this.stale) {
        this.stale = false
        this.decorations = build(update.view)
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
)

const typewriter = EditorState.transactionExtender.of((tr) => {
  if (!flags.typewriter || !tr.selection && !tr.docChanged) return null
  const keyboard = tr.isUserEvent('input') || tr.isUserEvent('delete') || tr.isUserEvent('undo') || tr.isUserEvent('redo') ||
    (tr.isUserEvent('select') && !tr.isUserEvent('select.pointer'))
  if (!keyboard) return null
  return { effects: EditorView.scrollIntoView(tr.newSelection.main.head, { y: 'center' }) }
})

export const focusModes = [focusPlugin, typewriter]

/** Called when shell settings change; after toggling, the editor recomputes decorations once. */
export function setFocusModes(view, { focus, typewriter: tw }) {
  const changed = flags.focus !== !!focus || flags.typewriter !== !!tw
  flags.focus = !!focus
  flags.typewriter = !!tw
  document.body.classList.toggle('nib-focus', flags.focus)
  document.body.classList.toggle('nib-typewriter', flags.typewriter)
  if (!changed || !view) return
  const plugin = view.plugin(focusPlugin)
  if (plugin) plugin.stale = true
  view.dispatch({})
  if (flags.typewriter) view.dispatch({ effects: EditorView.scrollIntoView(view.state.selection.main.head, { y: 'center' }) })
}
