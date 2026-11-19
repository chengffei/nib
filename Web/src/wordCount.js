// 字数统计，口径照 Typora 官方文档（support.typora.io/Word-Count）：
// 一个汉字算一个词；词数不算排版用的 Markdown 符号（列表符、#、>、强调符、链接地址等），字符数算。
// 字符数不含换行；行数按源文件的行。

const CJK = /[⺀-⿟぀-ヿ㄀-ㆿ㐀-䶿一-鿿가-힯豈-﫿]/g
const WORD = /[\p{L}\p{N}][\p{L}\p{N}'’_.-]*/gu

/** 去掉排版符号，只留读者看得到的文字。 */
function plain(text) {
  return text
    .replace(/^ {0,3}(`{3,}|~{3,}).*$/gm, '') // 代码块围栏行
    .replace(/^\s{0,3}#{1,6}\s+/gm, '') // 标题
    .replace(/^\s*>+\s?/gm, '') // 引用
    .replace(/^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/gm, '') // 列表、任务框
    .replace(/^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/gm, '') // 表格分隔行
    .replace(/^\s*([-*_]\s*){3,}$/gm, '') // 分隔线
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1') // 图片留替代文字
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1') // 链接留文字
    .replace(/<[^>\n]+>/g, ' ') // HTML 标签
    .replace(/[*_~`|]/g, ' ')
}

export function countWords(text) {
  const body = plain(text)
  const cjk = body.match(CJK)?.length || 0
  const rest = body.replace(CJK, ' ').match(WORD)?.length || 0
  return cjk + rest
}

export function stats(text) {
  return {
    words: countWords(text),
    chars: text.replace(/\r?\n/g, '').length,
    lines: text === '' ? 0 : text.split(/\r?\n/).length,
  }
}

/** 正文变了或选区变了就重算，停手 150 毫秒再报给外壳。选中文字时另报选中部分。 */
export function createWordCounter({ post, getText, getSelection }) {
  let timer = 0
  let lastKey = ''
  function report() {
    const all = stats(getText())
    const picked = getSelection()
    const sel = picked ? stats(picked) : null
    const key = JSON.stringify([all, sel])
    if (key === lastKey) return
    lastKey = key
    post({ type: 'stats', ...all, selection: sel })
  }
  return {
    schedule() {
      clearTimeout(timer)
      timer = setTimeout(report, 150)
    },
    reset() {
      lastKey = ''
      clearTimeout(timer)
      report()
    },
  }
}
