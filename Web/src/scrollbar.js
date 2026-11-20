// macOS-style floating scrollbar: hidden normally, fades in on scroll or when the mouse nears the right edge, and fades out about 1 second after stopping; never appears when the content fits on one screen.
// WebKit's native scrollbar follows the system setting and becomes a permanent thick bar when a mouse is attached, so the native one is hidden and a custom one is drawn.

const PAD = 2 // gap between the thumb and the top/bottom edges
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

  // Dragging the thumb: converts the displacement while held into a scroll distance.
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

  // Clicking empty track: page in that direction, as the system does.
  bar.addEventListener('mousedown', (event) => {
    if (event.target !== bar) return
    event.preventDefault()
    const thumbTop = thumb.getBoundingClientRect().top
    const page = scroller.clientHeight * 0.9
    scroller.scrollBy({ top: event.clientY < thumbTop ? -page : page, behavior: 'smooth' })
  })

  // When content or window height changes, the thumb resizes with it, without becoming visible.
  new ResizeObserver(layout).observe(scroller)
  const content = scroller.querySelector('.cm-content')
  if (content) new ResizeObserver(layout).observe(content)
  layout()
  return { layout }
}
