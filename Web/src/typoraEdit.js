// Edit mode also applies the Typora theme.
// Theme CSS is written for Typora's DOM (#write h1, blockquote > p, figure > table, ...), which CodeMirror's line structure does not match,
// and rewriting selectors cannot cover everything. Instead: place a sample inside #write, let the theme lay it out unchanged, then copy the measured computed styles onto the matching editor lines and marks.
// How the theme is written does not matter; edit mode simply mirrors whatever it renders.
// Block spacing is measured too (including margin collapsing) and applied as top padding on the adjacent line; blank lines between blocks are squeezed to that height.

const BLOCKS = {
  p: { html: '<p>x</p>', el: (n) => n, first: '.nib-p-first', last: '.nib-p-last', all: '.nib-p' },
  ...Object.fromEntries(
    [1, 2, 3, 4, 5, 6].map((i) => [`h${i}`, { html: `<h${i}>x</h${i}>`, el: (n) => n, first: `.nib-h${i}`, last: `.nib-h${i}`, all: `.nib-h${i}` }]),
  ),
  quote: { html: '<blockquote><p>x</p></blockquote>', el: (n) => n, text: (n) => n.querySelector('p'), first: '.nib-quote-first', last: '.nib-quote-last', all: '.nib-quote' },
  list: { html: '<ul><li class="md-list-item"><p>x</p></li></ul>', el: (n) => n, text: (n) => n.querySelector('p'), first: '.nib-list-first', last: '.nib-list-last', all: '.nib-list' },
  fence: {
    html: '<pre class="md-fences md-end-block ty-contain-cm modeLoaded" lang="js"><div class="CodeMirror cm-s-inner CodeMirror-wrap" lang="js"><div class="CodeMirror-scroll"><div class="CodeMirror-sizer"><div class="CodeMirror-lines"><div class="CodeMirror-code"><pre class="CodeMirror-line"><span><span class="cm-keyword">const</span> <span class="cm-def">a</span> <span class="cm-operator">=</span> <span class="cm-string">"s"</span> <span class="cm-comment">// c</span> <span class="cm-number">1</span> <span class="cm-variable-3 cm-type">T</span></span></pre></div></div></div></div></div></pre>',
    el: (n) => n,
    text: (n) => n.querySelector('.CodeMirror-line'),
    first: '.nib-cb-first',
    last: '.nib-cb-last',
    all: '.nib-cb',
  },
  hr: { html: '<hr>', el: (n) => n, first: '.nib-hrline', last: '.nib-hrline', all: '.nib-hrline' },
  table: {
    html: '<figure class="md-table-fig"><table class="md-table"><thead><tr><th>x</th></tr></thead><tbody><tr><td>x</td></tr><tr><td>x</td></tr></tbody></table></figure>',
    el: (n) => n,
    first: '.nib-table-wrap',
    last: '.nib-table-wrap',
    all: '.nib-table-wrap',
  },
}

const TEXT = ['color', 'font-family', 'font-weight', 'font-style', 'letter-spacing', 'text-transform', 'text-align', 'text-shadow', 'text-decoration-line', 'text-decoration-color', 'text-decoration-style']
const BOX_SIDES = ['top', 'right', 'bottom', 'left']
const PSEUDO = ['content', 'display', 'position', 'top', 'right', 'bottom', 'left', 'width', 'height', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
  'padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'color', 'background-color', 'background-image', 'border-top', 'border-right', 'border-bottom', 'border-left',
  'border-radius', 'font-family', 'font-size', 'font-weight', 'font-style', 'opacity', 'transform', 'vertical-align', 'line-height', 'letter-spacing', 'box-shadow']

const px = (v) => parseFloat(v) || 0
const isClear = (c) => !c || c === 'transparent' || /rgba\([^)]*,\s*0\)$/.test(c)
const em = (value, fs) => `${+(value / fs).toFixed(4)}em`

/** Converts a length to em relative to this element's font size, so it scales with Nib's font-size setting. */
function lengths(value, fs) {
  return value.replace(/(-?\d*\.?\d+)px/g, (_, n) => em(parseFloat(n), fs))
}

