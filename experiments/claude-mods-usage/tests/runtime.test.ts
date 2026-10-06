import { expect, mock, test } from 'claude-code/testing'
import { TEST_PUBLIC_KEY, openRequest } from './crypto-fixture.mjs'

const DIR = '/private/quotatempo-synthetic-probe'
const NOW = Date.parse('2026-10-06T00:00:00.000Z')
const GRANT = JSON.stringify({
  schemaVersion: 1, purpose: 'quotatempo-mods-comparison',
  connectionID: '11111111-1111-4111-8111-111111111111',
  createdAt: '2026-10-06T00:00:00.000Z',
})
const UNIX_DIR = '/private/tmp/qtc-33333333-3333-4333-8333-333333333333'
const UNIX_GRANT = JSON.stringify({
  ...JSON.parse(GRANT), schemaVersion: 3, transport: 'unix-hpke',
  socketPath: `${UNIX_DIR}/bridge.sock`,
})
const CONNECT = `connect ${UNIX_DIR} ${TEST_PUBLIC_KEY}`
const DISCONNECT_UNCONFIRMED = 'QuotaTempo probe stopped locally. Disconnect confirmation failed; prepare a new private comparison directory. No product source was changed.'

function deferred() {
  let resolve!: () => void
  const promise = new Promise<void>(done => { resolve = done })
  return { promise, resolve }
}

function encryptedEnvelope(init: any) {
  const envelope = JSON.parse(init.body)
  expect(Object.keys(envelope).sort().join(',')).toBe('ciphertext,connectionID,enc,requestID,schemaVersion,streamID')
  expect(envelope.schemaVersion).toBe(3)
  for (const marker of ['"rateLimits"', '"percentUsed"', '"resetsAt"', '"status"', '"readAt"']) {
    expect(init.body.includes(marker)).toBe(false)
  }
  return envelope
}

function stubs(on: any, unix = false, respond?: (e: any) => any, readGrant?: () => Promise<void>) {
  const directory = unix ? UNIX_DIR : DIR
  const files = new Map([[`${directory}/probe-grant.json`, unix ? UNIX_GRANT : GRANT]])
  const written: string[] = []
  const requests: any[] = []
  const clock = { value: NOW }
  // The kit allows one stub per event. Replace only mock.clock's now stub
  // to retain invalid-clock fixtures; keep its official timer wait handlers.
  const timers = mock.clock((name: any, ...args: any[]) => name === 'clock.now'
    ? on(name, () => ({ value: clock.value })) : on(name, ...args), { now: NOW })
  on('command.register', () => ({ value: undefined }))
  on('fs.stat', (_: unknown, e: any) => ({ value: {
    kind: e.path === directory ? 'dir' : 'file', isLink: false,
    size: (files.get(e.path) ?? '').length, mtimeMs: NOW, realPath: e.path,
  } }))
  on('fs.exists', (_: unknown, e: any) => ({ value: files.has(e.path) }))
  on('fs.read', async (_: unknown, e: any) => {
    expect(e.path).toBe(`${directory}/probe-grant.json`)
    if (readGrant) await readGrant()
    return { value: files.get(e.path) }
  })
  on('fs.write', (_: unknown, e: any) => {
    files.set(e.path, e.text)
    written.push(e.text)
    return { value: undefined }
  })
  on('http.fetch', async (_: unknown, e: any) => {
    expect(unix).toBe(true)
    expect(e.init.socketPath).toBe(`${UNIX_DIR}/bridge.sock`)
    expect(e.init.method).toBe('POST')
    expect(e.init.headers['Content-Type']).toBe('application/json')
    expect(Object.keys(e.init).sort().join(',')).toBe('body,headers,method,socketPath')
    const status = ({
      'http://quotatempo/connect': 'connected',
      'http://quotatempo/measure': 'accepted',
      'http://quotatempo/disconnect': 'disconnected',
    } as Record<string, string>)[e.url]
    expect(status !== undefined).toBe(true)
    const opened = await openRequest(encryptedEnvelope(e.init), new URL(e.url).pathname.slice(1))
    const reply = { status: 200, ok: true, headers: {}, text: JSON.stringify(opened.reply(status)) }
    const request = { ...e, body: opened.body, reply }
    requests.push(request)
    return { value: respond ? await respond(request) : reply }
  })
  on('session.measure', (_: unknown, e: any) => ({ changed: e.changed }))
  return { written, requests, files, clock, timers }
}

