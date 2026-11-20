// Typora theme: the theme CSS is only enabled in read mode (the #write rendered by readView.js).
// Edit mode uses styles measured from the theme by typoraEdit.js (headings, paragraphs, quotes, code, tables, block spacing, ...);
// source mode only borrows the background, text colour, link colour and font.
import { deriveEditCSS } from './typoraEdit.js'

// Theme base: Typora themes are written on top of the host's base styles, so the host must provide sensible defaults for a theme to specify only its differences.
// Written here from scratch against the page structure in Typora's public theme documentation (theme.typora.io): the variable names, #write, md-fences,
// md-task-list-item and md-meta-block are interface names themes depend on; the values and wording are Nib's own.
const BASE_CSS = `
:root {
  --bg-color: #fff;
  --text-color: #2b2b2b;
  --select-text-bg-color: rgba(0, 113, 227, 0.25);
  --monospace: ui-monospace, "SF Mono", Menlo, monospace;
}
/* Root font size: themes use rem heavily, so assume 14px */
html { font-size: 14px; background: var(--bg-color); color: var(--text-color); -webkit-font-smoothing: antialiased; text-size-adjust: 100%; }
body { margin: 0; line-height: 1.43; }
::selection { background: var(--select-text-bg-color); }
#write { position: relative; box-sizing: border-box; max-width: 860px; margin: 0 auto; padding: 32px 32px 96px; overflow-wrap: break-word; }
#write > ul:first-child, #write > ol:first-child { margin-top: 2em; }

/* Paragraphs preserve soft line breaks; headings do not break across pages */
p { white-space: pre-wrap; }
h1, h2, h3, h4, h5, h6 { break-inside: avoid; break-after: avoid-page; }
hr { break-after: avoid; }
blockquote { margin: 1em 0; }
a { cursor: pointer; }
img { max-width: 100%; vertical-align: middle; image-orientation: from-image; }

/* Tables are wrapped in figure.table-figure; wide tables scroll horizontally */
figure { margin: 1em 0; padding: 0; overflow-x: auto; }
figure > table, li > figure:last-child { margin-bottom: 0; }
table { width: 100%; border-collapse: collapse; border-spacing: 0; text-align: left; }
table.md-table td { min-width: 2.5em; }
thead { display: table-header-group; }
tr { break-inside: avoid; }

/* Code: inside pre.md-fences is CodeMirror 5's line structure */
code, kbd, pre, samp, tt { font-family: var(--monospace); }
pre.md-fences { display: block; position: relative; margin: 0 0 1em; padding: 6px 4px; font-size: 0.9rem; white-space: pre; text-align: left; background: inherit; break-inside: avoid; }
.CodeMirror { height: auto; }
.CodeMirror pre, .CodeMirror-line { margin: 0; padding: 0 4px; border: 0; background: none; font: inherit; line-height: inherit; }
.CodeMirror-wrap pre.CodeMirror-line { white-space: pre-wrap; overflow-wrap: break-word; }

/* Task list: the checkbox hangs to the left of the text */
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

  /** Enables the theme and measures the #write background, text and font for edit and source modes, then restores state for the current mode. */
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
    // Before measuring, remove the background Nib painted for the previous theme; otherwise the upward search for a background finds the old theme's and the title bar keeps the old colour.
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
    // The read layer is scaled by Nib's font size; remove that before measuring and restore it afterwards.
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
    // Secondary text uses the theme text colour at reduced opacity; too much reduction is hard to read on dark backgrounds, so dark themes reduce less.
    const darkBg = luminance(bg) < 0.45
    root.style.setProperty('--t-text2', rgb(text, darkBg ? 0.8 : 0.7))
    root.style.setProperty('--t-text3', rgb(text, darkBg ? 0.62 : 0.5))
    root.style.setProperty('--t-accent', accent)
    // The scrollbar uses the theme text colour so it follows the theme's tone.
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
    /** Stylesheet for exports: Typora's base plus the theme. */
    get exportCSS() {
      return css ? BASE_CSS + '\n' + css : null
    },
    /** Switches theme (null means none). Passing the same CSS again does nothing. */
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
