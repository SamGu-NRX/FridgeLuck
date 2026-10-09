import { describe, expect, it } from "bun:test";
import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import { generateRecipe } from "../services/recipeService.js";
import {
  RECIPE_STAPLE_INGREDIENTS,
  RECIPE_RECOGNIZED_FOOD_LEXICON
} from "../services/recipeService.js";
import {
  RecipeRejectedError,
  type RecipeGenerationRequest,
  type RecipeGenerationResponse,
  type RecipeRejectionReason
} from "../types/contracts.js";

// Tests run the REAL service; only `ai.models.generateContent` is faked.
// No API keys, no network, no server.

const config: AppConfig = {
  port: 0,
  useVertexAi: false,
  recipeModel: "gemini-2.5-flash",
  rankingModel: "gemini-2.5-flash",
  liveModel: "test-live-model",
  restockThresholdDays: 3,
  idempotencyTtlSeconds: 3600,
  restockBelowGrams: 50,
  sessionStoreMode: "memory",
  firestoreCollection: "liveSessions",
  groundingEnabled: false
};

/** Records each generateContent call and replies with canned text. */
function fakeAi(
  responseText: string | undefined,
  calls: unknown[]
): GoogleGenAI {
  return {
    models: {
      generateContent: async (args: unknown) => {
        calls.push(args);
        return { text: responseText };
      }
    }
  } as unknown as GoogleGenAI;
}

function recipePayload(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    title: "Tofu Rice Bowl",
    timeMinutes: 25,
    servings: 2,
    instructions: "Cook the rice, then add the tofu.",
    estimatedCaloriesPerServing: 400,
    ingredientsUsed: ["rice", "tofu"],
    ...overrides
  });
}

function baseRequest(
  overrides: Partial<RecipeGenerationRequest> = {}
): RecipeGenerationRequest {
  return { ingredientNames: ["rice", "tofu"], ...overrides };
}

function promptText(call: unknown): string {
  const parts = (call as { contents: { parts: { text?: string }[] }[] })
    .contents[0].parts;
  return parts.map((p) => p.text ?? "").join("\n");
}

/** Asserts the promise rejects with RecipeRejectedError carrying `reason`. */
async function expectRecipeRejected(
  run: Promise<RecipeGenerationResponse>,
  reason: RecipeRejectionReason
): Promise<RecipeRejectedError> {
  try {
    await run;
    throw new Error(
      `expected RecipeRejectedError(${reason}) but generation succeeded`
    );
  } catch (error) {
    if (!(error instanceof RecipeRejectedError)) throw error;
    expect(error.reason).toBe(reason);
    expect(error.status).toBe(422);
    expect(error.name).toBe("RecipeRejectedError");
    return error;
  }
}

/** Asserts the promise rejects with a plain (non-policy) decode error. */
async function expectMalformed(
  run: Promise<RecipeGenerationResponse>
): Promise<Error> {
  let succeeded = false;
  let caught: unknown;
  try {
    await run;
    succeeded = true;
  } catch (error) {
    caught = error;
  }
  if (succeeded) {
    throw new Error(
      "expected a malformed-response error but generation succeeded"
    );
  }
  if (caught instanceof RecipeRejectedError) {
    throw new Error(
      `expected plain malformed-response error, got RecipeRejectedError(${caught.reason})`
    );
  }
  if (!(caught instanceof Error)) {
    throw new Error("expected a plain Error instance");
  }
  return caught;
}

