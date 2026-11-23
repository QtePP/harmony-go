import localUnitTest from './LocalUnit.test';
import officePreviewTest from './OfficePreview.test';
import contextLedgerTest from './ContextLedger.test';

export default function testsuite() {
  localUnitTest();
  officePreviewTest();
  contextLedgerTest();
}
