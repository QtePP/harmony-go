/**
 * Pure parsers for the in-app Office preview.
 *
 * The app cannot reuse the Node plugin's parser (ArkTS and the runtime are
 * separate worlds), and it must not shell out for a conversion. What it can do
 * is unzip the package with the system zlib and parse the same OOXML with
 * plain string operations — no native library, no WebView, no network.
 *
 * Scope mirrors the writer: docx paragraphs/headings/lists/tables/emphasis and
 * xlsx sheets/cells/formulas/dates. Unknown parts are ignored rather than
 * thrown, because a preview that shows most of the document is more useful
 * than an error page. Caps keep a pathological file from freezing the UI.
 */

export enum DocBlockKind {
  HEADING = 'heading',
  PARAGRAPH = 'paragraph',
  BULLET = 'bullet',
  NUMBERED = 'numbered',
  TABLE = 'table',
  CODE = 'code',
  QUOTE = 'quote',
  RULE = 'rule'
}

/** One inline span. */
export class DocRun {
  text: string = ''
  bold: boolean = false
  italic: boolean = false
  code: boolean = false

  constructor(text: string, bold: boolean, italic: boolean, code: boolean) {
    this.text = text
    this.bold = bold
    this.italic = italic
    this.code = code
  }
}

/** One top-level document block. */
export class DocBlock {
  kind: DocBlockKind = DocBlockKind.PARAGRAPH
  level: number = 0
  runs: DocRun[] = []
  rows: string[][] = []

  constructor(kind: DocBlockKind, level: number, runs: DocRun[], rows: string[][]) {
    this.kind = kind
    this.level = level
    this.runs = runs
    this.rows = rows
  }
}

/** One worksheet reference resolved through the workbook relationships. */
export class SheetRef {
  name: string = ''
  target: string = ''

  constructor(name: string, target: string) {
    this.name = name
    this.target = target
  }
}

/** One parsed worksheet. */
export class SheetData {
  name: string = ''
  rows: string[][] = []
  truncated: boolean = false

  constructor(name: string, rows: string[][], truncated: boolean) {
    this.name = name
    this.rows = rows
    this.truncated = truncated
  }
}

const MAX_ROWS: number = 300
const MAX_COLS: number = 40
const MAX_CELL_CHARS: number = 300

/** Decode the entity forms Word/Excel emit. */
export function decodeXml(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (match: string, entity: string): string => {
    const lower = entity.toLowerCase()
    if (lower === 'amp') {
      return '&'
    }
    if (lower === 'lt') {
      return '<'
    }
    if (lower === 'gt') {
      return '>'
    }
    if (lower === 'quot') {
      return '"'
    }
    if (lower === 'apos') {
      return "'"
    }
    if (lower.startsWith('#x')) {
      return String.fromCodePoint(parseInt(lower.substring(2), 16))
    }
    return String.fromCodePoint(parseInt(lower.substring(1), 10))
  })
}

/** First attribute value by name (`w:val`, `r:id`, …), or ''. */
function attrOf(xml: string, name: string): string {
  const pattern = new RegExp('\\b' + name.replace(':', '\\:') + '="([^"]*)"')
  const match = pattern.exec(xml)
  return match === null ? '' : match[1]
}

/** A Word run property is on unless it is explicitly disabled. */
function propertyOn(props: string, tag: string): boolean {
  const pattern = new RegExp('<w:' + tag + '(\\s[^>]*)?/?>')
  const match = pattern.exec(props)
  if (match === null) {
    return false
  }
  return !/w:val="(0|false|off)"/.test(match[1] ?? '')
}

/** Concatenate every `<w:t>` in a fragment, ignoring formatting. */
function plainText(xml: string): string {
  let out = ''
  const pattern = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>/g
  let match = pattern.exec(xml)
  while (match !== null) {
    out += decodeXml(match[1])
    match = pattern.exec(xml)
  }
  return out
}

