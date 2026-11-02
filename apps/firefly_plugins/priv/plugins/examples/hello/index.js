// Hello: an example Firefly plugin. Each export is a hook handler (see
// PLUGINS.md); firefly.call reaches the host functions its permissions allow.
const {greet, escape} = require("./lib/greet");

const count = (key, by = 1) => {
  const value = (firefly.call("kv.get", {key}) || 0) + by;
  firefly.call("kv.set", {key, value});
  return value;
};

exports.enabled = () => firefly.log("Hello is on");

// [hello name="Ann"] → a greeting.
exports.render_shortcodes = ({shortcodes}) =>
  shortcodes.map((s) => `<span class="hello">${escape(greet(s.attrs.name || s.content))}</span>`);

// Marks posts that say hello.
exports.render_post = ({html}) =>
  html.includes('class="hello"') ? html + '<p><em>👋 This post says hello.</em></p>' : html;

// Counts new posts, and records how many hellos each has in a public field.
exports.handle_event = ({event, data}) => {
  count(event);
  const hellos = (data.post.body.match(/\[hello/g) || []).length;
  if (hellos > 0) firefly.call("fields.set", {type: "post", id: data.post.id, key: "hellos", value: hellos});
};

exports.run_job = ({job}) => firefly.call("kv.set", {key: "last_" + job, value: new Date().toISOString()});

exports.moderate_post = ({body}) => {
  const {blocked_words, review_links} = firefly.plugin.settings;
  const words = blocked_words.split("\n").map((w) => w.trim().toLowerCase()).filter(Boolean);
  const found = words.find((w) => body.toLowerCase().includes(w));
  if (found) return {action: "reject", message: `Please don't say "${found}".`};
  if (review_links && /https?:\/\//.test(body)) return {action: "queue", reason: "it has links"};
  return {action: "allow"};
};

exports.flag_created = ({flag}) => ({action: flag.reason === "spam" && flag.note === "hello-hide" ? "hide" : "none"});

exports.handle_widget = ({handler, user}) => {
  if (handler === "view") return {views: count("views"), greeting: greet(user && user.username)};
  throw new Error("unknown handler " + handler);
};

exports.render_page = ({path, user}) => {
  if (path === "/app") return {title: "Hello app", iframe: "app.html"};
  return {
    title: "Hello",
    html: `<p>${escape(greet(user && user.username))}</p>
      <p>Widget views: <strong>${firefly.call("kv.get", {key: "views"}) || 0}</strong></p>
      <p>Posts seen: ${firefly.call("kv.get", {key: "post_created"}) || 0}</p>`
  };
};

exports.render_admin = () => ({
  title: "Hello's numbers",
  html: `<ul><li>Widget views: ${firefly.call("kv.get", {key: "views"}) || 0}</li>
    <li>Last tally: ${escape(firefly.call("kv.get", {key: "last_tally"}) || "never")}</li></ul>`
});

exports.handle_request = ({method, path, user}) => {
  if (method === "GET" && path === "/stats")
    return {status: 200, body: {views: firefly.call("kv.get", {key: "views"}) || 0, user: user && user.username}};
  return {status: 404, body: {error: "no such endpoint"}};
};

// Other plugins that depend on Hello can call this.
exports.greet = ({name}) => greet(name);
