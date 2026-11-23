/**
 * Deterministic first pass for common, repeatable scenarios.
 *
 * The point is not to classify arbitrary language — it is to answer the cases
 * where the right output is knowable without a model: greetings, identity,
 * time/date, a literal arithmetic expression, and a short capability summary.
 * Everything else falls through to the real agent.
 *
 * Exact/regex matching is deliberate. A fuzzy score would put the cloud model
 * back in the loop to explain why a task was swallowed, and the gate must stay
 * auditable. The arithmetic evaluator is a small recursive-descent parser, not
 * `eval`: no property access, no calls, no identifiers.
 */

export class LocalGateContext {
  now: Date = new Date()
  model: string = ''

  constructor(now: Date = new Date(), model: string = '') {
    this.now = now
    this.model = model
  }
}

export class LocalGateReply {
  intent: string = ''
  reply: string = ''

  constructor(intent: string, reply: string) {
    this.intent = intent
    this.reply = reply
  }
}

const GREETINGS: string[] = [
  '你好', '您好', '嗨', '哈喽', 'hi', 'hello', 'hey',
  '在吗', '在么', '早上好', '早安', '下午好', '晚上好', '晚安'
]

const THANKS: string[] = ['谢谢', '多谢', 'thanks', 'thank you', 'thx']

const BYES: string[] = ['再见', '拜拜', 'bye', 'goodbye', 'see you']

const IDENTITY: string[] = ['你是谁', '你叫什么', '你是什么', '介绍一下你自己', '自我介绍']

const HELP: string[] = ['你能做什么', '你会什么', '帮助', 'help', '怎么用', '使用说明', '能干什么']

const TIME: string[] = ['现在几点', '几点了', '现在时间', '什么时间', 'what time is it']

const DATE: string[] = [
  '今天几号', '今天日期', '今天是什么日期', '今天星期几', '星期几',
  'date', 'what is the date', 'what day is it'
]

const WEEKDAYS: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

/** Strip surrounding whitespace and trailing punctuation, then lower-case. */
export function normalizeLocalGateText(text: string): string {
  let value = text.trim().toLowerCase()
  value = value.replace(/^[\s，,、]+/, '')
  value = value.replace(/[\s!！。.？?，,、~～…]+$/, '')
  return value.trim()
}

function pad(value: number): string {
  return value < 10 ? `0${value}` : `${value}`
}

function formatTime(now: Date): string {
  return `${pad(now.getHours())}:${pad(now.getMinutes())}`
}

