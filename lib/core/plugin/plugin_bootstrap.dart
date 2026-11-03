/// 注入到插件页面的桥接脚本：`window.host` 的全部能力都在这。
///
/// **必须放在 core**：普通插件页（app 层）和离屏查询宿主（core 层）都要注入
/// 同一份 —— 两处各写一份迟早漂移，而漂移表现为"插件在有页面时能查、离屏时不能"，
/// 极难查。
///
/// **幂等**：重复执行只会 return，不会把已注册的 handler 冲掉。
const String pluginBootstrapScript = r'''
(function () {
  if (window.host) return;
  var seq = 0;
  var pending = {};
  window.__hostResolve = function (id, payload) {
    var entry = pending[id];
    if (!entry) return;
    delete pending[id];
    if (payload && payload.ok) {
      entry.resolve(payload.result);
    } else {
      var error = (payload && payload.error) || {};
      entry.reject({ code: error.code || 'unknown', message: error.message || '调用失败' });
    }
  };
  var handlers = {};
  window.host = {
    call: function (method, params) {
      return new Promise(function (resolve, reject) {
        var id = ++seq;
        pending[id] = { resolve: resolve, reject: reject };
        HostBridge.postMessage(JSON.stringify({ id: id, method: method, params: params || {} }));
      });
    },
    // 事件订阅。宿主只推 manifest 里声明过的钩子；
    // 这里再挡一层：同一个事件可以挂多个处理函数，各自 try/catch ——
    // 一个处理函数抛异常不该让后面的收不到。
    on: function (name, fn) {
      if (typeof fn !== 'function') return;
      (handlers[name] = handlers[name] || []).push(fn);
    },
    off: function (name, fn) {
      var list = handlers[name];
      if (!list) return;
      var at = list.indexOf(fn);
      if (at >= 0) list.splice(at, 1);
    }
  };
  window.__hostEvent = function (name, payload) {
    var list = handlers[name];
    if (!list) return;
    for (var i = 0; i < list.length; i++) {
      try { list[i](payload); } catch (e) { /* 单个订阅者出错不影响其他 */ }
    }
  };

  // ---- 入站查询（主包问、插件答）----
  // 和 host.call 是反方向：主包 runJavaScript 调 __hostQuery，插件处理完
  // 通过 HostBridge 回 queryReply，主包按 callId 匹配。
  var queryHandlers = {};
  window.host.onQuery = function (method, fn) {
    if (typeof method === 'string' && typeof fn === 'function') {
      queryHandlers[method] = fn;
    }
  };
  function replyQuery(callId, ok, payload) {
    var msg = { queryReply: callId, ok: ok };
    if (ok) { msg.result = payload; } else { msg.error = payload; }
    HostBridge.postMessage(JSON.stringify(msg));
  }
  window.__hostQuery = function (callId, method, params) {
    var fn = queryHandlers[method];
    // 没注册就当"不支持"，回一个明确的错误 —— 让主包能区分"没实现"和"实现但失败"
    if (!fn) {
      replyQuery(callId, false, { code: 'unsupported', message: '不支持：' + method });
      return;
    }
    Promise.resolve()
      .then(function () { return fn(params || {}); })
      .then(function (result) { replyQuery(callId, true, result); })
      .catch(function (e) {
        replyQuery(callId, false, {
          code: 'failed',
          message: String((e && e.message) || e)
        });
      });
  };
})();
''';
