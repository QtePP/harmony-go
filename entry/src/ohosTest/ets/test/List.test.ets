import abilityTest from './Ability.test';
import projectSyncTest from './ProjectSync.test';
import nearLinkSyncTest from './NearLink.test';

export default function testsuite() {
  abilityTest();
  projectSyncTest();
  nearLinkSyncTest();
}