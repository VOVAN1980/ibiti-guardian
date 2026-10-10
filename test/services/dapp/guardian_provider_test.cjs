'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.resolve(__dirname, '../../../assets/dapp/guardian_provider.js'), 'utf8');
function browser({ protocol = 'https:', iframe = false } = {}) {
  const events = [], posted = [], listeners = new Map();
  const channel = { postMessage: value => posted.push(JSON.parse(value)) };
  const win = { guardianWallet: channel,
    addEventListener: (name, cb) => { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(cb); },
    dispatchEvent: event => { events.push(event); for (const cb of listeners.get(event.type) || []) cb(event); },
  };
  win.top = iframe ? {} : win;
  class Event { constructor(type, options = {}) { this.type = type; Object.assign(this, options); } }
  vm.runInNewContext(source, { window: win, location: { protocol }, crypto: require('node:crypto').webcrypto,
    CustomEvent: Event, Event, Uint8Array, Error, TypeError });
  return { win, posted, events, reply: value => channel.onmessage({ data: JSON.stringify(value) }),
    fire: type => win.dispatchEvent(new Event(type)) };
}
test('no provider injected into insecure pages or child frames', () => {
  assert.equal(browser({ protocol: 'http:' }).win.ethereum, undefined);
  assert.equal(browser({ iframe: true }).win.ethereum, undefined);
});
test('initial discovery reads do not request connection or signature', () => {
  const b = browser();
  assert.deepEqual(b.posted.map(x => x.method), ['eth_chainId', 'eth_accounts']);
  assert.ok(Object.isFrozen(b.win.ethereum));
  assert.equal(b.win.ethereum.isGuardian, true);
  assert.equal(b.win.ethereum.isMetaMask, undefined);
});
test('EIP-6963 announcement identifies the same single provider', () => {
  const b = browser();
  b.fire('eip6963:requestProvider');
  const announcements = b.events.filter(x => x.type === 'eip6963:announceProvider');
  assert.equal(announcements.length, 2);
  assert.equal(announcements[0].detail.provider, b.win.ethereum);
  assert.equal(announcements[0].detail.info.name, 'IBITI Guardian');
  assert.ok(Object.isFrozen(announcements[0].detail.info));
  assert.ok(!announcements[0].detail.info.icon.includes('"'));
  assert.ok(decodeURIComponent(announcements[0].detail.info.icon).includes('fill="#00c8ff"'));
});
test('request settles once with exact native result; duplicate reply ignored', async () => {
  const b = browser();
  const promise = b.win.ethereum.request({ method: 'eth_requestAccounts' });
  const id = b.posted.at(-1).id;
  b.reply({ id, result: ['0xaccount'], state: { accounts: ['0xaccount'], chainId: '0x38' } });
  b.reply({ id, result: ['malicious duplicate'] });
  assert.deepEqual(Array.from(await promise), ['0xaccount']);
  assert.equal(b.win.ethereum.selectedAddress, '0xaccount');
  assert.equal(b.win.ethereum.isConnected(), true);
});
test('native rejection preserves wallet-standard error code', async () => {
  const b = browser();
  const promise = b.win.ethereum.request({ method: 'personal_sign', params: ['0x00', '0xaccount'] });
  const assertion = assert.rejects(promise, { code: 4001, message: 'Rejected' });
  b.reply({ id: b.posted.at(-1).id, error: { code: 4001, message: 'Rejected' } });
  await assertion;
});
test('invalid JS request rejected before native transport', async () => {
  const b = browser();
  for (const args of [null, {}, { method: 'x', params: {} }]) {
    await assert.rejects(b.win.ethereum.request(args), { code: -32602 });
  }
  assert.equal(b.posted.length, 2);
});
test('account/network events and a broken site listener cannot break settlement', async () => {
  const b = browser(), received = [];
  b.win.ethereum.on('accountsChanged', value => { received.push(value); throw Error('site error'); });
  b.reply({ id: 1, result: '0x38', state: { chainId: '0x38', accounts: [] } });
  const promise = b.win.ethereum.request({ method: 'eth_accounts' });
  b.reply({ id: b.posted.at(-1).id, result: ['0xaccount'], state: { chainId: '0x1', accounts: ['0xaccount'] } });
  assert.deepEqual(Array.from(await promise), ['0xaccount']);
  assert.equal(received.length, 1);
  assert.equal(b.events.filter(x => x.type === 'eip6963:announceProvider').length, 1);
  assert.equal(b.win.ethereum.chainId, '0x1');
});
test('legacy sendAsync uses the same request and preserves JSON-RPC id', async () => {
  const b = browser();
  const promise = new Promise((resolve, reject) => b.win.ethereum.sendAsync({ id: 99, method: 'eth_accounts' },
    (error, value) => error ? reject(error) : resolve(value)));
  b.reply({ id: b.posted.at(-1).id, result: [] });
  const result = await promise;
  assert.equal(result.id, 99);
  assert.equal(result.jsonrpc, '2.0');
});
test('closing document rejects pending requests; no signing retry', async () => {
  const b = browser();
  const promise = b.win.ethereum.request({ method: 'eth_requestAccounts' });
  const assertion = assert.rejects(promise, { code: 4001 });
  const count = b.posted.length;
  b.fire('pagehide');
  await assertion;
  assert.equal(b.posted.length, count);
  assert.equal(b.win.ethereum.isConnected(), false);
});
