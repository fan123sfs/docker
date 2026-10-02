import fs from 'fs'

const p = 'apps/desktop/.env.windows'
const appId = process.env.DSH_DESKTOP_APP_ID
const mandatoryOrigin = process.env.DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN
if (!appId) throw new Error('DSH_DESKTOP_APP_ID is required')
if (!mandatoryOrigin) throw new Error('DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN is required')
let s = fs.readFileSync(p, 'utf8')
if (!/^DSH_DESKTOP_APP_ID=/m.test(s)) {
  throw new Error('.env.windows.example missing DSH_DESKTOP_APP_ID')
}
if (!/^DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN=/m.test(s)) {
  throw new Error('.env.windows.example missing DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN')
}
s = s.replace(/^DSH_DESKTOP_APP_ID=.*$/m, `DSH_DESKTOP_APP_ID=${appId}`)
s = s.replace(
  /^DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN=.*$/m,
  `DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN=${mandatoryOrigin}`,
)
fs.writeFileSync(p, s)
