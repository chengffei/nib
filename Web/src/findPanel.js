// 查找条：照 macOS 的样子重做（TextEdit / Safari 的查找栏）。
// 左边带放大镜的圆角搜索框和「第几个 / 共几个」，接着上一个 / 下一个箭头和三个选项开关，最右边「完成」。
// 可编辑时第二行是替换。CodeMirror 自带的那条是网页按钮和复选框，和系统控件对不上。

import {
  SearchQuery, closeSearchPanel, findNext, findPrevious, getSearchQuery, replaceAll, replaceNext, setSearchQuery,
} from '@codemirror/search'

const ICONS = {
  search: '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><circle cx="6.8" cy="6.8" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M10.2 10.2 14 14" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  prev: '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M10 3 5 8l5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  next: '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="m6 3 5 5-5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
}

const MAX_COUNT = 9999

function el(tag, props = {}, children = []) {
  const node = document.createElement(tag)
  Object.assign(node, props)
  for (const child of children) node.append(child)
  return node
}

function iconButton(icon, label, onClick) {
  const button = el('button', { type: 'button', className: 'nib-find-icon', title: label, innerHTML: icon })
  button.setAttribute('aria-label', label)
  button.addEventListener('mousedown', (event) => event.preventDefault())
  button.addEventListener('click', onClick)
  return button
}

function toggle(text, label, onChange) {
  const button = el('button', { type: 'button', className: 'nib-find-toggle', textContent: text, title: label })
  button.setAttribute('aria-label', label)
  button.setAttribute('aria-pressed', 'false')
  button.addEventListener('mousedown', (event) => event.preventDefault())
  button.addEventListener('click', () => {
    const on = button.getAttribute('aria-pressed') !== 'true'
    button.setAttribute('aria-pressed', String(on))
    onChange()
  })
  return button
}

function textButton(text, onClick) {
  const button = el('button', { type: 'button', className: 'nib-find-button', textContent: text })
  button.addEventListener('click', onClick)
  return button
}

export function createFindPanel(view) {
  const p = (phrase, ...insert) => view.state.phrase(phrase, ...insert)
  let query = getSearchQuery(view.state)

  const field = el('input', { type: 'text', className: 'nib-find-input', placeholder: p('Find'), value: query.search })
  field.setAttribute('main-field', 'true')
  field.setAttribute('aria-label', p('Find'))
  const count = el('span', { className: 'nib-find-count' })
  const searchBox = el('label', { className: 'nib-find-field' }, [
    el('span', { className: 'nib-find-glass', innerHTML: ICONS.search }), field, count,
  ])

  const caseToggle = toggle('Aa', p('match case'), commit)
  const wordToggle = toggle('W', p('by word'), commit)
  const regexToggle = toggle('.*', p('regexp'), commit)
  caseToggle.setAttribute('aria-pressed', String(query.caseSensitive))
  wordToggle.setAttribute('aria-pressed', String(query.wholeWord))
  regexToggle.setAttribute('aria-pressed', String(query.regexp))

  const done = textButton(p('Done'), () => closeSearchPanel(view))
  done.classList.add('nib-find-done')

  const row = el('div', { className: 'nib-find-row' }, [
    searchBox,
    el('span', { className: 'nib-find-segment' }, [
      iconButton(ICONS.prev, p('previous'), () => findPrevious(view)),
      iconButton(ICONS.next, p('next'), () => findNext(view)),
    ]),
    el('span', { className: 'nib-find-segment' }, [caseToggle, wordToggle, regexToggle]),
    el('span', { className: 'nib-find-spacer' }),
    done,
  ])

  const replaceField = el('input', { type: 'text', className: 'nib-find-input', placeholder: p('Replace'), value: query.replace })
  replaceField.setAttribute('aria-label', p('Replace'))
  const replaceRow = el('div', { className: 'nib-find-row nib-find-replace' }, [
    el('label', { className: 'nib-find-field' }, [replaceField]),
    textButton(p('replace'), () => replaceNext(view)),
    textButton(p('replace all'), () => replaceAll(view)),
  ])

  const dom = el('div', { className: 'nib-find' }, [row, replaceRow])

  function commit() {
    const next = new SearchQuery({
      search: field.value,
      replace: replaceField.value,
      caseSensitive: caseToggle.getAttribute('aria-pressed') === 'true',
      wholeWord: wordToggle.getAttribute('aria-pressed') === 'true',
      regexp: regexToggle.getAttribute('aria-pressed') === 'true',
    })
    if (!next.eq(query)) {
      query = next
      view.dispatch({ effects: setSearchQuery.of(next) })
    }
  }

  // 「第几个 / 共几个」。数到上限就停，大文档里不卡。
  function updateCount() {
    if (!query.search || !query.valid) {
      count.textContent = ''
      searchBox.classList.toggle('nib-find-invalid', !!query.search && !query.valid)
      return
    }
    searchBox.classList.remove('nib-find-invalid')
    const selection = view.state.selection.main
    const cursor = query.getCursor(view.state)
    let total = 0
    let current = 0
    for (let match = cursor.next(); !match.done; match = cursor.next()) {
      total++
      if (match.value.from === selection.from && match.value.to === selection.to) current = total
      if (total >= MAX_COUNT) break
    }
    count.textContent = total === 0 ? p('No results') : current ? p('$1 of $2', current, total) : String(total)
  }

  function syncMode() {
    replaceRow.hidden = view.state.readOnly
  }

  for (const input of [field, replaceField]) {
    input.addEventListener('input', commit)
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        closeSearchPanel(view)
      } else if (event.key === 'Enter' && input === field) {
        event.preventDefault()
        ;(event.shiftKey ? findPrevious : findNext)(view)
      } else if (event.key === 'Enter' && input === replaceField) {
        event.preventDefault()
        replaceNext(view)
      }
    })
  }

  syncMode()
  updateCount()
  return {
    dom,
    top: true,
    mount() {
      field.select()
    },
    update(update) {
      for (const tr of update.transactions) {
        for (const effect of tr.effects) {
          if (effect.is(setSearchQuery) && !effect.value.eq(query)) {
            query = effect.value
            field.value = query.search
            replaceField.value = query.replace
            caseToggle.setAttribute('aria-pressed', String(query.caseSensitive))
            wordToggle.setAttribute('aria-pressed', String(query.wholeWord))
            regexToggle.setAttribute('aria-pressed', String(query.regexp))
          }
        }
      }
      syncMode()
      if (update.docChanged || update.selectionSet || update.transactions.some((tr) => tr.effects.length)) updateCount()
    },
  }
}
