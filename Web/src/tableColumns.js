// Table column widths. The browser's automatic layout squeezes short columns to one character per line when another column is long
// (Chinese text can break anywhere) and leaves narrow tables hugging their content. Instead each table is measured and laid out here:
// - natural width: what a column needs with no wrapping (measured in place, so fonts and themes are exact);
// - short columns (every cell at most SHORT half-width units, CJK counts 2) never wrap: their minimum is their natural width;
//   other columns may wrap down to min(natural, MIN_EM);
// - everything fits: spare width is split half equally, half in proportion to natural width, so the table fills the text width;
// - only the minimums fit: the remainder goes to the wrapping columns in proportion to what they still lack, with each column's
//   weight capped at CAP_EM so one very long column cannot starve the others;
// - not even the minimums fit: columns get their minimums and the table scrolls sideways.
const SHORT = 30
const MIN_EM = 8
const CAP_EM = 24

function units(text) {
  let n = 0
  for (const ch of text) n += /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/.test(ch) ? 2 : 1
  return n
}

/** Pure width distribution (pixels in, pixels out); exported for tests. */
export function distribute(natural, min, avail, cap = Infinity) {
  const n = natural.length
  const sum = (list) => list.reduce((a, b) => a + b, 0)
  const totalNatural = sum(natural)
  if (totalNatural <= avail) {
    const spare = avail - totalNatural
    return natural.map((w) => w + spare / 2 / n + (totalNatural > 0 ? (spare / 2) * (w / totalNatural) : spare / 2 / n))
  }
  if (sum(min) >= avail) return min.slice()
  // Water-filling: share the rest by capped need; a column that reaches its natural width drops out and its share is re-split.
  const out = min.slice()
  let rest = avail - sum(min)
  let open = natural.map((_, i) => i).filter((i) => natural[i] > min[i])
  while (rest > 0.5 && open.length) {
    const weight = (i) => Math.max(1, Math.min(natural[i], cap) - min[i])
    const total = sum(open.map(weight))
    let given = 0
    const still = []
    for (const i of open) {
      const share = (rest * weight(i)) / total
      const room = natural[i] - out[i]
      if (share >= room) {
        out[i] = natural[i]
        given += room
      } else {
        still.push(i)
      }
    }
    if (still.length === open.length) {
      for (const i of open) out[i] += (rest * weight(i)) / total
      break
    }
    rest -= given
    open = still
  }
  return out
}

function columns(table) {
  const rows = [...table.querySelectorAll('tr')]
  const count = Math.max(0, ...rows.map((row) => row.children.length))
  return { rows, count }
}

/** Marks short columns as non-wrapping; safe to call before the table is in the page. */
export function keepShortColumns(table) {
  const { rows, count } = columns(table)
  const longest = new Array(count).fill(0)
  for (const row of rows) {
    ;[...row.children].forEach((cell, i) => {
      longest[i] = Math.max(longest[i], units(cell.textContent.trim()))
    })
  }
  table.dataset.short = longest.map((u) => (u <= SHORT ? 1 : 0)).join('')
  for (const row of rows) {
    ;[...row.children].forEach((cell, i) => {
      cell.style.whiteSpace = longest[i] <= SHORT ? 'nowrap' : ''
    })
  }
}

/** Measures the table in place and fixes its column widths to fill avail pixels. */
export function fitColumns(table, avail) {
  if (!(avail > 0) || !table.isConnected) return
  const { rows, count } = columns(table)
  if (!count) return
  if (table.dataset.short?.length !== count) keepShortColumns(table)
  const short = [...table.dataset.short].map((c) => c === '1')
  // Natural widths: no wrapping, content-sized.
  table.querySelector(':scope > colgroup.nib-cols')?.remove()
  table.style.tableLayout = 'auto'
  table.style.width = 'max-content'
  for (const row of rows) for (const cell of row.children) cell.style.whiteSpace = 'nowrap'
  const widest = rows.find((row) => row.children.length === count)
  const natural = [...widest.children].map((cell) => cell.getBoundingClientRect().width)
  const em = parseFloat(getComputedStyle(table).fontSize) || 16
  const min = natural.map((w, i) => (short[i] ? w : Math.min(w, MIN_EM * em)))
  const widths = distribute(natural, min, avail, CAP_EM * em).map((w) => Math.floor(w))
  for (const row of rows) {
    ;[...row.children].forEach((cell, i) => {
      cell.style.whiteSpace = short[i] ? 'nowrap' : ''
    })
  }
  const group = document.createElement('colgroup')
  group.className = 'nib-cols'
  for (const w of widths) {
    const col = document.createElement('col')
    col.style.width = `${w}px`
    group.appendChild(col)
  }
  table.prepend(group)
  table.style.tableLayout = 'fixed'
  table.style.width = `${widths.reduce((a, b) => a + b, 0)}px`
}

/** Keeps a table fitted to its container: refits when the container's width changes (window resize, sidebar). */
export function autoFit(table, container, onFit) {
  let last = -1
  const run = () => {
    const avail = container.clientWidth
    if (avail === last) return
    last = avail
    fitColumns(table, avail)
    onFit?.()
  }
  const observer = new ResizeObserver(run)
  observer.observe(container)
  container.__nibRefit = () => {
    last = -1
    run()
  }
}

/** Refits every table on the page; called after font, size or theme changes, which change natural widths but not container widths. */
export function refitAll(root = document) {
  for (const el of root.querySelectorAll('.nib-table-wrap, figure.table-figure')) el.__nibRefit?.()
}
