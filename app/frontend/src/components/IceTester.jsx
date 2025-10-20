import { useState, useRef } from 'react'
import styles from './IceTester.module.css'

// ---------------------------------------------------------------------------
// TURN REST API credential generation (HMAC-SHA1 via WebCrypto)
// ---------------------------------------------------------------------------
async function hmacSha1Base64(secret, message) {
  const enc = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw', enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-1' },
    false, ['sign']
  )
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(message))
  return btoa(String.fromCharCode(...new Uint8Array(sig)))
}

async function buildIceServers(host, port, secret, ttl) {
  const expires    = Math.floor(Date.now() / 1000) + parseInt(ttl, 10)
  const username   = String(expires)
  const credential = await hmacSha1Base64(secret, username)
  return {
    username,
    credential,
    servers: [
      { urls: `stun:${host}:${port}` },
      { urls: `turn:${host}:${port}?transport=udp`, username, credential },
      { urls: `turn:${host}:${port}?transport=tcp`, username, credential },
      { urls: `turns:${host}:5349?transport=tcp`,   username, credential },
    ],
  }
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------
export default function IceTester() {
  const [host,    setHost]    = useState(import.meta.env.VITE_TURN_HOST ?? '')
  const [port,    setPort]    = useState('3478')
  const [secret,  setSecret]  = useState('')
  const [ttl,     setTtl]     = useState('3600')
  const [results, setResults] = useState([])
  const [verdict, setVerdict] = useState(null)   // null | 'relay' | 'srflx' | 'host-only'
  const [running, setRunning] = useState(false)
  const pcRef    = useRef(null)
  const seenRef  = useRef({ srflx: false, relay: false })

  const append = (text, type = 'default') =>
    setResults(prev => [...prev, { text, type, id: crypto.randomUUID() }])

  const finish = (reason, seen) => {
    setRunning(false)
    append('')
    append(`ICE gathering ${reason}.`, 'info')
    pcRef.current?.close()
    pcRef.current = null

    if (seen.relay)      setVerdict('relay')
    else if (seen.srflx) setVerdict('srflx')
    else                 setVerdict('host-only')
  }

  const runTest = async () => {
    if (running) return
    setResults([])
    setVerdict(null)
    setRunning(true)
    seenRef.current = { srflx: false, relay: false }

    if (!host || !secret) {
      append('host and secret are required.', 'error')
      setRunning(false)
      return
    }

    append(`Starting ICE gathering  →  ${host}:${port}`, 'info')

    let creds
    try {
      creds = await buildIceServers(host, port, secret, ttl)
    } catch (e) {
      append(`Credential error: ${e.message}`, 'error')
      setRunning(false)
      return
    }

    append(`Username:   ${creds.username}`, 'info')
    append(`Credential: ${creds.credential}`, 'info')
    append('')

    let pc
    try {
      pc = new RTCPeerConnection({ iceServers: creds.servers })
    } catch (e) {
      append(`RTCPeerConnection error: ${e.message}`, 'error')
      setRunning(false)
      return
    }
    pcRef.current = pc

    let done = false
    const stop = (reason) => {
      if (done) return
      done = true
      finish(reason, seenRef.current)
    }

    // Data channel forces ICE gathering
    pc.createDataChannel('test')

    pc.onicecandidate = ({ candidate }) => {
      if (!candidate || candidate.candidate === '') {
        stop('complete')
        return
      }
      const sdp        = candidate.candidate
      const typeMatch  = sdp.match(/typ (\S+)/)
      const type       = typeMatch ? typeMatch[1] : candidate.type
      const relayMatch = sdp.match(/^\S+ \S+ (\S+) \S+ (\S+) (\d+) typ relay/)
      const srflxMatch = sdp.match(/^\S+ \S+ (\S+) \S+ (\S+) (\d+) typ srflx/)

      if (type === 'relay') {
        seenRef.current.relay = true
        const proto = relayMatch ? relayMatch[1].toLowerCase() : candidate.protocol
        const ip    = relayMatch ? relayMatch[2] : candidate.address
        const p     = relayMatch ? relayMatch[3] : candidate.port
        append(`[relay]  ${proto}  ${ip}:${p}`, 'relay')
      } else if (type === 'srflx') {
        seenRef.current.srflx = true
        const proto = srflxMatch ? srflxMatch[1].toLowerCase() : candidate.protocol
        const ip    = srflxMatch ? srflxMatch[2] : candidate.address
        const p     = srflxMatch ? srflxMatch[3] : candidate.port
        append(`[srflx]  ${proto}  ${ip}:${p}`, 'srflx')
      } else {
        append(`[${type}]  ${sdp.split(' ').slice(0, 8).join(' ')}`, 'host')
      }
    }

    pc.onicegatheringstatechange = () => {
      if (pc.iceGatheringState === 'complete') stop('complete')
    }

    try {
      const offer = await pc.createOffer()
      await pc.setLocalDescription(offer)
    } catch (e) {
      append(`Offer error: ${e.message}`, 'error')
      stop('failed')
    }

    setTimeout(() => stop('timed out after 15 s'), 15_000)
  }

  const VERDICTS = {
    'relay': {
      label: 'TURN working — relay candidate received',
      cls:   'verdictOk',
    },
    'srflx': {
      label: 'STUN reachable, but no relay — check your secret',
      cls:   'verdictWarn',
    },
    'host-only': {
      label: 'Server unreachable — check host and port',
      cls:   'verdictFail',
    },
  }

  return (
    <div className={styles.tester}>
      <h1>TURN Server ICE Tester</h1>
      <p className={styles.subtitle}>
        Generates HMAC-SHA1 REST credentials in-browser and runs ICE gathering.
      </p>

      <label>TURN Host</label>
      <input value={host}   onChange={e => setHost(e.target.value)}   placeholder="turn.example.com" />

      <label>TURN Port</label>
      <input value={port}   onChange={e => setPort(e.target.value)}   type="number" />

      <label>Shared Secret</label>
      <input value={secret} onChange={e => setSecret(e.target.value)} type="password" placeholder="static-auth-secret" />

      <label>TTL (seconds)</label>
      <input value={ttl}    onChange={e => setTtl(e.target.value)}    type="number" />

      <div className={styles.actions}>
        <button onClick={runTest} disabled={running}>
          {running ? 'Gathering...' : 'Run ICE Gathering'}
        </button>
        <button onClick={() => { setResults([]); setVerdict(null) }} className={styles.secondary}>
          Clear
        </button>
      </div>

      {verdict && (
        <div className={`${styles.verdict} ${styles[VERDICTS[verdict].cls]}`}>
          {VERDICTS[verdict].label}
        </div>
      )}

      <div className={styles.output}>
        {results.length === 0
          ? <span className={styles.placeholder}>Results will appear here...</span>
          : results.map(r => (
              r.text === ''
                ? <br key={r.id} />
                : <span key={r.id} className={styles[r.type] ?? ''}>{r.text}{'\n'}</span>
            ))
        }
      </div>
    </div>
  )
}
