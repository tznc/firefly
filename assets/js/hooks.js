import Prism from "prismjs"
import "prismjs/components/prism-elixir"
import "prismjs/components/prism-erlang"
import "prismjs/components/prism-haml"
import "prismjs/components/prism-css"
import "prismjs/components/prism-scss"
import "prismjs/plugins/line-numbers/prism-line-numbers"
import "prismjs/plugins/normalize-whitespace/prism-normalize-whitespace"

// Spoilers in rendered markdown (`.spoiler`, see FirestormWeb.Markdown):
// hidden until clicked, or activated with Enter or Space. Until then
// they're a button named "Spoiler" to assistive technology, so the hidden
// text isn't read out either.
const setUpSpoilers = root => {
  root.querySelectorAll(".spoiler:not([data-spoiler])").forEach(spoiler => {
    spoiler.dataset.spoiler = "hidden"
    spoiler.setAttribute("role", "button")
    spoiler.setAttribute("tabindex", "0")
    spoiler.setAttribute("aria-label", "Spoiler: activate to reveal")
    const reveal = e => {
      if (spoiler.dataset.spoiler !== "hidden") { return }
      e.preventDefault()
      spoiler.dataset.spoiler = "revealed"
      ;["role", "tabindex", "aria-label"].forEach(name => spoiler.removeAttribute(name))
    }
    spoiler.addEventListener("click", reveal)
    spoiler.addEventListener("keydown", e => { if (e.key === "Enter" || e.key === " ") { reveal(e) } })
  })
}

// Math in rendered markdown (`span[data-math-style]`, see
// FirestormWeb.Markdown), typeset with KaTeX, vendored in
// priv/static/vendor/katex and loaded the first time a page has math.
// Untrusted input: no \href, \url or HTML extensions, and errors show the
// source instead of throwing.
let katexLoading = null
const loadKatex = () => {
  katexLoading = katexLoading || new Promise((resolve, reject) => {
    const css = document.createElement("link")
    css.rel = "stylesheet"
    css.href = "/vendor/katex/katex.min.css"
    document.head.append(css)
    const script = document.createElement("script")
    script.src = "/vendor/katex/katex.min.js"
    script.onload = () => resolve(window.katex)
    script.onerror = () => { katexLoading = null; reject(new Error("KaTeX didn't load")) }
    document.head.append(script)
  })
  return katexLoading
}
const typesetMath = root => {
  const pending = root.querySelectorAll("[data-math-style]:not([data-math-rendered])")
  if (pending.length === 0) { return }
  loadKatex().then(katex => pending.forEach(el => {
    const tex = el.textContent
    katex.render(tex, el, {
      displayMode: el.dataset.mathStyle === "display",
      throwOnError: false,
      trust: false,
      maxSize: 20,
      maxExpand: 500,
    })
    el.dataset.mathRendered = "true"
    el.setAttribute("title", tex)
  })).catch(() => {})
}

