import pg from 'pg'
import { resolveAppVersion } from './version.js'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})

export async function initDb() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS notes (
      id SERIAL PRIMARY KEY,
      title TEXT NOT NULL,
      body TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `)
}

export async function listNotes() {
  const result = await pool.query(
    'SELECT id, title, body, created_at FROM notes ORDER BY id DESC',
  )
  return result.rows
}

export async function createNote({ title, body }) {
  const result = await pool.query(
    'INSERT INTO notes (title, body) VALUES ($1, $2) RETURNING id, title, body, created_at',
    [title, body ?? ''],
  )
  return result.rows[0]
}

export async function deleteNote(id) {
  const result = await pool.query('DELETE FROM notes WHERE id = $1 RETURNING id', [id])
  return result.rowCount > 0
}

export async function healthCheck() {
  await pool.query('SELECT 1')
  return {
    ok: true,
    version: resolveAppVersion(),
    uploadDir: process.env.UPLOAD_DIR ?? null,
  }
}

export async function closeDb() {
  await pool.end()
}
