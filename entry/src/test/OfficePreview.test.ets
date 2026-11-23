import { describe, it, expect } from '@ohos/hypium';
import {
  columnIndex,
  columnName,
  decodeXml,
  DocBlockKind,
  isNumericText,
  paragraphBlock,
  paragraphRuns,
  parseDateStyles,
  parseDocxBlocks,
  parseSharedStrings,
  parseSheetRefs,
  parseWorksheet,
  previewLimits,
  serialToIso,
  tableRows
} from '../main/ets/common/OfficePreview';

/**
 * Pure parser tests for the Office preview. Fixtures are the XML shapes Word,
 * Excel and WPS actually write, kept inline so the suite runs without a device
 * and without binaries in the repo.
 */

function json(value: Object): string {
  return JSON.stringify(value)
}

export default function officePreviewTest() {
  describe('OfficePreview / docx', () => {
    it('decodes the entities Word emits', 0, () => {
      expect(decodeXml('A &amp; B &lt; C &#x4e2d;&#25991;')).assertEqual('A & B < C 中文');
    });

    it('reads bold, italic and code runs', 0, () => {
      const xml = '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>粗</w:t></w:r>'
        + '<w:r><w:rPr><w:i/></w:rPr><w:t>斜</w:t></w:r>'
        + '<w:r><w:rPr><w:rStyle w:val="CodeChar"/></w:rPr><w:t>码</w:t></w:r>'
        + '<w:r><w:t xml:space="preserve"> 普通</w:t></w:r></w:p>';
      const runs = paragraphRuns(xml);
      expect(runs.length).assertEqual(4);
      expect(runs[0].text).assertEqual('粗');
      expect(runs[0].bold).assertTrue();
      expect(runs[1].italic).assertTrue();
      expect(runs[2].code).assertTrue();
      expect(runs[3].text).assertEqual(' 普通');
    });

    it('classifies headings, lists, quotes and code', 0, () => {
      const heading = paragraphBlock('<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>标题</w:t></w:r></w:p>');
      expect(heading !== null).assertTrue();
      if (heading !== null) {
        expect(heading.kind).assertEqual(DocBlockKind.HEADING);
        expect(heading.level).assertEqual(2);
      }
      const bullet = paragraphBlock('<w:p><w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>项</w:t></w:r></w:p>');
      expect(bullet !== null).assertTrue();
      if (bullet !== null) {
        expect(bullet.kind).assertEqual(DocBlockKind.BULLET);
      }
      const numbered = paragraphBlock('<w:p><w:pPr><w:numPr><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>项</w:t></w:r></w:p>');
      expect(numbered !== null).assertTrue();
      if (numbered !== null) {
        expect(numbered.kind).assertEqual(DocBlockKind.NUMBERED);
      }
      const quote = paragraphBlock('<w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr><w:r><w:t>引</w:t></w:r></w:p>');
      expect(quote !== null).assertTrue();
      if (quote !== null) {
        expect(quote.kind).assertEqual(DocBlockKind.QUOTE);
      }
      const code = paragraphBlock('<w:p><w:pPr><w:pStyle w:val="CodeBlock"/></w:pPr><w:r><w:t>x</w:t></w:r></w:p>');
      expect(code !== null).assertTrue();
      if (code !== null) {
        expect(code.kind).assertEqual(DocBlockKind.CODE);
      }
    });

    it('walks body order and merges adjacent code lines', 0, () => {
      const document = '<w:document><w:body>'
        + '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>标题</w:t></w:r></w:p>'
        + '<w:p><w:r><w:t>正文</w:t></w:r></w:p>'
        + '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr>'
        + '<w:tr><w:tc><w:p><w:r><w:t>A2</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B2</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        + '<w:p><w:pPr><w:pStyle w:val="CodeBlock"/></w:pPr><w:r><w:t>const a = 1;</w:t></w:r></w:p>'
        + '<w:p><w:pPr><w:pStyle w:val="CodeBlock"/></w:pPr><w:r><w:t>const b = 2;</w:t></w:r></w:p>'
        + '<w:sectPr/></w:body></w:document>';
      const blocks = parseDocxBlocks(document);
      expect(blocks.length).assertEqual(4);
      expect(blocks[0].kind).assertEqual(DocBlockKind.HEADING);
      expect(blocks[1].runs[0].text).assertEqual('正文');
      expect(blocks[2].kind).assertEqual(DocBlockKind.TABLE);
      expect(json(blocks[2].rows)).assertEqual(json([['A1', 'B1'], ['A2', 'B2']]));
      expect(blocks[3].kind).assertEqual(DocBlockKind.CODE);
      expect(blocks[3].runs[0].text).assertEqual('const a = 1;\nconst b = 2;');
    });

    it('joins multi-paragraph table cells with a space', 0, () => {
      const rows = tableRows('<w:tbl><w:tr><w:tc><w:p><w:r><w:t>第一段</w:t></w:r></w:p>'
        + '<w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:tc></w:tr></w:tbl>');
      expect(rows[0][0]).assertEqual('第一段 第二段');
    });

    it('returns an empty list for a document without a body', 0, () => {
      expect(parseDocxBlocks('<w:document/>').length).assertEqual(0);
    });
  });

  describe('OfficePreview / xlsx', () => {
    it('resolves sheet targets through workbook relationships', 0, () => {
      const workbook = '<workbook><sheets><sheet name="甲" sheetId="1" r:id="rId1"/>'
        + '<sheet name="乙" sheetId="2" r:id="rId2"/></sheets></workbook>';
      const rels = '<Relationships><Relationship Id="rId1" Type="x/worksheet" Target="worksheets/sheet1.xml"/>'
        + '<Relationship Id="rId2" Type="x/worksheet" Target="/xl/worksheets/sheet2.xml"/></Relationships>';
      const refs = parseSheetRefs(workbook, rels);
      expect(refs.length).assertEqual(2);
      expect(refs[0].name).assertEqual('甲');
      expect(refs[0].target).assertEqual('xl/worksheets/sheet1.xml');
      expect(refs[1].target).assertEqual('xl/worksheets/sheet2.xml');
    });

    it('reads rich shared strings', 0, () => {
      const values = parseSharedStrings('<sst><si><t>普通</t></si><si><r><t>富</t></r><r><t>文本</t></r></si></sst>');
      expect(values.length).assertEqual(2);
      expect(values[1]).assertEqual('富文本');
    });

    it('marks date-formatted styles', 0, () => {
      const styles = '<styleSheet><numFmts><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/></numFmts>'
        + '<cellXfs><xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="14"/></cellXfs></styleSheet>';
      const dates = parseDateStyles(styles);
      expect(json(dates)).assertEqual(json([false, true, true]));
    });

    it('parses strings, numbers, formulas, booleans and dates', 0, () => {
      const sheet = '<worksheet><sheetData><row r="1">'
        + '<c r="A1" t="s"><v>0</v></c>'
        + '<c r="B1" t="inlineStr"><is><t>内联</t></is></c>'
        + '<c r="C1" t="b"><v>1</v></c>'
        + '<c r="D1" s="1"><v>46389</v></c>'
        + '<c r="E1"><f>SUM(B2:B3)</f><v></v></c>'
        + '<c r="F1"><v>3.5</v></c>'
        + '</row></sheetData></worksheet>';
      const rows = parseWorksheet(sheet, ['共享'], [false, true]);
      expect(json(rows[0])).assertEqual(json(['共享', '内联', 'TRUE', '2027-01-02', '=SUM(B2:B3)', '3.5']));
    });

    it('fills gaps so column order is stable', 0, () => {
      const sheet = '<worksheet><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="C1"><v>3</v></c></row>'
        + '<row r="3"><c r="B3"><v>2</v></c></row></sheetData></worksheet>';
      const rows = parseWorksheet(sheet, [], []);
      expect(json(rows[0])).assertEqual(json(['1', '', '3']));
      expect(json(rows[1])).assertEqual(json([]));
      expect(json(rows[2])).assertEqual(json(['', '2']));
    });

    it('converts Excel serial dates with the 1900 quirk', 0, () => {
      expect(serialToIso(1)).assertEqual('1900-01-01');
      expect(serialToIso(59)).assertEqual('1900-02-28');
      expect(serialToIso(60)).assertEqual('1900-02-28');
      expect(serialToIso(61)).assertEqual('1900-03-01');
      expect(serialToIso(46389)).assertEqual('2027-01-02');
      expect(serialToIso(46389.5)).assertEqual('2027-01-02 12:00:00');
    });

    it('maps column letters both ways', 0, () => {
      expect(columnName(0)).assertEqual('A');
      expect(columnName(26)).assertEqual('AA');
      expect(columnName(702)).assertEqual('AAA');
      expect(columnIndex('AA')).assertEqual(26);
      expect(columnIndex('1A')).assertEqual(-1);
    });

    it('detects numeric cells for alignment', 0, () => {
      expect(isNumericText('42')).assertTrue();
      expect(isNumericText('-3.5')).assertTrue();
      expect(isNumericText('1,234.5')).assertTrue();
      expect(isNumericText('42 元')).assertFalse();
      expect(isNumericText('A1')).assertFalse();
    });

    it('exposes the preview caps', 0, () => {
      const limits = previewLimits();
      expect(limits.length).assertEqual(2);
      expect(limits[0] > 0).assertTrue();
      expect(limits[1] > 0).assertTrue();
    });
  });
}