const measurement = {
  context: { tokens: 0, window: 200000, percent: 0 },
  rateLimits: [{ kind: 'seven_day', percentUsed: 42, resetsAt: '2026-10-13T00:00:00.000Z' }],
  changed: ['rateLimits'],
}

// Returning above an unfinished next(e) abandons the real engine event scope.
// An actual AbortController drives that return; HttpInit gains no signal API.
const abandonFirstConnect = {
  name: 'synthetic-command-abandonment',
  tier: 'prepend' as const,
  register(on: any) {
    let first = true
    on('command.run', { command: 'quotatempo-probe' }, async ($: any, e: any, next: any) => {
      if (!first || !e.args.startsWith('connect ')) return next(e)
      first = false
      const controller = new AbortController()
      const pending = next(e)
      pending.catch(() => {})
      const abandoned = new Promise<void>(resolve => {
        controller.signal.addEventListener('abort', () => resolve(), { once: true })
      })
      await $.clock.sleep(1)
      controller.abort()
      await abandoned
      return { text: 'Synthetic command abandoned.' }
    })
  },
}

for (const stage of ['initial grant', 'connect ACK', 'connect timeout', 'disconnect timeout']) {
  test(`abandoned command during ${stage} cannot activate after a late completion`,
    { plugins: [abandonFirstConnect] }, async ($, on) => {
      const entered = deferred()
      const late = deferred()
      const disconnectEntered = deferred()
      const lateDisconnect = deferred()
      let firstRead = true
      const { requests, written, timers } = stubs(on, true, async e => {
        if (stage !== 'initial grant' && e.url.endsWith('/connect')) {
          entered.resolve()
          await late.promise
        }
        if (stage === 'disconnect timeout' && e.url.endsWith('/disconnect')) {
          disconnectEntered.resolve()
          await lateDisconnect.promise
        }
        return e.reply
      }, async () => {
        if (stage === 'initial grant' && firstRead) {
          firstRead = false
          entered.resolve()
          await late.promise
        }
      })
      const connecting = $.command.run({ command: 'quotatempo-probe', args: CONNECT })
      await entered.promise
      await timers.advance(1)
      expect((await connecting).text).toBe('Synthetic command abandoned.')
      await $.session.measure(measurement)
      if (stage === 'connect timeout') await timers.advance(5000)
      else late.resolve()
      await timers.settle()
      if (stage === 'disconnect timeout') await disconnectEntered.promise
      await timers.advance(5000)
      await timers.settle()
      await $.session.measure(measurement)
      expect(requests.filter(e => e.url.endsWith('/measure')).length).toBe(0)
      expect(requests.filter(e => e.url.endsWith('/connect')).length).toBe(stage === 'initial grant' ? 0 : 1)
      expect(requests.filter(e => e.url.endsWith('/disconnect')).length).toBe(stage === 'initial grant' ? 0 : 1)
      expect(written.length).toBe(0)
      expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text.includes('connected. Stream:')).toBe(false)
      late.resolve()
      lateDisconnect.resolve()
      await timers.settle()
      await $.session.measure(measurement)
      await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
      expect(requests.filter(e => e.url.endsWith('/measure')).length).toBe(0)
      expect(requests.filter(e => e.url.endsWith('/disconnect')).length).toBe(stage === 'initial grant' ? 0 : 1)
    })
}

test('abandoning an older command scope cannot cancel a later active generation',
  { plugins: [abandonFirstConnect] }, async ($, on) => {
    const entered = deferred()
    const late = deferred()
    let first = true
    const { requests, written, timers } = stubs(on, true, undefined, async () => {
      if (first) { first = false; entered.resolve(); await late.promise }
    })
    const old = $.command.run({ command: 'quotatempo-probe', args: CONNECT })
    await entered.promise
    expect((await $.command.run({ command: 'quotatempo-probe', args: CONNECT })).text.includes('Comparison-only')).toBe(true)
    await timers.advance(1)
    expect((await old).text).toBe('Synthetic command abandoned.')
    late.resolve()
    await timers.settle()
    await $.session.measure(measurement)
    expect(requests.map(e => new URL(e.url).pathname).join(',')).toBe('/connect,/measure')
    expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text.includes('connected. Stream:')).toBe(true)
    expect(written.length).toBe(0)
  })

