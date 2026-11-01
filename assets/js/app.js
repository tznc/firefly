// Phoenix and LiveView client
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import Hooks from "./hooks"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // The browser's offset from UTC, in minutes (as getTimezoneOffset()), so
  // times picked on the server (bookmark reminders) mean local time.
  params: {_csrf_token: csrfToken, tz_offset: new Date().getTimezoneOffset()},
  hooks: Hooks,
  uploaders: Hooks.Uploaders,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#DB3440", ".5": "#FAAF3F"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
window.liveSocket = liveSocket