/** One paragraph's inline runs, with bold/italic/code. */
export function paragraphRuns(xml: string): DocRun[] {
  const runs: DocRun[] = []
  const runPattern = /<w:r(?:\s[^>]*)?>([\s\S]*?)<\/w:r>/g
  let runMatch = runPattern.exec(xml)
  while (runMatch !== null) {
    const body = runMatch[1]
    const propsMatch = /<w:rPr>([\s\S]*?)<\/w:rPr>/.exec(body)
    const props = propsMatch === null ? '' : propsMatch[1]
    let text = ''
    const textPattern = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>|<w:tab\/>|<w:br\/>/g
    let textMatch = textPattern.exec(body)
    while (textMatch !== null) {
      if (textMatch[1] !== undefined) {
        text += decodeXml(textMatch[1])
      } else if (textMatch[0] === '<w:tab/>') {
        text += '\t'
      } else {
        text += '\n'
      }
      textMatch = textPattern.exec(body)
    }
    if (text.length > 0) {
      const code = /w:rStyle w:val="CodeChar"/.test(props)
      runs.push(new DocRun(text, propertyOn(props, 'b'), propertyOn(props, 'i'), code))
    }
    runMatch = runPattern.exec(xml)
  }
  return runs
}

/** Classify one `<w:p>…</w:p>` into a block; null for an empty paragraph. */
export function paragraphBlock(xml: string): DocBlock | null {
  const runs = paragraphRuns(xml)
  if (runs.length === 0) {
    return null
  }
  const styleMatch = /<w:pStyle w:val="([^"]+)"/.exec(xml)
  const style = styleMatch === null ? '' : styleMatch[1]
  const heading = /^Heading([1-3])$/.exec(style)
  if (heading !== null) {
    return new DocBlock(DocBlockKind.HEADING, Number(heading[1]), runs, [])
  }
  if (style === 'CodeBlock') {
    return new DocBlock(DocBlockKind.CODE, 0, runs, [])
  }
  if (style === 'Quote') {
    return new DocBlock(DocBlockKind.QUOTE, 0, runs, [])
  }
  const numMatch = /<w:numId w:val="(\d+)"/.exec(xml)
  const numId = numMatch === null ? 0 : Number(numMatch[1])
  if (numId === 1) {
    return new DocBlock(DocBlockKind.BULLET, 0, runs, [])
  }
  if (numId === 2) {
    return new DocBlock(DocBlockKind.NUMBERED, 0, runs, [])
  }
  return new DocBlock(DocBlockKind.PARAGRAPH, 0, runs, [])
}

/** Parse the rows/cells of a `<w:tbl>` fragment. */
export function tableRows(xml: string): string[][] {
  const rows: string[][] = []
  const rowPattern = /<w:tr(?:\s[^>]*)?>([\s\S]*?)<\/w:tr>/g
  let rowMatch = rowPattern.exec(xml)
  while (rowMatch !== null) {
    const cells: string[] = []
    const cellPattern = /<w:tc(?:\s[^>]*)?>([\s\S]*?)<\/w:tc>/g
    let cellMatch = cellPattern.exec(rowMatch[1])
    while (cellMatch !== null) {
      const texts: string[] = []
      const paragraphPattern = /<w:p(?:\s[^>]*)?>([\s\S]*?)<\/w:p>/g
      let paragraphMatch = paragraphPattern.exec(cellMatch[1])
      while (paragraphMatch !== null) {
        const text = plainText(`<w:p>${paragraphMatch[1]}</w:p>`).trim()
        if (text.length > 0) {
          texts.push(text)
        }
        paragraphMatch = paragraphPattern.exec(cellMatch[1])
      }
      cells.push(texts.join(' '))
      cellMatch = cellPattern.exec(rowMatch[1])
    }
    rows.push(cells)
    rowMatch = rowPattern.exec(xml)
  }
  return rows
}

/** Locate the next `<w:name>` start tag, ignoring longer names. */
function nextTag(xml: string, name: string, from: number): number {
  const pattern = new RegExp('<w:' + name + '(?=[\\s/>])', 'g')
  pattern.lastIndex = from
  const match = pattern.exec(xml)
  return match === null ? -1 : match.index
}

