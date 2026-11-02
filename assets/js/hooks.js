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
// In UTF-8 bytes, as the server measures it (FirestormWeb.Quote).
const MAX_SELECTION = 5000
const QuoteSelection = {
  mounted() {
    this.read = () => {
      const selection = window.getSelection()
      const body = document.getElementById(this.el.dataset.body)
      const inPost = selection && !selection.isCollapsed && body &&
        body.contains(selection.anchorNode) && body.contains(selection.focusNode)
      const text = inPost ? selection.toString().trim() : ""
      return new TextEncoder().encode(text).length <= MAX_SELECTION ? text : ""
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

// The post editor's attachments: files pasted into it (e.g. a screenshot)
// are uploaded like picked or dropped ones, to the LiveView upload named
// by `data-upload`. While files are dragged over it, it's highlighted
// (dropping is LiveView's own phx-drop-target). The server appends each
// upload's markdown to the body, but LiveView doesn't touch a focused
// textarea, so then this does the same ("attachment_added").
const PasteUpload = {
  mounted() {
    this.handleEvent("attachment_added", ({markdown}) => {
      const textarea = this.el.querySelector("textarea")
      if (!textarea || document.activeElement !== textarea) { return }
      textarea.value = textarea.value.trim() === "" ? markdown : `${textarea.value}\n\n${markdown}`
      textarea.dispatchEvent(new Event("input", {bubbles: true}))
    })
    this.el.addEventListener("paste", e => {
      const files = Array.from((e.clipboardData && e.clipboardData.files) || [])
      if (files.length > 0) {
        e.preventDefault()
        this.upload(this.el.dataset.upload, files)
      }
    })
    const highlight = on => ["ring-2", "ring-primary"].forEach(c => this.el.classList.toggle(c, on))
    this.el.addEventListener("dragover", () => highlight(true))
    this.el.addEventListener("dragleave", () => highlight(false))
    this.el.addEventListener("drop", () => highlight(false))
  },
}

// Plugin toolbar buttons above the post editor: each inserts its
// `data-insert` template at the caret of the textarea named by `data-target`,
// with `{{selection}}` replaced by the selected text, then fires an input
// event so the form's phx-change sees the new text.
const ComposerButtons = {
  mounted() {
    this.el.addEventListener("click", e => {
      const button = e.target.closest("button[data-insert]")
      const textarea = document.getElementById(this.el.dataset.target)
      if (!button || !textarea) { return }
      const {selectionStart: start, selectionEnd: end, value} = textarea
      const text = button.dataset.insert.split("{{selection}}").join(value.slice(start, end))
      textarea.value = value.slice(0, start) + text + value.slice(end)
      textarea.focus()
      textarea.setSelectionRange(start + text.length, start + text.length)
      textarea.dispatchEvent(new Event("input", {bubbles: true}))
    })
  },
}

// A plugin widget: a sandboxed iframe (no same-origin) talking to the page
// through postMessage only (see priv/plugins/sdk/widget.js). The page
// answers its "ready" with the viewer's public profile and the widget's
// context, resizes it on request (within bounds), and relays its calls to
// the plugin's server-side handler as a LiveView event.
const PluginWidget = {
  mounted() {
    this.frame = this.el.querySelector("iframe")
    this.onMessage = event => {
      const message = event.data || {}
      if (!this.frame || event.source !== this.frame.contentWindow || message.firefly !== 1) { return }
      const context = JSON.parse(this.el.dataset.context || "null")
      if (message.type === "ready") {
        this.send({type: "init", user: JSON.parse(this.el.dataset.user || "null"), context, plugin: this.el.dataset.plugin})
        this.el.dataset.ready = "true"
      } else if (message.type === "resize") {
        const height = Math.max(20, Math.min(2000, Math.round(Number(message.height) || 0)))
        this.frame.style.height = `${height}px`
        this.el.dataset.height = height
      } else if (message.type === "call") {
        const params = {plugin: this.el.dataset.plugin, handler: String(message.handler), args: message.args, context}
        this.pushEvent("plugin_widget_call", params, reply => this.send({...reply, type: "result", id: message.id}))
      }
    }
    window.addEventListener("message", this.onMessage)
  },
  destroyed() { window.removeEventListener("message", this.onMessage) },
  send(message) {
    // The frame's origin is opaque, so "*" is the only possible target; it
    // only ever gets public data.
    if (this.frame.contentWindow) { this.frame.contentWindow.postMessage({...message, firefly: 1}, "*") }
  },
}

export default {ComposerButtons, PasteUpload, PluginWidget, Highlight, LocalTime, MentionAutocomplete, QuoteSelection}
