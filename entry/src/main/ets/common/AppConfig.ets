import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { normalizeModelId } from './ModelCatalog'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { ACCENT_KEY, ACCENT_DEFAULT, accentOf, themeIdOf } from './Theme'
import { FONT_SCALE_KEY, fontScaleOf, fontIdOf } from './Typography'

interface SecretsFile {
  deepseekApiKey?: string
}

/**
 * Runtime configuration.
 *
 * The API key is resolved in this order: the value saved from Settings, then
 * the `rawfile/secrets.json` bundled at build time. The bundled file is
 * gitignored — never commit it, and rotate the key if the HAP is shared.
 */
export class AppConfig {
  static readonly BRIDGE_PORT: number = 4517
  static readonly PROVIDER: string = 'deepseek-official'
  /**
   * Fallback model id, used only until the real catalog arrives.
   *
   * `deepseek-flash` is the id dsh's provider catalog declares
   * (DeepSeek-V4.1-Flash, the one whose inputModalities include image). The
   * previous value `deepseek-v4-flash` is not in that catalog, so the SDK
   * profile handed `initialize` an id the provider had to reject. Settings now
   * fetches the list with the API key; this constant only covers the window
   * before a fetch succeeds.
   */
  static readonly MODEL: string = 'deepseek-flash'
  static readonly STORE: string = 'dsh_settings'
  static readonly PROFILE_SDK: string = 'sdk'
  static readonly PROFILE_ACP: string = 'acp'
  static readonly PERMISSION_READONLY: string = 'read-only'
  static readonly PERMISSION_WORKSPACE: string = 'workspace-write'
  static readonly PERMISSION_DANGER: string = 'danger-full-access'
  static readonly APPEARANCE_SYSTEM: string = 'system'
  static readonly APPEARANCE_LIGHT: string = 'light'
  static readonly APPEARANCE_DARK: string = 'dark'

  /**
   * Canonical model id.
   *
   * A blank choice means "not chosen yet" and falls back to the shipped
   * default; a legacy id (`deepseek-v4-flash`) is rewritten to the id the
   * provider catalog declares. Both doors matter: `load` fixes a stored value,
   * `save` keeps a stale one from being written again.
   */
  static normalizeModel(model: string): string {
    const normalized = normalizeModelId(model)
    return normalized.length === 0 ? AppConfig.MODEL : normalized
  }

  /** Named presets shipped by dsh (dsh-base cordis.patch.yml): sandbox + approval bundled. */
  static normalizePermissionMode(mode: string): string {
    if (mode === AppConfig.PERMISSION_READONLY || mode === AppConfig.PERMISSION_DANGER) {
      return mode
    }
    return AppConfig.PERMISSION_WORKSPACE
  }

  static apiKey: string = ''
  /**
   * GitHub token for `git push`. Kept apart from the API key and staged as its
   * own file (`dsh-home/.git-token`) because only the git tool reads it, and
   * because a token that can write to a repository is a different risk class
   * from a model key.
   */
  static gitToken: string = ''
  static model: string = AppConfig.MODEL
  /** Accent theme id; the colour itself lives in AppStorage for the views. */
  static accentId: string = 'blue'
  /** 'system' | 'light' | 'dark'; applied through the application context. */
  static appearance: string = AppConfig.APPEARANCE_SYSTEM
  /** Transcript text size id; the multiplier lives in AppStorage for the views. */
  static fontLevelId: string = 'standard'
  /**
   * dsh profile for the next boot.
   *
   * SDK stays the shipped default because it is the path that never needs a
   * restart to be understood, but it is the degraded one (no ohos profile, so
   * no pure-JS search, no streaming, no approvals). First launch therefore
   * asks once — see `profilePrompted` — and the answer is written here.
   */
  static profile: string = AppConfig.PROFILE_SDK
  /** Whether the first-launch mode question has been answered. */
  static profilePrompted: boolean = false
  /** Approval tier surfaced to bootstrap as DSH_PERMISSION_MODE. */
  static permissionMode: string = AppConfig.PERMISSION_WORKSPACE
  private static store: preferences.Preferences | null = null

