// Typora 主题：主题 CSS 只在阅读模式（readView.js 渲染的 #write）里打开。
// 编辑模式用 typoraEdit.js 从主题量出来的样式（标题、段落、引用、代码、表格、块间距……）；
// 源码模式只借底色、文字色、链接色和字体。
import { deriveEditCSS } from './typoraEdit.js'

// 主题的底座：Typora 主题是写在宿主基础样式之上的，宿主要先给出一套合理默认值，主题才能只写差异。
// 这里按 Typora 公开的主题文档（theme.typora.io）里的页面结构自行编写：变量名、#write、md-fences、
// md-task-list-item、md-meta-block 这些名字是主题依赖的接口，取值和写法是 Nib 自己的。
const BASE_CSS = `
:root {
  --bg-color: #fff;
  --text-color: #2b2b2b;
  --select-text-bg-color: rgba(0, 113, 227, 0.25);
  --monospace: ui-monospace, "SF Mono", Menlo, monospace;
}
/* 根字号：主题大量用 rem，按 14px 算 */
html { font-size: 14px; background: var(--bg-color); color: var(--text-color); -webkit-font-smoothing: antialiased; text-size-adjust: 100%; }
body { margin: 0; line-height: 1.43; }
::selection { background: var(--select-text-bg-color); }
#write { position: relative; box-sizing: border-box; max-width: 860px; margin: 0 auto; padding: 32px 32px 96px; overflow-wrap: break-word; }
#write > ul:first-child, #write > ol:first-child { margin-top: 2em; }

/* 段落保留软换行；标题不在分页处断开 */
p { white-space: pre-wrap; }
h1, h2, h3, h4, h5, h6 { break-inside: avoid; break-after: avoid-page; }
hr { break-after: avoid; }
blockquote { margin: 1em 0; }
a { cursor: pointer; }
img { max-width: 100%; vertical-align: middle; image-orientation: from-image; }

/* 表格包在 figure.table-figure 里，宽表横向滚动 */
figure { margin: 1em 0; padding: 0; overflow-x: auto; }
figure > table, li > figure:last-child { margin-bottom: 0; }
table { width: 100%; border-collapse: collapse; border-spacing: 0; text-align: left; }
table.md-table td { min-width: 2.5em; }
thead { display: table-header-group; }
tr { break-inside: avoid; }

/* 代码：pre.md-fences 内是 CodeMirror 5 的行结构 */
code, kbd, pre, samp, tt { font-family: var(--monospace); }
pre.md-fences { display: block; position: relative; margin: 0 0 1em; padding: 6px 4px; font-size: 0.9rem; white-space: pre; text-align: left; background: inherit; break-inside: avoid; }
.CodeMirror { height: auto; }
.CodeMirror pre, .CodeMirror-line { margin: 0; padding: 0 4px; border: 0; background: none; font: inherit; line-height: inherit; }
.CodeMirror-wrap pre.CodeMirror-line { white-space: pre-wrap; overflow-wrap: break-word; }

/* 任务列表：勾选框挂在文字左侧 */
.md-task-list-item { position: relative; list-style: none; }
.md-task-list-item > input { position: absolute; top: 0.3em; left: 0; margin: 0 0 0 -1.3em; border: none; }

.md-meta-block { white-space: pre-wrap; font-family: var(--monospace); font-size: 0.85em; }
`

function parseColor(value) {
  const m = /rgba?\(([^)]+)\)/.exec(value || '')
  if (!m) return null
  const [r, g, b, a = 1] = m[1].split(/[\s,/]+/).filter(Boolean).map(Number)
  return { r, g, b, a }
}

