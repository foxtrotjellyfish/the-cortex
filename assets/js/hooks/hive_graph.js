const SVG_NS = "http://www.w3.org/2000/svg"

function createSignalDot(layer, x1, y1, x2, y2, color, duration = 600) {
  const circle = document.createElementNS(SVG_NS, "circle")
  circle.setAttribute("r", "5")
  circle.setAttribute("fill", color)
  circle.setAttribute("cx", x1)
  circle.setAttribute("cy", y1)
  circle.style.filter = `drop-shadow(0 0 8px ${color})`
  layer.appendChild(circle)

  const trail = document.createElementNS(SVG_NS, "circle")
  trail.setAttribute("r", "3")
  trail.setAttribute("fill", color)
  trail.setAttribute("opacity", "0.4")
  trail.setAttribute("cx", x1)
  trail.setAttribute("cy", y1)
  trail.style.filter = `drop-shadow(0 0 4px ${color})`
  layer.appendChild(trail)

  const startTime = performance.now()

  function animate(currentTime) {
    const elapsed = currentTime - startTime
    const progress = Math.min(elapsed / duration, 1)
    const eased = 1 - Math.pow(1 - progress, 3)

    const cx = x1 + (x2 - x1) * eased
    const cy = y1 + (y2 - y1) * eased

    circle.setAttribute("cx", cx)
    circle.setAttribute("cy", cy)
    circle.setAttribute("opacity", 1 - progress * 0.2)

    const trailProgress = Math.max(0, (elapsed - 80) / duration)
    const trailEased = 1 - Math.pow(1 - Math.min(trailProgress, 1), 3)
    trail.setAttribute("cx", x1 + (x2 - x1) * trailEased)
    trail.setAttribute("cy", y1 + (y2 - y1) * trailEased)
    trail.setAttribute("opacity", 0.3 * (1 - progress))

    if (progress < 1) {
      requestAnimationFrame(animate)
    } else {
      circle.style.transition = "opacity 0.3s"
      circle.style.opacity = "0"
      trail.style.transition = "opacity 0.2s"
      trail.style.opacity = "0"
      setTimeout(() => { circle.remove(); trail.remove() }, 300)
    }
  }

  requestAnimationFrame(animate)
}

function createBurstEffect(layer, x, y, color, count = 6) {
  for (let i = 0; i < count; i++) {
    const angle = (2 * Math.PI * i) / count
    const dist = 30 + Math.random() * 20

    const dot = document.createElementNS(SVG_NS, "circle")
    dot.setAttribute("r", "2")
    dot.setAttribute("fill", color)
    dot.setAttribute("cx", x)
    dot.setAttribute("cy", y)
    dot.setAttribute("opacity", "0.8")
    dot.style.filter = `drop-shadow(0 0 4px ${color})`
    layer.appendChild(dot)

    const startTime = performance.now()
    const duration = 400 + Math.random() * 200

    function animate(currentTime) {
      const elapsed = currentTime - startTime
      const progress = Math.min(elapsed / duration, 1)
      const eased = 1 - Math.pow(1 - progress, 2)

      dot.setAttribute("cx", x + Math.cos(angle) * dist * eased)
      dot.setAttribute("cy", y + Math.sin(angle) * dist * eased)
      dot.setAttribute("opacity", 0.8 * (1 - progress))
      dot.setAttribute("r", 2 * (1 - progress * 0.5))

      if (progress < 1) {
        requestAnimationFrame(animate)
      } else {
        dot.remove()
      }
    }

    requestAnimationFrame(animate)
  }
}

function pulseNode(el) {
  el.classList.add("processing")
}

function unpulseNode(el) {
  el.classList.remove("processing")
}

export const HiveGraph = {
  mounted() {
    this.animationLayer = this.el.querySelector("#signal-animations")

    this.handleEvent("signal_routed", ({fromX, fromY, toX, toY, color}) => {
      if (this.animationLayer && fromX != null && toX != null) {
        createSignalDot(this.animationLayer, fromX, fromY, toX, toY, color)
      }
    })

    this.handleEvent("domain_spawned", ({name, x, y, color}) => {
      if (this.animationLayer && x != null && y != null) {
        createBurstEffect(this.animationLayer, x, y, color, 8)
      }
    })

    this.handleEvent("domain_processing", ({name}) => {
      const node = this.el.querySelector(`[data-domain="${name}"]`)
      if (node) pulseNode(node)
    })

    this.handleEvent("domain_completed", ({name, x, y, color}) => {
      const node = this.el.querySelector(`[data-domain="${name}"]`)
      if (node) {
        unpulseNode(node)
        node.classList.add("completed")
        setTimeout(() => node.classList.remove("completed"), 1200)
      }
      if (this.animationLayer && x != null && y != null) {
        const routerX = 400, routerY = 240
        createSignalDot(this.animationLayer, x, y, routerX, routerY, color, 400)
        setTimeout(() => {
          createSignalDot(this.animationLayer, routerX, routerY, 400, 490, "#6366f1", 400)
        }, 300)
      }
    })

    this.handleEvent("domain_crashed", ({name}) => {
      const node = this.el.querySelector(`[data-domain="${name}"]`)
      if (node) {
        unpulseNode(node)
        node.classList.add("crashed")
        setTimeout(() => node.classList.remove("crashed"), 2000)
      }
    })

    this.handleEvent("domain_restarted", ({name}) => {
      const node = this.el.querySelector(`[data-domain="${name}"]`)
      if (node) {
        node.classList.remove("crashed")
        node.classList.add("restarted")
        setTimeout(() => node.classList.remove("restarted"), 1500)
      }
    })
  }
}

export const ChatScroll = {
  mounted() {
    this.scrollToBottom()
  },
  updated() {
    this.scrollToBottom()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}
