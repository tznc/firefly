// Shared by the shortcode, the widget and the export.
exports.greet = (name) => `${firefly.plugin.settings.greeting}, ${name || "friend"}!`;

exports.escape = (text) =>
  String(text).replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"})[c]);
