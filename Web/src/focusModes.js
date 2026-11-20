// 专注模式（F8）和打字机模式（F9），照 Typora。
// 专注：光标所在的那一块（段落、标题、列表项、引用、代码块……）正常显示，其余调淡；只在编辑和源码模式生效。
// 打字机：打字或用键盘移动光标时，光标所在行保持在屏幕中间；鼠标点击不跟着滚，免得点哪儿页面跳到哪儿。
import { Decoration, EditorView, ViewPlugin } from '@codemirror/view'
import { EditorState } from '@codemirror/state'
import { syntaxTree } from '@codemirror/language'

const flags = { focus: false, typewriter: false }
const on = Decoration.line({ class: 'nib-focus-on' })

/** 光标所在的块：从光标往上找，列表停在列表项，其余停在文档的直接子节点。 */
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

/** 外壳设置变了就调这里；切换后让编辑器重算一次装饰。 */
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