describe("generateRecipe — grounded behavior", () => {
  it("returns the decoded recipe with ingredientsUsed on a grounded result", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(recipePayload(), calls);

    const result = await generateRecipe(ai, config, baseRequest());

    expect(result).toEqual({
      title: "Tofu Rice Bowl",
      timeMinutes: 25,
      servings: 2,
      instructions: "Cook the rice, then add the tofu.",
      estimatedCaloriesPerServing: 400,
      ingredientsUsed: ["rice", "tofu"]
    });
  });

  it("prompts supplied-foods-only plus frozen staple allowances", async () => {
    const calls: unknown[] = [];
    await generateRecipe(
      fakeAi(recipePayload(), calls),
      config,
      baseRequest()
    );

    const text = promptText(calls[0]);
    expect(text).toContain("ingredients_from_scan: rice, tofu");
    // Staples are allowances, not assertions the kitchen stocks them.
    expect(text).toContain(RECIPE_STAPLE_INGREDIENTS.join(", "));
    expect(text).toContain("allowance");
    expect(text.toLowerCase()).toContain("only");
  });

  it("lists explicit exclusions in the prompt and requires ingredientsUsed in the schema", async () => {
    const calls: unknown[] = [];
    await generateRecipe(
      fakeAi(recipePayload(), calls),
      config,
      baseRequest({ avoidIngredients: ["garlic", "onion"] })
    );

    const text = promptText(calls[0]);
    expect(text).toContain("avoid_ingredients: garlic, onion");

    const args = calls[0] as {
      config: {
        responseSchema: {
          properties: Record<string, unknown>;
          required: string[];
        };
      };
    };
    expect(args.config.responseSchema.properties.ingredientsUsed).toBeDefined();
    expect(args.config.responseSchema.required).toContain("ingredientsUsed");
  });

  it("does not require exclusions and reports none when absent", async () => {
    const calls: unknown[] = [];
    await generateRecipe(fakeAi(recipePayload(), calls), config, baseRequest());
    expect(promptText(calls[0])).toContain("avoid_ingredients: none");
  });

  it("passes the scan photo through as an inline JPEG part", async () => {
    const calls: unknown[] = [];
    await generateRecipe(
      fakeAi(recipePayload(), calls),
      config,
      baseRequest({ photoBase64JPEG: "aGVsbG8=" })
    );

    const parts = (calls[0] as {
      contents: { parts: { inlineData?: { mimeType: string; data: string } }[] }[];
    }).contents[0].parts;
    expect(
      parts.some(
        (p) =>
          p.inlineData?.mimeType === "image/jpeg" &&
          p.inlineData?.data === "aGVsbG8="
      )
    ).toBe(true);
  });

  it("allows staples that were never supplied (allowances, not inventory assertions)", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({
        ingredientsUsed: ["tofu", "water", "salt", "black pepper", "cooking oil"]
      }),
      calls
    );

    const result = await generateRecipe(
      ai,
      config,
      baseRequest({ ingredientNames: ["tofu"] })
    );
    expect(result.ingredientsUsed).toEqual([
      "tofu",
      "water",
      "salt",
      "black pepper",
      "cooking oil"
    ]);
  });

  it("does not clamp or fall back on valid low values", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(recipePayload({ timeMinutes: 3, servings: 1 }), calls);
    const result = await generateRecipe(ai, config, baseRequest());
    expect(result.timeMinutes).toBe(3);
    expect(result.servings).toBe(1);
  });
});

describe("generateRecipe — avoided-ingredient rejections", () => {
  it("rejects a staple when the exclusion list overrides it", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ ingredientsUsed: ["rice", "salt"] }),
      calls
    );

    const error = await expectRecipeRejected(
      generateRecipe(
        ai,
        config,
        baseRequest({
          ingredientNames: ["rice"],
          avoidIngredients: ["salt"]
        })
      ),
      "uses_avoided_ingredient"
    );
    // Public error hygiene: no request content in the message.
    expect(error.message.toLowerCase()).not.toContain("salt");
    expect(error.message.toLowerCase()).not.toContain("rice");
  });

  it("rejects an avoided ingredient named in instructions even when hidden from ingredientsUsed", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({
        ingredientsUsed: ["rice", "tofu"],
        instructions: "Cook the rice. Mince the garlic and stir it in."
      }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(
        ai,
        config,
        baseRequest({ avoidIngredients: ["garlic"] })
      ),
      "uses_avoided_ingredient"
    );
  });

  it("rejects an avoided ingredient named in the title", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ title: "Peanut Noodles" }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(
        ai,
        config,
        baseRequest({ avoidIngredients: ["peanut"] })
      ),
      "uses_avoided_ingredient"
    );
  });

  it("matches case-insensitively and simple plurals", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ ingredientsUsed: ["rice", "eggs"] }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(
        ai,
        config,
        baseRequest({
          ingredientNames: ["rice"],
          avoidIngredients: ["Egg"]
        })
      ),
      "uses_avoided_ingredient"
    );
  });

  it("prefers the avoided reason when a food is both avoided and unlisted", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ ingredientsUsed: ["rice", "mango"] }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(
        ai,
        config,
        baseRequest({
          ingredientNames: ["rice"],
          avoidIngredients: ["mango"]
        })
      ),
      "uses_avoided_ingredient"
    );
  });
});

