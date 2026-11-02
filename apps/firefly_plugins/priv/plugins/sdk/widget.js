// Firefly widget SDK, for plugin widgets and frame apps. Load it in the
// plugin's HTML asset with <script src="/plugins/sdk.js"></script>.
//
//   Firefly.ready(({user, context, plugin}) => ...)  // viewer (or null) and context
//   Firefly.user, Firefly.isLoggedIn()               // the viewer, once ready
//   Firefly.call(handler, args)                     // the plugin's handle_widget; a promise
//   Firefly.storage.get(key) / .set(key, value)      // the viewer's own data for this
//     / .delete(key) / .list(prefix)                 // plugin, on the server; promises
//   Firefly.resize(height?)                          // automatic on content changes
//
// Storage is always the logged-in viewer's: the page decides whose it is,
// never the widget. Visitors get an error; check isLoggedIn() first.
//
// The frame is sandboxed (an opaque origin with no network access): the
// page it's in is the only thing it can talk to, through postMessage.
(function () {
  var pending = {};
  var nextId = 1;
  var waiting = [];
  var info = null;

  function post(message) {
    message.firefly = 1;
    window.parent.postMessage(message, "*");
  }

  window.addEventListener("message", function (event) {
    var message = event.data || {};
    if (event.source !== window.parent || message.firefly !== 1) return;

    if (message.type === "init") {
      if (info) return;
      info = { user: message.user, context: message.context, plugin: message.plugin };
      waiting.splice(0).forEach(function (callback) { callback(info); });
    } else if (message.type === "result" && pending[message.id]) {
      var call = pending[message.id];
      delete pending[message.id];
      if (Object.prototype.hasOwnProperty.call(message, "error")) call.reject(new Error(message.error));
      else call.resolve(message.ok);
    }
  });

  function request(message) {
    return new Promise(function (resolve, reject) {
      var id = nextId++;
      pending[id] = { resolve: resolve, reject: reject };
      message.id = id;
      post(message);
    });
  }

  function storage(op, fields) {
    fields.type = "storage";
    fields.op = op;
    return request(fields);
  }

  window.Firefly = {
    ready: function (callback) {
      if (info) callback(info);
      else waiting.push(callback);
    },
    get user() { return info ? info.user : null; },
    isLoggedIn: function () { return !!(info && info.user); },
    call: function (handler, args) {
      return request({ type: "call", handler: String(handler), args: args === undefined ? null : args });
    },
    storage: {
      get: function (key) { return storage("get", { key: String(key) }); },
      set: function (key, value) {
        return storage("set", { key: String(key), value: value === undefined ? null : value });
      },
      delete: function (key) { return storage("delete", { key: String(key) }); },
      list: function (prefix) { return storage("list", { prefix: prefix === undefined ? "" : String(prefix) }); }
    },
    resize: function (height) {
      post({ type: "resize", height: height || document.documentElement.scrollHeight });
    }
  };

  // The page may not be listening yet (its scripts connect after this
  // frame can load): say so until it answers.
  (function hello(tries) {
    if (info || tries === 0) return;
    post({ type: "ready" });
    setTimeout(function () { hello(tries - 1); }, 250);
  })(40);

  if (window.ResizeObserver) {
    new ResizeObserver(function () { window.Firefly.resize(); }).observe(document.documentElement);
  }
})();
