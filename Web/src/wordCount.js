// Word count, following Typora's official documentation (support.typora.io/Word-Count):
// each CJK character counts as one word; words exclude Markdown formatting symbols (list markers, #, >, emphasis markers, link URLs, etc.), while characters include them.
// The character count excludes newlines; the line count follows source lines.

const CJK = /[⺀-⿟぀-ヿ㄀-ㆿ㐀-䶿一-鿿가-힯豈-﫿]/g
const WORD = /[\p{L}\p{N}][\p{L}\p{N}'’_.-]*/gu

/** Strips formatting symbols, keeping only the text a reader sees. */
function plain(text) {
  return text
    .replace(/^ {0,3}(`{3,}|~{3,}).*$/gm, '') // code fence lines
    .replace(/^\s{0,3}#{1,6}\s+/gm, '') // headings
    .replace(/^\s*>+\s?/gm, '') // blockquotes
    .replace(/^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/gm, '') // lists, task checkboxes
    .replace(/^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/gm, '') // table separator rows
    .replace(/^\s*([-*_]\s*){3,}$/gm, '') // thematic breaks
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1') // images keep their alt text
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1') // links keep their text
    .replace(/<[^>\n]+>/g, ' ') // HTML tags
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

/** Recomputed when the text or selection changes, reported to the shell once typing pauses for 150 ms. When text is selected, the selection is reported separately. */
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
