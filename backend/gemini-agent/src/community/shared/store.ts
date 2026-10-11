/**
 * The community module's single Firestore handle and its collections.
 *
 * When `emulatorHost` is set the SDK is pointed at the emulator explicitly
 * (ssl off, fixed project id) so tests are hermetic per project namespace.
 * Production wiring passes only a project id and uses ambient credentials —
 * deployment/IAM is a later integration task's concern (UNVERIFIED for prod).
 */
import { Firestore, type CollectionReference } from "@google-cloud/firestore";

export interface CommunityStoreConfig {
  readonly projectId: string;
  /** e.g. "127.0.0.1:8080" — set when talking to the Firestore emulator. */
  readonly emulatorHost?: string;
}

export class CommunityStore {
  readonly firestore: Firestore;
  readonly accounts: CollectionReference;
  readonly sessions: CollectionReference;
  readonly tables: CollectionReference;
  readonly publications: CollectionReference;
  readonly challenges: CollectionReference;
  readonly battleVotes: CollectionReference;
  readonly blocks: CollectionReference;
  readonly reports: CollectionReference;
  readonly moderationItems: CollectionReference;
  readonly deletionRuns: CollectionReference;
  readonly retentionRecords: CollectionReference;

  constructor(config: CommunityStoreConfig) {
    this.firestore = new Firestore({
      projectId: config.projectId,
      ignoreUndefinedProperties: true,
    });
    if (config.emulatorHost !== undefined) {
      const [host, port] = config.emulatorHost.split(":");
      this.firestore.settings({
        host: `${host}:${port ?? "80"}`,
        ssl: false,
        projectId: config.projectId,
      });
    }
    this.accounts = this.firestore.collection("communityAccounts");
    this.sessions = this.firestore.collection("communitySessions");
    this.tables = this.firestore.collection("communityTables");
    this.publications = this.firestore.collection("communityPublications");
    this.challenges = this.firestore.collection("communityChallenges");
    this.battleVotes = this.firestore.collection("communityBattleVotes");
    this.blocks = this.firestore.collection("communityBlocks");
    this.reports = this.firestore.collection("communityReports");
    this.moderationItems = this.firestore.collection("communityModerationItems");
    this.deletionRuns = this.firestore.collection("communityDeletionRuns");
    this.retentionRecords = this.firestore.collection("communityRetentionRecords");
  }
}