/** Parse `word/document.xml` into blocks in body order. */
export function parseDocxBlocks(documentXml: string): DocBlock[] {
  const blocks: DocBlock[] = []
  const bodyStart = documentXml.indexOf('<w:body')
  if (bodyStart < 0) {
    return blocks
  }
  const open = documentXml.indexOf('>', bodyStart)
  const close = documentXml.lastIndexOf('</w:body>')
  if (open < 0 || close <= open) {
    return blocks
  }
  const body = documentXml.substring(open + 1, close)
  let position = 0
  while (position < body.length) {
    const pIndex = nextTag(body, 'p', position)
    const tIndex = nextTag(body, 'tbl', position)
    if (pIndex < 0 && tIndex < 0) {
      break
    }
    const isTable = tIndex >= 0 && (pIndex < 0 || tIndex < pIndex)
    const start = isTable ? tIndex : pIndex
    if (isTable) {
      let depth = 0
      let cursor = start
      let end = -1
      while (cursor < body.length) {
        const openTag = nextTag(body, 'tbl', cursor)
        const closeTag = body.indexOf('</w:tbl>', cursor)
        if (closeTag < 0) {
          break
        }
        if (openTag >= 0 && openTag < closeTag) {
          depth++
          cursor = openTag + 6
          continue
        }
        depth--
        cursor = closeTag + 8
        if (depth === 0) {
          end = cursor
          break
        }
      }
      if (end < 0) {
        break
      }
      const rows = tableRows(body.substring(start, end))
      if (rows.length > 0) {
        blocks.push(new DocBlock(DocBlockKind.TABLE, 0, [], rows))
      }
      position = end
      continue
    }
    const end = body.indexOf('</w:p>', start)
    if (end < 0) {
      break
    }
    const block = paragraphBlock(body.substring(start, end + 6))
    if (block !== null) {
      const previous = blocks.length > 0 ? blocks[blocks.length - 1] : null
      if (block.kind === DocBlockKind.CODE && previous !== null && previous.kind === DocBlockKind.CODE) {
        // The writer emits one paragraph per code line; merge them back.
        const merged = previous.runs.map((run) => run.text).join('') + '\n' + block.runs.map((run) => run.text).join('')
        previous.runs = [new DocRun(merged, false, false, true)]
      } else {
        blocks.push(block)
      }
    }
    position = end + 6
  }
  return blocks
}

/** Parse `<sheet>` entries and resolve each target through workbook rels. */
export function parseSheetRefs(workbookXml: string, relsXml: string): SheetRef[] {
  const rels: Map<string, string> = new Map<string, string>()
  const relPattern = /<Relationship\b[^>]*>/g
  let relMatch = relPattern.exec(relsXml)
  while (relMatch !== null) {
    const id = attrOf(relMatch[0], 'Id')
    const target = attrOf(relMatch[0], 'Target')
    const type = attrOf(relMatch[0], 'Type')
    if (id.length > 0 && target.length > 0 && (type.length === 0 || /\/worksheet$/.test(type))) {
      rels.set(id, target)
    }
    relMatch = relPattern.exec(relsXml)
  }
  const refs: SheetRef[] = []
  const sheetPattern = /<sheet\b[^>]*>/g
  let sheetMatch = sheetPattern.exec(workbookXml)
  let fallback = 1
  while (sheetMatch !== null) {
    const name = decodeXml(attrOf(sheetMatch[0], 'name'))
    let relId = attrOf(sheetMatch[0], 'r:id')
    if (relId.length === 0) {
      relId = attrOf(sheetMatch[0], 'id')
    }
    let target = rels.get(relId) ?? `worksheets/sheet${fallback}.xml`
    if (target.startsWith('/')) {
      target = target.substring(1)
    } else if (!target.startsWith('xl/')) {
      target = `xl/${target}`
    }
    refs.push(new SheetRef(name.length === 0 ? `Sheet${fallback}` : name, target))
    fallback++
    sheetMatch = sheetPattern.exec(workbookXml)
  }
  return refs
}

