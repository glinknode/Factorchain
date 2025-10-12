// src/issuance.ts
import { SCHEMA_QVI_SAID, SCHEMA_LEGAL_ENTITY_SAID } from "./config.js";
import { logger } from "./logger.js";
import { getAid } from "./aid.js";
import { getClient } from "./signify.js";
import { ensureRegistry } from "./registry.js";

export type QVISubject = { lei: string; dt?: string };
export type VLEISubject = { legalName: string; lei: string; dt?: string };

export async function issueQVI(
  issuerName: string,
  recipientName: string,
  subj: QVISubject
) {
  const client = getClient();
  const iss = await getAid(issuerName);
  const rec = await getAid(recipientName);
  if (!iss || !rec) throw new Error("issuer or recipient AID missing");

  const registry = await ensureRegistry();

  const data = { LEI: subj.lei, dt: subj.dt ?? new Date().toISOString() };

  const out = await client.credentials().issue({
    schema: SCHEMA_QVI_SAID,
    issuer: (iss as any).prefix ?? (iss as any).pre,
    recipient: (rec as any).prefix ?? (rec as any).pre,
    data,
    registry,
  });

  logger.info("[issue.qvi] %j", {
    schema: SCHEMA_QVI_SAID,
    issuer: issuerName,
    recipient: recipientName,
    data,
  });
  return out;
}

export async function issueLegalEntityVLEI(
  qviIssuerName: string,
  holderName: string,
  subj: VLEISubject
) {
  const client = getClient();
  const iss = await getAid(qviIssuerName);
  const rec = await getAid(holderName);
  if (!iss || !rec) throw new Error("issuer or holder AID missing");

  const registry = await ensureRegistry();

  const data = {
    legalName: subj.legalName,
    LEI: subj.lei,
    dt: subj.dt ?? new Date().toISOString(),
  };

  const out = await client.credentials().issue({
    schema: SCHEMA_LEGAL_ENTITY_SAID,
    issuer: (iss as any).prefix ?? (iss as any).pre,
    recipient: (rec as any).prefix ?? (rec as any).pre,
    data,
    registry,
  });

  logger.info("[issue.vlei] %j", {
    schema: SCHEMA_LEGAL_ENTITY_SAID,
    issuer: qviIssuerName,
    holder: holderName,
    data,
  });
  return out;
}