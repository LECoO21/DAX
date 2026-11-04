(function () {
  'use strict';
  const cache = Object.create(null);
  globalThis.crypto = { getRandomValues(array) { const bytes = _random(array.byteLength); const view = new Uint8Array(array.buffer, array.byteOffset, array.byteLength); view.set(bytes); return array; } }; 
  function DataValue(base64) { this.__daxData = base64 || ''; }
  Object.defineProperty(DataValue.prototype, 'length', { get() { return _data('length', this.__daxData, null); } });
  DataValue.prototype.toUTF8 = function () { const value = _data('utf8', this.__daxData, null); return value === null ? undefined : value; };
  DataValue.prototype.toHex = function (upper) { const value = _data('hex', this.__daxData, null); return upper ? value.toUpperCase() : value; };
  DataValue.prototype.toBase64 = function () { return this.__daxData; };
  DataValue.prototype.toByteArray = function () { return _data('bytes', this.__daxData, null); };
  DataValue.prototype.readUInt8 = function (index) { return _data('read', this.__daxData, index); };
  DataValue.prototype.writeUInt8 = function (value, index) { this.__daxData = _data('write', this.__daxData, { value, index }); };
  DataValue.prototype.subData = function (start, end) { return new DataValue(_data('sub', this.__daxData, { start, end })); };
  DataValue.prototype.appendData = function (value) { this.__daxData = _data('append', this.__daxData, value.__daxData); };
  globalThis.$data = {
    fromUTF8(value) { return new DataValue(_data('fromUTF8', String(value), null)); },
    fromBase64(value) { return new DataValue(_data('fromBase64', String(value), null)); },
    fromHex(value) { return new DataValue(_data('fromHex', String(value), null)); },
    fromByteArray(value) { return new DataValue(_data('fromBytes', '', value)); },
    fromData(value) { return new DataValue(value.__daxData); },
    isData(value) { return value instanceof DataValue; }
  };
  function restoreData(value) {
    if (!value || typeof value !== 'object') return value;
    if (typeof value.__daxData === 'string') return new DataValue(value.__daxData);
    if (Array.isArray(value)) return value.map(restoreData);
    Object.keys(value).forEach(key => { value[key] = restoreData(value[key]); });
    return value;
  }
  globalThis.$signal = { new() {
    const listeners = new Set();
    return {
      send(value) { Array.from(listeners).forEach(listener => listener(value)); },
      subscribe(handler) { listeners.add(handler); return { dispose() { listeners.delete(handler); } }; },
      removeAllSubscriber() { listeners.clear(); }
    };
  } };
  globalThis.__cancelSignal = $signal.new();
  globalThis.$log = { info() {}, warn() {}, warning() {}, error() {}, debug() {} };
  const util = {
    type(value) { return value === null ? 'null' : value === undefined ? 'undefined' : Object.prototype.toString.call(value).slice(8, -1).toLowerCase(); },
    tag(value) { return Object.prototype.toString.call(value); },
    desc(value) { try { return typeof value === 'object' ? JSON.stringify(value, null, 4) : String(value); } catch (_) { return String(value); } },
    detail(value) { return '[type]: ' + this.type(value) + ',\n[tag]: ' + this.tag(value) + ',\n[desc]: ' + this.desc(value); },
    isNil(value) { return value === undefined || value === null; },
    get(value, path, fallback) { for (const key of Array.isArray(path) ? path : [path]) { if (value == null || typeof value !== 'object') return fallback; value = value[key]; } return value == null ? fallback : value; },
    props(value) { const result = new Set(); for (; value != null; value = Object.getPrototypeOf(value)) Object.getOwnPropertyNames(value).forEach(key => result.add(key)); return Array.from(result); },
    propsFiltered(value) { return this.props(value).filter(key => !(key in Object.prototype) && key !== 'constructor'); }
  };
  globalThis.$util = util;
  function requireModule(path, parent) {
    if (path === '$util') return util;
    const descriptor = _moduleRead(path, parent || '/main.js');
    if (!descriptor || descriptor.error) throw new Error('无法加载插件模块 ' + path);
    if (cache[descriptor.path]) return cache[descriptor.path].exports;
    const module = { exports: {} };
    cache[descriptor.path] = module;
    if (descriptor.path.endsWith('.json')) { module.exports = JSON.parse(descriptor.source); return module.exports; }
    const directory = descriptor.path.substring(0, descriptor.path.lastIndexOf('/')) || '/';
    const expose = '\n; if(typeof supportLanguages === "function") module.exports.supportLanguages = supportLanguages;'
      + 'if(typeof translate === "function") module.exports.translate = translate;'
      + 'if(typeof ocr === "function") module.exports.ocr = ocr;'
      + 'if(typeof tts === "function") module.exports.tts = tts;'
      + 'if(typeof pluginTimeoutInterval === "function") module.exports.pluginTimeoutInterval = pluginTimeoutInterval;'
      + 'if(typeof pluginValidate === "function") module.exports.pluginValidate = pluginValidate;'
      + 'if(typeof supportBoundingBox === "function") module.exports.supportBoundingBox = supportBoundingBox;';
    const execute = new Function('module', 'exports', 'require', '__filename', '__dirname', descriptor.source + expose);
    execute(module, module.exports, child => requireModule(child, descriptor.path), descriptor.path, directory);
    return module.exports;
  }
  globalThis.require = path => requireModule(path, '/main.js');
  function request(options, method, streaming) {
    const args = Object.assign({}, options);
    if (method) args.method = method;
    const handler = args.handler;
    let subscription;
    function start(resolve) {
      const identifier = _http(args, event => {
        if (event.stream) { if (typeof args.streamHandler === 'function') args.streamHandler(restoreData(event.stream)); return; }
        if (subscription) subscription.dispose();
        resolve(restoreData(event));
      }, !!streaming);
      if (args.cancelSignal && typeof args.cancelSignal.subscribe === 'function') {
        subscription = args.cancelSignal.subscribe(() => _cancelHTTP(identifier));
      }
    }
    if (typeof handler === 'function') { start(handler); return; }
    return new Promise(resolve => start(resolve));
  }
  globalThis.$http = {
    request(options) { return request(options, null, false); },
    get(options) { return request(options, 'GET', false); },
    post(options) { return request(options, 'POST', false); },
    streamRequest(options) { return request(options, null, true); }
  };
  globalThis.$file = {
    read(path) { const value = _file('read', path); return value === null ? undefined : new DataValue(value); },
    write(options) { return _file('write', options); },
    delete(path) { return _file('delete', path); },
    list(path) { return _file('list', path); },
    copy(options) { return _file('copy', options); },
    move(options) { return _file('move', options); },
    mkdir(path) { return _file('mkdir', path); },
    exists(path) { return _file('exists', path); },
    isDirectory(path) { return _file('isDirectory', path); }
  };
  globalThis.$timer = {
    schedule(options) { return _timer(options.interval || 0, !!options.repeats, options.handler); },
    invalidate(identifier) { _cancelTimer(identifier); }
  };
  globalThis.setTimeout = (handler, milliseconds) => _timer(Math.max(0, milliseconds || 0) / 1000, false, handler);
  globalThis.clearTimeout = identifier => _cancelTimer(identifier);
  globalThis.setInterval = (handler, milliseconds) => _timer(Math.max(10, milliseconds || 10) / 1000, true, handler);
  globalThis.clearInterval = identifier => _cancelTimer(identifier);
  globalThis.$websocket = { new(options) {
    const listeners = {};
    const socket = { readyState: 0 };
    const id = _websocket(options, event => {
      if (event.state !== undefined) socket.readyState = event.state;
      const handler = listeners[event.kind];
      if (handler) {
        if (event.kind === 'close') handler(socket, event.code, event.reason);
        else handler(socket, restoreData(event.value));
      }
    });
    socket.open = () => _websocketCommand(id, 'open', null);
    socket.close = options => { socket.readyState = 2; _websocketCommand(id, 'close', options || {}); };
    socket.sendString = text => _websocketCommand(id, 'text', text);
    socket.sendData = data => _websocketCommand(id, 'data', data);
    socket.ping = data => _websocketCommand(id, 'ping', data || null);
    socket.pong = data => _websocketCommand(id, 'pong', data || null);
    ['Open','Close','Error','ReceiveString','ReceiveData','ReceivePing','ReceivePong'].forEach(name => {
      const kind = { Open:'open', Close:'close', Error:'error', ReceiveString:'text', ReceiveData:'data', ReceivePing:'ping', ReceivePong:'pong' }[name];
      socket['listen' + name] = handler => { listeners[kind] = handler; };
    });
    return socket;
  } };
  globalThis.__invokePlugin = function (operation, query) {
    const entry = requireModule('/main.js', '/main.js');
    if (typeof entry.pluginTimeoutInterval === 'function') _emit({ kind: 'timeout', seconds: entry.pluginTimeoutInterval() });
    if (operation === 'languages') { _emit({ kind: 'complete', result: { languages: entry.supportLanguages ? entry.supportLanguages() : [], supportBoundingBox: entry.supportBoundingBox ? !!entry.supportBoundingBox() : false } }); return; }
    const functionName = operation === 'validate' ? 'pluginValidate' : operation;
    if (typeof entry[functionName] !== 'function') { _emit({ kind: 'error', message: '插件未实现 ' + functionName }); return; }
    let lastFormat = 'plain';
    function normalizeResult(result) {
      if (!result || typeof result !== 'object') return result;
      if (result.content) {
        if (result.content.format) lastFormat = result.content.format;
        else result.content.format = lastFormat;
      }
      return result;
    }
    const completion = response => {
      if (response && response.error) _emit({ kind: 'error', message: response.error.message || response.error.type || '插件服务调用失败。' });
      else if (response && response.result !== undefined) _emit({ kind: 'complete', result: typeof response.result === 'object' ? normalizeResult(response.result) : { valid: !!response.result } });
      else _emit({ kind: 'error', message: '插件未返回有效结果。' });
    };
    if (operation === 'validate') { entry[functionName](completion); return; }
    query = restoreData(query);
    if (query.originalText === undefined && query.text !== undefined) query.originalText = query.text;
    query.cancelSignal = __cancelSignal;
    query.onCompletion = completion;
    query.onStream = result => _emit({ kind: 'stream', result: normalizeResult(result) });
    query.completion = completion;
    const returned = entry[functionName](query, completion);
    if (returned && typeof returned.catch === 'function') returned.catch(error => completion({ error: { message: error.message || String(error) } }));
  };
})();