/** Shared-string table in index order. */
export function parseSharedStrings(xml: string): string[] {
  const values: string[] = []
  const siPattern = /<si>([\s\S]*?)<\/si>/g
  let match = siPattern.exec(xml)
  while (match !== null) {
    let text = ''
    const tPattern = /<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g
    let tMatch = tPattern.exec(match[1])
    while (tMatch !== null) {
      text += decodeXml(tMatch[1])
      tMatch = tPattern.exec(match[1])
    }
    values.push(text)
    match = siPattern.exec(xml)
  }
  return values
}

const BUILTIN_DATE_FORMATS: number[] = [14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47]

/** Style index → whether it renders as a date. */
export function parseDateStyles(stylesXml: string): boolean[] {
  const custom: Map<number, string> = new Map<number, string>()
  const numFmtPattern = /<numFmt\b[^>]*numFmtId="(\d+)"[^>]*formatCode="([^"]*)"[^>]*\/>/g
  let numFmtMatch = numFmtPattern.exec(stylesXml)
  while (numFmtMatch !== null) {
    custom.set(Number(numFmtMatch[1]), decodeXml(numFmtMatch[2]))
    numFmtMatch = numFmtPattern.exec(stylesXml)
  }
  const xfs = /<cellXfs\b[^>]*>([\s\S]*?)<\/cellXfs>/.exec(stylesXml)
  if (xfs === null) {
    return []
  }
  const result: boolean[] = []
  const xfPattern = /<xf\b([^>]*?)\/?>/g
  let xfMatch = xfPattern.exec(xfs[1])
  while (xfMatch !== null) {
    const idMatch = /numFmtId="(\d+)"/.exec(xfMatch[1])
    const id = idMatch === null ? 0 : Number(idMatch[1])
    const format = custom.get(id)
    if (BUILTIN_DATE_FORMATS.indexOf(id) >= 0) {
      result.push(true)
    } else if (format !== undefined && /[ymd]/i.test(format) && !/^[#0.,%]+$/.test(format)) {
      result.push(true)
    } else {
      result.push(false)
    }
    xfMatch = xfPattern.exec(xfs[1])
  }
  return result
}

/** Excel serial date → ISO text (handles the 1900 leap-year quirk). */
export function serialToIso(serial: number): string {
  if (!Number.isFinite(serial) || serial < 0) {
    return `${serial}`
  }
  const whole = Math.floor(serial)
  const fraction = serial - whole
  const days = whole <= 59 ? whole + 1 : whole
  const date = new Date(Date.UTC(1899, 11, 30) + days * 86400000)
  if (Number.isNaN(date.getTime())) {
    return `${serial}`
  }
  const y = date.getUTCFullYear()
  const m = `${date.getUTCMonth() + 1}`.padStart(2, '0')
  const d = `${date.getUTCDate()}`.padStart(2, '0')
  const iso = `${y}-${m}-${d}`
  if (fraction <= 0) {
    return iso
  }
  const seconds = Math.round(fraction * 86400)
  const hh = `${Math.floor(seconds / 3600)}`.padStart(2, '0')
  const mm = `${Math.floor((seconds % 3600) / 60)}`.padStart(2, '0')
  const ss = `${seconds % 60}`.padStart(2, '0')
  return `${iso} ${hh}:${mm}:${ss}`
}

/** Zero-based column index for `A`, `AA`…; -1 when invalid. */
export function columnIndex(letters: string): number {
  let value = 0
  const upper = letters.toUpperCase()
  for (let index = 0; index < upper.length; index++) {
    const digit = upper.charCodeAt(index) - 64
    if (digit < 1 || digit > 26) {
      return -1
    }
    value = value * 26 + digit
  }
  return value - 1
}

/** `A`, `Z`, `AA`… for a zero-based column index. */
export function columnName(index: number): string {
  let name = ''
  let value = index + 1
  while (value > 0) {
    const remainder = (value - 1) % 26
    name = String.fromCharCode(65 + remainder) + name
    value = Math.floor((value - 1) / 26)
  }
  return name
}

