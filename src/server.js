import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { join, extname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { closeDb, createNote, deleteNote, healthCheck, initDb, listNotes } from './db.js'
import { resolveAppVersion } from './version.js'

const root = join(fileURLToPath(import.meta.url), '..', '..')
const publicDir = join(root, 'public')
const port = Number(process.env.PORT ?? 3000)

const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
}

function sendJson(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' })
  res.end(body === undefined ? '' : JSON.stringify(body))
}

async function readJson(req) {
  const chunks = []
  for await (const chunk of req) chunks.push(chunk)
  const text = Buffer.concat(chunks).toString('utf8')
  if (!text) return {}
  return JSON.parse(text)
}

async function handleApi(req, res, pathname) {
  if (pathname === '/api/health' && req.method === 'GET') {
    return sendJson(res, 200, await healthCheck())
  }
  if (pathname === '/api/version' && req.method === 'GET') {
    return sendJson(res, 200, { version: resolveAppVersion() })
  }
  if (pathname === '/api/notes' && req.method === 'GET') {
    return sendJson(res, 200, { items: await listNotes() })
  }
  if (pathname === '/api/notes' && req.method === 'POST') {
    const body = await readJson(req)
    const title = String(body.title ?? '').trim()
    if (!title) return sendJson(res, 400, { error: 'title is required' })
    const note = await createNote({ title, body: String(body.body ?? '') })
    return sendJson(res, 201, note)
  }
  const match = /^\/api\/notes\/(\d+)$/.exec(pathname)
  if (match && req.method === 'DELETE') {
    const ok = await deleteNote(Number(match[1]))
    return sendJson(res, ok ? 204 : 404, ok ? undefined : { error: 'not found' })
  }
  return false
}

async function serveStatic(res, pathname) {
  const rel = pathname === '/' ? '/index.html' : pathname
  const file = join(publicDir, rel)
  if (!file.startsWith(publicDir)) {
    res.writeHead(403)
    res.end('Forbidden')
    return
  }
  try {
    const data = await readFile(file)
    res.writeHead(200, { 'Content-Type': mime[extname(file)] ?? 'application/octet-stream' })
    res.end(data)
  } catch {
    res.writeHead(404)
    res.end('Not found')
  }
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
    const handled = await handleApi(req, res, url.pathname)
    if (handled !== false) return
    await serveStatic(res, url.pathname)
  } catch (error) {
    sendJson(res, 500, { error: error instanceof Error ? error.message : 'internal error' })
  }
})

await initDb()
server.listen(port, () => {
  console.log(`listening on ${port}, version=${resolveAppVersion()}`)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    server.close()
    await closeDb()
    process.exit(0)
  })
}
