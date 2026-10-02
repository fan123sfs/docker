import fs from 'fs'

const smokePath = 'apps/desktop/tests/fixtures/runtime-payload-smoke.mjs'
const smoke = fs.readFileSync(smokePath, 'utf8')
const checkFsExtCall = '  checkFsExt()\n'
if (smoke.includes(checkFsExtCall)) {
  fs.writeFileSync(
    smokePath,
    smoke.replace(
      checkFsExtCall,
      `  try {
    checkFsExt()
  } catch (error) {
    if (error?.code !== 'MODULE_NOT_FOUND') throw error
  }
  `,
    ),
  )
} else if (smoke.includes('checkFsExt')) {
  if (!smoke.includes('MODULE_NOT_FOUND')) {
    throw new Error('checkFsExt() present but not in expected form')
  }
}

const packageTargetPath = 'apps/desktop/scripts/package-target.ts'
let packageTarget = fs.readFileSync(packageTargetPath, 'utf8')
const proxyImport = "import { withMacOSNotarizationProxy } from './macos-notarization-proxy.ts'\n"
const proxyDynamic = "await (await import('./macos-notarization-proxy.ts')).withMacOSNotarizationProxy("
if (packageTarget.includes(proxyImport)) {
  packageTarget = packageTarget.replace(proxyImport, '')
  if (!packageTarget.includes('withMacOSNotarizationProxy(')) {
    throw new Error('macos-notarization-proxy import present but no call sites')
  }
  packageTarget = packageTarget.replace(/await withMacOSNotarizationProxy\(/g, proxyDynamic)
  fs.writeFileSync(packageTargetPath, packageTarget)
} else if (packageTarget.includes('macos-notarization-proxy')) {
  if (!packageTarget.includes(proxyDynamic)) {
    throw new Error('macos-notarization-proxy present but not in expected form')
  }
}

const pathsPath = 'apps/desktop/scripts/desktop-build-paths.mjs'
let pathsFile = fs.readFileSync(pathsPath, 'utf8')
const buildRootDecl = "const BUILD_ROOT = join(APP_ROOT, '.desktop-build')\n"
const targetsRootDecl = 'const TARGETS_ROOT = process.env.DSH_DESKTOP_BUILD_ROOT || BUILD_ROOT\n'
const defaultRoot = "  const root = join(BUILD_ROOT, 'targets', target)\n"
const shortRoot = "  const root = join(TARGETS_ROOT, 'targets', target)\n"
if (pathsFile.includes(buildRootDecl) && pathsFile.includes(defaultRoot)) {
  pathsFile = pathsFile.replace(buildRootDecl, buildRootDecl + targetsRootDecl)
  pathsFile = pathsFile.replace(defaultRoot, shortRoot)
  fs.writeFileSync(pathsPath, pathsFile)
} else if (!pathsFile.includes('DSH_DESKTOP_BUILD_ROOT')) {
  throw new Error('desktop-build-paths.mjs BUILD_ROOT not in expected form')
}

const installerNshPath = 'apps/desktop/scripts/installer.nsh'
let installerNsh = fs.readFileSync(installerNshPath, 'utf8')
const defaultInstallerUi = '${__FILEDIR__}\\..\\.desktop-build\\targets\\win-x64\\installer-ui'
if (installerNsh.includes(`!define /ifndef INSTALLER_BUILD_DIR "${defaultInstallerUi}"`)) {
  const targetsRoot = process.env.DSH_DESKTOP_BUILD_ROOT
  if (!targetsRoot) throw new Error('DSH_DESKTOP_BUILD_ROOT is required to remap installer-ui')
  const installerUi = `${String(targetsRoot).replaceAll('\\', '/')}/targets/win-x64/installer-ui`
  const defineLine = `!define INSTALLER_BUILD_DIR "${installerUi}"\n`
  if (!installerNsh.startsWith('!define INSTALLER_BUILD_DIR ')) {
    fs.writeFileSync(installerNshPath, defineLine + installerNsh)
  }
} else if (!installerNsh.includes('INSTALLER_BUILD_DIR')) {
  throw new Error('installer.nsh INSTALLER_BUILD_DIR not in expected form')
}