function clipCell(value: string): string {
  return value.length > MAX_CELL_CHARS ? value.substring(0, MAX_CELL_CHARS) : value
}

/** Parse one worksheet into a rectangular string matrix. */
export function parseWorksheet(xml: string, shared: string[], dates: boolean[]): string[][] {
  const rows: string[][] = []
  const rowPattern = /<row\b([^>]*)>([\s\S]*?)<\/row>/g
  let rowMatch = rowPattern.exec(xml)
  while (rowMatch !== null) {
    const rowNumberMatch = /r="(\d+)"/.exec(rowMatch[1])
    const rowNumber = rowNumberMatch === null ? rows.length + 1 : Number(rowNumberMatch[1])
    const cells: string[] = []
    const cellPattern = /<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g
    let cellMatch = cellPattern.exec(rowMatch[2])
    while (cellMatch !== null) {
      const attrs = cellMatch[1]
      const body = cellMatch[2] ?? ''
      const reference = /r="([A-Za-z]+)(\d+)"/.exec(attrs)
      const column = reference === null ? cells.length : columnIndex(reference[1])
      if (column >= 0 && column < MAX_COLS) {
        while (cells.length < column) {
          cells.push('')
        }
        const typeMatch = /t="([^"]+)"/.exec(attrs)
        const type = typeMatch === null ? 'n' : typeMatch[1]
        const styleMatch = /s="(\d+)"/.exec(attrs)
        const style = styleMatch === null ? 0 : Number(styleMatch[1])
        const formulaMatch = /<f(?:\s[^>]*)?>([\s\S]*?)<\/f>/.exec(body)
        const valueMatch = /<v(?:\s[^>]*)?>([\s\S]*?)<\/v>/.exec(body)
        const inlineMatch = /<is>([\s\S]*?)<\/is>/.exec(body)
        let value = ''
        if (formulaMatch !== null) {
          value = `=${decodeXml(formulaMatch[1])}`
        } else if (type === 's' && valueMatch !== null) {
          const index = Number(valueMatch[1])
          value = index >= 0 && index < shared.length ? shared[index] : ''
        } else if (type === 'inlineStr' && inlineMatch !== null) {
          // SpreadsheetML uses unprefixed <t>, unlike Word's <w:t>.
          const inlineText = /<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g
          let inlineMatchText = inlineText.exec(inlineMatch[1])
          while (inlineMatchText !== null) {
            value += decodeXml(inlineMatchText[1])
            inlineMatchText = inlineText.exec(inlineMatch[1])
          }
        } else if (type === 'b' && valueMatch !== null) {
          value = valueMatch[1] === '1' ? 'TRUE' : 'FALSE'
        } else if (type === 'str' && valueMatch !== null) {
          value = decodeXml(valueMatch[1])
        } else if (valueMatch !== null) {
          const raw = decodeXml(valueMatch[1])
          const numeric = Number(raw)
          if (style < dates.length && dates[style] && Number.isFinite(numeric)) {
            value = serialToIso(numeric)
          } else {
            value = raw
          }
        }
        cells[column] = clipCell(value)
      }
      cellMatch = cellPattern.exec(rowMatch[2])
    }
    if (rowNumber > MAX_ROWS) {
      break
    }
    while (rows.length < rowNumber - 1) {
      rows.push([])
    }
    rows[rowNumber - 1] = cells
    rowMatch = rowPattern.exec(xml)
  }
  return rows
}

/** Right-align values that read as numbers; text stays left. */
export function isNumericText(text: string): boolean {
  return /^-?\d+(?:\.\d+)?$/.test(text) || /^-?\d{1,3}(?:,\d{3})+(?:\.\d+)?$/.test(text)
}

/** The cap the preview applies, exposed for the "truncated" note. */
export function previewLimits(): number[] {
  return [MAX_ROWS, MAX_COLS]
}