function textRules(cs, baseFs, withSize = true) {
  const out = TEXT.map((p) => `${p}: ${cs.getPropertyValue(p)}`)
  const fs = px(cs.fontSize)
  if (withSize) out.push(`font-size: ${+(fs / baseFs).toFixed(4)}em`)
  const lh = cs.lineHeight === 'normal' ? 1.4 : px(cs.lineHeight) / fs
  out.push(`line-height: ${+lh.toFixed(4)}`)
  return out
}

function border(cs, side, fs) {
  const w = px(cs.getPropertyValue(`border-${side}-width`))
  const style = cs.getPropertyValue(`border-${side}-style`)
  if (!w || style === 'none') return null
  return `${em(w, fs)} ${style} ${cs.getPropertyValue(`border-${side}-color`)}`
}

function pseudo(el, which, fs) {
  const cs = getComputedStyle(el, which)
  const content = cs.getPropertyValue('content')
  if (!content || content === 'none' || content === 'normal') return null
  return PSEUDO.map((p) => `${p}: ${p === 'content' ? content : lengths(cs.getPropertyValue(p), fs)}`).join('; ')
}

export function deriveEditCSS(write) {
  const baseCs = getComputedStyle(write)
  const baseFs = px(baseCs.fontSize) || 16
  const host = document.createElement('div')
  host.style.cssText = 'position: relative'
  write.append(host)
  const css = []
  const S = 'body.typora-active.nib-themed-edit:not([data-mode="source"])'

  // Overall: font size is converted from the theme baseline (Nib's font-size setting still applies); font, line height and text colour come from the body paragraph.
  host.innerHTML = '<p>x</p>'
  const pCs = getComputedStyle(host.firstChild)
  css.push(`${S} .cm-editor { font-size: calc(var(--fs) * ${+(baseFs / 16).toFixed(4)}); }`)
  css.push(`${S} .cm-scroller { ${textRules(pCs, baseFs, false).filter((r) => !r.startsWith('text-align')).join('; ')}; }`)

  // Each block type: text style, box (background, border, radius, padding), and ::before / ::after decorations.
  const sizes = {}
  for (const [type, b] of Object.entries(BLOCKS)) {
    host.innerHTML = b.html
    const node = host.firstChild
    const box = getComputedStyle(b.el(node))
    const textEl = b.text ? b.text(node) : node
    const tcs = getComputedStyle(textEl)
    const fs = px(tcs.fontSize)
    sizes[type] = { fs, mt: px(box.marginTop), mb: px(box.marginBottom), pt: px(box.paddingTop), pb: px(box.paddingBottom), bt: !!border(box, 'top', fs) }
    if (type === 'table' || type === 'hr') continue
    const all = `${S} .cm-content .cm-line${b.all}`
    const rules = textRules(tcs, baseFs)
    if (type.startsWith('h') || type === 'p') rules.push(`padding-top: 0; padding-bottom: 0`)
    if (!isClear(box.backgroundColor)) rules.push(`background-color: ${box.backgroundColor}`)
    if (box.backgroundImage !== 'none') rules.push(`background-image: ${box.backgroundImage}`)
    if (box.boxShadow !== 'none' && type !== 'fence') rules.push(`box-shadow: none`)
    const left = px(box.paddingLeft) + px(box.borderLeftWidth) + (b.text ? px(tcs.paddingLeft) : 0)
    const right = px(box.paddingRight) + (b.text ? px(tcs.paddingRight) : 0)
    if (type !== 'list') rules.push(`padding-left: ${em(left - px(box.borderLeftWidth), fs)}; padding-right: ${em(right, fs)}`)
    const l = border(box, 'left', fs)
    const r = border(box, 'right', fs)
    rules.push(`border-left: ${l || 'none'}; border-right: ${r || 'none'}`)
    if (type === 'quote') rules.push('background-clip: padding-box')
    css.push(`${all} { ${rules.join('; ')}; position: relative; }`)
    // Multi-line blocks: the top border, top radius and top padding go on the first line, the bottom ones on the last line.
    const radius = box.borderRadius
    const t = border(box, 'top', fs)
    const btm = border(box, 'bottom', fs)
    const firstRules = [`padding-top: ${em(px(box.paddingTop) + (b.text ? px(tcs.paddingTop) : 0), fs)}`]
    const lastRules = [`padding-bottom: ${em(px(box.paddingBottom) + (b.text ? px(tcs.paddingBottom) : 0), fs)}`]
    if (t) firstRules.push(`border-top: ${t}`)
    if (btm) lastRules.push(`border-bottom: ${btm}`)
    if (radius && radius !== '0px') {
      const [tl, tr, br, bl] = ['top-left', 'top-right', 'bottom-right', 'bottom-left'].map((c) => lengths(box.getPropertyValue(`border-${c}-radius`), fs))
      firstRules.push(`border-top-left-radius: ${tl}; border-top-right-radius: ${tr}`)
      lastRules.push(`border-bottom-right-radius: ${br}; border-bottom-left-radius: ${bl}`)
    }
    if (b.first !== b.all) {
      css.push(`${S} .cm-content .cm-line${b.first} { ${firstRules.join('; ')}; }`)
      css.push(`${S} .cm-content .cm-line${b.last} { ${lastRules.join('; ')}; }`)
    } else {
      css.push(`${S} .cm-content .cm-line${b.all} { ${[...firstRules, ...lastRules].join('; ')}; }`)
    }
    for (const which of ['::before', '::after']) {
      const rule = pseudo(textEl === node ? node : node, which, fs)
      if (rule) css.push(`${all}${which} { ${rule}; }`)
    }
  }

  // Block spacing: samples are laid out in pairs and measured, with margin collapsing included. Adjacent blocks use it as the later block's top padding; where a blank line separates them, the blank line is squeezed to this height.
  const types = Object.keys(BLOCKS)
  host.innerHTML = types.flatMap((a) => types.map((b) => BLOCKS[a].html + BLOCKS[b].html)).join('')
  const kids = [...host.children]
  let i = 0
  for (const a of types) {
    for (const b of types) {
      const top = kids[i * 2 + 1]
      const gap = Math.max(0, top.getBoundingClientRect().top - kids[i * 2].getBoundingClientRect().bottom)
      i++
      const A = BLOCKS[a]
      const B = BLOCKS[b]
      const fsB = sizes[b].fs
      const lineA = a === 'table' ? A.last : `.cm-line${A.last}`
      const lineB = b === 'table' ? B.first : `.cm-line${B.first}`
      const ownTop = b === 'table' ? 0 : sizes[b].pt
      if (b === 'table') css.push(`${S} .cm-content ${lineA} + ${lineB} { padding-top: ${em(gap, fsB)}; }`)
      else css.push(`${S} .cm-content ${lineA} + ${lineB} { padding-top: ${em(ownTop + gap, fsB)}; }`)
      css.push(`${S} .cm-content ${lineA} + .cm-line.nib-blank:has(+ ${lineB}) { height: ${em(gap, baseFs)}; line-height: ${em(gap, baseFs)}; font-size: 1em; }`)
    }
  }
  css.push(`${S} .cm-content .nib-table-wrap { padding-bottom: 0; }`)

  // Spacing between list items (themes often put vertical margins on li or li > p).
  host.innerHTML = '<ul><li class="md-list-item"><p>x</p></li><li class="md-list-item"><p>x</p></li></ul>'
  const [li1, li2] = host.querySelectorAll('li')
  const liGap = Math.max(0, li2.getBoundingClientRect().top - li1.getBoundingClientRect().bottom)
  const liP = li1.querySelector('p').getBoundingClientRect()
  const liInner = Math.max(0, liP.top - li1.getBoundingClientRect().top) + Math.max(0, li1.getBoundingClientRect().bottom - liP.bottom)
  css.push(`${S} .cm-content .cm-line.nib-li + .cm-line.nib-li { padding-top: ${em(liGap + liInner, sizes.list.fs)}; }`)

  // Inline: bold, italic, strikethrough, links, inline code.
  host.innerHTML = '<p><strong>s</strong><em>e</em><del>d</del><a href="#">l</a><code>c</code></p>'
  const p = host.firstChild
  const inline = (sel, el, extra = []) => {
    const cs = getComputedStyle(el)
    const fs = px(cs.fontSize)
    const rules = [...TEXT.filter((x) => x !== 'text-align').map((x) => `${x}: ${cs.getPropertyValue(x)}`), ...extra.map((x) => `${x}: ${lengths(cs.getPropertyValue(x), fs)}`)]
    css.push(`${S} .cm-content ${sel} { ${rules.join('; ')}; }`)
  }
  inline('.nib-strong', p.querySelector('strong'))
  inline('.nib-em', p.querySelector('em'))
  inline('.nib-del', p.querySelector('del'))
  inline('.nib-link', p.querySelector('a'), ['border-bottom'])
  const code = p.querySelector('code')
  const codeCs = getComputedStyle(code)
  inline('.nib-code', code, ['background-color', 'border-top', 'border-right', 'border-bottom', 'border-left', 'border-radius', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left'])
  css.push(`${S} .cm-content .nib-code { font-size: ${+(px(codeCs.fontSize) / px(pCs.fontSize)).toFixed(4)}em; }`)

  // Syntax colours in code blocks: themes colour by CodeMirror 5 class names; these are mapped to Nib's colour variables.
  host.innerHTML = BLOCKS.fence.html
  const colorOf = (cls) => {
    const el = host.querySelector(`.${cls}`)
    return el ? getComputedStyle(el).color : null
  }
  const vars = { keyword: 'cm-keyword', string: 'cm-string', comment: 'cm-comment', number: 'cm-number', type: 'cm-type', func: 'cm-def' }
  css.push(`${S} { ${Object.entries(vars).map(([k, cls]) => `--c-${k}: ${colorOf(cls)}`).join('; ')}; }`)

  // Thematic break.
  host.innerHTML = '<hr>'
  const hr = getComputedStyle(host.firstChild)
  const hrTop = border(hr, 'top', baseFs)
  const hrHeight = px(hr.height)
  css.push(`${S} .cm-content .nib-hr { height: ${hrHeight ? em(hrHeight, baseFs) : '0'}; background: ${isClear(hr.backgroundColor) ? 'transparent' : hr.backgroundColor}${hr.backgroundImage !== 'none' ? `; background-image: ${hr.backgroundImage}` : ''}; border-top: ${hrTop || 'none'}; }`)

  // Tables: header, cells, zebra background, outer border.
  host.innerHTML = BLOCKS.table.html
  const table = host.querySelector('table')
  const th = host.querySelector('th')
  const tds = host.querySelectorAll('td')
  const cell = (sel, el) => {
    const cs = getComputedStyle(el)
    const fs = px(cs.fontSize)
    const rules = textRules(cs, px(getComputedStyle(table).fontSize) || baseFs)
    rules.push(`background-color: ${cs.backgroundColor}`)
    for (const side of BOX_SIDES) {
      rules.push(`border-${side}: ${border(cs, side, fs) || 'none'}`)
      rules.push(`padding-${side}: ${em(px(cs.getPropertyValue(`padding-${side}`)), fs)}`)
    }
    css.push(`${S} .cm-content .nib-table-wrap ${sel} { ${rules.join('; ')}; }`)
  }
  const tcs = getComputedStyle(table)
  const tfs = px(tcs.fontSize)
  css.push(`${S} .cm-content .nib-table-wrap table { font-size: ${+(tfs / baseFs).toFixed(4)}em; width: 100%; border-collapse: ${tcs.borderCollapse}; border-spacing: ${tcs.borderSpacing}; ` +
    `border-radius: ${lengths(tcs.borderRadius, tfs)}; overflow: ${tcs.overflow === 'visible' ? 'visible' : 'hidden'}; ` +
    BOX_SIDES.map((s) => `border-${s}: ${border(tcs, s, tfs) || 'none'}`).join('; ') +
    `; background-color: ${tcs.backgroundColor}; box-shadow: ${tcs.boxShadow}; }`)
  cell('th', th)
  cell('td', tds[0])
  const even = getComputedStyle(tds[1]).backgroundColor
  const evenRow = getComputedStyle(tds[1].parentElement).backgroundColor
  const stripe = !isClear(even) ? even : evenRow
  if (!isClear(stripe)) css.push(`${S} .cm-content .nib-table-wrap tbody tr:nth-child(2n) td { background-color: ${stripe}; }`)
  const headRow = getComputedStyle(th.parentElement).backgroundColor
  if (!isClear(headRow)) css.push(`${S} .cm-content .nib-table-wrap thead tr { background-color: ${headRow}; }`)

  host.remove()
  return css.join('\n')
}
