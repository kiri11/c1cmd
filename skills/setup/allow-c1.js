// Writes Claude Code allow rules for c1 into a settings file, idempotently.
// usage: osascript -l JavaScript allow-c1.js read-only|all <path to c1> [settings.json]
// The commands and which are read-only come from `c1 --commands`, the command table.
ObjC.import('Foundation')

function quoted(text) { return "'" + text.replace(/'/g, "'\\''") + "'" }

function run(argv) {
    const mode = argv[0]
    if ((mode !== 'read-only' && mode !== 'all') || !argv[1]) return 'usage: osascript -l JavaScript allow-c1.js read-only|all <path to c1> [settings.json]'
    const env = $.NSProcessInfo.processInfo.environment
    const home = ObjC.unwrap(env.objectForKey('HOME'))
    const configDir = ObjC.unwrap(env.objectForKey('CLAUDE_CONFIG_DIR')) || home + '/.claude'
    const path = argv[2] || configDir + '/settings.json'

    const app = Application.currentApplication()
    app.includeStandardAdditions = true
    const commands = JSON.parse(app.doShellScript(quoted(argv[1]) + ' --commands'))
    const wanted = commands.filter(c => mode === 'all' || c.readOnly).map(c => 'Bash(c1 ' + c.name + ' *)')

    const fm = $.NSFileManager.defaultManager
    let settings = {}
    if (fm.fileExistsAtPath(path)) {
        const text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null))
        settings = text && text.trim() ? JSON.parse(text) : {}
    }
    settings.permissions = settings.permissions || {}
    const allow = settings.permissions.allow || []
    // Only rules for c1's own commands are c1's to manage; every other rule stays as it is.
    const ours = rule => commands.some(c => rule === 'Bash(c1 ' + c.name + ' *)')
    const kept = allow.filter(rule => !ours(rule) || wanted.includes(rule))
    const added = wanted.filter(rule => !kept.includes(rule))
    const removed = allow.filter(rule => !kept.includes(rule))
    if (added.length === 0 && removed.length === 0) return 'unchanged: ' + path + ' already allows ' + mode + ' c1 commands'

    settings.permissions.allow = kept.concat(added)
    fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(path).stringByDeletingLastPathComponent, true, $(), null)
    $(JSON.stringify(settings, null, 2) + '\n').writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)
    return 'updated ' + path + ': added ' + (added.join(', ') || 'none') + '; removed ' + (removed.join(', ') || 'none')
}
