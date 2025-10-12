// src/registry.ts
import { logger } from "./logger.js";
import { getClient } from "./signify.js";
import { getAid } from "./aid.js";
import { QVI_AID_NAME } from "./config.js";

const ISSUER_ALIAS = QVI_AID_NAME || "qvi";         // app’s issuer alias
const REGISTRY_NAME = "vlei-reg";                   // registry alias to use
const FALLBACK_SAID = process.env.REGISTRY_SAID || "";

// normalize various return shapes into a SAID (string)
function pickSaid(x: any): string | null {
  if (!x) return null;
  if (typeof x === "string") return x;
  return x?.vcp?.d ?? x?.regk ?? x?.said ?? x?.d ?? null;
}

async function listByAliasOrPrefix(client: any, alias: string, prefix?: string) {
  const registries = client.registries();
  let out: any[] = [];
  try {
    logger.debug("[registry.list] for alias=%s", alias);
    const a = await registries.list(alias).catch(() => []);
    if (Array.isArray(a)) out = a;
    logger.debug("[registry.list] %d items", out.length);
  } catch {}
  if ((!out || out.length === 0) && prefix) {
    try {
      logger.debug("[registry.list] for prefix=%s", prefix);
      const p = await registries.list(prefix).catch(() => []);
      if (Array.isArray(p)) out = p;
      logger.debug("[registry.list] %d items", out.length);
    } catch {}
  }
  return out;
}

export async function ensureRegistry(): Promise<string> {
  const client = getClient();
  const registries = client.registries?.();
  if (!registries) throw new Error("signify-ts missing registries() API");

  // Resolve issuer prefix from our alias (avoid “undefined” surprises)
  const aid = await getAid(ISSUER_ALIAS);
  const PREFIX = (aid as any)?.prefix ?? (aid as any)?.pre ?? null;
  if (!PREFIX) throw new Error(`issuer AID not found: ${ISSUER_ALIAS}`);

  // 1) Already exists?
  const existing = await listByAliasOrPrefix(client, ISSUER_ALIAS, PREFIX);
  const named =    existing.find((r: any) => (r?.name ?? r?.vcp?.name) === REGISTRY_NAME) ??
  existing[0];
const said0 = pickSaid(named);
if (said0) {
  logger.debug(
    "[registry] using existing (alias=%s, name=%s, said=%s)",
    ISSUER_ALIAS,
    REGISTRY_NAME,
    said0
  );
  return said0;
}

// ----- Try multiple explicit, stringy signatures -----

// A. create(alias, { name, noBackers, estOnly })
try {
  const body = { name: REGISTRY_NAME, noBackers: true, estOnly: true };
  logger.info(
    "[registry] create(alias, object) alias=%s body=%j",
    ISSUER_ALIAS,
    body
  );
  const res = await registries.create(ISSUER_ALIAS, body);
  const said = pickSaid(res);
  if (said) return said;
  logger.warn("[registry] create(alias, object) returned no SAID: %j", res);
} catch (e: any) {
  logger.warn(
    "[registry] create(alias, object) failed: %s",
    e?.message ?? String(e)
  );
}

// B. create(prefix, { name, noBackers, estOnly })
try {
  const body = { name: REGISTRY_NAME, noBackers: true, estOnly: true };
  logger.info(
    "[registry] create(prefix, object) prefix=%s body=%j",
    PREFIX,
    body
  );
  const res = await registries.create(PREFIX, body);
  const said = pickSaid(res);
  if (said) return said;
  logger.warn("[registry] create(prefix, object) returned no SAID: %j", res);
} catch (e: any) {
  logger.warn(
    "[registry] create(prefix, object) failed: %s",
    e?.message ?? String(e)
  );
}

// C. create({ alias, name, ... })
try {
  const body = {
    alias: ISSUER_ALIAS,
    name: REGISTRY_NAME,
    noBackers: true,
    estOnly: true,
  };
  logger.info("[registry] create(object-with-alias) body=%j", body);
  const res = await registries.create(body);
  const said = pickSaid(res);
  if (said) return said;
  logger.warn("[registry] create(object-with-alias) returned no SAID: %j", res);
} catch (e: any) {
  logger.warn(
    "[registry] create(object-with-alias) failed: %s",
    e?.message ?? String(e)
  );
}

// D. create({ controller: prefix, name, ... })
try {
  const body = {
    controller: PREFIX,
    name: REGISTRY_NAME,
    noBackers: true,
    estOnly: true,
  };
  logger.info("[registry] create(object-with-controller) body=%j", body);
  const res = await registries.create(body);
  const said = pickSaid(res);
  if (said) return said;
  logger.warn(
    "[registry] create(object-with-controller) returned no SAID: %j",
    res
  );
} catch (e: any) {
  logger.warn(
    "[registry] create(object-with-controller) failed: %s",
    e?.message ?? String(e)
    );
  }

  // Last resort: allow configured SAID
  if (FALLBACK_SAID) {
    logger.warn("[registry] using REGISTRY_SAID override: %s", FALLBACK_SAID);
    return FALLBACK_SAID;
  }

  throw new Error(
    "ensureRegistry(): failed"
  );
}
