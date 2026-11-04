import Prism from "prismjs"
import "prismjs/components/prism-elixir"
import "prismjs/components/prism-erlang"
import "prismjs/components/prism-haml"
import "prismjs/components/prism-css"
import "prismjs/components/prism-scss"
import "prismjs/plugins/line-numbers/prism-line-numbers"
import "prismjs/plugins/normalize-whitespace/prism-normalize-whitespace"

// Spoilers in rendered markdown (`.spoiler`, see Firefly.Markdown):
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
// Firefly.Markdown), typeset with KaTeX, vendored in
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

// A post's outbound links: the click count next to each (data-clicks, by
// href), and, when data-post-id is set, a beacon to count a click (no
// redirect: the link stays as written). The server only counts links the
// post has.
const outbound = a => a.host && a.host !== window.location.host && /^https?:$/.test(a.protocol)
const trackLinks = el => {
  const counts = el.dataset.clicks ? JSON.parse(el.dataset.clicks) : {}
  el.querySelectorAll("a[href]").forEach(a => {
    if (!outbound(a)) { return }
    const href = a.getAttribute("href")
    const count = counts[href]
    if (count && !(a.nextElementSibling && a.nextElementSibling.classList.contains("link-clicks"))) {
      const badge = document.createElement("span")
      badge.className = "link-clicks badge badge-ghost badge-xs ml-1 align-middle"
      badge.textContent = count >= 1000 ? `${(count / 1000).toFixed(1)}k` : String(count)
      badge.title = `${count} ${count === 1 ? "click" : "clicks"}`
      a.after(badge)
    }
  })
  if (el.dataset.postId && !el.dataset.tracking) {
    el.dataset.tracking = "true"
    el.addEventListener("click", event => {
      const a = event.target.closest("a[href]")
      if (!a || !outbound(a) || !navigator.sendBeacon) { return }
      const body = new URLSearchParams({post_id: el.dataset.postId, url: a.getAttribute("href")})
      navigator.sendBeacon("/analytics/click", body)
    })
  }
}

// Syntax-highlight code blocks inside rendered markdown, typeset its math,
// set up its spoilers and its links' click counts.
const renderMarkdown = el => {
  Prism.highlightAllUnder(el)
  typesetMath(el)
  setUpSpoilers(el)
  trackLinks(el)
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
// In UTF-8 bytes, as the server measures it (Firefly.Quote).
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
// FireflyWeb.Editor) and `:emoji` (after `:` and 2 characters,
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

// The chat composer (see FireflyWeb.ChatComponents): the editor's
// autocomplete, plus Enter to send (Shift+Enter for a new line; Enter
// still picks a suggestion while the menu is open), a "typing" event at
// most every 2 seconds while typing (`data-thread` says where), and
// clearing once the server says the message went ("chat_sent"): LiveView
// leaves a focused textarea's value alone.
const ChatComposer = {
  ...MentionAutocomplete,
  mounted() {
    MentionAutocomplete.mounted.call(this)
    this.lastTyping = 0
    this.el.addEventListener("keydown", e => {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing || e.defaultPrevented) { return }
      e.preventDefault()
      if (this.el.value.trim() !== "") { this.el.form.requestSubmit() }
    })
    this.el.addEventListener("input", () => {
      const now = Date.now()
      if (now - this.lastTyping > 2000 && this.el.value.trim() !== "") {
        this.lastTyping = now
        this.pushEvent("typing", {thread: this.el.dataset.thread || null})
      }
    })
    this.handleEvent("chat_sent", ({form}) => {
      if (this.el.form && this.el.form.id === form) { this.el.value = ""; this.lastTyping = 0 }
    })
  },
}

// The chat's message list: stays at the bottom as messages arrive (unless
// scrolled up), keeps its place when older messages are added above, asks
// for older ones ("load_older") near the top while `data-has-more`, and
// on opening a channel ("chat_opened") shows `focus` (the new-messages
// divider or a message linked to) or the bottom.
const ChatScroll = {
  mounted() {
    this.atBottom = true
    this.lastHeight = this.el.scrollHeight
    this.el.addEventListener("scroll", () => {
      this.atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
      if (this.el.scrollTop < 60 && this.el.dataset.hasMore === "true" && !this.loading) {
        this.loading = true
        this.pushEvent("load_older", {}, () => { this.loading = false })
      }
    })
    this.observer = new MutationObserver(() => {
      const added = this.el.scrollHeight - this.lastHeight
      if (this.atBottom) { this.el.scrollTop = this.el.scrollHeight }
      else if (this.el.scrollTop < 60 && added > 0) { this.el.scrollTop += added }
      this.lastHeight = this.el.scrollHeight
    })
    this.observer.observe(this.el, {childList: true, subtree: true})
    this.handleEvent("chat_opened", ({focus}) => requestAnimationFrame(() => this.show(focus)))
    this.show(this.el.dataset.focus)
  },
  destroyed() { this.observer.disconnect() },
  show(focus) {
    const target = focus && document.getElementById(focus)
    if (target) {
      target.scrollIntoView({block: "center"})
      this.atBottom = false
    } else {
      this.el.scrollTop = this.el.scrollHeight
      this.atBottom = true
    }
    this.lastHeight = this.el.scrollHeight
  },
}

