import localUnitTest from './LocalUnit.test';
import officePreviewTest from './OfficePreview.test';
import contextLedgerTest from './ContextLedger.test';
import localGateTest from './LocalGate.test';

export default function testsuite() {
  localUnitTest();
  officePreviewTest();
  contextLedgerTest();
  localGateTest();
}
