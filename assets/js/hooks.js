import Prism from "prismjs"
import "prismjs/components/prism-elixir"
import "prismjs/components/prism-erlang"
import "prismjs/components/prism-haml"
import "prismjs/components/prism-css"
import "prismjs/components/prism-scss"
import "prismjs/plugins/line-numbers/prism-line-numbers"
import "prismjs/plugins/normalize-whitespace/prism-normalize-whitespace"

// Syntax-highlight code blocks inside rendered markdown.
const Highlight = {
  mounted() { Prism.highlightAllUnder(this.el) },
  updated() { Prism.highlightAllUnder(this.el) },
}

// Render an ISO 8601 UTC timestamp as relative time ("3 hours ago") in the
// viewer's locale. The server-rendered text stays as the fallback.
const UNITS = [
  ["year", 31536000], ["month", 2592000], ["week", 604800],
  ["day", 86400], ["hour", 3600], ["minute", 60], ["second", 1],
]
const relative = iso => {
  const seconds = (new Date(iso).getTime() - Date.now()) / 1000
  const rtf = new Intl.RelativeTimeFormat(undefined, {numeric: "auto"})
  for (const [unit, size] of UNITS) {
    if (Math.abs(seconds) >= size || unit === "second") {
      return rtf.format(Math.round(seconds / size), unit)
    }
  }
}
const LocalTime = {
  mounted() { this.render() },
  updated() { this.render() },
  render() {
    const iso = this.el.getAttribute("datetime")
    if (iso) { this.el.textContent = relative(iso) }
  },
}

// A post's "Quote" link: if the reader selected text inside that post, quote
// just the selection by passing it to the reply page as a param (the server
// checks it really is in the post). The selection is read on mousedown,
// before the click collapses it, and the link's href is set before
// LiveView's own click handler navigates.
const MAX_SELECTION = 5000
const QuoteSelection = {
  mounted() {
    this.read = () => {
      const selection = window.getSelection()
      const body = document.getElementById(this.el.dataset.body)
      const inPost = selection && !selection.isCollapsed && body &&
        body.contains(selection.anchorNode) && body.contains(selection.focusNode)
      const text = inPost ? selection.toString().trim() : ""
      return text.length <= MAX_SELECTION ? text : ""
    }
    this.el.addEventListener("mousedown", () => { this.selected = this.read() })
    this.el.addEventListener("click", () => {
      const text = this.selected ?? this.read()
      this.selected = undefined
      const url = new URL(this.el.dataset.href, window.location.origin)
      if (text) { url.searchParams.set("selection", text) }
      this.el.setAttribute("href", url.pathname + url.search)
    })
  },
}

// Upload directly from the browser to S3 with a presigned POST policy.
const Uploaders = {
  S3(entries, onViewError) {
    entries.forEach(entry => {
      const {url, fields} = entry.meta
      const formData = new FormData()
      Object.entries(fields).forEach(([key, val]) => formData.append(key, val))
      formData.append("file", entry.file)

      const xhr = new XMLHttpRequest()
      onViewError(() => xhr.abort())
      xhr.onload = () => (xhr.status >= 200 && xhr.status < 300) ? entry.progress(100) : entry.error()
      xhr.onerror = () => entry.error()
      xhr.upload.addEventListener("progress", event => {
        if (event.lengthComputable) {
          const percent = Math.round((event.loaded / event.total) * 100)
          if (percent < 100) { entry.progress(percent) }
        }
      })
      xhr.open("POST", url, true)
      xhr.send(formData)
    })
  },
}

export default {Highlight, LocalTime, QuoteSelection, Uploaders}