// The chat's emoji picker for reactions: one for the page, opened by a
// message's "More reactions" button (a "chat:react" event with the
// message's id); picking reacts ("react").
const ReactionPicker = {
  ...EmojiPicker,
  mounted() {
    EmojiPicker.mounted.call(this)
    // Opened after the click that asked for it, which would close it.
    this.el.addEventListener("chat:react", e => {
      this.messageId = e.detail.id
      setTimeout(() => this.open(), 0)
    })
  },
  pick(emoji) {
    rememberEmoji(emoji)
    this.close()
    if (this.messageId) { this.pushEvent("react", {id: String(this.messageId), emoji: emojiText(emoji)}) }
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
// the plugin's server-side handler and its storage requests (the viewer's
// own data) as LiveView events.
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
      } else if (message.type === "storage") {
        // Only these fields go on: whose data it is is the server's call.
        const params = {plugin: this.el.dataset.plugin, op: String(message.op), key: message.key, value: message.value, prefix: message.prefix}
        this.pushEvent("plugin_widget_storage", params, reply => this.send({...reply, type: "result", id: message.id}))
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

// WebAuthn: binary fields travel as unpadded base64url (see Firefly.WebAuthn).
const fromB64url = text => {
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/")
  return Uint8Array.from(atob(base64 + "===".slice((base64.length + 3) % 4)), c => c.charCodeAt(0)).buffer
}
const toB64url = buffer =>
  btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const withCredentialIds = list => (list || []).map(c => ({...c, id: fromB64url(c.id)}))

// The browser's answer to navigator.credentials.get, as the server reads it.
const assertionParams = credential => ({
  id: toB64url(credential.rawId),
  authenticator_data: toB64url(credential.response.authenticatorData),
  signature: toB64url(credential.response.signature),
  client_data_json: toB64url(credential.response.clientDataJSON),
  user_handle: credential.response.userHandle ? toB64url(credential.response.userHandle) : "",
})

const requestOptions = options => ({
  ...options,
  challenge: fromB64url(options.challenge),
  allowCredentials: withCredentialIds(options.allowCredentials),
})

// Logging in with a security key (second factor): asks the browser to sign
// the challenge in data-options, then posts the answer with the hook's form.
const SecurityKeyLogin = {
  mounted() {
    this.el.addEventListener("click", async () => {
      try {
        const options = JSON.parse(this.el.dataset.options)
        const credential = await navigator.credentials.get({publicKey: requestOptions(options)})
        const params = assertionParams(credential)
        this.el.form.querySelectorAll("input[data-field]").forEach(input => { input.value = params[input.dataset.field] })
        this.el.form.submit()
      } catch (_error) {
        this.el.dataset.error = "true"
      }
    })
  },
}

// Registering a security key from the settings: the server makes the
// options (security_key_options), the browser makes the credential, the
// server checks and saves it (security_key_register) under the name typed
// in the input data-name-input points to.
const SecurityKeyRegister = {
  mounted() {
    this.el.addEventListener("click", () => {
      this.pushEvent(this.el.dataset.optionsEvent || "security_key_options", {}, async ({options}) => {
        try {
          const publicKey = {
            ...options,
            challenge: fromB64url(options.challenge),
            user: {...options.user, id: fromB64url(options.user.id)},
            excludeCredentials: withCredentialIds(options.excludeCredentials),
          }
          const credential = await navigator.credentials.create({publicKey})
          const name = document.getElementById(this.el.dataset.nameInput)
          this.pushEvent(this.el.dataset.registerEvent || "security_key_register", {
            name: name ? name.value : "",
            attestation_object: toB64url(credential.response.attestationObject),
            client_data_json: toB64url(credential.response.clientDataJSON),
          })
        } catch (_error) {
          this.pushEvent("security_key_error", {})
        }
      })
    })
  },
}

// Logging in with a passkey: the button asks the browser for one; with
// data-conditional="true" the browser also offers passkeys in the username
// field's autofill, where it can. Each attempt gets a fresh challenge from
// data-challenge-url (kept in the session), and the answer is posted with
// the hook's form.
const PasskeyLogin = {
  mounted() {
    if (!window.PublicKeyCredential) { this.el.hidden = true; return }
    this.el.addEventListener("click", () => this.start(undefined))
    const conditional = PublicKeyCredential.isConditionalMediationAvailable
    if (this.el.dataset.conditional === "true" && conditional) {
      conditional.call(PublicKeyCredential).then(available => available && this.start("conditional"))
    }
  },
  destroyed() { if (this.abort) { this.abort.abort() } },
  async start(mediation) {
    if (this.abort) { this.abort.abort() }
    const abort = this.abort = new AbortController()
    try {
      const response = await fetch(this.el.dataset.challengeUrl, {credentials: "same-origin"})
      if (!response.ok) { return }
      const options = await response.json()
      const credential = await navigator.credentials.get({publicKey: requestOptions(options), mediation, signal: abort.signal})
      const params = assertionParams(credential)
      this.el.form.querySelectorAll("input[data-field]").forEach(input => { input.value = params[input.dataset.field] })
      this.el.form.submit()
    } catch (_error) {
      // Cancelled, or replaced by a newer attempt: nothing to do.
    }
  },
}

// Browser push notifications (Settings > Notifications): reports whether this
// browser is subscribed (`push_state`), and turns pushes on or off for it
// from the buttons inside (data-push="on"/"off"), with the site's VAPID key
// from data-public-key. The service worker (/service-worker.js) shows them.
const base64UrlBytes = text => {
  const padded = (text + "=".repeat((4 - text.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/")
  return Uint8Array.from(atob(padded), c => c.charCodeAt(0))
}

const PushNotifications = {
  async mounted() {
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
      this.pushEvent("push_state", {state: "unsupported"})
      return
    }
    this.el.addEventListener("click", event => {
      const button = event.target.closest("[data-push]")
      if (button) { button.dataset.push === "on" ? this.subscribe() : this.unsubscribe() }
    })
    const registration = await navigator.serviceWorker.register("/service-worker.js")
    const subscription = await registration.pushManager.getSubscription()
    this.report(subscription)
  },
  report(subscription) {
    const denied = window.Notification && Notification.permission === "denied"
    const state = subscription ? "on" : (denied ? "denied" : "off")
    this.pushEvent("push_state", {state, endpoint: subscription && subscription.endpoint})
  },
  async subscribe() {
    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: base64UrlBytes(this.el.dataset.publicKey),
      })
      this.pushEvent("push_subscribe", {subscription: subscription.toJSON(), user_agent: navigator.userAgent})
      this.report(subscription)
    } catch (_error) {
      // Permission refused or no push service: say so.
      this.report(null)
    }
  },
  async unsubscribe() {
    const registration = await navigator.serviceWorker.ready
    const subscription = await registration.pushManager.getSubscription()
    if (subscription) {
      this.pushEvent("push_unsubscribe", {endpoint: subscription.endpoint})
      await subscription.unsubscribe()
    }
    this.report(null)
  },
}


// Keyboard shortcuts, like Discourse's: "?" opens the help, j/k move
// through the topics or posts on the page (whatever carries
// data-shortcut-item), g then a letter goes somewhere, and r/l/b act on
// the item in hand through its data-shortcut buttons. Typing in a field
// is never intercepted, and a member can turn the whole thing off (see
// their interface settings, which sets data-shortcuts="false").
const SHORTCUT_PATHS = {h: "/", l: "/", n: "/new", u: "/unread", t: "/top", c: "/categories", b: "/bookmarks", m: "/messages", p: "/chat"}
const TYPING = /^(input|textarea|select)$/i

const typing = target =>
  TYPING.test(target.tagName) || target.isContentEditable || target.closest("[contenteditable='true']")

const KeyboardShortcuts = {
  mounted() {
    this.index = -1
    this.pending = null
    this.onKeyDown = event => this.handle(event)
    window.addEventListener("keydown", this.onKeyDown)
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown)
  },
  enabled() {
    return this.el.dataset.shortcuts !== "false"
  },
  items() {
    return Array.from(document.querySelectorAll("[data-shortcut-item]"))
  },
  handle(event) {
    if (!this.enabled() || event.metaKey || event.ctrlKey || event.altKey) { return }
    if (typing(event.target)) { return }

    const key = event.key
    if (this.pending === "g") {
      this.pending = null
      const path = SHORTCUT_PATHS[key.toLowerCase()]
      if (path) { event.preventDefault(); window.location.assign(path) }
      return
    }

    switch (key) {
      case "?":
        event.preventDefault()
        this.help()
        break
      case "j":
        event.preventDefault()
        this.move(1)
        break
      case "k":
        event.preventDefault()
        this.move(-1)
        break
      case "g":
        this.pending = "g"
        break
      case "/":
        event.preventDefault()
        this.search()
        break
      case "r":
      case "l":
      case "b":
        if (this.act({r: "reply", l: "like", b: "bookmark"}[key])) { event.preventDefault() }
        break
      case "Escape":
        this.close()
        break
    }
  },
  move(step) {
    const items = this.items()
    if (!items.length) { return }
    this.index = Math.min(Math.max(this.index + step, 0), items.length - 1)
    const item = items[this.index]
    if (!item.hasAttribute("tabindex")) { item.setAttribute("tabindex", "-1") }
    item.focus({preventScroll: true})
    item.scrollIntoView({block: "center", behavior: "smooth"})
  },
  // The button on the item in hand, else the page's own (a thread's reply
  // button, say). Returns whether anything was clicked.
  act(name) {
    const items = this.items()
    const current = items[this.index] || document.activeElement.closest("[data-shortcut-item]")
    const button = (current || document).querySelector(`[data-shortcut="${name}"]`) ||
      document.querySelector(`[data-shortcut="${name}"]`)
    if (!button) { return false }
    button.click()
    return true
  },
  search() {
    const field = document.querySelector("input[type='search']")
    if (field) { field.focus() } else { window.location.assign("/search") }
  },
  help() {
    const dialog = document.getElementById("shortcuts-help")
    if (!dialog) { return }
    dialog.open ? dialog.close() : dialog.showModal()
  },
  close() {
    const dialog = document.getElementById("shortcuts-help")
    if (dialog && dialog.open) { dialog.close() }
  },
}

