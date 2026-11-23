import { describe, it, expect } from '@ohos/hypium';
import { hasSecret, maskSecrets, secretCount } from '../main/ets/common/SecretMask';
import { fontIdOf, fontScaleOf, scaled } from '../main/ets/common/Typography';
import { activeTodo, completedCount, isTodoTool, todosFromJson, todoSummary } from '../main/ets/model/TodoModel';
import { goalFromJson, goalSettled, goalStatusLabel, isGoalTool } from '../main/ets/model/GoalModel';
import { NodeKind, kindVerb, statusLabel, toolKindOf } from '../main/ets/common/TimelineNode';
import { isWriteTool, writePathsOf } from '../main/ets/model/Rollback';
import { refsFromText } from '../main/ets/view/ChatView';
import { decodeEnvelope, encodeEnvelope, keepRemainder, makeEnvelope, takeLines } from '../main/ets/common/Interop';
import { compactCount, dayKey, mergeUsage, usageTotal, UsageDay } from '../main/ets/model/Usage';
import { spokenForm } from '../main/ets/common/ReadAloud';
import { extOf, fallbackUtd, nameOf } from '../main/ets/common/FileShare';
import { modelsFromBody, ModelEntry, normalizeModelId } from '../main/ets/common/ModelCatalog';
import { flattenChoices, AcpModelChoice, AcpConfigGroup } from '../main/ets/model/AcpProtocol';

/**
 * Tests for the pure projections and formatters.
 *
 * These are the modules whose bugs are silent: a mask that hides the wrong
 * span, a todo list that parses to nothing, a goal that forgets it was paused.
 * None of them needs a device, so they belong in the host-side suite that runs
 * before every deploy.
 */
