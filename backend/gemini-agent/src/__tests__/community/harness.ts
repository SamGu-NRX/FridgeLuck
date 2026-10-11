/**
 * Community test harness. Inside `firebase emulators:exec` the emulator runs
 * on FIRESTORE_EMULATOR_HOST; each run gets a fresh project namespace, so
 * tests are hermetic without a global cleanup. Load config through
 * loadCommunityConfig the way the server will.
 */
import { loadCommunityConfig, type CommunityConfig } from "../../community/config.js";
import { CommunityStore } from "../../community/shared/store.js";
import { systemClock, type Clock } from "../../community/shared/time.js";
import { SessionService } from "../../community/shared/sessionCore.js";

export interface CommunityTestHarness {
  readonly config: CommunityConfig;
  readonly store: CommunityStore;
  readonly sessions: SessionService;
  readonly clock: Clock;
  close(): Promise<void>;
}

export async function makeHarness(): Promise<CommunityTestHarness> {
  const projectId = `community-test-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
  const config: CommunityConfig = {
    ...loadCommunityConfig(process.env as Record<string, string | undefined>),
    projectId,
  };
  const store = new CommunityStore({
    projectId: config.projectId,
    ...(config.emulatorHost !== null ? { emulatorHost: config.emulatorHost } : {}),
  });
  const clock = systemClock;
  return {
    config,
    store,
    sessions: new SessionService({ sessions: store.sessions, firestore: store.firestore, config }),
    clock,
    async close(): Promise<void> {
      await store.firestore.terminate();
    },
  };
}
