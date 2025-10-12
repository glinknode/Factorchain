// src/aid.ts
import { prepareWitnessArgs, getClient } from "./signify.js";
import { WITNESS_EIDS } from "./config.js";
import { logger } from "./logger.js";

export type CreateAidOpts = {
  transferable?: boolean;
  toad?: number;     
  logPrefix?: string; 
};

export function extractPrefix(r: any): string | null {
  return (
    r?.icp?.i ??
    r?.prefix ??
    r?.pre ??
    r?.aid ??
    r?.i ??
    null
  );
}

export async function getAid(name: string): Promise<any | null> {
  const client = getClient();
  try {
    const r = await client.identifiers().get(name);
    const pre = extractPrefix(r);
    if (pre) logger.info("[aid.get] %s -> %s", name, pre);
    return r;
  } catch (e: any) {
    logger.debug("[aid.get] %s not found (%s)", name, e?.message ?? String(e));
    return null;
  }
}

export async function createAid(
  name = "qvi",
  opts: CreateAidOpts = {}
): Promise<any> {
  const desiredToad = opts.toad ?? 2;
  const { wits, toad: t } = await prepareWitnessArgs(desiredToad, WITNESS_EIDS, {
    logPrefix: opts.logPrefix ?? "aid.wits",
  });
  const client = getClient();

  const cfg = {
    algo: "salty" as const,
    transferable: opts.transferable ?? true,
    toad: t,
    wits,
  };

  logger.info("[aid.create] -> %j", { name, toad: t, wits: wits.length });

  const res = await client.identifiers().create(name, cfg);

  const pre = extractPrefix(res);
  if (pre) logger.info("[aid.create] OK %s %s", name, pre);
  else logger.warn("[aid.create] no prefix in response for %s", name);

  return res;
}

export async function getOrCreateAid(
  name: string,
  opts: CreateAidOpts = {}
): Promise<any> {
  const existing = await getAid(name);
  if (existing) return existing;
  return createAid(name, opts);
}

export async function listAids(): Promise<any[]> {
  const client = getClient();
  try {
    const list = await client.identifiers().list();
    if (Array.isArray(list)) {
      logger.info("[aid.list] %d entries", list.length);
      return list;
    }
    logger.debug("[aid.list] non-array response type=%s", typeof list);
    return [];
  } catch (e: any) {
    logger.warn("[aid.list] %s", e?.message ?? String(e));
    return [];
  }
}