test('unconnected measurements never export', async ($, on) => {
  const { written } = stubs(on)
  await $.session.measure(measurement)
  expect(written.length).toBe(0)
})

test('experimental schema 1 connection exports measured metadata only', async ($, on) => {
  const { written } = stubs(on)
  const connected = await $.command.run({ command: 'quotatempo-probe', args: `connect ${DIR}` })
  expect(connected.text.includes('Comparison-only')).toBe(true)
  expect(written.length).toBe(0)
  await $.session.measure(measurement)
  expect(written.length).toBe(1)
  const result = JSON.parse(written[0])
  expect(result.result.rateLimits[0].percentUsed).toBe(42)
  expect(result.result.rateLimits[0].firstSeenAt).toBe('2026-10-06T00:00:00.000Z')
  expect(Object.keys(result).sort().join(',')).toBe('connectionID,result,schemaVersion,sequence,streamID')
})

test('experimental schema 1 disconnect exports invalidation and prevents later observations', async ($, on) => {
  const { written } = stubs(on)
  await $.command.run({ command: 'quotatempo-probe', args: `connect ${DIR}` })
  await $.session.measure(measurement)
  await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
  expect(written.length).toBe(2)
  expect(JSON.parse(written[1]).result.reason).toBe('disconnected')
  await $.session.measure(measurement)
  expect(written.length).toBe(2)
})

test('Unix HPKE connects, measures and disconnects without filesystem quota writes', async ($, on) => {
  const { written, requests } = stubs(on, true)
  const connected = await $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  expect(connected.text.includes('Comparison-only')).toBe(true)
  expect(requests.length).toBe(1)
  const binding = requests[0].body
  expect(binding.schemaVersion).toBe(2)
  expect(Object.keys(binding).sort().join(',')).toBe('connectionID,schemaVersion,streamID')
  await $.session.measure(measurement)
  const body = requests[1].body
  expect(body.schemaVersion).toBe(1)
  expect(body.streamID).toBe(binding.streamID)
  expect(body.result.rateLimits[0].percentUsed).toBe(42)
  expect(Object.keys(body).sort().join(',')).toBe('connectionID,result,schemaVersion,sequence,streamID')
  await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
  expect(requests.map(e => e.url).join(',')).toBe('http://quotatempo/connect,http://quotatempo/measure,http://quotatempo/disconnect')
  expect(JSON.stringify(requests[2].body)).toBe(JSON.stringify(requests[0].body))
  expect(requests[2].init.body === requests[0].init.body).toBe(false)
  expect(new Set(requests.map(e => JSON.parse(e.init.body).requestID)).size).toBe(3)
  await $.session.measure(measurement)
  expect(requests.length).toBe(3)
  expect(written.length).toBe(0)
})

test('Unix HPKE refuses a missing command pin without requests or file fallback', async ($, on) => {
  const { written, requests } = stubs(on, true)
  expect((await $.command.run({ command: 'quotatempo-probe', args: `connect ${UNIX_DIR}` })).text.includes('failed')).toBe(true)
  await $.session.measure(measurement)
  expect(requests.length).toBe(0)
  expect(written.length).toBe(0)
})

