/**
 * Contract types (SPEC §7.1: the two packages share the contract, not code).
 * These mirror docs/spec/community/contracts/schemas/*.json — recipe-content,
 * publication, explore-card, moderation-case, account, session. The
 * contract-round-trip tests validate live responses against the actual JSON
 * Schemas via Ajv, so drift between these interfaces and the schemas fails a
 * test the same day it lands.
 */

export type RecipeSource = "catalog" | "user" | "community" | "generated";

export interface RecipeRef {
  readonly source: RecipeSource;
  readonly id: string;
  readonly revision: number;
}

export interface IngredientLine {
  readonly name: string;
  readonly quantity: number | null;
  readonly unit: string | null;
  readonly preparation: string | null;
  readonly fdcId: number | null;
}

export interface StepLine {
  readonly text: string;
  readonly timerMinutes: number | null;
}

export interface RecipeContent {
  readonly title: string;
  readonly description: string | null;
  readonly servings: number;
  readonly timeMinutes: number | null;
  readonly ingredientLines: readonly IngredientLine[];
  readonly steps: readonly StepLine[];
  readonly equipment: readonly string[];
  readonly dietaryTags: readonly string[];
}

export interface RightsDeclaration {
  readonly ownRights: boolean;
  readonly noPersonalData: boolean;
}

export type AllergenTag =
  | "milk"
  | "eggs"
  | "fish"
  | "shellfish"
  | "tree-nuts"
  | "peanuts"
  | "wheat"
  | "soy"
  | "sesame"
  | "mustard"
  | "sulphites"
  | "unknown-contents";

export type PublicationState = "published" | "queued" | "rejected" | "withdrawn";

export type ScreeningCheck = "food-safety-lint" | "compound-allergens" | "personal-data";
export type ScreeningVerdictKind = "pass" | "flag" | "block";

export interface ScreeningOutcome {
  readonly check: ScreeningCheck;
  readonly verdict: ScreeningVerdictKind;
  readonly detail: string | null;
}

/** The reader/author wire view: contracts/publication.schema.json. */
export interface PublicationView {
  readonly publicationId: string;
  readonly recipeRef: RecipeRef;
  readonly content: RecipeContent;
  readonly authorDisplayName: string;
  readonly allergenTags: readonly string[];
  readonly state: PublicationState;
  readonly publishedAt: string;
  readonly withdrawnAt: string | null;
  readonly flaggedTag: string | null;
  readonly challengeId: string | null;
}

/** Contracts/account.schema.json. */
export interface AccountView {
  readonly accountId: string;
  readonly displayName: string;
  readonly isAdult: boolean;
  readonly canVoteAt: string | null;
  readonly moderationOperator: boolean;
}

/** Contracts/session.schema.json. */
export interface SessionView {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly account: AccountView;
}

/** Contracts/explore-card.schema.json. */
export interface ExploreCard {
  readonly recipeRef: RecipeRef;
  readonly title: string;
  readonly authorDisplayName: string | null;
  readonly timeMinutes: number | null;
  readonly allergenTags: readonly string[];
  readonly publishedAt: string;
  readonly cookedBy: number | null;
  readonly challengeId: string | null;
}

/** Contracts/moderation-case.schema.json (operator view only). */
export interface ModerationCaseView {
  readonly caseId: string;
  readonly targetType: "recipe" | "tableCard" | "challengeEntry" | "tableMember";
  readonly targetId: string;
  readonly origin: "screening" | "report" | "sampling";
  readonly state: "queued" | "resolved";
  readonly createdAt: string;
  readonly declaration: RightsDeclaration | null;
  readonly screening: readonly ScreeningOutcome[];
  readonly reports: readonly { readonly reason: string; readonly detail: string | null }[];
  readonly decision: { readonly action: string; readonly note: string | null; readonly decidedAt: string } | null;
}

/** Contracts/error.schema.json. */
export interface ErrorView {
  readonly error: {
    readonly code: string;
    readonly message: string;
    readonly reason?: string | null;
  };
}
