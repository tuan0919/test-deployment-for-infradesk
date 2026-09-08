export function resolveAppVersion(env = process.env) {
  const value = env.APP_VERSION?.trim()
  return value ? value : 'latest'
}

export function versionLabel(version) {
  return `Phiên bản ${version}`
}