  static async load(context: common.UIAbilityContext): Promise<void> {
    AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    const saved = await AppConfig.store.get('api_key', '') as string
    const token = await AppConfig.store.get('git_token', '') as string
    const storedModel = await AppConfig.store.get('model', AppConfig.MODEL) as string
    const profile = await AppConfig.store.get('profile', AppConfig.PROFILE_SDK) as string
    const prompted = await AppConfig.store.get('profile_prompted', false) as boolean
    const permission = await AppConfig.store.get('permission_mode', AppConfig.PERMISSION_WORKSPACE) as string
    const accent = await AppConfig.store.get('accent', 'blue') as string
    const appearance = await AppConfig.store.get('appearance', AppConfig.APPEARANCE_SYSTEM) as string
    const fontLevel = await AppConfig.store.get('font_level', 'standard') as string
    AppConfig.model = AppConfig.normalizeModel(storedModel)
    if (AppConfig.model !== storedModel) {
      // Persist the rewrite once: otherwise every boot keeps reading an id the
      // provider rejects, and the fix would only hold for this process.
      await AppConfig.store.put('model', AppConfig.model)
      await AppConfig.store.flush()
    }
    AppConfig.profile = profile === AppConfig.PROFILE_ACP ? AppConfig.PROFILE_ACP : AppConfig.PROFILE_SDK
    AppConfig.profilePrompted = prompted
    AppConfig.permissionMode = AppConfig.normalizePermissionMode(permission)
    AppConfig.accentId = themeIdOf(accentOf(accent))
    AppStorage.setOrCreate(ACCENT_KEY, accentOf(AppConfig.accentId))
    AppConfig.fontLevelId = fontIdOf(fontScaleOf(fontLevel))
    AppStorage.setOrCreate(FONT_SCALE_KEY, fontScaleOf(AppConfig.fontLevelId))
    AppConfig.appearance = AppConfig.normalizeAppearance(appearance)
    AppConfig.apiKey = saved.length > 0 ? saved : AppConfig.readBundledKey(context)
    AppConfig.gitToken = token
  }

  /**
   * `gitToken` is optional so every existing caller keeps working; pass it to
   * set or clear the GitHub token that `push` reads.
   */
  static async save(context: common.UIAbilityContext, key: string, model: string, gitToken?: string): Promise<void> {
    AppConfig.apiKey = key.trim()
    if (gitToken !== undefined) {
      AppConfig.gitToken = gitToken.trim()
    }
    AppConfig.model = AppConfig.normalizeModel(model)
    if (AppConfig.store === null) {
      AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    }
    await AppConfig.store.put('api_key', AppConfig.apiKey)
    await AppConfig.store.put('git_token', AppConfig.gitToken)
    await AppConfig.store.put('model', AppConfig.model)
    await AppConfig.store.flush()
    AppConfig.stageApiKey(context)
    AppConfig.stageGitToken(context)
  }

  /**
   * Mirror the token into `<filesDir>/dsh-home/.git-token`, the only path
   * `push` reads. Never an env var: node-bridge dumps the child environment
   * into node.log, so a token there would be readable from the shell.
   * bootstrap.cjs tightens the file to 0600 on the next boot, same as the API
   * key — ArkTS has no chmod.
   */
  private static stageGitToken(context: common.UIAbilityContext): void {
    const home = `${context.filesDir}/dsh-home`
    if (!fs.accessSync(home)) {
      return
    }
    const tokenPath = `${home}/.git-token`
    try {
      if (AppConfig.gitToken.length === 0) {
        if (fs.accessSync(tokenPath)) {
          fs.unlinkSync(tokenPath)
        }
        return
      }
      const tmpPath = `${home}/.git-token.tmp`
      const file = fs.openSync(tmpPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, AppConfig.gitToken)
      fs.closeSync(file)
      fs.renameSync(tmpPath, tokenPath)
    } catch (error) {
      // Staging is best-effort; the token also survives in preferences.
    }
  }