export default function localUnitTest() {
  describe('SecretMask', () => {
    it('masks an API key to its first eight characters', 0, () => {
      const masked = maskSecrets('key is sk-abcdefghijklmnop and that is it');
      expect(masked).assertContain('sk-abcde…');
      expect(masked.indexOf('sk-abcdefghijklmnop') < 0).assertTrue();
    });

    it('leaves prose without credentials untouched', 0, () => {
      const text = 'nothing secret here, just words';
      expect(maskSecrets(text)).assertEqual(text);
      expect(hasSecret(text)).assertFalse();
    });

    it('counts every credential in one message', 0, () => {
      const text = 'sk-aaaaaaaaaaaaaaaa and sk-bbbbbbbbbbbbbbbb';
      expect(secretCount(text)).assertEqual(2);
      expect(hasSecret(text)).assertTrue();
    });

    it('does not mask a bare word that merely starts with sk', 0, () => {
      const text = 'sk-short';
      expect(maskSecrets(text)).assertEqual(text);
      expect(hasSecret(text)).assertFalse();
    });
  });

  describe('Typography', () => {
    it('maps a level id to its multiplier', 0, () => {
      expect(fontScaleOf('xlarge')).assertEqual(1.3);
      expect(fontScaleOf('standard')).assertEqual(1);
    });

    it('falls back to standard for an unknown level', 0, () => {
      expect(fontScaleOf('gigantic')).assertEqual(1);
      expect(fontIdOf(1)).assertEqual('standard');
    });

    it('rounds a scaled size to a half point', 0, () => {
      expect(scaled(15, 1.3)).assertEqual(19.5);
      // 12 * 0.9 = 10.8, which rounds to the nearest half point (11).
      expect(scaled(12, 0.9)).assertEqual(11);
      expect(scaled(13, 1)).assertEqual(13);
    });
  });

  describe('TodoModel', () => {
    it('recognises the todo tool by name', 0, () => {
      expect(isTodoTool('todo_write')).assertTrue();
      expect(isTodoTool('glob')).assertFalse();
    });

    it('parses a whole-list snapshot', 0, () => {
      const todos = todosFromJson('{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"in_progress"}]}');
      expect(todos === null).assertFalse();
      if (todos !== null) {
        expect(todos.length).assertEqual(2);
        expect(completedCount(todos)).assertEqual(1);
        expect(activeTodo(todos)).assertEqual('b');
      }
    });

    it('rejects unknown statuses instead of guessing', 0, () => {
      const todos = todosFromJson('{"todos":[{"content":"a","status":"doing"}]}');
      expect(todos === null).assertFalse();
      if (todos !== null) {
        expect(todos.length).assertEqual(0);
      }
    });

    it('returns null for text that is not a todo snapshot', 0, () => {
      expect(todosFromJson('not json') === null).assertTrue();
      expect(todosFromJson('{"pattern":"**/*"}') === null).assertTrue();
    });

    it('summarises progress and the current step', 0, () => {
      const todos = todosFromJson(
        '{"todos":[{"content":"one","status":"completed"},{"content":"two","status":"pending"}]}');
      if (todos !== null) {
        expect(todoSummary(todos)).assertContain('1/2');
        expect(todoSummary(todos)).assertContain('two');
      }
    });
  });

  describe('Usage ledger', () => {
    it('creates the day row on first use and adds to it afterwards', 0, () => {
      let rows: UsageDay[] = mergeUsage([], '2026-11-15', 120);
      rows = mergeUsage(rows, '2026-11-15', 80);
      expect(rows.length).assertEqual(1);
      expect(rows[0].tokens).assertEqual(200);
      expect(rows[0].turns).assertEqual(2);
    });

    it('keeps days separate and sorts newest first', 0, () => {
      let rows: UsageDay[] = mergeUsage([], '2026-11-14', 10);
      rows = mergeUsage(rows, '2026-11-15', 20);
      expect(rows.length).assertEqual(2);
      expect(rows[0].day).assertEqual('2026-11-15');
      expect(rows[1].day).assertEqual('2026-11-14');
    });

    it('does not mutate the input array', 0, () => {
      const before: UsageDay[] = [{ day: '2026-11-15', tokens: 5, turns: 1 }];
      mergeUsage(before, '2026-11-15', 5);
      expect(before[0].tokens).assertEqual(5);
    });

    it('counts the turn but adds nothing for a non-positive delta', 0, () => {
      const rows = mergeUsage([], '2026-11-15', 0);
      expect(rows[0].tokens).assertEqual(0);
      expect(rows[0].turns).assertEqual(1);
    });

    it('sums only the newest N rows', 0, () => {
      let rows: UsageDay[] = mergeUsage([], '2026-11-10', 100);
      rows = mergeUsage(rows, '2026-11-14', 30);
      rows = mergeUsage(rows, '2026-11-15', 20);
      expect(usageTotal(rows, 2)).assertEqual(50);
      expect(usageTotal(rows, 7)).assertEqual(150);
    });

    it('formats a day key with zero padding', 0, () => {
      expect(dayKey(new Date(2026, 0, 5))).assertEqual('2026-01-05');
      expect(dayKey(new Date(2026, 10, 15))).assertEqual('2026-11-15');
    });

    it('compacts large counts', 0, () => {
      expect(compactCount(999)).assertEqual('999');
      expect(compactCount(1200)).assertEqual('1.2k');
      expect(compactCount(2500000)).assertEqual('2.5M');
    });
  });

  describe('FileShare', () => {
    it('reads the extension of a plain name', 0, () => {
      expect(extOf('index.html')).assertEqual('html');
    });

    it('lowercases the extension', 0, () => {
      expect(extOf('/a/b/REPORT.PDF')).assertEqual('pdf');
    });

    it('ignores dots in directory names', 0, () => {
      // The last dot after the last slash is the only candidate; a folder
      // called "v1.2" must not make its children look extension-less.
      expect(extOf('/work/v1.2/notes')).assertEqual('');
      expect(extOf('/work/v1.2/notes.md')).assertEqual('md');
    });

    it('treats a trailing dot as no extension', 0, () => {
      expect(extOf('weird.')).assertEqual('');
    });

    it('returns empty for a bare filename', 0, () => {
      expect(extOf('README')).assertEqual('');
    });

    // The fallback table runs only when the platform query fails; its job is
    // to keep the common artifacts shareable, not to be exhaustive.
    it('maps the extensions this app produces', 0, () => {
      expect(fallbackUtd('png')).assertEqual('general.png');
      expect(fallbackUtd('jpeg')).assertEqual('general.jpeg');
      expect(fallbackUtd('pdf')).assertEqual('com.adobe.pdf');
      expect(fallbackUtd('md')).assertEqual('general.markdown');
      expect(fallbackUtd('html')).assertEqual('general.html');
      expect(fallbackUtd('txt')).assertEqual('general.plain-text');
    });

    it('falls back to general.file for anything unknown', 0, () => {
      expect(fallbackUtd('xyz')).assertEqual('general.file');
      expect(fallbackUtd('')).assertEqual('general.file');
    });

    it('names a file from its path', 0, () => {
      expect(nameOf('/a/b/c.html')).assertEqual('c.html');
      expect(nameOf('c.html')).assertEqual('c.html');
    });
  });

  describe('spokenForm', () => {
    it('drops code blocks instead of reading them out', 0, () => {
      const spoken = spokenForm('前文\n```js\nconst a = 1\n```\n后文');
      expect(spoken).assertContain('前文');
      expect(spoken).assertContain('后文');
      expect(spoken).assertContain('代码略');
      expect(spoken.indexOf('const a')).assertEqual(-1);
    });

    it('keeps inline code text and strips the backticks', 0, () => {
      expect(spokenForm('用 `SpeechInput` 即可')).assertEqual('用 SpeechInput 即可');
    });

    it('strips emphasis, headings and list bullets', 0, () => {
      expect(spokenForm('## 标题\n- **要点**')).assertEqual('标题 要点');
    });

    it('reduces a link to its text', 0, () => {
      expect(spokenForm('见 [文档](https://example.com/a)')).assertEqual('见 文档');
    });

    it('collapses whitespace so the voice does not pause at every newline', 0, () => {
      expect(spokenForm('a\n\n\nb')).assertEqual('a b');
    });
  });

  describe('refsFromText', () => {
    it('collapses the same file written three ways into one chip', 0, () => {
      const text = 'loadUrl("file:///data/storage/el2/base/haps/entry/files/workspace/plan.html")'
        + '\n\n保存成 plan.html 就行，plan.html 可以直接打开。';
      const refs = refsFromText(text, 4);
      expect(refs.length).assertEqual(1);
      expect(refs[0].name).assertEqual('plan.html');
    });

    it('keeps two files that share a basename but live in different folders', 0, () => {
      const refs = refsFromText('对比 a/report.md 和 b/report.md 两份。', 4);
      expect(refs.length).assertEqual(2);
    });

    it('keeps a relative path and its absolute form together once', 0, () => {
      const refs = refsFromText('见 `exports/INDEX.md`，完整路径是 /work/exports/INDEX.md。', 4);
      expect(refs.length).assertEqual(1);
    });

    it('ignores urls and bare words without a preview extension', 0, () => {
      expect(refsFromText('https://example.com/a.html 和 README 都提到了。', 4).length).assertEqual(0);
    });

    it('respects the limit', 0, () => {
      const refs = refsFromText('a.md b.md c.md d.md e.md f.md', 3);
      expect(refs.length).assertEqual(3);
    });
  });

  describe('Interop envelope', () => {
    it('round-trips one message through the wire format', 0, () => {
      const envelope = makeEnvelope('Pixel', '你好', 1700000000000);
      const line = encodeEnvelope(envelope);
      expect(line.endsWith('\n')).assertTrue();
      const back = decodeEnvelope(line);
      expect(back === null).assertFalse();
      if (back !== null) {
        expect(back.text).assertEqual('你好');
        expect(back.from).assertEqual('Pixel');
        expect(back.id).assertEqual(envelope.id);
      }
    });

    it('rejects a different envelope version instead of guessing', 0, () => {
      expect(decodeEnvelope('{"v":2,"id":"a","from":"b","at":1,"text":"c"}') === null).assertTrue();
    });

    it('rejects a line that is not an envelope at all', 0, () => {
      expect(decodeEnvelope('hello') === null).assertTrue();
      expect(decodeEnvelope('') === null).assertTrue();
      expect(decodeEnvelope('{"v":1,"id":"a"}') === null).assertTrue();
    });

    it('splits a read that carries half a message', 0, () => {
      // A TCP read is not a message boundary; this is the case that silently
      // merges two messages if the remainder is dropped.
      const partial = '{"v":1,"id":"a","from":"x","at":1,"text":"one"}\n{"v":1,"id":"b","from":"x"';
      const lines = takeLines(partial);
      expect(lines.length).assertEqual(1);
      expect(decodeEnvelope(lines[0]) === null).assertFalse();
      const rest = keepRemainder(partial);
      expect(rest.startsWith('{"v":1,"id":"b"')).assertTrue();
      expect(decodeEnvelope(rest) === null).assertTrue();
    });

    it('keeps everything when no newline has arrived yet', 0, () => {
      expect(takeLines('partial').length).assertEqual(0);
      expect(keepRemainder('partial')).assertEqual('partial');
    });
  });

  describe('TimelineNode', () => {
    it('classifies tools by what they do, not by which plugin ships them', 0, () => {
      expect(toolKindOf('read')).assertEqual(NodeKind.READ);
      expect(toolKindOf('glob')).assertEqual(NodeKind.SEARCH);
      expect(toolKindOf('write')).assertEqual(NodeKind.WRITE);
      expect(toolKindOf('web_fetch')).assertEqual(NodeKind.NETWORK);
    });

    it('gives a subagent its own kind instead of "other"', 0, () => {
      expect(toolKindOf('subagent')).assertEqual(NodeKind.SUBAGENT);
      expect(toolKindOf('subagent_fork')).assertEqual(NodeKind.SUBAGENT);
      expect(kindVerb(NodeKind.SUBAGENT)).assertEqual('子代理');
    });

    it('keeps a todo write out of the "changed your files" colour', 0, () => {
      // todo_write contains "write"; the kind must still be OTHER.
      expect(toolKindOf('todo_write')).assertEqual(NodeKind.OTHER);
    });

    it('labels statuses and leaves unknown ones blank', 0, () => {
      expect(statusLabel('completed')).assertEqual('完成');
      expect(statusLabel('failed')).assertEqual('失败');
      expect(statusLabel('weird')).assertEqual('');
    });
  });

  describe('Rollback path detection', () => {
    it('treats only mutating tools as writes', 0, () => {
      expect(isWriteTool('write')).assertTrue();
      expect(isWriteTool('edit')).assertTrue();
      expect(isWriteTool('read')).assertFalse();
      expect(isWriteTool('glob')).assertFalse();
      expect(isWriteTool('todo_write')).assertTrue();
    });

    it('reads the path out of an XML-ish argument block', 0, () => {
      // ArkTS has no untyped object literals; the arguments arrive as JSON, so
      // the test builds them the same way the wire does.
      const raw = JSON.parse('{"path":"<path>/tmp/a.txt</path><type>file</type>"}') as Record<string, Object>;
      const paths = writePathsOf('write', raw, '/work');
      expect(paths.length).assertEqual(1);
      expect(paths[0]).assertEqual('/tmp/a.txt');
    });

    it('resolves a relative path against the turn cwd', 0, () => {
      const raw = JSON.parse('{"file_path":"notes/today.md"}') as Record<string, Object>;
      const paths = writePathsOf('edit', raw, '/work');
      expect(paths[0]).assertEqual('/work/notes/today.md');
    });

    it('refuses a value that is still markup rather than guessing', 0, () => {
      const raw = JSON.parse('{"path":"<content>oops</content>"}') as Record<string, Object>;
      expect(writePathsOf('write', raw, '/work').length).assertEqual(0);
    });

    it('returns nothing for a read tool even when it names a path', 0, () => {
      const raw = JSON.parse('{"path":"/tmp/a.txt"}') as Record<string, Object>;
      expect(writePathsOf('read', raw, '/work').length).assertEqual(0);
    });
  });

  describe('GoalModel', () => {
    it('recognises the goal tools', 0, () => {
      expect(isGoalTool('create_goal')).assertTrue();
      expect(isGoalTool('update_goal')).assertTrue();
      expect(isGoalTool('glob')).assertFalse();
    });

    it('creates an active goal from create_goal', 0, () => {
      const goal = goalFromJson(null, 'create_goal', '{"objective":"ship it"}');
      expect(goal === null).assertFalse();
      if (goal !== null) {
        expect(goal.objective).assertEqual('ship it');
        expect(goal.status).assertEqual('active');
        expect(goalSettled(goal.status)).assertFalse();
      }
    });

    it('applies pause, resume and complete to the standing goal', 0, () => {
      const created = goalFromJson(null, 'create_goal', '{"objective":"x"}');
      const paused = goalFromJson(created, 'update_goal', '{"action":"pause"}');
      if (paused !== null) {
        expect(paused.status).assertEqual('paused');
        expect(goalStatusLabel(paused.status)).assertEqual('已暂停');
      }
      const done = goalFromJson(paused, 'update_goal', '{"action":"complete"}');
      if (done !== null) {
        expect(done.status).assertEqual('completed');
        expect(done.objective).assertEqual('x');
        expect(goalSettled(done.status)).assertTrue();
      }
    });

    it('replaces the objective on edit and ignores read-only calls', 0, () => {
      const created = goalFromJson(null, 'create_goal', '{"objective":"old"}');
      const edited = goalFromJson(created, 'update_goal', '{"action":"edit","objective":"new"}');
      if (edited !== null) {
        expect(edited.objective).assertEqual('new');
      }
      expect(goalFromJson(created, 'get_goal', '{}') === null).assertTrue();
    });
  });
  describe('modelCatalog', () => {
    it('decodes the OpenAI-shaped listing with names and descriptions', 0, () => {
      const body = '{"data":[{"id":"deepseek-flash","name":"DeepSeek-V4.1-Flash","description":"fast"},' +
        '{"id":"deepseek-v4-pro","name":"DeepSeek-V4-Pro"}]}';
      const entries: ModelEntry[] = modelsFromBody(body);
      expect(entries.length).assertEqual(2);
      expect(entries[0].id).assertEqual('deepseek-flash');
      expect(entries[0].name).assertEqual('DeepSeek-V4.1-Flash');
      expect(entries[0].description).assertEqual('fast');
      expect(entries[1].name).assertEqual('DeepSeek-V4-Pro');
      expect(entries[1].description).assertEqual('');
    });

    it('falls back to the id when a name is missing', 0, () => {
      const entries = modelsFromBody('{"data":[{"id":"m-1"}]}');
      expect(entries.length).assertEqual(1);
      expect(entries[0].name).assertEqual('m-1');
    });

    it('drops entries without an id and de-duplicates the rest', 0, () => {
      const entries = modelsFromBody('{"data":[{"name":"no id"},{"id":"a"},{"id":"a"},{"id":"  "}]}');
      expect(entries.length).assertEqual(1);
      expect(entries[0].id).assertEqual('a');
    });

    it('returns nothing for an empty, malformed or non-listing body', 0, () => {
      expect(modelsFromBody('').length).assertEqual(0);
      expect(modelsFromBody('not json').length).assertEqual(0);
      expect(modelsFromBody('{"data":{}}').length).assertEqual(0);
      expect(modelsFromBody('{"error":"invalid key"}').length).assertEqual(0);
    });

    // The fake id was the shipped default for a month, so devices that saved
    // settings in that window still carry it; load rewrites it once and stores
    // the result, which is what keeps initialize from sending it again.
    it('rewrites the model id older builds saved', 0, () => {
      expect(normalizeModelId('deepseek-v4-flash')).assertEqual('deepseek-flash');
      expect(normalizeModelId('  deepseek-v4-flash ')).assertEqual('deepseek-flash');
    });

    it('leaves real and unknown ids alone', 0, () => {
      expect(normalizeModelId('deepseek-flash')).assertEqual('deepseek-flash');
      expect(normalizeModelId('deepseek-v4-pro')).assertEqual('deepseek-v4-pro');
      expect(normalizeModelId('vendor/some-model')).assertEqual('vendor/some-model');
      expect(normalizeModelId('')).assertEqual('');
    });
  });

  describe('modelChoices', () => {
    // dsh-acp nests model options by provider ({group, name, options[]}). The
    // flattening used to drop both the group and its display name, so the
    // picker showed one flat list even when several providers were routable.
    it('keeps the provider group dsh-acp sends, and its display name', 0, () => {
      const entries: AcpConfigGroup[] = [
        {
          group: 'deepseek-official',
          name: 'DeepSeek',
          options: [
            { value: 'deepseek-official|deepseek-flash', name: 'DeepSeek-V4.1-Flash' },
            { value: 'deepseek-official|deepseek-v4-pro', name: 'DeepSeek-V4-Pro' }
          ]
        }
      ];
      const choices: AcpModelChoice[] = flattenChoices(entries);
      expect(choices.length).assertEqual(2);
      expect(choices[0].group).assertEqual('deepseek-official');
      expect(choices[0].groupName).assertEqual('DeepSeek');
      expect(choices[1].name).assertEqual('DeepSeek-V4-Pro');
    });

    it('labels every group separately so same-named models stay apart', 0, () => {
      const entries: AcpConfigGroup[] = [
        { group: 'a', name: 'A', options: [{ value: 'a|m', name: 'same' }] },
        { group: 'b', name: 'B', options: [{ value: 'b|m', name: 'same' }] }
      ];
      const choices = flattenChoices(entries);
      expect(choices.length).assertEqual(2);
      expect(choices[0].group).assertEqual('a');
      expect(choices[1].group).assertEqual('b');
    });

    it('falls back to the group id when the server sends no name', 0, () => {
      const entries: AcpConfigGroup[] = [{ group: 'g1', options: [{ value: 'g1|m' }] }];
      const choices = flattenChoices(entries);
      expect(choices[0].groupName).assertEqual('g1');
      expect(choices[0].name).assertEqual('g1|m');
    });

    it('leaves an ungrouped leaf without a group', 0, () => {
      const choices = flattenChoices([{ value: 'x' }]);
      expect(choices.length).assertEqual(1);
      expect(choices[0].group).assertEqual('');
      expect(choices[0].groupName).assertEqual('');
    });

    it('returns nothing for an absent list', 0, () => {
      expect(flattenChoices(undefined).length).assertEqual(0);
    });
  });

}