describe("generateRecipe — egg versus eggplant (word boundaries)", () => {
  it("accepts eggplant when egg is avoided", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({
        title: "Grilled Eggplant",
        instructions: "Grill the eggplant slices.",
        ingredientsUsed: ["eggplant"]
      }),
      calls
    );

    const result = await generateRecipe(
      ai,
      config,
      baseRequest({
        ingredientNames: ["eggplant"],
        avoidIngredients: ["egg"]
      })
    );
    expect(result.ingredientsUsed).toEqual(["eggplant"]);
  });

  it("rejects egg itself when egg is avoided", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ ingredientsUsed: ["egg"] }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(
        ai,
        config,
        baseRequest({
          ingredientNames: ["rice"],
          avoidIngredients: ["egg"]
        })
      ),
      "uses_avoided_ingredient"
    );
  });
});

describe("generateRecipe — unlisted-ingredient rejections", () => {
  it("rejects a declared ingredient that was not supplied and is not a staple", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ ingredientsUsed: ["rice", "mango"] }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(
        ai,
        config,
        baseRequest({ ingredientNames: ["rice"] })
      ),
      "uses_unlisted_ingredient"
    );
  });

  it("rejects chicken hidden in instructions even when omitted from ingredientsUsed", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({
        ingredientsUsed: ["rice", "bell pepper"],
        instructions: "Season the chicken, then roast it with the peppers."
      }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(
        ai,
        config,
        baseRequest({ ingredientNames: ["rice", "bell pepper"] })
      ),
      "uses_unlisted_ingredient"
    );
  });

  it("rejects chicken surfacing in the title", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ title: "Chicken Surprise Bowl" }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(ai, config, baseRequest()),
      "uses_unlisted_ingredient"
    );
  });

  it("rejects chicken when the model declares it in ingredientsUsed", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ ingredientsUsed: ["rice", "chicken"] }),
      calls
    );

    await expectRecipeRejected(
      generateRecipe(ai, config, baseRequest()),
      "uses_unlisted_ingredient"
    );
  });

  it("keeps the recognized-food screen limited to the frozen lexicon", () => {
    expect(RECIPE_RECOGNIZED_FOOD_LEXICON).toContain("chicken");
    expect(RECIPE_RECOGNIZED_FOOD_LEXICON.length).toBeLessThanOrEqual(60);
    for (const food of RECIPE_RECOGNIZED_FOOD_LEXICON) {
      // No staple may appear in the unlisted-food lexicon: staples are
      // always allowed, so screening them would be dead weight and would
      // let the lexicon drift back into asserting inventory.
      expect(RECIPE_STAPLE_INGREDIENTS).not.toContain(food);
    }
  });
});