// Syntax-highlight code blocks inside rendered markdown, typeset its math
// and set up its spoilers.
const renderMarkdown = el => {
  Prism.highlightAllUnder(el)
  typesetMath(el)
  setUpSpoilers(el)
}
const Highlight = {
  mounted() { renderMarkdown(this.el) },
  updated() { renderMarkdown(this.el) },
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

// Emoji for the editor: the standard set (gemoji, vendored at
// /vendor/emoji.json and fetched once, on first use) plus the site's custom
// emoji, given as JSON in a `data-custom-emoji` attribute. Standard emoji
// insert as the character, custom ones as `:name:` (the server renders those).
let standardEmoji = null
const loadEmoji = () => {
  standardEmoji = standardEmoji || fetch("/vendor/emoji.json")
    .then(response => response.json())
    .then(({emoji}) => emoji.map(([char, names, tags]) => ({char, name: names[0], names, tags})))
    .catch(() => { standardEmoji = null; return [] })
  return standardEmoji
}
const customEmoji = el => {
  try { return JSON.parse(el.dataset.customEmoji || "[]").map(({name, url}) => ({name, url, names: [name], tags: []})) }
  catch (_e) { return [] }
}
const emojiText = emoji => emoji.url ? `:${emoji.name}:` : emoji.char
const emojiMatches = (list, query) => {
  query = query.toLowerCase()
  // Exact names first, then the shortest names starting with the query.
  const rank = e => Math.min(...e.names.filter(n => n.startsWith(query)).map(n => n === query ? 0 : n.length))
  const starts = list.filter(e => e.names.some(n => n.startsWith(query))).sort((a, b) => rank(a) - rank(b))
  const contains = list.filter(e => !starts.includes(e) &&
    (e.names.some(n => n.includes(query)) || e.tags.some(t => t.startsWith(query))))
  return starts.concat(contains)
}
// The emoji's picture: the character, or the custom emoji's image.
const emojiNode = emoji => {
  if (!emoji.url) { return document.createTextNode(emoji.char) }
  const img = document.createElement("img")
  img.src = emoji.url
  img.alt = `:${emoji.name}:`
  img.className = "emoji"
  return img
}
// The emoji picked recently, newest first, remembered in this browser.
const RECENT_KEY = "firefly:recent-emoji"
const recentEmoji = () => {
  try { return JSON.parse(localStorage.getItem(RECENT_KEY) || "[]") } catch (_e) { return [] }
}
const rememberEmoji = emoji => {
  const recent = [emoji.name, ...recentEmoji().filter(name => name !== emoji.name)].slice(0, 24)
  try { localStorage.setItem(RECENT_KEY, JSON.stringify(recent)) } catch (_e) { /* private mode */ }
}
// Puts `text` at the caret of `textarea` and tells LiveView.
const insertAtCaret = (textarea, text) => {
  const {selectionStart: start, selectionEnd: end, value} = textarea
  textarea.value = value.slice(0, start) + text + value.slice(end)
  textarea.focus()
  textarea.setSelectionRange(start + text.length, start + text.length)
  textarea.dispatchEvent(new Event("input", {bubbles: true}))
}

// The editor's emoji picker: a button opening a searchable grid (recent
// emoji first); picking inserts at the caret of the textarea named by
// `data-target`. Escape or a click elsewhere closes it.
const EmojiPicker = {
  mounted() {
    this.button = this.el.querySelector("button[data-toggle]")
    this.panel = this.el.querySelector("[data-panel]")
    this.search = this.el.querySelector("input[type=search]")
    this.grid = this.el.querySelector("[data-grid]")
    this.button.addEventListener("click", () => this.panel.hidden ? this.open() : this.close())
    this.search.addEventListener("input", () => this.render())
    this.el.addEventListener("keydown", e => { if (e.key === "Escape") { this.close(); this.button.focus() } })
    this.outside = e => { if (!this.el.contains(e.target)) { this.close() } }
    document.addEventListener("click", this.outside)
  },
  destroyed() { document.removeEventListener("click", this.outside) },
  async open() {
    this.panel.hidden = false
    this.button.setAttribute("aria-expanded", "true")
    this.all = customEmoji(this.el).concat(await loadEmoji())
    this.search.value = ""
    this.render()
    this.search.focus()
  },
  close() {
    this.panel.hidden = true
    this.button.setAttribute("aria-expanded", "false")
  },
  render() {
    const query = this.search.value.trim().replace(/^:|:$/g, "")
    let shown
    if (query) {
      shown = emojiMatches(this.all, query)
    } else {
      const byName = new Map(this.all.map(e => [e.name, e]))
      const recent = recentEmoji().map(name => byName.get(name)).filter(Boolean)
      shown = recent.concat(this.all.filter(e => !recent.includes(e)))
    }
    this.grid.replaceChildren(...shown.slice(0, 400).map(emoji => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "btn btn-ghost btn-sm btn-square text-lg"
      button.title = `:${emoji.name}:`
      button.setAttribute("aria-label", emoji.name.replace(/_/g, " "))
      button.append(emojiNode(emoji))
      button.addEventListener("click", () => this.pick(emoji))
      return button
    }))
  },
  pick(emoji) {
    rememberEmoji(emoji)
    const textarea = document.getElementById(this.el.dataset.target)
    this.close()
    if (textarea) { insertAtCaret(textarea, emojiText(emoji)) }
  },
}

