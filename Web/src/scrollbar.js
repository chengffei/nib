// 仿 macOS 浮动滚动条：平时不显示，滚动或鼠标移到右边缘时淡入，停下约 1 秒后淡出；内容不够一屏时永远不出现。
// WebKit 自带的滚动条跟随系统设置，接了鼠标就变成常驻的粗条，所以藏掉原生的，自己画一条。

const PAD = 2 // 滑块离上下边的距离
const MIN_THUMB = 32
const HIDE_AFTER = 1000

export function attachScrollbar(scroller) {
  const bar = document.createElement('div')
  bar.className = 'nib-scrollbar'
  const thumb = document.createElement('div')
  thumb.className = 'nib-scrollbar-thumb'
  bar.appendChild(thumb)
  document.body.appendChild(bar)

  let hideTimer = null
  let dragging = null
  let hovering = false

  const metrics = () => {
    const total = scroller.scrollHeight
    const visible = scroller.clientHeight
    const track = bar.clientHeight - PAD * 2
    const size = Math.max(MIN_THUMB, Math.round(track * visible / total))
    return { total, visible, track, size, range: Math.max(1, total - visible) }
  }

  const scrollable = () => scroller.scrollHeight > scroller.clientHeight + 1

  const layout = () => {
    if (!scrollable()) {
      bar.classList.remove('visible')
      bar.hidden = true
      return
    }
    bar.hidden = false
    const m = metrics()
    const top = PAD + Math.round((m.track - m.size) * scroller.scrollTop / m.range)
    thumb.style.height = `${m.size}px`
    thumb.style.transform = `translateY(${top}px)`
  }

  const show = () => {
    if (!scrollable()) return
    bar.classList.add('visible')
    clearTimeout(hideTimer)
    hideTimer = setTimeout(() => {
      if (!hovering && !dragging) bar.classList.remove('visible')
    }, HIDE_AFTER)
  }

  scroller.addEventListener('scroll', () => {
    layout()
    show()
  }, { passive: true })

  bar.addEventListener('mouseenter', () => {
    hovering = true
    bar.classList.add('hover')
    show()
  })
  bar.addEventListener('mouseleave', () => {
    hovering = false
    bar.classList.remove('hover')
    show()
  })

  // 拖滑块：按住时的位移换算成滚动距离。
  thumb.addEventListener('mousedown', (event) => {
    event.preventDefault()
    event.stopPropagation()
    dragging = { y: event.clientY, top: scroller.scrollTop }
    bar.classList.add('dragging')
  })
  window.addEventListener('mousemove', (event) => {
    if (!dragging) return
    const m = metrics()
    const ratio = m.range / Math.max(1, m.track - m.size)
    scroller.scrollTop = dragging.top + (event.clientY - dragging.y) * ratio
  })
  window.addEventListener('mouseup', () => {
    if (!dragging) return
    dragging = null
    bar.classList.remove('dragging')
    show()
  })

  // 点轨道空白处：朝那个方向翻一页，和系统一致。
  bar.addEventListener('mousedown', (event) => {
    if (event.target !== bar) return
    event.preventDefault()
    const thumbTop = thumb.getBoundingClientRect().top
    const page = scroller.clientHeight * 0.9
    scroller.scrollBy({ top: event.clientY < thumbTop ? -page : page, behavior: 'smooth' })
  })

  // 内容或窗口高度变了，滑块大小跟着变；不因此显示出来。
  new ResizeObserver(layout).observe(scroller)
  const content = scroller.querySelector('.cm-content')
  if (content) new ResizeObserver(layout).observe(content)
  layout()
  return { layout }
}
