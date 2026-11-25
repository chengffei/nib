// Mermaid diagrams in ```mermaid fences. The library (Nib/Editor/mermaid.min.js, ~3.5 MB) is loaded only when a document
// actually contains one, so startup cost is unchanged. Rendering runs with securityLevel 'strict': labels are sanitised and
// click handlers are off, so opening an untrusted document cannot run script through a diagram.
import { t } from './i18n.js'

export const isMermaid = (info) => /^mermaid(\s|$)/i.test(info.trim())

let loading = null
function load() {
  if (window.mermaid) return Promise.resolve(window.mermaid)
  if (!loading) {
    loading = new Promise((resolve, reject) => {
      const script = document.createElement('script')
      script.src = 'mermaid.min.js'
      script.onload = () => resolve(window.mermaid)
      script.onerror = () => {
        loading = null
        reject(new Error('mermaid.min.js failed to load'))
      }
      document.head.appendChild(script)
    })
  }
  return loading
}

const FONT = '-apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans", "Helvetica Neue", sans-serif'
// Finished renders by theme + source, so widgets rebuilt while scrolling show the diagram at once instead of flickering.
const done = new Map()
const pending = new Map()
let queue = Promise.resolve()
let seq = 0

const keyOf = (code, dark) => `${dark ? 'd' : 'l'}\n${code}`

/** SVG markup for the diagram. Renders are serialised because mermaid's config is global and changes with the theme. */
export function renderMermaid(code, dark) {
  const key = keyOf(code, dark)
  if (done.has(key)) return Promise.resolve(done.get(key))
  if (pending.has(key)) return pending.get(key)
  const job = (queue = queue.catch(() => {}).then(async () => {
    const mermaid = await load()
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default', fontFamily: FONT, suppressErrorRendering: true })
    const id = `nib-mermaid-${++seq}`
    try {
      const { svg } = await mermaid.render(id, code)
      return svg
    } finally {
      document.getElementById(id)?.remove()
      document.getElementById(`d${id}`)?.remove()
    }
  }))
  pending.set(key, job)
  job.then(
    (svg) => {
      pending.delete(key)
      done.set(key, svg)
      if (done.size > 100) done.delete(done.keys().next().value)
    },
    () => pending.delete(key),
  )
  return job
}

/** Whether the text colour inside el is light, i.e. the page around it is dark. */
export function isDarkAt(el) {
  const m = /rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)/.exec(getComputedStyle(el).color)
  if (!m) return false
  const [r, g, b] = m.slice(1).map(Number)
  return 0.299 * r + 0.587 * g + 0.114 * b > 140
}

function showSource(box, code, error) {
  box.classList.add('nib-mermaid-failed')
  box.replaceChildren()
  if (error) {
    const note = document.createElement('div')
    note.className = 'nib-mermaid-error'
    note.textContent = t('Diagram could not be rendered: ') + String(error.message || error).split('\n')[0]
    box.appendChild(note)
  }
  const pre = document.createElement('pre')
  pre.className = 'nib-mermaid-source'
  pre.textContent = code
  box.appendChild(pre)
}

/** Fills box with the rendered diagram. The theme is read from the text colour around `themeFrom` (or box once attached). */
export function mountMermaid(box, code, { themeFrom, onChange } = {}) {
  const dark = isDarkAt(themeFrom || box)
  const key = keyOf(code, dark)
  if (box.__nibMermaid?.key === key && box.querySelector('svg')) return
  box.__nibMermaid = { code, key, themeFrom, onChange }
  box.classList.remove('nib-mermaid-failed')
  if (done.has(key)) {
    box.innerHTML = done.get(key)
    return
  }
  // While the library loads, the source stands in so the layout does not jump from zero height.
  if (!box.firstChild) showSource(box, code)
  renderMermaid(code, dark).then(
    (svg) => {
      if (box.__nibMermaid?.code !== code) return
      box.classList.remove('nib-mermaid-failed')
      box.innerHTML = svg
      onChange?.()
    },
    (error) => {
      if (box.__nibMermaid?.code !== code) return
      showSource(box, code, error)
      onChange?.()
    },
  )
}

/** Re-renders every diagram under root, e.g. after the theme changed between light and dark. */
export function refreshMermaid(root) {
  for (const box of root.querySelectorAll('.nib-mermaid')) {
    const state = box.__nibMermaid
    if (state) mountMermaid(box, state.code, state)
  }
}