for (const phase of ['before', 'after']) {
  test(`Unix HPKE rejects key replacement ${phase} connect without plaintext or fallback`, async ($, on) => {
    const { written, requests, files } = stubs(on, true)
    if (phase === 'after') {
      expect((await $.command.run({ command: 'quotatempo-probe', args: CONNECT })).text.includes('Comparison-only')).toBe(true)
    }
    files.set(`${UNIX_DIR}/probe-grant.json`, JSON.stringify({ ...JSON.parse(UNIX_GRANT), publicKey: '09' + '00'.repeat(31) }))
    if (phase === 'before') {
      expect((await $.command.run({ command: 'quotatempo-probe', args: CONNECT })).text.includes('failed')).toBe(true)
    }
    await $.session.measure(measurement)
    await $.session.measure(measurement)
    await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
    expect(requests.length).toBe(phase === 'after' ? 1 : 0)
    expect(written.length).toBe(0)
    expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text)
      .toBe(phase === 'after' ? DISCONNECT_UNCONFIRMED : 'QuotaTempo probe disconnected.')
  })

  for (const attack of ['fake endpoint', 'forged proof', 'replayed proof']) {
    test(`Unix HPKE rejects ${attack} ${phase} connect with only ciphertext and no fallback`, async ($, on) => {
      let attacking = false
      let captured: any
      let previous: any
      const { written, requests } = stubs(on, true, async e => {
        const envelope = encryptedEnvelope(e.init)
        if (!attacking) {
          previous = e.reply
          return e.reply
        }
        captured = envelope
        if (attack === 'fake endpoint') {
          let rejected = false
          try { await openRequest(envelope, 'disconnect') } catch { rejected = true }
          expect(rejected).toBe(true)
          return { status: 200, ok: true, text: JSON.stringify({ status: phase === 'before' ? 'connected' : 'accepted' }) }
        }
        const reply = JSON.parse(attack === 'replayed proof' ? previous.text : e.reply.text)
        // Keep the new request ID to exercise authentication rather than only ID rejection.
        reply.requestID = envelope.requestID
        if (attack === 'forged proof') reply.proof = (reply.proof[0] === '0' ? '1' : '0') + reply.proof.slice(1)
        return { ...e.reply, text: JSON.stringify(reply) }
      })
      if (phase === 'after') {
        expect((await $.command.run({ command: 'quotatempo-probe', args: CONNECT })).text.includes('Comparison-only')).toBe(true)
        if (attack === 'replayed proof') await $.session.measure(measurement)
      } else if (attack === 'replayed proof') {
        // Capture an authentic connect reply from an earlier, explicitly disconnected stream.
        expect((await $.command.run({ command: 'quotatempo-probe', args: CONNECT })).text.includes('Comparison-only')).toBe(true)
        const connectedReply = previous
        await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
        previous = connectedReply
      }
      const count = requests.length
      attacking = true
      if (phase === 'before') {
        expect((await $.command.run({ command: 'quotatempo-probe', args: CONNECT })).text.includes('failed')).toBe(true)
      } else await $.session.measure(measurement)
      expect(captured !== undefined).toBe(true)
      expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text).toBe(DISCONNECT_UNCONFIRMED)
      await $.session.measure(measurement)
      await $.session.measure(measurement)
      expect(requests.length).toBe(count + 1)
      expect(written.length).toBe(0)
    })
  }
}

test('malformed Unix handshake stays inactive without schema 1 fallback', async ($, on) => {
  const { written, requests } = stubs(on, true, () => ({
    status: 200, ok: true, headers: {}, text: '{"status":"connected","extra":true}',
  }))
  const connected = await $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  expect(connected.text.includes('failed')).toBe(true)
  await $.session.measure(measurement)
  expect(requests.length).toBe(1)
  expect(written.length).toBe(0)
})

test('Unix HTTP refuses metadata after grant replacement', async ($, on) => {
  const { written, requests, files } = stubs(on, true)
  await $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  files.set(`${UNIX_DIR}/probe-grant.json`, GRANT)
  await $.session.measure(measurement)
  const status = await $.command.run({ command: 'quotatempo-probe', args: 'status' })
  expect(status.text).toBe(DISCONNECT_UNCONFIRMED)
  expect(requests.length).toBe(1)
  expect(written.length).toBe(0)
})

