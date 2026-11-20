// Simulated IME composition (pinyin "ni" -> 你) on the list line, as the browser would do it: composition events plus direct DOM text edits.
// Checks: composing flag on, other lines' decorations untouched during composition, final text right, cursor after the committed text.
const frame = () => new Promise((r) => requestAnimationFrame(() => r()))
const wait = (ms) => new Promise((r) => setTimeout(r, ms))
nib.setMode('edit')
const v = nib.view
v.focus()
const line = v.state.doc.line(5)
const pos = line.from + line.text.indexOf(' 尾巴')
v.dispatch({ selection: { anchor: pos } })
await frame(); await frame()
const other = () => v.contentDOM.querySelectorAll('.cm-line')[2].innerHTML
const before = other()
const { node, offset } = v.domAtPos(pos)
const text = node.nodeType === 3 ? node : node.childNodes[offset] || node.firstChild
const at = node.nodeType === 3 ? offset : 0
const dom = v.contentDOM
const out = []
dom.dispatchEvent(new CompositionEvent('compositionstart', { data: '' }))
text.insertData(at, 'n'); getSelection().collapse(text, at + 1); dom.dispatchEvent(new CompositionEvent('compositionupdate', { data: 'n' })); await frame()
text.insertData(at + 1, 'i'); getSelection().collapse(text, at + 2); dom.dispatchEvent(new CompositionEvent('compositionupdate', { data: 'ni' })); await frame()
out.push('composing=' + v.composing)
out.push('mid=' + JSON.stringify(v.state.doc.line(5).text))
out.push('otherLineStable=' + (other() === before))
text.replaceData(at, 2, '你'); getSelection().collapse(text, at + 1)
dom.dispatchEvent(new CompositionEvent('compositionupdate', { data: '你' }))
dom.dispatchEvent(new CompositionEvent('compositionend', { data: '你' }))
await wait(120); await frame()
out.push('composingAfter=' + v.composing)
out.push('final=' + JSON.stringify(v.state.doc.line(5).text))
out.push('cursorOK=' + (v.state.selection.main.head === pos + 1))
out.push('line3Hidden=' + !v.contentDOM.querySelectorAll('.cm-line')[2].textContent.includes('**'))
return out.join(' | ')
