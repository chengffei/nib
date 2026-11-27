// Writes a synthetic ~1,000,000-character Markdown document: mixed CJK / English prose, headings, lists, tables, code.
// Deterministic (no randomness), so every run measures the same text. Usage: node gen.mjs out.md
import { writeFileSync } from 'node:fs'

const zh = '中文排版需要处理标点挤压与中英文混排，阅读模式下表格、列表和代码块都要排好版。'
const en = 'Markdown written by agents and scripts is read far more often than it is edited, so rendering must stay fast. '
let out = ''
for (let chapter = 1; out.length < 1_000_000; chapter++) {
  out += `## Chapter ${chapter} 第 ${chapter} 章\n\n`
  out += `${zh.repeat(3)}${en.repeat(2)}\n\n`
  out += `- 列表项 one with **bold** and \`code\`\n- 列表项 two with [a link](https://example.com)\n  - nested 嵌套项\n\n`
  if (chapter % 2 === 0) {
    out += '| 日期 | 变更 | 负责人 |\n|---|---|---|\n'
    for (let row = 0; row < 8; row++) out += `| 2026-11-${String(row + 1).padStart(2, '0')} | ${zh} | 张三 |\n`
    out += '\n'
  }
  if (chapter % 3 === 0) out += '```js\nconst total = items.reduce((sum, item) => sum + item.value, 0)\nconsole.log(total)\n```\n\n'
  out += `${en}${zh.repeat(2)}\n\n`
}
writeFileSync(process.argv[2], out)
console.log(`${out.length} characters, ${out.split('\n').length} lines`)