const luminance = ({ r, g, b }) => (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255

export function createTyporaTheme({ post }) {
  const base = document.createElement('style')
  base.id = 'nib-typora-base'
  base.textContent = BASE_CSS
  const theme = document.createElement('style')
  theme.id = 'nib-typora-theme'
  const edit = document.createElement('style')
  edit.id = 'nib-typora-edit'
  document.head.append(base, theme, edit)
  base.disabled = true
  theme.disabled = true

  let css = null
  let reading = false

  function setReading(on) {
    reading = on && !!css
    base.disabled = !reading
    theme.disabled = !reading
    document.body.classList.toggle('nib-themed-edit', !!css && !reading)
  }

  /** 打开主题量一下 #write 的底色、文字、字体，交给编辑和源码模式用，量完按当前模式恢复。 */
  function derive() {
    const root = document.documentElement
    const write = document.getElementById('write')
    if (!css || !write) {
      document.body.classList.remove('typora-active')
      edit.textContent = ''
      for (const name of ['--t-bg', '--t-text', '--t-text2', '--t-text3', '--t-accent', '--t-sans', '--t-mono', '--t-thumb', '--t-thumb-strong']) root.style.removeProperty(name)
      return
    }
    const container = document.getElementById('nib-typora')
    const wasHidden = container.hidden
    // 量之前去掉 Nib 自己按上一个主题涂的底色，不然往上找底色时找到的是上一个主题的（11-19 换主题后标题栏不变色）。
    document.body.classList.remove('typora-active')
    container.hidden = false
    base.disabled = false
    theme.disabled = false
    const probeLink = document.createElement('a')
    const probeCode = document.createElement('code')
    probeLink.textContent = 'x'
    probeCode.textContent = 'x'
    write.append(probeLink, probeCode)

    let bg = null
    for (let node = write; node && !bg; node = node.parentElement) {
      const color = parseColor(getComputedStyle(node).backgroundColor)
      if (color && color.a > 0.5) bg = color
    }
    bg = bg || { r: 255, g: 255, b: 255, a: 1 }
    const style = getComputedStyle(write)
    const text = parseColor(style.color) || { r: 51, g: 51, b: 51 }
    const accent = getComputedStyle(probeLink).color
    const sans = style.fontFamily
    const mono = getComputedStyle(probeCode).fontFamily
    // 阅读层按 Nib 字号缩放过，量之前先去掉，量完还原。
    const zoom = container.style.zoom
    container.style.zoom = ''
    try {
      edit.textContent = deriveEditCSS(write)
    } catch (error) {
      edit.textContent = ''
      post({ type: 'log', text: `typora edit css failed: ${error}` })
    }
    container.style.zoom = zoom

    probeLink.remove()
    probeCode.remove()
    container.hidden = wasHidden
    setReading(reading)

    const rgb = (c, a = 1) => `rgba(${c.r}, ${c.g}, ${c.b}, ${a})`
    root.style.setProperty('--t-bg', rgb(bg))
    root.style.setProperty('--t-text', rgb(text))
    // 次要文字用主题文字色降透明度；深色底上降多了看不清，所以深色主题降得少些。
    const darkBg = luminance(bg) < 0.45
    root.style.setProperty('--t-text2', rgb(text, darkBg ? 0.8 : 0.7))
    root.style.setProperty('--t-text3', rgb(text, darkBg ? 0.62 : 0.5))
    root.style.setProperty('--t-accent', accent)
    // 滚动条用主题文字色，跟着主题的色调走。
    root.style.setProperty('--t-thumb', rgb(text, darkBg ? 0.4 : 0.32))
    root.style.setProperty('--t-thumb-strong', rgb(text, darkBg ? 0.6 : 0.5))
    root.style.setProperty('--t-sans', sans)
    root.style.setProperty('--t-mono', mono)
    document.body.classList.add('typora-active')
    const dark = luminance(bg) < 0.45
    document.documentElement.dataset.typoraDark = String(dark)
    post({ type: 'theme', dark, bg: [bg.r, bg.g, bg.b] })
  }

  return {
    get active() {
      return !!css
    },
    /** 换主题（null 表示不用）。同一份 CSS 再传一次不重来。 */
    setCSS(next) {
      next = next || null
      if (next === css) return false
      css = next
      theme.textContent = css || ''
      derive()
      setReading(reading)
      return true
    },
    setReading,
  }
}
