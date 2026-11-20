// Short columns do not wrap: Chinese text can break anywhere, and the browser's automatic layout would squeeze short columns to one character per line and give long columns all the width.
// When every cell in a column is at most SHORT half-width units (CJK counts as 2), the column does not wrap and the remaining width goes to the long columns.
// Wrapping columns get a minimum width: the browser distributes extra width by content length, so when one column is very long the other wrapping columns get only a character or two.
// Minimum width = the smaller of the content width and MIN_EM, with a half-width unit counted as 0.5em; the longest column gets none, since the leftover width goes to it anyway.
const SHORT = 30
const MIN_EM = 8

function width(text) {
  let n = 0
  for (const ch of text) n += /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/.test(ch) ? 2 : 1
  return n
}

export function keepShortColumns(table) {
  const rows = [...table.querySelectorAll('tr')]
  const longest = []
  for (const row of rows) {
    ;[...row.children].forEach((cell, i) => {
      longest[i] = Math.max(longest[i] || 0, width(cell.textContent.trim()))
    })
  }
  const widest = longest.indexOf(Math.max(...longest))
  for (const row of rows) {
    ;[...row.children].forEach((cell, i) => {
      if (longest[i] <= SHORT) cell.style.whiteSpace = 'nowrap'
      else if (i === widest) return
      else cell.style.minWidth = `${Math.min(longest[i] * 0.5, MIN_EM)}em`
    })
  }
}
