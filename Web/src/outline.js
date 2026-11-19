// 大纲：从语法树取标题（代码块里的 # 不算），报给外壳画在标题栏的大纲面板里；
// 滚动时报当前读到哪一节；面板里点一项，滚到那个标题。阅读层（Typora 主题）按第几个标题对应。
import { ensureSyntaxTree } from '@codemirror/language'
import { EditorView } from '@codemirror/view'

export function headings(state) {
  const tree = ensureSyntaxTree(state, state.doc.length, 200)
  const out = []
  if (!tree) return out
  tree.iterate({
    enter(n) {
      const m = /^(ATX|Setext)Heading(\d)$/.exec(n.name)
      if (!m) return n.name === 'Document' || n.name === 'Blockquote' || n.name === 'ListItem' || n.name.endsWith('List')
      const line = state.doc.lineAt(n.from)
      const text = m[1] === 'ATX'
        ? line.text.replace(/^\s{0,3}#{1,6}\s*/, '').replace(/\s+#+\s*$/, '')
        : line.text
      out.push({ level: Number(m[2]), text: plain(text.trim()), from: n.from })
      return false
    },
  })
  return out
}

/** 标题里的行内标记去掉，只留文字。 */
function plain(text) {
  return text
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/(\*\*|__|\*|_|~~)(.+?)\1/g, '$2')
}

export function createOutline({ post, getView, reader }) {
  let items = []
  let lastKey = ''
  let current = -1
  let timer = 0

  function report() {
    const view = getView()
    items = headings(view.state)
    const key = JSON.stringify(items.map((h) => [h.level, h.text]))
    if (key !== lastKey) {
      lastKey = key
      post({ type: 'outline', items: items.map(({ level, text }) => ({ level, text })) })
    }
    track()
  }

  /** 当前一节：视口顶部往下一点之前的最后一个标题。 */
  function track() {
    let index = -1
    if (reader.visible) {
      const top = reader.scroller.getBoundingClientRect().top + 80
      const nodes = reader.scroller.querySelectorAll('#write h1, #write h2, #write h3, #write h4, #write h5, #write h6')
      nodes.forEach((node, i) => {
        if (node.getBoundingClientRect().top <= top) index = i
      })
    } else {
      const view = getView()
      const top = view.lineBlockAtHeight(view.scrollDOM.getBoundingClientRect().top + 80 - view.documentTop).from
      items.forEach((h, i) => {
        if (h.from <= top) index = i
      })
    }
    if (index !== current) {
      current = index
      post({ type: 'outlineCurrent', index })
    }
  }

  return {
    schedule() {
      clearTimeout(timer)
      timer = setTimeout(report, 200)
    },
    reset() {
      lastKey = ''
      current = -2
      report()
    },
    track,
    /** 滚到第 index 个标题，标题停在视口上方留一点空。 */
    go(index) {
      if (reader.visible) {
        const nodes = reader.scroller.querySelectorAll('#write h1, #write h2, #write h3, #write h4, #write h5, #write h6')
        const node = nodes[index]
        if (node) reader.scroller.scrollTo({ top: node.getBoundingClientRect().top - reader.scroller.getBoundingClientRect().top + reader.scroller.scrollTop - 24, behavior: 'smooth' })
        return
      }
      const view = getView()
      const h = items[index]
      if (!h) return
      view.dispatch({ effects: EditorView.scrollIntoView(h.from, { y: 'start', yMargin: 24 }) })
    },
  }
}
