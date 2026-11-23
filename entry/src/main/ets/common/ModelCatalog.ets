import { http } from '@kit.NetworkKit'

/**
 * The models this API key can actually use.
 *
 * Why fetch instead of shipping a list: which models an account may call is a
 * property of the credential and the deployment, not of this app. The client
 * used to carry `deepseek-v4-flash` as a constant, which is not an id dsh
 * knows (`deepseek-flash` and `deepseek-v4-pro` are), so the SDK profile sent
 * an id the provider had to reject and Settings displayed a name that looked
 * authoritative while being wrong.
 *
 * The endpoint is the one dsh itself calls: `new URL("/models", origin)` of the
 * provider's Messages baseURL (`https://api.deepseek.com/anthropic`), so this
 * stays consistent with whatever the runtime asks for.
 */
export const MODELS_URL: string = 'https://api.deepseek.com/models'

/** One selectable model, reduced to what the picker renders. */
export class ModelEntry {
  id: string = ''
  name: string = ''
  description: string = ''

  constructor(id: string, name: string, description: string) {
    this.id = id
    this.name = name
    this.description = description
  }
}

/** Read a string field, or '' when it is missing or not a string. */
function textOf(source: Record<string, Object>, key: string): string {
  const value = source[key]
  return typeof value === 'string' ? value as string : ''
}

/**
 * Decode a `/models` body into entries, tolerating anything else.
 *
 * Pure so it can be tested without a network: the shape is OpenAI-compatible
 * (`{ data: [{ id, ... }] }`) but the listing also carries `name` and
 * `description`, and a malformed body must yield an empty list rather than
 * throw inside the settings sheet.
 */
export function modelsFromBody(body: string): ModelEntry[] {
  if (body.length === 0) {
    return []
  }
  let parsed: Record<string, Object>
  try {
    parsed = JSON.parse(body) as Record<string, Object>
  } catch (error) {
    return []
  }
  const data = parsed['data']
  if (!Array.isArray(data)) {
    return []
  }
  const out: ModelEntry[] = []
  const seen: string[] = []
  for (const raw of data as Object[]) {
    if (raw === null || raw === undefined) {
      continue
    }
    const entry = raw as Record<string, Object>
    const id = textOf(entry, 'id').trim()
    if (id.length === 0 || seen.includes(id)) {
      continue
    }
    seen.push(id)
    const name = textOf(entry, 'name').trim()
    out.push(new ModelEntry(id, name.length === 0 ? id : name, textOf(entry, 'description').trim()))
  }
  return out
}

/** One authenticated GET; '' on any failure so callers can tell "empty" apart. */
async function getModels(apiKey: string): Promise<string> {
  const request = http.createHttp()
  try {
    const response = await request.request(MODELS_URL, {
      method: http.RequestMethod.GET,
      connectTimeout: 8000,
      readTimeout: 12000,
      header: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`
      }
    })
    if (response.responseCode !== 200) {
      return ''
    }
    return typeof response.result === 'string' ? response.result as string : ''
  } catch (error) {
    return ''
  } finally {
    request.destroy()
  }
}

/**
 * Fetch the catalog for this key.
 *
 * Returns [] for a blank key (nothing to authenticate with), a rejected key,
 * or an unreachable endpoint. The caller decides how to say that; the settings
 * sheet keeps the last known selection so a failed refresh cannot lock anyone
 * out of a working configuration.
 */
export async function fetchModels(apiKey: string): Promise<ModelEntry[]> {
  const key = apiKey.trim()
  if (key.length === 0) {
    return []
  }
  return modelsFromBody(await getModels(key))
}
