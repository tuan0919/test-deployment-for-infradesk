function versionLabel(version) {
  return 'Phiên bản ' + version
}

fetch('./version.json')
  .then((response) => {
    if (!response.ok) throw new Error('Không đọc được version.json')
    return response.json()
  })
  .then((data) => {
    document.getElementById('version').textContent = versionLabel(data.version)
  })
  .catch((error) => {
    document.getElementById('version').textContent = error.message
  })
