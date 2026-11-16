// Typora 主题：主题 CSS 只在阅读模式（readView.js 渲染的 #write）里打开。
// 编辑和源码模式不套整份主题，只借它的底色、文字色、链接色和字体，切模式时页面不会突然换一副样子。

// Typora 自己的基础样式（主题都是在它之上写的），这里只留主题普遍依赖的部分。
const BASE_CSS = `
html { font-size: 14px; -webkit-font-smoothing: antialiased; text-size-adjust: 100%; }
body { margin: 0; padding: 0; height: auto; line-height: 1.42857; }
#write { max-width: 860px; margin: 0 auto; padding: 30px 30px 100px; position: relative; word-break: normal; overflow-wrap: break-word; }
#write > ul:first-child, #write > ol:first-child { margin-top: 30px; }
#write li > figure:last-child { margin-bottom: 0.5rem; }
img { max-width: 100%; vertical-align: middle; image-orientation: from-image; }
p { white-space: pre-wrap; }
h1, h2, h3, h4, h5, h6 { break-after: avoid-page; break-inside: avoid; orphans: 4; }
a { cursor: pointer; }
figure { overflow-x: auto; margin: 1.2em 0; max-width: calc(100% + 16px); padding: 0; }
figure > table { margin: 0; }
table { border-collapse: collapse; border-spacing: 0; width: 100%; overflow: auto; break-inside: auto; text-align: left; }
table.md-table td { min-width: 32px; }
tr { break-inside: avoid; break-after: auto; }
thead { display: table-header-group; }
code, kbd, pre, samp, tt { font-family: var(--monospace, ui-monospace, "SF Mono", Menlo, monospace); }
pre.md-fences { font-size: 0.9rem; display: block; break-inside: avoid; text-align: left; overflow: visible; white-space: pre; background: inherit; position: relative; padding: 8px 4px 6px; margin-bottom: 15px; }
.CodeMirror { height: auto; }
.CodeMirror-wrap pre.CodeMirror-line { white-space: pre-wrap; word-wrap: break-word; word-break: normal; }
.CodeMirror-line, .CodeMirror pre { margin: 0; padding: 0 4px; border: 0; background: transparent; font-family: inherit; font-size: inherit; line-height: inherit; }
.md-task-list-item { position: relative; list-style-type: none; }
.md-task-list-item > input { position: absolute; top: 0; left: 0; margin-left: -1.2em; margin-top: calc(1em - 10px); border: none; }
.md-meta-block { white-space: pre-wrap; font-family: var(--monospace, ui-monospace, monospace); font-size: 0.85em; }
blockquote { margin: 0.8em 0; }
hr { break-after: avoid; }
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
  document.head.append(base, theme)
  base.disabled = true
  theme.disabled = true

  let css = null
  let reading = false

  function setReading(on) {
    reading = on && !!css
    base.disabled = !reading
    theme.disabled = !reading
  }

  /** 打开主题量一下 #write 的底色、文字、字体，交给编辑和源码模式用，量完按当前模式恢复。 */
  function derive() {
    const root = document.documentElement
    const write = document.getElementById('write')
    if (!css || !write) {
      document.body.classList.remove('typora-active')
      for (const name of ['--t-bg', '--t-text', '--t-text2', '--t-text3', '--t-accent', '--t-sans', '--t-mono']) root.style.removeProperty(name)
      return
    }
    const container = document.getElementById('nib-typora')
    const wasHidden = container.hidden
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
