async function loadVersion() {
  const res = await fetch('/api/version')
  const data = await res.json()
  document.getElementById('version').textContent = `Phiên bản ${data.version}`
}

function renderNotes(items) {
  const list = document.getElementById('notes')
  list.replaceChildren()
  for (const note of items) {
    const li = document.createElement('li')
    const header = document.createElement('header')
    const title = document.createElement('strong')
    title.textContent = note.title
    const del = document.createElement('button')
    del.type = 'button'
    del.className = 'danger'
    del.textContent = 'Xóa'
    del.addEventListener('click', async () => {
      await fetch(`/api/notes/${note.id}`, { method: 'DELETE' })
      await loadNotes()
    })
    header.append(title, del)
    const body = document.createElement('p')
    body.textContent = note.body || '—'
    li.append(header, body)
    list.append(li)
  }
}

async function loadNotes() {
  const res = await fetch('/api/notes')
  const data = await res.json()
  renderNotes(data.items)
}

document.getElementById('note-form').addEventListener('submit', async (event) => {
  event.preventDefault()
  const title = document.getElementById('title').value.trim()
  const body = document.getElementById('body').value.trim()
  if (!title) return
  await fetch('/api/notes', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title, body }),
  })
  event.target.reset()
  await loadNotes()
})

loadVersion()
loadNotes()