// Reorderable nested lists (the categories admin): drag a row by its
// handle (native HTML5 drag and drop), or focus the handle, press Space to
// pick the row up, the arrow keys to move it and Space to drop it (Escape
// cancels). Rows are `[data-sortable-item]` with `data-id` and
// `data-label`, inside `[data-sortable-list]`s with `data-parent` ("" for
// the top level); an item with `data-has-children="true"` stays top-level.
// The move shows at once; the server gets `data-event` with
// {id, parent_id, index} and the row goes back if it replies without ok.
// What's announced (to the `[data-sortable-status]` live region) comes
// translated from the `data-msg-*` attributes.
const fill = (template, values) =>
  (template || "").replace(/%\{(\w+)\}/g, (_, key) => String(values[key] ?? ""))

const Sortable = {
  mounted() {
    this.el.addEventListener("dragstart", e => this.dragStart(e))
    this.el.addEventListener("dragover", e => this.dragOver(e))
    this.el.addEventListener("drop", e => this.drop(e))
    this.el.addEventListener("dragend", () => this.dragEnd())
    this.el.addEventListener("keydown", e => this.keydown(e))
  },
  item(node) { return node && node.closest("[data-sortable-item]") },
  items(list) { return [...list.children].filter(child => child.matches("[data-sortable-item]")) },
  handle(item) {
    return [...item.querySelectorAll("[data-sortable-handle]")].find(h => this.item(h) === item)
  },
  sublist(item) {
    return [...item.querySelectorAll("[data-sortable-list]")].find(l => this.item(l) === item)
  },
  // Where an item may go: anywhere at the top; into another item's
  // sublist only if it has no subcategories itself.
  allowed(item, list) {
    return !item.contains(list) && (list.dataset.parent === "" || item.dataset.hasChildren !== "true")
  },
  place(item) {
    const list = item.parentElement
    return {list, next: item.nextElementSibling}
  },
  where(item) {
    const list = item.parentElement
    const items = this.items(list)
    return {
      item: item.dataset.label,
      position: items.indexOf(item) + 1,
      count: items.length,
      parent: list.dataset.parentLabel || "",
    }
  },
  announce(message, item) {
    const status = this.el.querySelector("[data-sortable-status]")
    if (status) { status.textContent = fill(this.el.dataset[message], this.where(item)) }
  },
  moved(item, from) {
    const {list, next} = this.place(item)
    return list !== from.list || next !== from.next
  },
  restore(item, from) { from.list.insertBefore(item, from.next) },
  // Sends the move; puts the row back if the server refuses it.
  commit(item, from) {
    if (!this.moved(item, from)) { return }
    const list = item.parentElement
    const payload = {
      id: Number(item.dataset.id),
      parent_id: list.dataset.parent === "" ? null : Number(list.dataset.parent),
      index: this.items(list).indexOf(item),
    }
    this.pushEvent(this.el.dataset.event, payload, reply => {
      if (reply && reply.ok) { return }
      this.restore(item, from)
      this.announce("msgFailed", item)
    })
  },

  dragStart(e) {
    const handle = e.target.closest && e.target.closest("[data-sortable-handle]")
    if (!handle) { return }
    const item = this.item(handle)
    this.dragging = {item, from: this.place(item), dropped: false}
    e.dataTransfer.effectAllowed = "move"
    e.dataTransfer.setData("text/plain", item.dataset.label)
    e.dataTransfer.setDragImage(item, 16, 16)
    this.el.setAttribute("data-dragging", "")
    item.classList.add("opacity-60")
  },
  dragOver(e) {
    if (!this.dragging) { return }
    const {item} = this.dragging
    const list = e.target.closest("[data-sortable-list]")
    const target = this.item(e.target)
    if (!list || !this.el.contains(list)) { return }

    if (target && target !== item && list.contains(target) && !item.contains(target)) {
      // Over a row: before it in its upper half, after it in its lower.
      const targetList = target.parentElement
      if (!this.allowed(item, targetList)) { return }
      e.preventDefault()
      const row = target.querySelector("[data-sortable-row]") || target
      const box = row.getBoundingClientRect()
      const before = e.clientY < box.top + box.height / 2
      const next = before ? target : target.nextElementSibling
      if (item.nextElementSibling !== next || item.parentElement !== targetList) {
        targetList.insertBefore(item, next)
      }
    } else if (!target || target === this.item(list)) {
      // Over a list's own space (an empty sublist): to its end.
      if (!this.allowed(item, list)) { return }
      e.preventDefault()
      if (item.parentElement !== list) { list.appendChild(item) }
    } else if (target === item || item.contains(target)) {
      e.preventDefault()
    }
  },
  drop(e) {
    if (!this.dragging) { return }
    e.preventDefault()
    this.dragging.dropped = true
    this.commit(this.dragging.item, this.dragging.from)
    this.announce("msgDropped", this.dragging.item)
  },
  dragEnd() {
    if (!this.dragging) { return }
    const {item, from, dropped} = this.dragging
    // Dropped outside, or cancelled with Escape.
    if (!dropped) { this.restore(item, from) }
    item.classList.remove("opacity-60")
    this.el.removeAttribute("data-dragging")
    this.dragging = null
  },

  keydown(e) {
    const handle = e.target.closest && e.target.closest("[data-sortable-handle]")
    if (!handle) { return }
    const item = this.item(handle)

    if (!this.held) {
      if (e.key !== " ") { return }
      e.preventDefault()
      this.held = {item, from: this.place(item)}
      handle.setAttribute("aria-pressed", "true")
      this.announce("msgGrabbed", item)
      return
    }
    if (this.held.item !== item) { return }

    switch (e.key) {
      case "ArrowUp":
      case "ArrowDown":
        e.preventDefault()
        this.step(item, e.key === "ArrowUp" ? -1 : 1)
        handle.focus()
        break
      case " ":
      case "Enter":
        e.preventDefault()
        this.release(handle)
        this.commit(item, this.held.from)
        this.announce("msgDropped", item)
        this.held = null
        break
      case "Escape":
      case "Tab":
        if (e.key === "Escape") { e.preventDefault() }
        this.restore(item, this.held.from)
        this.release(handle)
        handle.focus()
        this.announce("msgCancelled", item)
        this.held = null
        break
    }
  },
  release(handle) { handle.removeAttribute("aria-pressed") },
  // One place up or down among its siblings; past either end of a
  // sublist, into the neighbouring category's.
  step(item, direction) {
    const list = item.parentElement
    const siblings = this.items(list)
    const index = siblings.indexOf(item)
    const neighbour = siblings[index + direction]

    if (neighbour) {
      list.insertBefore(item, direction < 0 ? neighbour : neighbour.nextElementSibling)
      this.announce("msgMoved", item)
      return
    }
    if (list.dataset.parent === "") { return }

    const parent = this.item(list)
    const parents = this.items(parent.parentElement)
    const other = parents[parents.indexOf(parent) + direction]
    const into = other && this.sublist(other)
    if (!into) { return }
    into.insertBefore(item, direction < 0 ? null : into.firstElementChild)
    this.announce("msgMovedInto", item)
  },
}

export default {KeyboardShortcuts, Sortable, ChatComposer, ChatScroll, ReactionPicker, PushNotifications, ComposerButtons, PasskeyLogin, SecurityKeyLogin, SecurityKeyRegister, EmojiPicker, PasteUpload, PluginWidget, Highlight, LocalTime, MentionAutocomplete, QuoteSelection}
