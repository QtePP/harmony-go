import { describe, it, expect } from '@ohos/hypium';
import { LocalGateContext, matchLocalIntent } from '../main/ets/common/LocalGate';

/**
 * The gate is deliberately exact-match. These tests pin the boundary as much
 * as the happy path: a task that starts with "你好" must NOT be swallowed.
 */

export default function localGateTest() {
  describe('LocalGate / narrow intents', () => {
    it('answers greetings in Chinese and English', 0, () => {
      expect(matchLocalIntent('你好')?.intent).assertEqual('greeting');
      expect(matchLocalIntent('  HELLO!  ')?.intent).assertEqual('greeting');
      expect(matchLocalIntent('在吗？')?.intent).assertEqual('greeting');
      expect(matchLocalIntent('早上好。')?.reply).assertContain('我在');
    });

    it('answers identity and thanks', 0, () => {
      expect(matchLocalIntent('你是谁？')?.intent).assertEqual('identity');
      expect(matchLocalIntent('谢谢')?.intent).assertEqual('thanks');
      expect(matchLocalIntent('bye')?.intent).assertEqual('bye');
    });

    it('treats one trailing tone particle as the same intent', 0, () => {
      expect(matchLocalIntent('你好啊')?.intent).assertEqual('greeting');
      expect(matchLocalIntent('您好呀')?.intent).assertEqual('greeting');
      expect(matchLocalIntent('在吗呢')?.intent).assertEqual('greeting');
      expect(matchLocalIntent('谢谢啊')?.intent).assertEqual('thanks');
      expect(matchLocalIntent('再见吧')?.intent).assertEqual('bye');
      expect(matchLocalIntent('你是谁啊')?.intent).assertEqual('identity');
      expect(matchLocalIntent('现在几点啦')?.intent).assertEqual('time');
      expect(matchLocalIntent('HI呀')?.intent).assertEqual('greeting');
      expect(matchLocalIntent('算一下 3+4啊')?.intent).assertEqual('math');
    });

    it('does not stretch the tone rule into a fuzzy matcher', 0, () => {
      // Two particles, or a particle on an unknown phrase, stay misses.
      expect(matchLocalIntent('你好啊啊')).assertNull();
      expect(matchLocalIntent('你好啊，帮我写一个周报')).assertNull();
      expect(matchLocalIntent('好的吧')).assertNull();
      expect(matchLocalIntent('天啊')).assertNull();
      expect(matchLocalIntent('早点睡吧')).assertNull();
      expect(matchLocalIntent('谢谢你啊')).assertNull();
    });

    it('does not swallow a task that merely starts with a greeting', 0, () => {
      expect(matchLocalIntent('你好，帮我写一个周报')).assertNull();
      expect(matchLocalIntent('hello, summarize this file')).assertNull();
      expect(matchLocalIntent('你是谁开发的？')).assertNull();
    });

    it('ignores empty input', 0, () => {
      expect(matchLocalIntent('')).assertNull();
      expect(matchLocalIntent('   ')).assertNull();
    });

    it('answers time and date from the supplied clock', 0, () => {
      const context = new LocalGateContext(new Date(2026, 10, 23, 22, 31), 'deepseek-v4-pro');
      const time = matchLocalIntent('现在几点？', context);
      expect(time?.intent).assertEqual('time');
      expect(time?.reply).assertContain('22:31');
      expect(time?.reply).assertContain('2026-11-23');
      expect(time?.reply).assertContain('周一');
      const date = matchLocalIntent('今天星期几', context);
      expect(date?.intent).assertEqual('date');
      expect(date?.reply).assertContain('2026-11-23');
    });

    it('evaluates literal arithmetic with precedence', 0, () => {
      expect(matchLocalIntent('1+1')?.reply).assertEqual('1+1 = 2');
      expect(matchLocalIntent('2 + 3 * 4')?.reply).assertEqual('2+3*4 = 14');
      expect(matchLocalIntent('(1+2)*3')?.reply).assertEqual('(1+2)*3 = 9');
      expect(matchLocalIntent('算一下 10/4')?.reply).assertEqual('10/4 = 2.5');
      expect(matchLocalIntent('1除以0')).assertNull();
      expect(matchLocalIntent('2026-11-23')).assertNull();
    });

    it('answers the capability help without a model', 0, () => {
      const help = matchLocalIntent('你能做什么？');
      expect(help?.intent).assertEqual('help');
      expect(help?.reply).assertContain('Office');
    });
  });
}