  /**
   * Mirror the saved key into `<filesDir>/dsh-home/.api-key`. The ohos
   * profile's credentials-live plugin watches that file and pushes changes
   * through the credentials service, so a key saved mid-session takes effect
   * without a restart (ACP path); the next boot re-seeds it via DSH_KEY_FILE.
   */
  private static stageApiKey(context: common.UIAbilityContext): void {
    const home = `${context.filesDir}/dsh-home`
    if (!fs.accessSync(home)) {
      // Pre-boot save: nothing to notify yet, boot writes the staged file.
      return
    }
    const keyPath = `${home}/.api-key`
    try {
      if (AppConfig.apiKey.length === 0) {
        // Cleared: drop the staged file so the live plugin clears the store
        // and the next boot stops seeding the env fallback.
        if (fs.accessSync(keyPath)) {
          fs.unlinkSync(keyPath)
        }
        return
      }
      // Atomic replace: a concurrent poller never observes a torn value.
      const tmpPath = `${home}/.api-key.tmp`
      const file = fs.openSync(tmpPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, AppConfig.apiKey)
      fs.closeSync(file)
      fs.renameSync(tmpPath, keyPath)
    } catch (error) {
      // Staging is best-effort; boot falls back to the same value from prefs.
    }
  }

  /**
   * Apply the saved appearance before the page is created.
   *
   * `setColorMode` while a page is alive rebuilds the window and leaves the
   * ArkUI tree blank on this device, so the switch is a boot-time decision:
   * EntryAbility calls this in onCreate, before loadContent, using the
   * synchronous preferences API. Changing it in Settings persists the choice
   * and asks for a restart.
   */
  static applyAppearanceAtBoot(context: common.UIAbilityContext): void {
    let mode: string = AppConfig.APPEARANCE_SYSTEM
    try {
      const store = preferences.getPreferencesSync(context, { name: AppConfig.STORE })
      mode = store.getSync('appearance', AppConfig.APPEARANCE_SYSTEM) as string
    } catch (error) {
      // No store yet (first launch): follow the system.
    }
    AppConfig.appearance = AppConfig.normalizeAppearance(mode)
    AppConfig.applyAppearance(context)
  }

  /**
   * Whether the offline speech engine has ever failed to start on this device.
   *
   * The syscap can be advertised while the offline Chinese model is a separate
   * download; the engine then fails every time with 1002200001. Remembering the
   * failure keeps the microphone out of the composer instead of offering a
   * button that can only produce the same toast on every launch.
   */
  static speechAsrUsable(context: common.UIAbilityContext): boolean {
    try {
      const store = preferences.getPreferencesSync(context, { name: AppConfig.STORE })
      return store.getSync('speech_asr_usable', true) as boolean
    } catch (error) {
      return true
    }
  }

  /**
   * Publish the flag into AppStorage at boot.
   *
   * The composer binds to AppStorage rather than reading preferences itself, so
   * resetting the flag from Settings makes the microphone come back without a
   * restart — the sheet and the chat are different components and only shared
   * state reaches both.
   */
  static applySpeechAtBoot(context: common.UIAbilityContext): void {
    AppStorage.setOrCreate('speechAsrUsable', AppConfig.speechAsrUsable(context))
  }

  /** Called once after the engine refuses to construct. */
  static setSpeechAsrUsable(context: common.UIAbilityContext, usable: boolean): void {
    try {
      const store = preferences.getPreferencesSync(context, { name: AppConfig.STORE })
      store.putSync('speech_asr_usable', usable)
      store.flush()
      AppStorage.setOrCreate('speechAsrUsable', usable)
    } catch (error) {
      // Losing the flag only costs one extra tap next launch.
    }
  }

  /** Unknown or legacy values fall back to following the system. */
  static normalizeAppearance(mode: string): string {
    if (mode === AppConfig.APPEARANCE_LIGHT || mode === AppConfig.APPEARANCE_DARK) {
      return mode
    }
    return AppConfig.APPEARANCE_SYSTEM
  }

