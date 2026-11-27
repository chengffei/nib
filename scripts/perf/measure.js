// Runs inside webcheck: per-operation main-thread time for typing, backspace and scrolling in edit mode.
// Each sample = the editor's synchronous update plus a forced layout, so it measures work, not frame pacing.
const pct = (list, p) => {
  const s = [...list].sort((a, b) => a - b)
  return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(3)
}
const view = nib.view
nib.setMode('edit')
await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
const settle = () => {
  if (typeof view.measure === 'function') view.measure()
  return view.dom.offsetHeight
}
const middle = view.state.doc.line(Math.floor(view.state.doc.lines / 2)).to
view.dispatch({ selection: { anchor: middle }, scrollIntoView: true })
settle()
const runs = { type: [], backspace: [], scroll: [] }
for (let i = 0; i < 100; i++) {
  let t = performance.now()
  const at = view.state.selection.main.head
  view.dispatch({ changes: { from: at, insert: i % 2 ? '字' : 'a' }, selection: { anchor: at + 1 }, userEvent: 'input.type' })
  settle()
  runs.type.push(performance.now() - t)
  t = performance.now()
  const head = view.state.selection.main.head
  view.dispatch({ changes: { from: head - 1, to: head }, selection: { anchor: head - 1 }, userEvent: 'delete.backward' })
  settle()
  runs.backspace.push(performance.now() - t)
}
for (let i = 0; i < 100; i++) {
  const t = performance.now()
  view.scrollDOM.scrollTop += 700
  settle()
  runs.scroll.push(performance.now() - t)
}
const result = {}
for (const [name, list] of Object.entries(runs)) result[name] = { p50: pct(list, 50), p95: pct(list, 95) }
return JSON.stringify(result)