function formatDate(now: Date): string {
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

function formatWeekday(now: Date): string {
  return WEEKDAYS[now.getDay()]
}

function timeReply(now: Date): string {
  return `现在是 ${formatTime(now)}（${formatDate(now)} ${formatWeekday(now)}）。`
}

function dateReply(now: Date): string {
  return `今天是 ${formatDate(now)}，${formatWeekday(now)}。`
}

/** A tiny recursive-descent evaluator for + - * / % and parentheses. */
class ArithmeticParser {
  private text: string = ''
  private index: number = 0

  parse(text: string): number | null {
    this.text = text
    this.index = 0
    const value = this.expression()
    if (value === null || this.index !== this.text.length) {
      return null
    }
    return Number.isFinite(value) ? value : null
  }

  private expression(): number | null {
    let value = this.term()
    if (value === null) {
      return null
    }
    while (this.index < this.text.length) {
      const op = this.text.charAt(this.index)
      if (op !== '+' && op !== '-') {
        break
      }
      this.index++
      const right = this.term()
      if (right === null) {
        return null
      }
      value = op === '+' ? value + right : value - right
    }
    return value
  }

  private term(): number | null {
    let value = this.factor()
    if (value === null) {
      return null
    }
    while (this.index < this.text.length) {
      const op = this.text.charAt(this.index)
      if (op !== '*' && op !== '/' && op !== '%') {
        break
      }
      this.index++
      const right = this.factor()
      if (right === null) {
        return null
      }
      if ((op === '/' || op === '%') && right === 0) {
        return null
      }
      if (op === '*') {
        value = value * right
      } else if (op === '/') {
        value = value / right
      } else {
        value = value % right
      }
    }
    return value
  }

  private factor(): number | null {
    if (this.index >= this.text.length) {
      return null
    }
    const ch = this.text.charAt(this.index)
    if (ch === '+') {
      this.index++
      return this.factor()
    }
    if (ch === '-') {
      this.index++
      const value = this.factor()
      return value === null ? null : -value
    }
    if (ch === '(') {
      this.index++
      const value = this.expression()
      if (value === null || this.index >= this.text.length || this.text.charAt(this.index) !== ')') {
        return null
      }
      this.index++
      return value
    }
    return this.number()
  }

  private number(): number | null {
    const start = this.index
    let dots = 0
    while (this.index < this.text.length) {
      const ch = this.text.charAt(this.index)
      if (ch === '.') {
        dots++
        this.index++
      } else if (ch >= '0' && ch <= '9') {
        this.index++
      } else {
        break
      }
    }
    if (this.index === start || dots > 1) {
      return null
    }
    const value = Number(this.text.substring(start, this.index))
    return Number.isFinite(value) ? value : null
  }
}

const ARITHMETIC_PREFIXES: string[] = ['计算', '算一下', '算一算', '算', 'calculate', "what's", 'what is']

function arithmeticExpression(text: string): string | null {
  let value = text.trim()
  for (const prefix of ARITHMETIC_PREFIXES) {
    if (value.toLowerCase().startsWith(prefix)) {
      value = value.substring(prefix.length).trim()
      break
    }
  }
  value = value.replace(/[×xX]/g, '*').replace(/÷/g, '/').replace(/除以/g, '/')
    .replace(/乘以/g, '*').replace(/[加]/g, '+').replace(/[减]/g, '-')
    .replace(/[乘]/g, '*').replace(/\s+/g, '')
  if (value.length === 0 || value.length > 80) {
    return null
  }
  if (!/[0-9]/.test(value) || !/[+\-*/%]/.test(value)) {
    return null
  }
  if (!/^[0-9+\-*/%().]+$/.test(value)) {
    return null
  }
  // Do not treat an ISO date as a subtraction: 2026-11-23 is a date, not 1992.
  if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(value)) {
    return null
  }
  return value
}

function formatNumber(value: number): string {
  const rounded = Math.round(value * 1e10) / 1e10
  return Number.isInteger(rounded) ? `${rounded}` : `${rounded}`
}

/**
 * Return a local reply for a deterministic scenario, or null to let the agent
 * handle it. Exact matches only; arithmetic is the one regex-shaped exception,
 * and still only literal numbers/operators/parentheses.
 */
export function matchLocalIntent(text: string, context: LocalGateContext = new LocalGateContext()): LocalGateReply | null {
  const value = normalizeLocalGateText(text)
  if (value.length === 0) {
    return null
  }
  if (IDENTITY.indexOf(value) >= 0) {
    return new LocalGateReply('identity',
      '我是 HarmonyGo，一个跑在鸿蒙设备上的 dsh 外壳；这条回复由本机规则直接给出，没有调用云端模型。')
  }
  if (HELP.indexOf(value) >= 0) {
    return new LocalGateReply('help',
      '我可以对话、读写工作区文件、生成和预览 Office 文档、联网搜索，也可以在实验设置里跑 Python。具体的工具和开关在输入框旁的菜单里。')
  }
  if (TIME.indexOf(value) >= 0) {
    return new LocalGateReply('time', timeReply(context.now))
  }
  if (DATE.indexOf(value) >= 0) {
    return new LocalGateReply('date', dateReply(context.now))
  }
  if (GREETINGS.indexOf(value) >= 0) {
    return new LocalGateReply('greeting', '你好，我在。要处理什么？')
  }
  if (THANKS.indexOf(value) >= 0) {
    return new LocalGateReply('thanks', '不客气。')
  }
  if (BYES.indexOf(value) >= 0) {
    return new LocalGateReply('bye', '再见。')
  }
  const expression = arithmeticExpression(value)
  if (expression !== null) {
    const result = new ArithmeticParser().parse(expression)
    if (result !== null) {
      return new LocalGateReply('math', `${expression} = ${formatNumber(result)}`)
    }
  }
  return null
}
