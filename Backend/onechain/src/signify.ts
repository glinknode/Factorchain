// src/signify.ts
import signify from "signify-ts";
import { logger } from "./logger.js";
import {
  KERIA_ADMIN,
  KERIA_BOOT,
  PASSCODE,
  WITNESS_OOBIS,            // e.g. ['http://wan:5642/oobi/<EID>/witness', ...]
  WITNESS_EIDS,             // e.g. ['BHNT...', 'BBOP...', 'BH4Z...']
  CONTACT_WAIT_TIMEOUT_MS,  // e.g. 60_000
  CONTACT_WAIT_POLL_MS,     // e.g. 500
} from "./config.js";

const { ready, SignifyClient, Tier } = signify;

let clientRef: any = null;


function uniq<T>(arr: T[]): T[] {
  return Array.from(new Set(arr.filter(Boolean)));
}

function normalizeBootBase(u: string) {
  // SignifyClient expects the base admin endpoint; some envs give us ".../boot"
  return u.replace(/\/+boot\/?$/, "");
}

function makeClient() {
  return new SignifyClient(
    KERIA_ADMIN,
    PASSCODE,
    Tier.low,
    normalizeBootBase(KERIA_BOOT)
  );
}

function eidFromOobi(u: string): string | null {
  const m = /\/oobi\/([A-Za-z0-9_\-]+)\//.exec(u);
  return m ? m[1] : null;
}

function oobiMap() {
  const map = new Map<string, string>();
  (Array.isArray(WITNESS_OOBIS) ? WITNESS_OOBIS : []).forEach((u) => {
    const pre = eidFromOobi(String(u));
    if (pre) map.set(pre, u);
  });
  return map;
}

async function resolveOobi(client: any, url: string, aliasPrefix = "wit") {
  const alias = `${aliasPrefix}-${(eidFromOobi(url) ?? "").slice(0, 6)}`;
  try {
    logger.info("[signify] resolve OOBI: %s", url);
    await client.oobis().resolve(url, alias);
  } catch (e: any) {
    logger.warn("[oobi] %s", String(e?.message ?? e));
  }
}

export async function refreshWitnessOobis(client: any) {
  const list = (Array.isArray(WITNESS_OOBIS) ? WITNESS_OOBIS : []).filter(Boolean);
  const endList = uniq(
    list
      .map((u) => u.replace(/\/witness\/?$/, "/end"))
      .filter((u) => u && u !== "/end")
  );

  for (const url of list) await resolveOobi(client, url, "wit");
  for (const url of endList) await resolveOobi(client, url, "end");
}


async function contactExists(client: any, pre: string): Promise<boolean> {
  if (!pre) return false;
  try {
    const c = await client.contacts().get(pre); // 404 -> throw
    const got =
      c?.eid ?? c?.pre ?? c?.prefix ?? c?.id ?? (typeof c === "string" ? c : "");
    return got === pre;
  } catch {
    return false;
  }
}


export type SelectWitnessesOpts = {
  timeoutMs?: number;
  pollMs?: number;
  logPrefix?: string;
  reResolveEvery?: number;
  stableRounds?: number;
  stableOnce?: boolean;
  forceStable?: boolean;
};

let _witnessWarm = false;
let _lastStable: string[] = [];
export function resetWitnessWarm() {
  _witnessWarm = false;
  _lastStable = [];
}

