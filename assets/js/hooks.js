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

// `@username` autocomplete for the post editor's textarea. Typing `@` and a
// few characters asks the LiveView for matching users ("mention_search", see
// FirestormWeb.Web.Editor) and lists them in the menu named by `data-menu`;
// arrows move, Enter or Tab picks, Escape closes. Picking replaces the typed
// prefix and fires an input event so the form's phx-change sees the new text.
const MENTION_BEFORE_CARET = /(?:^|[^\w@#/&])@([A-Za-z0-9_-]{1,32})$/
const MentionAutocomplete = {
  mounted() {
    this.menu = document.getElementById(this.el.dataset.menu)
    this.users = []
    this.active = 0
    this.el.addEventListener("input", () => this.search())
    this.el.addEventListener("keydown", e => this.keydown(e))
    this.el.addEventListener("blur", () => setTimeout(() => this.close(), 150))
  },
  prefix() {
    const caret = this.el.selectionStart
    if (caret !== this.el.selectionEnd) { return null }
    const match = this.el.value.slice(0, caret).match(MENTION_BEFORE_CARET)
    return match && match[1]
  },
  search() {
    const prefix = this.prefix()
    if (!prefix) { return this.close() }
    this.pushEvent("mention_search", {prefix}, ({users}) => {
      // Ignore answers to a prefix the user has typed past.
      if (this.prefix() === prefix) { this.open(users) }
    })
  },
  open(users) {
    this.users = users
    this.active = 0
    if (users.length === 0) { return this.close() }
    this.render()
    this.menu.classList.remove("hidden")
  },
  close() {
    this.users = []
    this.menu.classList.add("hidden")
    this.menu.replaceChildren()
  },
  render() {
    this.menu.replaceChildren(...this.users.map((user, i) => {
      const button = document.createElement("button")
      button.type = "button"
      button.setAttribute("role", "option")
      button.setAttribute("aria-selected", i === this.active)
      button.classList.toggle("menu-active", i === this.active)
      const username = document.createElement("strong")
      username.textContent = "@" + user.username
      const name = document.createElement("span")
      name.className = "text-base-content/60"
      name.textContent = user.name && user.name !== user.username ? user.name : ""
      button.append(username, name)
      // mousedown, not click: keep the textarea focused.
      button.addEventListener("mousedown", e => { e.preventDefault(); this.pick(user) })
      const item = document.createElement("li")
      item.append(button)
      return item
    }))
  },
  keydown(e) {
    if (this.users.length === 0) { return }
    const moves = {ArrowDown: 1, ArrowUp: -1}
    if (e.key in moves) {
      e.preventDefault()
      this.active = (this.active + moves[e.key] + this.users.length) % this.users.length
      this.render()
    } else if (e.key === "Enter" || e.key === "Tab") {
      e.preventDefault()
      this.pick(this.users[this.active])
    } else if (e.key === "Escape") {
      this.close()
    }
  },
  pick(user) {
    const prefix = this.prefix()
    if (!prefix) { return this.close() }
    const caret = this.el.selectionStart
    const start = caret - prefix.length
    const insert = user.username + " "
    this.el.value = this.el.value.slice(0, start) + insert + this.el.value.slice(caret)
    this.el.selectionStart = this.el.selectionEnd = start + insert.length
    this.close()
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
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

export default {Highlight, LocalTime, MentionAutocomplete, QuoteSelection, Uploaders}
