const JSON_HEADERS = {
  "content-type": "application/json; charset=UTF-8",
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type",
  "cache-control": "no-store",
};

const ALLOWED_SCOPES = new Set(["hub", "bloom", "mailer"]);
const MAX_JSON_BYTES = 64 * 1024;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: JSON_HEADERS,
  });
}

async function sha256(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);

  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function validateScope(value) {
  return typeof value === "string" && ALLOWED_SCOPES.has(value)
    ? value
    : null;
}

function validateData(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Config data must be a JSON object.");
  }

  const encoded = JSON.stringify(value);

  if (encoded.length > MAX_JSON_BYTES) {
    throw new Error("Config data is too large.");
  }

  return value;
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

    const validPaths = new Set([
      "/load",
      "/save",
      "/set-default",
    ]);

    if (!validPaths.has(url.pathname)) {
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
    const scope = validateScope(body?.scope);

    if (
      typeof key !== "string" ||
      key.length < 20 ||
      key.length > 128
    ) {
      return json(
        {
          ok: false,
          error: "User key must be 20-128 characters.",
        },
        400,
      );
    }

    if (!scope) {
      return json(
        {
          ok: false,
          error: "Invalid config scope.",
        },
        400,
      );
    }

    const hashedKey = await sha256(key);

    const userStorageKey =
      `user:${hashedKey}:${scope}`;

    const defaultStorageKey =
      `default:${scope}`;

    try {
      if (url.pathname === "/load") {
        const userConfig = await env.CONFIGS.get(
          userStorageKey,
          "json",
        );

        if (userConfig) {
          return json({
            ok: true,
            found: true,
            source: "user",
            data: userConfig,
          });
        }

        // Migration support for the first Bloom config Worker.
        // Older versions stored Bloom settings as:
        // config:<hash>
        if (scope === "bloom") {
          const legacyStorageKey =
            `config:${hashedKey}`;

          const legacyConfig = await env.CONFIGS.get(
            legacyStorageKey,
            "json",
          );

          if (legacyConfig) {
            await env.CONFIGS.put(
              userStorageKey,
              JSON.stringify(legacyConfig),
            );

            return json({
              ok: true,
              found: true,
              source: "legacy-user-migrated",
              data: legacyConfig,
            });
          }
        }

        const defaultConfig = await env.CONFIGS.get(
          defaultStorageKey,
          "json",
        );

        if (defaultConfig) {
          return json({
            ok: true,
            found: true,
            source: "default",
            data: defaultConfig,
          });
        }

        return json({
          ok: true,
          found: false,
          source: "none",
          data: null,
        });
      }

      const cleanData = validateData(body?.data);

      if (url.pathname === "/save") {
        await env.CONFIGS.put(
          userStorageKey,
          JSON.stringify(cleanData),
        );

        return json({
          ok: true,
          saved: true,
          scope,
          source: "user",
          savedAt: new Date().toISOString(),
        });
      }

      // Global default config.
      // Existing UserId settings still take priority.
      await env.CONFIGS.put(
        defaultStorageKey,
        JSON.stringify(cleanData),
      );

      return json({
        ok: true,
        saved: true,
        scope,
        source: "default",
        savedAt: new Date().toISOString(),
      });
    } catch (error) {
      return json(
        {
          ok: false,
          error:
            error instanceof Error
              ? error.message
              : "Storage operation failed.",
        },
        500,
      );
    }
  },
};