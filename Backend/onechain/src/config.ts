// Centralized config (env-only; 

export const PORT = parseInt(process.env.PORT ?? process.env.HTTP_PORT ?? "18882", 10);

export const KERIA_ADMIN = process.env.KERIA_ADMIN_URL ?? "http://keria:3901";
export const KERIA_BOOT  = process.env.KERIA_BOOT_URL  ?? "http://keria:3903/boot";
export const PASSCODE    = process.env.CONTROLLER_PASSCODE ?? "0123456789abcdefghijk";

export const W1_EID = process.env.W1_EID ?? "BHNToblRIHAQowUthBzac6qzGrHz0ScG0WeIaXu3rvIT"; // wan
export const W2_EID = process.env.W2_EID ?? "BBOPdJQxRVH3uu5TJNMA7rFWIDWKZ1DV1dE9Q9oDQ_kR"; // wil
export const W3_EID = process.env.W3_EID ?? "BH4ZvhAKB2CoqoIKHJlAO_DwN4bxixdhdRt74pMQme9S"; // wes

export const W1_URL = process.env.W1_URL ?? "http://wan:5642";
export const W2_URL = process.env.W2_URL ?? "http://wil:5643";
export const W3_URL = process.env.W3_URL ?? "http://wes:5644";

export const WITNESS_EIDS = [W1_EID, W2_EID, W3_EID];

export const WITNESS_OOBIS = [
  `${W1_URL}/oobi/${W1_EID}/witness`,
  `${W2_URL}/oobi/${W2_EID}/witness`,
  `${W3_URL}/oobi/${W3_EID}/witness`,
];

export const WITNESS_ENDPOINTS: Array<{ eid: string; url: string }> = [
  { eid: W1_EID, url: W1_URL },
  { eid: W2_EID, url: W2_URL },
  { eid: W3_EID, url: W3_URL },
];

export const TOAD = parseInt(process.env.TOAD ?? "2", 10);

export const CONTACT_WAIT_TIMEOUT_MS = parseInt(
  process.env.CONTACT_WAIT_TIMEOUT_MS ?? "60000",
  10
);
export const CONTACT_WAIT_POLL_MS = parseInt(
  process.env.CONTACT_WAIT_POLL_MS ?? "500",
  10
);

export const SCHEMA_QVI_SAID          =
  process.env.SCHEMA_QVI_SAID ??
  "EBfdlu8R27Fbx-ehrqwImnK-8Cm79sqbAQ4MmvEAYqao"; // qualified-vLEI-issuer-vLEI-credential.json

export const SCHEMA_LEGAL_ENTITY_SAID =
  process.env.SCHEMA_LE_SAID  ??
  "ENPXp1vQzRF6JwIuS-mp2U8Uf1MoADoP_GqQ62VsDZWY"; // legal-entity-vLEI-credential.json

// QVI bootstrap values used during /init
export const QVI_AID_NAME = process.env.QVI_AID_NAME ?? "qvi";
export const QVI_LEI      = process.env.QVI_LEI      ?? "529900T8BM49AURSDO55";
