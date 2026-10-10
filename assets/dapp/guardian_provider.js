// EIP-1193 + EIP-6963. Native code authorizes every request using WebView origin.
(() => {
  'use strict';
  if (window !== window.top || location.protocol !== 'https:') return;
  const channel = window.guardianWallet;
  if (!channel || typeof channel.postMessage !== 'function') return;
  const pending = new Map();
  const listeners = new Map();
  let nextId = 0;
  let accounts = [];
  let chainId = null;
  let connected = false;
  const rpcError = (code, message) => Object.assign(new Error(message), { code });
  const emit = (name, value) => {
    for (const callback of [...(listeners.get(name) || [])]) {
      try { callback(value); } catch (_) { /* A site listener cannot break settlement. */ }
    }
  };
  const update = (state) => {
    if (!state) return;
    if (state.chainId && chainId !== state.chainId) {
      const previous = chainId;
      chainId = state.chainId;
      if (previous !== null) emit('chainChanged', chainId);
    }
    if (Array.isArray(state.accounts) && JSON.stringify(accounts) !== JSON.stringify(state.accounts)) {
      accounts = state.accounts.slice();
      emit('accountsChanged', accounts.slice());
    }
    if (!connected && chainId) { connected = true; emit('connect', { chainId }); }
  };
  channel.onmessage = event => {
    let response;
    try { response = JSON.parse(event.data); } catch (_) { return; }
    update(response.state);
    const promise = pending.get(response.id);
    if (!promise) return;
    pending.delete(response.id);
    if (response.error) promise.reject(rpcError(response.error.code, response.error.message));
    else promise.resolve(response.result);
  };
  const request = args => {
    if (!args || typeof args.method !== 'string' ||
        (args.params !== undefined && !Array.isArray(args.params))) {
      return Promise.reject(rpcError(-32602, 'Invalid wallet request.'));
    }
    if (pending.size >= 32) return Promise.reject(rpcError(-32005, 'Too many pending requests.'));
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject });
      try { channel.postMessage(JSON.stringify({ id, method: args.method, params: args.params || [] })); }
      catch (_) { pending.delete(id); reject(rpcError(4900, 'Guardian is unavailable.')); }
    });
  };
  const on = (name, callback) => {
    if (typeof callback !== 'function') throw new TypeError('Listener must be a function.');
    if (!listeners.has(name)) listeners.set(name, new Set());
    listeners.get(name).add(callback);
    return provider;
  };
  const removeListener = (name, callback) => { listeners.get(name)?.delete(callback); return provider; };
  const sendAsync = (payload, callback) => {
    request(payload).then(result => callback(null, { id: payload.id, jsonrpc: '2.0', result }),
      error => callback(error, { id: payload.id, jsonrpc: '2.0', error: { code: error.code, message: error.message } }));
  };
  const provider = Object.freeze({
    isGuardian: true,
    request, on, removeListener,
    isConnected: () => connected,
    get chainId() { return chainId; },
    get networkVersion() { return chainId ? String(parseInt(chainId, 16)) : null; },
    get selectedAddress() { return accounts[0] || null; },
    enable: () => request({ method: 'eth_requestAccounts' }),
    sendAsync,
    send: (payload, paramsOrCallback) => typeof paramsOrCallback === 'function'
      ? sendAsync(payload, paramsOrCallback)
      : request(typeof payload === 'string' ? { method: payload, params: paramsOrCallback || [] } : payload),
  });
  Object.defineProperty(window, 'ethereum', { value: provider, writable: false, configurable: false });
  const uuid = typeof crypto.randomUUID === 'function' ? crypto.randomUUID()
    : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
      const n = crypto.getRandomValues(new Uint8Array(1))[0] & 15;
      return (c === 'x' ? n : (n & 3) | 8).toString(16);
    });
  const info = Object.freeze({ uuid, name: 'IBITI Guardian', rdns: 'com.ibiti.guardian',
    icon: 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path fill="#00c8ff" d="M32 2 58 12v20c0 15-26 30-26 30S6 47 6 32V12z"/></svg>') });
  const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider',
    { detail: Object.freeze({ info, provider }) }));
  window.addEventListener('eip6963:requestProvider', announce);
  announce();
  window.dispatchEvent(new Event('ethereum#initialized'));
  // No account access prompt on page load. eth_accounts is permission-gated.
  request({ method: 'eth_chainId' }).catch(() => {});
  request({ method: 'eth_accounts' }).catch(() => {});
  window.addEventListener('pagehide', () => {
    connected = false;
    emit('disconnect', rpcError(4900, 'Document closed.'));
    for (const promise of pending.values()) promise.reject(rpcError(4001, 'Document closed.'));
    pending.clear();
  }, { once: true });
})();
