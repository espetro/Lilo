// Shared imports for the capture harness, so the specs never reach across directories twice.
export { bootChrome, installFakeHost, pressAndLift } from "../e2e/fakeHost";
export type { FakeHostWorld } from "../e2e/fakeHost";
export { initialWorld, splitWorld, SPACE_1, SPACE_2 } from "../e2e/fixtures";
export { tab, treeItem } from "../src/stores/testFixtures";
