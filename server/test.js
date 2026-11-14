// Self-test of the relay: static files, room validation, offer/answer forwarding, error paths.
'use strict';
const { spawn } = require('child_process');
const assert = require('assert');
const http = require('http');
const WebSocket = require('ws');

const PORT = 18080 + Math.floor(Math.random() * 1000);
const ROOM = 'TestRoomCode_0123456789abcdef';
const srv = spawn(process.execPath, [__dirname + '/server.js'], { env: { ...process.env, PORT: String(PORT) }, stdio: 'inherit' });

const wait = ms => new Promise(r => setTimeout(r, ms));
const get = p => new Promise((res, rej) => http.get(`http://127.0.0.1:${PORT}${p}`, r => {
  let b = ''; r.on('data', d => (b += d)); r.on('end', () => res({ status: r.statusCode, body: b }));
}).on('error', rej));
const open = q => new Promise((res, rej) => { const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?${q}`); ws.once('open', () => res(ws)); ws.once('error', rej); });
const next = ws => new Promise(res => ws.once('message', d => res(JSON.parse(d))));

(async () => {
  for (let i = 0; i < 50; i++) { try { await get('/healthz'); break; } catch { await wait(100); } }
  try {
    assert.strictEqual((await get('/healthz')).status, 200);
    const index = await get('/');
    assert.strictEqual(index.status, 200);
    assert.match(index.body, /VR Desktop/);
    assert.strictEqual((await get('/app.js')).status, 200);
    assert.strictEqual((await get('/../server.js')).status, 404);

    // invalid room is rejected
    const bad = await open('role=client&room=short');
    assert.strictEqual((await next(bad)).type, 'error');

    // client without host gets an error
    const lonely = await open(`role=client&room=${ROOM}`);
    lonely.send(JSON.stringify({ type: 'offer', sdp: 'v=0' }));
    const e = await next(lonely);
    assert.strictEqual(e.type, 'error');
    lonely.close();

    // host answers a client's offer
    const host = await open(`role=host&room=${ROOM}`);
    host.on('message', d => {
      const m = JSON.parse(d);
      if (m.type === 'offer') host.send(JSON.stringify({ type: 'answer', sdp: 'answer-to:' + m.sdp, to: m.from }));
    });
    await wait(50);
    const client = await open(`role=client&room=${ROOM}`);
    client.send(JSON.stringify({ type: 'offer', sdp: 'OFFER' }));
    const a = await next(client);
    assert.deepStrictEqual([a.type, a.sdp], ['answer', 'answer-to:OFFER']);

    // a client in another room can't reach this host
    const other = await open('role=client&room=SomeOtherRoom_0123456789');
    other.send(JSON.stringify({ type: 'offer', sdp: 'X' }));
    assert.strictEqual((await next(other)).type, 'error');

    console.log('relay tests passed');
    process.exitCode = 0;
  } catch (err) {
    console.error('relay tests FAILED:', err);
    process.exitCode = 1;
  } finally {
    srv.kill();
    setTimeout(() => process.exit(), 200);
  }
})();