test('Unix cancellation waits for handshake cleanup and disconnect confirmation', async ($, on) => {
  const handshakeEntered = deferred()
  const handshakeGate = deferred()
  const disconnectEntered = deferred()
  const disconnectGate = deferred()
  const { written, requests } = stubs(on, true, async e => {
    if (e.url.endsWith('/connect')) {
      handshakeEntered.resolve()
      await handshakeGate.promise
      return e.reply
    }
    expect(e.url).toBe('http://quotatempo/disconnect')
    disconnectEntered.resolve()
    await disconnectGate.promise
    return e.reply
  })
  const connecting = $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  await handshakeEntered.promise
  let closed = false
  const closing = $.command.run({ command: 'quotatempo-probe', args: 'disconnect' }).then((result: any) => {
    closed = true
    return result
  })
  await Promise.resolve()
  expect(closed).toBe(false)
  expect(requests.length).toBe(1)
  handshakeGate.resolve()
  await disconnectEntered.promise
  expect(closed).toBe(false)
  expect(requests.length).toBe(2)
  disconnectGate.resolve()
  expect((await connecting).text).toBe('Probe connection cancelled. No product source was changed.')
  expect((await closing).text).toBe('QuotaTempo probe disconnected. No product source was changed.')
  expect(JSON.stringify(requests[1].body)).toBe(JSON.stringify(requests[0].body))
  await $.session.measure(measurement)
  expect(requests.length).toBe(2)
  expect(written.length).toBe(0)
})

test('Unix clock failure keeps explicit disconnect control without exporting another quota', async ($, on) => {
  const { written, requests, clock } = stubs(on, true)
  await $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  await $.session.measure(measurement)
  clock.value = NaN
  await $.session.measure(measurement)
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text).toBe(DISCONNECT_UNCONFIRMED)
  await $.session.measure(measurement)
  expect(requests.length).toBe(2)
  const disconnected = await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
  expect(disconnected.text).toBe('QuotaTempo probe disconnected. No product source was changed.')
  expect(requests[2].url).toBe('http://quotatempo/disconnect')
  expect(JSON.stringify(requests[2].body)).toBe(JSON.stringify(requests[0].body))
  await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
  await $.session.measure(measurement)
  expect(requests.length).toBe(3)
  expect(written.length).toBe(0)
})

test('Unix uncertain export retains only disconnect control and never retries quota', async ($, on) => {
  const { written, requests } = stubs(on, true, e => e.url.endsWith('/measure')
    ? { status: 503, ok: false, headers: {}, text: '{"status":"accepted"}' } : e.reply)
  await $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  await $.session.measure(measurement)
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text).toBe(DISCONNECT_UNCONFIRMED)
  await $.session.measure(measurement)
  expect(requests.length).toBe(2)
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })).text).toBe('QuotaTempo probe disconnected. No product source was changed.')
  expect(requests.map(e => e.url).join(',')).toBe('http://quotatempo/connect,http://quotatempo/measure,http://quotatempo/disconnect')
  expect(JSON.stringify(requests[2].body)).toBe(JSON.stringify(requests[0].body))
  expect(written.length).toBe(0)
})

test('Unix failed disconnect confirmation has fixed output and is not retried', async ($, on) => {
  const { written, requests } = stubs(on, true, e => e.url.endsWith('/connect') ? e.reply : ({
    status: 200, ok: true, headers: {}, text: '{"status":"disconnected","extra":true}',
  }))
  await $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })).text).toBe(DISCONNECT_UNCONFIRMED)
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })).text).toBe(DISCONNECT_UNCONFIRMED)
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text).toBe(DISCONNECT_UNCONFIRMED)
  await $.session.measure(measurement)
  expect(requests.length).toBe(2)
  expect(written.length).toBe(0)
})