// Autocomplete for the post editor's textarea, in the menu named by
// `data-menu`: `@username` (typing `@` and a few characters asks the
// LiveView for matching users, "mention_search", see
// FirestormWeb.Web.Editor) and `:emoji` (after `:` and 2 characters,
// standard and custom emoji). Arrows move, Enter or Tab picks, Escape
// closes. Picking replaces the typed prefix and fires an input event so the
// form's phx-change sees the new text.
const MENTION_BEFORE_CARET = /(?:^|[^\w@#/&])@([A-Za-z0-9_-]{1,32})$/
const EMOJI_BEFORE_CARET = /(?:^|[\s(])(:[a-z0-9_+-]{2,32})$/
const MentionAutocomplete = {
  mounted() {
    this.menu = document.getElementById(this.el.dataset.menu)
    this.items = []
    this.active = 0
    this.el.addEventListener("input", () => this.search())
    this.el.addEventListener("keydown", e => this.keydown(e))
    this.el.addEventListener("blur", () => setTimeout(() => this.close(), 150))
  },
  // What's being typed before the caret: {kind, prefix, length} or null.
  typed() {
    const caret = this.el.selectionStart
    if (caret !== this.el.selectionEnd) { return null }
    const before = this.el.value.slice(0, caret)
    const mention = before.match(MENTION_BEFORE_CARET)
    if (mention) { return {kind: "mention", prefix: mention[1], length: mention[1].length} }
    const emoji = before.match(EMOJI_BEFORE_CARET)
    if (emoji) { return {kind: "emoji", prefix: emoji[1].slice(1), length: emoji[1].length} }
    return null
  },
  search() {
    const typed = this.typed()
    if (!typed) { return this.close() }
    const current = () => { const now = this.typed(); return now && now.kind === typed.kind && now.prefix === typed.prefix }
    if (typed.kind === "mention") {
      this.pushEvent("mention_search", {prefix: typed.prefix}, ({users}) => {
        // Ignore answers to a prefix the user has typed past.
        if (current()) { this.open(users.map(user => ({user}))) }
      })
    } else {
      loadEmoji().then(standard => {
        const found = emojiMatches(customEmoji(this.el).concat(standard), typed.prefix).slice(0, 8)
        if (current()) { this.open(found.map(emoji => ({emoji}))) }
      })
    }
  },
  open(items) {
    this.items = items
    this.active = 0
    if (items.length === 0) { return this.close() }
    this.render()
    this.menu.classList.remove("hidden")
  },
  close() {
    this.items = []
    this.menu.classList.add("hidden")
    this.menu.replaceChildren()
  },
  render() {
    this.menu.replaceChildren(...this.items.map((item, i) => {
      const button = document.createElement("button")
      button.type = "button"
      button.setAttribute("role", "option")
      button.setAttribute("aria-selected", i === this.active)
      button.classList.toggle("menu-active", i === this.active)
      const label = document.createElement("strong")
      const detail = document.createElement("span")
      detail.className = "text-base-content/60"
      if (item.user) {
        label.textContent = "@" + item.user.username
        detail.textContent = item.user.name && item.user.name !== item.user.username ? item.user.name : ""
      } else {
        label.append(emojiNode(item.emoji))
        detail.textContent = `:${item.emoji.name}:`
      }
      button.append(label, detail)
      // mousedown, not click: keep the textarea focused.
      button.addEventListener("mousedown", e => { e.preventDefault(); this.pick(item) })
      const li = document.createElement("li")
      li.append(button)
      return li
    }))
  },
  keydown(e) {
    if (this.items.length === 0) { return }
    const moves = {ArrowDown: 1, ArrowUp: -1}
    if (e.key in moves) {
      e.preventDefault()
      this.active = (this.active + moves[e.key] + this.items.length) % this.items.length
      this.render()
    } else if (e.key === "Enter" || e.key === "Tab") {
      e.preventDefault()
      this.pick(this.items[this.active])
    } else if (e.key === "Escape") {
      this.close()
    }
  },
  pick(item) {
    const typed = this.typed()
    if (!typed) { return this.close() }
    const caret = this.el.selectionStart
    const start = caret - typed.length
    let insert
    if (item.user) {
      insert = item.user.username + " "
    } else {
      rememberEmoji(item.emoji)
      insert = emojiText(item.emoji) + " "
    }
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

export default {ComposerButtons, EmojiPicker, PasteUpload, PluginWidget, Highlight, LocalTime, MentionAutocomplete, QuoteSelection}
