// 短列不换行：中文任意处可断，浏览器自动布局会把短列挤成一字一行，长列独占宽度。
// 一列里每格都不超过 SHORT 个半角宽（中文算 2）时，整列不换行，其余宽度留给长列。
// 会换行的列给个最小宽度：浏览器按内容长短分多出来的宽度，一列特别长时别的换行列只分到一两个字宽（11-19 Felix 反馈）。
// 最小宽度 = 内容宽度与 MIN_EM 取小，半角宽按 0.5em 算；最长的那列不设，剩下的宽度本来就归它。
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
