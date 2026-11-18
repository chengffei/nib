// 短列不换行：中文任意处可断，浏览器自动布局会把短列挤成一字一行，长列独占宽度。
// 一列里每格都不超过 SHORT 个半角宽（中文算 2）时，整列不换行，其余宽度留给长列。
const SHORT = 30

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
  for (const row of rows) {
    ;[...row.children].forEach((cell, i) => {
      if (longest[i] <= SHORT) cell.style.whiteSpace = 'nowrap'
    })
  }
}