  /**
   * Apply the appearance through the application context.
   *
   * The light and dark resource sets are already complete, so switching is one
   * runtime call — no restart, and the system setting is the default rather
   * than something the app fights.
   */
  static applyAppearance(context: common.UIAbilityContext): void {
    let mode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
    if (AppConfig.appearance === AppConfig.APPEARANCE_LIGHT) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
    } else if (AppConfig.appearance === AppConfig.APPEARANCE_DARK) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK
    }
    try {
      context.getApplicationContext().setColorMode(mode)
    } catch (error) {
      // Older devices may reject the call; the system setting still applies.
    }
  }

  /** Persist the appearance choice; it takes effect on the next launch. */
  static async saveAppearance(context: common.UIAbilityContext, mode: string): Promise<void> {
    AppConfig.appearance = AppConfig.normalizeAppearance(mode)
    if (AppConfig.store === null) {
      AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    }
    await AppConfig.store.put('appearance', AppConfig.appearance)
    await AppConfig.store.flush()
  }

  /** Persist the transcript text size and publish it to every bound view. */
  static async saveFontLevel(context: common.UIAbilityContext, id: string): Promise<void> {
    AppConfig.fontLevelId = fontIdOf(fontScaleOf(id))
    AppStorage.setOrCreate(FONT_SCALE_KEY, fontScaleOf(AppConfig.fontLevelId))
    if (AppConfig.store === null) {
      AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    }
    await AppConfig.store.put('font_level', AppConfig.fontLevelId)
    await AppConfig.store.flush()
  }

  /**
   * Persist the accent and publish it to every bound view.
   *
   * AppStorage is the transport, not the store: the id is what survives a
   * restart, the colour is what the views bind to. Setting both in one call
   * keeps a switch instant while leaving the persisted value authoritative on
   * the next launch.
   */
  static async saveAccent(context: common.UIAbilityContext, id: string): Promise<void> {
    AppConfig.accentId = themeIdOf(accentOf(id))
    AppStorage.setOrCreate(ACCENT_KEY, accentOf(AppConfig.accentId))
    if (AppConfig.store === null) {
      AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    }
    await AppConfig.store.put('accent', AppConfig.accentId)
    await AppConfig.store.flush()
  }

  /**
   * Record the first-launch mode answer.
   *
   * Called before the runtime boots, so the chosen profile is what this very
   * launch mounts — no restart involved. The marker keeps the question to
   * exactly one appearance, including after the user later switches modes in
   * Settings (that path goes through `saveRuntimeChoice`).
   */
  static async saveInitialProfile(context: common.UIAbilityContext, profile: string): Promise<void> {
    AppConfig.profile = profile === AppConfig.PROFILE_ACP ? AppConfig.PROFILE_ACP : AppConfig.PROFILE_SDK
    AppConfig.profilePrompted = true
    if (AppConfig.store === null) {
      AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    }
    await AppConfig.store.put('profile', AppConfig.profile)
    await AppConfig.store.put('profile_prompted', true)
    await AppConfig.store.flush()
  }

  /** Both profile and approval tier are read by bootstrap at boot, not live. */
  static async saveRuntimeChoice(context: common.UIAbilityContext, profile: string, permissionMode: string): Promise<void> {
    AppConfig.profile = profile === AppConfig.PROFILE_ACP ? AppConfig.PROFILE_ACP : AppConfig.PROFILE_SDK
    AppConfig.permissionMode = AppConfig.normalizePermissionMode(permissionMode)
    if (AppConfig.store === null) {
      AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    }
    await AppConfig.store.put('profile', AppConfig.profile)
    await AppConfig.store.put('permission_mode', AppConfig.permissionMode)
    await AppConfig.store.flush()
  }

  /** Optional build-time default key; absence is normal. */
  private static readBundledKey(context: common.UIAbilityContext): string {
    try {
      const bytes = context.resourceManager.getRawFileContentSync('secrets.json')
      const text = util.TextDecoder.create('utf-8').decodeToString(bytes)
      const parsed = JSON.parse(text) as SecretsFile
      const key = parsed.deepseekApiKey
      return key === undefined ? '' : key
    } catch (error) {
      const failure = error as BusinessError
      console.info(`no bundled secrets: ${failure.message}`)
      return ''
    }
  }
}
