// Pasting from a web page or a rich-text app: convert the HTML on the clipboard into markdown (requirement P1).
// Only when the HTML carries structure (headings, lists, links, emphasis, tables, code, images); styled plain text,
// such as code copied from an editor, is pasted as its plain text. Inside a code block the plain text always wins.

import TurndownService from 'turndown'
import { gfm } from 'turndown-plugin-gfm'
import { syntaxTree } from '@codemirror/language'

const STRUCTURE = 'h1,h2,h3,h4,h5,h6,ul,ol,table,a[href],img,strong,b,em,i,blockquote,pre,code,hr,del,s'

const service = new TurndownService({
  headingStyle: 'atx',
  hr: '---',
  bulletListMarker: '-',
  codeBlockStyle: 'fenced',
  emDelimiter: '*',
  strongDelimiter: '**',
  linkStyle: 'inlined',
})
service.use(gfm)
service.remove(['script', 'style', 'meta', 'link', 'title', 'noscript', 'iframe', 'object', 'button', 'input', 'select', 'textarea'])
// Links whose text is empty (icons, anchors) would leave "[](url)" behind.
service.addRule('emptyLink', {
  filter: (node) => node.nodeName === 'A' && !node.textContent.trim() && !node.querySelector('img'),
  replacement: () => '',
})
// Fenced code: take the language from class="language-x" / "lang-x" on pre or code.
service.addRule('fencedLanguage', {
  filter: (node) => node.nodeName === 'PRE',
  replacement: (_content, node) => {
    const code = node.querySelector('code') || node
    const cls = `${node.className} ${code.className}`
    const lang = (/(?:language|lang)-([\w+#-]+)/.exec(cls) || [])[1] || ''
    const text = code.textContent.replace(/\n$/, '')
    const fence = text.includes('```') ? '~~~' : '```'
    return `\n\n${fence}${lang}\n${text}\n${fence}\n\n`
  },
})

// List items as "- item" / "1. item" with content indented to match, instead of turndown's "-   item".
service.addRule('listItem', {
  filter: 'li',
  replacement: (content, node) => {
    const parent = node.parentNode
    let prefix = '- '
    if (parent.nodeName === 'OL') {
      const start = Number(parent.getAttribute('start')) || 1
      prefix = `${start + Array.prototype.indexOf.call(parent.children, node)}. `
    }
    const body = content.replace(/^\n+/, '').replace(/\n+$/, '\n').replace(/\n/gm, '\n' + ' '.repeat(prefix.length))
    return prefix + body + (node.nextSibling && !/\n$/.test(body) ? '\n' : '')
  },
})

/** Markdown for the clipboard HTML, or null when the plain text should be pasted instead. */
export function htmlToMarkdown(html, plain) {
  const doc = new DOMParser().parseFromString(html, 'text/html')
  const body = doc.body
  if (!body) return null
  // Google Docs wraps the whole selection in <b style="font-weight:normal">; such wrappers are not bold.
  for (const el of body.querySelectorAll('b, strong')) {
    const weight = el.style?.fontWeight
    if (weight === 'normal' || weight === '400') el.replaceWith(...el.childNodes)
  }
  // Docs apps (Google Docs, Feishu) mark bold and italic with inline styles on spans.
  for (const span of body.querySelectorAll('span[style]')) {
    const weight = span.style.fontWeight
    const bold = weight === 'bold' || Number(weight) >= 600
    const italic = span.style.fontStyle === 'italic'
    if (!span.textContent.trim() || (!bold && !italic)) continue
    let wrapper = span
    if (italic) wrapper = wrap(doc, wrapper, 'em')
    if (bold) wrap(doc, wrapper, 'strong')
  }
  if (!body.querySelector(STRUCTURE)) return null
  const markdown = service
    .turndown(body)
    .replace(/ /g, ' ')
    .replace(/[ \t]+$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
  if (!markdown) return null
  // A selection inside one paragraph converts to a single line; keep the trailing newline only if the plain text had one.
  return /\n$/.test(plain || '') && markdown.includes('\n') ? markdown + '\n' : markdown
}

function wrap(doc, node, tag) {
  const el = doc.createElement(tag)
  node.replaceWith(el)
  el.appendChild(node)
  return el
}

/** Whether the cursor sits in code, where text must stay verbatim. */
export function inCode(state) {
  const pos = state.selection.main.from
  for (let node = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
    if (/^(FencedCode|CodeBlock|InlineCode|CodeText)$/.test(node.name)) return true
  }
  return false
}
