const JSON_HEADERS = {
  "content-type": "application/json; charset=UTF-8",
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type",
  "cache-control": "no-store",
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: JSON_HEADERS,
  });
}

async function hashSyncKey(key) {
  const bytes = new TextEncoder().encode(key);
  const digest = await crypto.subtle.digest("SHA-256", bytes);

  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function cleanBoolean(value, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function cleanNumber(value, fallback, min, max) {
  const number = Number(value);

  if (!Number.isFinite(number)) {
    return fallback;
  }

  return Math.min(max, Math.max(min, number));
}

function cleanSelections(value, allowedNames, defaults) {
  const result = { ...defaults };

  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return result;
  }

  for (const name of allowedNames) {
    if (typeof value[name] === "boolean") {
      result[name] = value[name];
    }
  }

  return result;
}

function sanitizeConfig(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("Config data must be an object.");
  }

  const sprinklerNames = [
    "Common Sprinkler",
    "Uncommon Sprinkler",
    "Rare Sprinkler",
    "Legendary Sprinkler",
    "Super Sprinkler",
  ];

  const wateringCanNames = [
    "Common Watering Can",
    "Super Watering Can",
  ];

  const defaultsSprinklers = Object.fromEntries(
    sprinklerNames.map((name) => [
      name,
      name === "Super Sprinkler",
    ]),
  );

  const defaultsCans = Object.fromEntries(
    wateringCanNames.map((name) => [
      name,
      name === "Super Watering Can",
    ]),
  );

  return {
    version: 1,
    masterEnabled: cleanBoolean(input.masterEnabled, true),
    enabled: cleanBoolean(input.enabled, false),
    kgThreshold: cleanNumber(input.kgThreshold, 93, 0, 1000000),
    kgFilterEnabled: cleanBoolean(input.kgFilterEnabled, true),
    kgMode: input.kgMode === "Below" ? "Below" : "Above",
    ratioControlEnabled: cleanBoolean(
      input.ratioControlEnabled,
      true,
    ),
    startBelowRatio: cleanNumber(
      input.startBelowRatio,
      0.8,
      0,
      100,
    ),
    stopAboveRatio: cleanNumber(
      input.stopAboveRatio,
      0.85,
      0,
      100,
    ),
    selectedSprinklers: cleanSelections(
      input.selectedSprinklers,
      sprinklerNames,
      defaultsSprinklers,
    ),
    selectedWateringCans: cleanSelections(
      input.selectedWateringCans,
      wateringCanNames,
      defaultsCans,
    ),
    minimized: cleanBoolean(input.minimized, false),
    uiX: cleanNumber(input.uiX, 4, -10000, 10000),
    uiY: cleanNumber(input.uiY, 34, -10000, 10000),
    savedAt: new Date().toISOString(),
  };
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: JSON_HEADERS,
      });
    }

    if (request.method !== "POST") {
      return json(
        {
          ok: false,
          error: "Use POST.",
        },
        405,
      );
    }

    const url = new URL(request.url);

    if (
      url.pathname !== "/load" &&
      url.pathname !== "/save"
    ) {
      return json(
        {
          ok: false,
          error: "Not found.",
        },
        404,
      );
    }

    let body;

    try {
      body = await request.json();
    } catch {
      return json(
        {
          ok: false,
          error: "Invalid JSON body.",
        },
        400,
      );
    }

    const key = body?.key;

    if (
      typeof key !== "string" ||
      key.length < 20 ||
      key.length > 128
    ) {
      return json(
        {
          ok: false,
          error: "Sync key must be 20-128 characters.",
        },
        400,
      );
    }

    const hashedKey = await hashSyncKey(key);
    const storageKey = `config:${hashedKey}`;

    try {
      if (url.pathname === "/load") {
        const stored = await env.CONFIGS.get(
          storageKey,
          "json",
        );

        if (!stored) {
          return json({
            ok: true,
            found: false,
            data: null,
          });
        }

        return json({
          ok: true,
          found: true,
          data: stored,
        });
      }

      const cleanConfig = sanitizeConfig(body?.data);

      await env.CONFIGS.put(
        storageKey,
        JSON.stringify(cleanConfig),
      );

      return json({
        ok: true,
        saved: true,
        savedAt: cleanConfig.savedAt,
      });
    } catch (error) {
      return json(
        {
          ok: false,
          error:
            error instanceof Error
              ? error.message
              : "Storage failed.",
        },
        500,
      );
    }
  },
};