async function fastKnown(client: any, want: string[], logPrefix: string) {
  const seen = new Set<string>();

  try {
    const list = await client.contacts().list();
    if (Array.isArray(list)) {
      for (const c of list) {
        const pre = c?.eid || c?.pre || c?.prefix || c?.id || null;
        if (pre && want.includes(pre)) seen.add(pre);
      }
    }
  } catch { /* ignore */ }

  for (const pre of want) {
    if (seen.has(pre)) continue;
    if (await contactExists(client, pre)) seen.add(pre);
  }

  const out = want.filter((pre) => seen.has(pre));
  logger.info("[%s.fast] known now=%d/%d wits=%j", logPrefix, out.length, want.length, out);
  return out;
}
export async function selectWitnessesFor(
  toadRequired = 2,
  desiredEids: string[] = WITNESS_EIDS,
  {
    timeoutMs = CONTACT_WAIT_TIMEOUT_MS,
    pollMs = CONTACT_WAIT_POLL_MS,
    logPrefix = "contacts.wait",
    reResolveEvery = 10,  // first run only
    stableRounds = 10,    // first run only
    stableOnce = true,
    forceStable = false,
  }: SelectWitnessesOpts = {}
): Promise<{ wits: string[]; toad: number }> {
  const client = getClient();
  const want = uniq(desiredEids);
  const oobis = oobiMap();

  if (!want.length || toadRequired <= 0) {
    return { wits: [], toad: 0 };
  }

  if (_witnessWarm && stableOnce && !forceStable) {
    const have = await fastKnown(client, want, logPrefix);
    const clampedToad = Math.min(toadRequired, have.length);
    return { wits: have, toad: clampedToad };
  }

  if (stableRounds < 1) stableRounds = 1;
  const deadline = Date.now() + Math.max(0, timeoutMs);
  let iter = 0;

  const confirms = new Map<string, number>();
  for (const pre of want) confirms.set(pre, 0);

  const stableList = () => want.filter((pre) => (confirms.get(pre) ?? 0) >= stableRounds);
   const theoreticalMin = stableRounds * pollMs;
   if (timeoutMs < theoreticalMin) {
     logger.warn(
       "[%s] timeout=%dms < stableRounds*pollMs=%dms (rounds=%d, poll=%d). Consider raising timeout.",
       logPrefix, timeoutMs, theoreticalMin, stableRounds, pollMs
     );
   }
 
   while (Date.now() < deadline) {
     iter += 1;
 
     const seenThisIter = new Set<string>();
 
     try {
       const list = await client.contacts().list();
       if (Array.isArray(list)) {
         for (const c of list) {
           const pre = c?.eid || c?.pre || c?.prefix || c?.id || null;
           if (pre && want.includes(pre)) seenThisIter.add(pre);
         }
       } else {
         logger.debug("[%s] iter=%d list.type=%s", logPrefix, iter, typeof list);
       }
     } catch (e: any) {
       logger.debug("[%s] iter=%d list error: %s", logPrefix, iter, e?.message ?? String(e));
     }
 
     for (const pre of want) {
       if (seenThisIter.has(pre)) continue;
       if (await contactExists(client, pre)) seenThisIter.add(pre);
     }
 
     for (const pre of want) {
       const prev = confirms.get(pre) ?? 0;
       const next = seenThisIter.has(pre) ? prev + 1 : 0;
       confirms.set(pre, next);
     }
 
     if (iter === 1 || iter % 5 === 0) {
       const snapshot = want.map((pre) => [pre.slice(0, 6), confirms.get(pre) ?? 0]);
       logger.info("[%s] iter=%d rounds=%d progress=%j", logPrefix, iter, stableRounds, snapshot);
     } else {
      for (const pre of want) {
        if ((confirms.get(pre) ?? 0) === stableRounds && seenThisIter.has(pre)) {
          logger.info("[%s] iter=%d stabilized=%s (%d/%d)",
            logPrefix, iter, pre, stableRounds, stableRounds);
        }
      }
    }

    const stable = stableList();
    if (stable.length >= toadRequired) {
      logger.info("[%s] satisfied (stable) after %d iters: have=%d/%d wits=%j",
        logPrefix, iter, stable.length, toadRequired, stable);

      _witnessWarm = true;
      _lastStable = stable.slice();

      return { wits: stable, toad: toadRequired };
    }

    if (iter % Math.max(1, reResolveEvery) === 0) {
      const notStable = want.filter((w) => !stable.includes(w));
      for (const pre of notStable) {
        const url = oobis.get(pre);
        if (!url) continue;
        try {
          logger.debug("[%s] iter=%d re-resolve OOBI for %s: %s", logPrefix, iter, pre, url);
          await client.oobis().resolve(url, `wit-${pre.slice(0, 6)}`);
          const endUrl = url.replace(/\/witness\/?$/, "/end");
          if (endUrl !== url) {
            await client.oobis().resolve(endUrl, `end-${pre.slice(0, 6)}`);
          }
        } catch (e: any) {
          logger.warn("[oobi.re] %s", e?.message ?? String(e));
        }
      }
    }

    await new Promise((r) => setTimeout(r, pollMs));
  }

  const stable = want.filter((pre) => (confirms.get(pre) ?? 0) >= stableRounds);
  const missing = want.filter((w) => !stable.includes(w));
  const snapshot = want.map((pre) => [pre.slice(0, 6), confirms.get(pre) ?? 0]);
  logger.warn(
    "[%s] timeout after %dms; stable=%d need=%d missing=%j progress=%j",
    logPrefix,
    Math.max(0, timeoutMs),
    stable.length,
    toadRequired,
    missing,
    snapshot
  );
  throw new Error(
    `Not enough STABLE witnesses: stable=${stable.length} need=${toadRequired}; missing=${JSON.stringify(missing)}`
  );
}

export async function ensureBootStrictAndConnect() {
  await ready();
  if (clientRef) return clientRef;

  const client = makeClient();

  let needBoot = false;
  try {
    await client.state();
    logger.info("[signify] agent exists");
  } catch (e: any) {
    if (String(e?.message ?? e).includes("agent does not exist")) needBoot = true;
    else throw e;
  }

  if (needBoot) {
    logger.info("[signify] strict boot via /boot …");
    await client.boot();
    logger.info("[signify] boot OK");
  }

  await client.connect();
  logger.info("[signify] connect OK");

  await refreshWitnessOobis(client);

  clientRef = client;
  return clientRef;
}

export function getClient(): any {
  if (!clientRef) throw new Error("signify client not connected");
  return clientRef;
}


export async function prepareWitnessArgs(
  toadRequired = 2,
  desiredEids: string[] = WITNESS_EIDS,
  opts?: SelectWitnessesOpts
): Promise<{ wits: string[]; toad: number }> {
  await ensureBootStrictAndConnect(); // no-op if already connected
  return selectWitnessesFor(toadRequired, desiredEids, opts);
}