describe("generateRecipe — untrusted JSON decoding", () => {
  it("rejects invalid JSON with a plain error and a static, safe message", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi("not json {", calls);

    const error = await expectMalformed(
      generateRecipe(ai, config, baseRequest())
    );
    expect(error.message).toContain("Malformed");
    expect(error.message).not.toContain("not json");
  });

  it("rejects JSON that is not an object", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi("[1, 2, 3]", calls);
    await expectMalformed(generateRecipe(ai, config, baseRequest()));
  });

  it("rejects a response with no text content", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(undefined, calls);
    await expectMalformed(generateRecipe(ai, config, baseRequest()));
  });

  it("rejects a missing ingredientsUsed instead of defaulting it", async () => {
    const calls: unknown[] = [];
    const payload = recipePayload();
    const withoutUsed = JSON.parse(payload);
    delete withoutUsed.ingredientsUsed;
    const ai = fakeAi(JSON.stringify(withoutUsed), calls);

    await expectMalformed(generateRecipe(ai, config, baseRequest()));
  });

  it("rejects a non-array ingredientsUsed", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ ingredientsUsed: "rice, tofu" }),
      calls
    );
    await expectMalformed(generateRecipe(ai, config, baseRequest()));
  });

  it("rejects non-string entries in ingredientsUsed", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(
      recipePayload({ ingredientsUsed: ["rice", 5] }),
      calls
    );
    await expectMalformed(generateRecipe(ai, config, baseRequest()));
  });

  it("rejects a missing, empty, or non-string title", async () => {
    for (const badTitle of [undefined, "", "   ", 7, null]) {
      const calls: unknown[] = [];
      const payload = recipePayload();
      const parsed = JSON.parse(payload);
      if (badTitle === undefined) {
        delete parsed.title;
      } else {
        parsed.title = badTitle;
      }
      const ai = fakeAi(JSON.stringify(parsed), calls);
      const error = await expectMalformed(
        generateRecipe(ai, config, baseRequest())
      );
      expect(error.message).toContain("title");
    }
  });

  it("rejects missing instructions", async () => {
    const calls: unknown[] = [];
    const parsed = JSON.parse(recipePayload());
    delete parsed.instructions;
    const ai = fakeAi(JSON.stringify(parsed), calls);
    await expectMalformed(generateRecipe(ai, config, baseRequest()));
  });

  it("rejects non-finite numbers instead of falling back (1e999 parses to Infinity)", async () => {
    const calls: unknown[] = [];
    const raw =
      '{"title":"Tofu Rice Bowl","instructions":"Cook the rice.","ingredientsUsed":["rice","tofu"],"timeMinutes":1e999,"servings":2,"estimatedCaloriesPerServing":400}';
    const ai = fakeAi(raw, calls);

    const error = await expectMalformed(
      generateRecipe(ai, config, baseRequest())
    );
    expect(error.message).toContain("timeMinutes");
    // Field name may appear; the value must not.
    expect(error.message).not.toContain("1e999");
    expect(error.message).not.toContain("Infinity");
  });

  it("rejects a missing numeric field instead of defaulting it", async () => {
    const calls: unknown[] = [];
    const parsed = JSON.parse(recipePayload());
    delete parsed.timeMinutes;
    const ai = fakeAi(JSON.stringify(parsed), calls);

    const error = await expectMalformed(
      generateRecipe(ai, config, baseRequest())
    );
    expect(error.message).toContain("timeMinutes");
  });

  it("rejects string-encoded numbers instead of coercing them", async () => {
    const calls: unknown[] = [];
    const ai = fakeAi(recipePayload({ timeMinutes: "45" }), calls);
    await expectMalformed(generateRecipe(ai, config, baseRequest()));
  });

  it("rejects numerics outside sensible ranges", async () => {
    for (const bad of [
      { timeMinutes: 0 },
      { timeMinutes: 5000 },
      { servings: 0 },
      { servings: 101 },
      { estimatedCaloriesPerServing: 0 },
      { estimatedCaloriesPerServing: -50 },
      { estimatedCaloriesPerServing: 100000 }
    ]) {
      const calls: unknown[] = [];
      const ai = fakeAi(recipePayload(bad), calls);
      const error = await expectMalformed(
        generateRecipe(ai, config, baseRequest())
      );
      expect(error.message).toContain("Malformed");
      // The offending value must never be echoed into the public error.
      for (const value of Object.values(bad)) {
        expect(error.message).not.toContain(String(value));
      }
    }
  });
});