// Official engine/VM coverage with stubbed I/O, not live Code/native acceptance.
for (const endpoint of ['connect', 'measure', 'disconnect']) {
  test(`Unix ${endpoint} deadline ignores a late authentic reply without quota replay`, async ($, on) => {
    const entered = deferred()
    const late = deferred()
    const { written, requests, timers } = stubs(on, true, async e => {
      if (e.url.endsWith(`/${endpoint}`)) {
        entered.resolve()
        await late.promise
      }
      return e.reply
    })
    if (endpoint !== 'connect') {
      expect((await $.command.run({ command: 'quotatempo-probe', args: CONNECT })).text.includes('Comparison-only')).toBe(true)
    }
    let finished = false
    const pending = (endpoint === 'measure' ? $.session.measure(measurement)
      : $.command.run({ command: 'quotatempo-probe', args: endpoint === 'connect' ? CONNECT : 'disconnect' }))
      .then((result: any) => { finished = true; return result })
    await entered.promise
    await timers.advance(4999)
    expect(finished).toBe(false)
    await timers.advance(1)
    const answer = await pending
    if (endpoint === 'connect') expect(answer.text.includes('connection failed')).toBe(true)
    if (endpoint === 'disconnect') expect(answer.text).toBe(DISCONNECT_UNCONFIRMED)
    expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text).toBe(DISCONNECT_UNCONFIRMED)
    const count = requests.length
    late.resolve()
    await timers.settle()
    await $.session.measure(measurement)
    expect(requests.length).toBe(count)
    expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text).toBe(DISCONNECT_UNCONFIRMED)
    const stopped = await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
    expect(stopped.text).toBe(endpoint === 'disconnect' ? DISCONNECT_UNCONFIRMED
      : 'QuotaTempo probe disconnected. No product source was changed.')
    await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
    expect(requests.filter(e => e.url.endsWith('/disconnect')).length).toBe(1)
    expect(written.length).toBe(0)
  })
}

test('Unix stop waits only for bounded measure and disconnect wrappers, discarding queued quota', async ($, on) => {
  const measureEntered = deferred()
  const disconnectEntered = deferred()
  const lateMeasure = deferred()
  const lateDisconnect = deferred()
  const { written, requests, timers } = stubs(on, true, async e => {
    if (e.url.endsWith('/measure')) { measureEntered.resolve(); await lateMeasure.promise }
    if (e.url.endsWith('/disconnect')) { disconnectEntered.resolve(); await lateDisconnect.promise }
    return e.reply
  })
  await $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  const measuring = $.session.measure(measurement)
  await measureEntered.promise
  const queued = $.session.measure({ ...measurement,
    rateLimits: [{ ...measurement.rateLimits[0], percentUsed: 60 }] })
  let closed = false
  const closing = $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
    .then((result: any) => { closed = true; return result })
  await timers.settle()
  expect(closed).toBe(false)
  await timers.advance(5000)
  await disconnectEntered.promise
  expect(closed).toBe(false)
  await timers.advance(5000)
  expect((await closing).text).toBe(DISCONNECT_UNCONFIRMED)
  await measuring
  await queued
  expect(requests.map(e => e.url).join(',')).toBe('http://quotatempo/connect,http://quotatempo/measure,http://quotatempo/disconnect')
  expect(JSON.stringify(requests[2].body)).toBe(JSON.stringify(requests[0].body))
  lateMeasure.resolve()
  lateDisconnect.resolve()
  await timers.settle()
  await $.session.measure(measurement)
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })).text).toBe(DISCONNECT_UNCONFIRMED)
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'status' })).text).toBe(DISCONNECT_UNCONFIRMED)
  expect(requests.length).toBe(3)
  expect(written.length).toBe(0)
})

test('Unix cancelled stalled handshake and disconnect each expire without late activation', async ($, on) => {
  const connectEntered = deferred()
  const disconnectEntered = deferred()
  const late = deferred()
  const { written, requests, timers } = stubs(on, true, async e => {
    if (e.url.endsWith('/connect')) connectEntered.resolve()
    else disconnectEntered.resolve()
    await late.promise
    return e.reply
  })
  const connecting = $.command.run({ command: 'quotatempo-probe', args: CONNECT })
  await connectEntered.promise
  const closing = $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })
  await timers.settle()
  await timers.advance(5000)
  expect((await connecting).text.includes('connection failed')).toBe(true)
  await disconnectEntered.promise
  await timers.advance(5000)
  expect((await closing).text).toBe(DISCONNECT_UNCONFIRMED)
  late.resolve()
  await timers.settle()
  await $.session.measure(measurement)
  expect((await $.command.run({ command: 'quotatempo-probe', args: 'disconnect' })).text).toBe(DISCONNECT_UNCONFIRMED)
  expect(requests.map(e => e.url).join(',')).toBe('http://quotatempo/connect,http://quotatempo/disconnect')
  expect(written.length).toBe(0)
})
