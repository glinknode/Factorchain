// iso20022-adapter-public.js
const express = require("express");
const cors = require("cors");
const crypto = require("crypto");
const { XMLParser } = require("fast-xml-parser");

/* -------------------- config via env -------------------- */
const PORT = Number(process.env.PORT || 18887);
const JSON_LIMIT = process.env.JSON_LIMIT || "1mb";
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

/* ---- logging knobs (same style as your vLEI adapters) ---- */
const LOG_LEVEL = (process.env.LOG_LEVEL || "info").toLowerCase(); // info|debug|warn|error
const LOG_BODY = ["1", "true", "yes"].includes(String(process.env.LOG_BODY || "0").toLowerCase());
const LOG_PRETTY = ["1", "true", "yes"].includes(String(process.env.LOG_PRETTY || "0").toLowerCase());
const SUMMARY_INTERVAL_SEC = Number(process.env.LOG_SUMMARY_INTERVAL || "0"); // 0=off
const BODY_PREVIEW_LIMIT = Number(process.env.LOG_BODY_PREVIEW_LIMIT || "800");

/* -------------------- logger -------------------- */
const LEVEL_WEIGHT = { debug: 10, info: 20, warn: 30, error: 40 };
const THRESHOLD = LEVEL_WEIGHT[["debug", "info", "warn", "error"].includes(LOG_LEVEL) ? LOG_LEVEL : "info"];

function bodyPreview(val) {
  if (!LOG_BODY) return undefined;
  try {
    const s = JSON.stringify(val);
    return s.length <= BODY_PREVIEW_LIMIT ? s : s.slice(0, BODY_PREVIEW_LIMIT) + "…(trunc)";
  } catch {
    const s = String(val);
    return s.length <= BODY_PREVIEW_LIMIT ? s : s.slice(0, BODY_PREVIEW_LIMIT) + "…(trunc)";
  }
}

function log(level, event, meta = {}) {
  if (LEVEL_WEIGHT[level] < THRESHOLD) return;
  const rec = { ts: new Date().toISOString(), level, event, ...meta };
  const out = LOG_PRETTY ? JSON.stringify(rec, null, 2) : JSON.stringify(rec);
  console.log(out);
}

/* -------------------- app & middleware -------------------- */
const app = express();
app.use(express.json({ limit: JSON_LIMIT }));
app.use((_req, res, next) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Referrer-Policy", "no-referrer");
  next();
});

// CORS: allow all if ALLOWED_ORIGINS empty; else restrict to list
app.use(
  cors({
    origin: (origin, cb) => {
      if (!origin || ALLOWED_ORIGINS.length === 0 || ALLOWED_ORIGINS.includes(origin)) return cb(null, true);
      return cb(new Error("CORS"), false);
    },
  })
);

/* -------------------- utils & state -------------------- */
const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  allowBooleanAttributes: true,
});
const hexKeccak = (s) => "0x" + crypto.createHash("sha3-256").update(s).digest("hex");
const nowISO = () => new Date().toISOString();

// tokenId -> (msgId -> MsgEntry)
const store = new Map();

function xmlHeader() {
  return `<?xml version="1.0" encoding="UTF-8"?>`;
}

function save(tokenId, kind, type, xml, meta) {
  const key = `${kind}:${type}:${Date.now()}`;
  const entry = { kind, type, xml, createdAt: nowISO(), hash: hexKeccak(xml), meta };
  if (!store.has(tokenId)) store.set(tokenId, new Map());
  store.get(tokenId).set(key, entry);
  log("info", "iso:save", { tokenId, id: key, kind, type, hash: entry.hash });
  return { id: key, ...entry };
}

/* -------------------- lite validators -------------------- */
function valPacs008(doc) {
  const D = doc["Document"] || doc["Doc:Document"];
  const reasons = [];
  if (!D) reasons.push("Document root missing");
  const root = D?.["FIToFICstmrCdtTrf"] || D?.["Doc:FIToFICstmrCdtTrf"];
  if (!root) reasons.push("FIToFICstmrCdtTrf missing");
  const hdr = root?.["GrpHdr"];
  if (!hdr?.["MsgId"]) reasons.push("GrpHdr/MsgId missing");
  const tx = root?.["CdtTrfTxInf"];
  if (!tx) reasons.push("CdtTrfTxInf missing");
  const amt = tx?.["Amt"]?.["InstdAmt"];
  if (!amt || !amt?.["@_Ccy"]) reasons.push("InstdAmt @Ccy missing");
  return { valid: reasons.length === 0, reasons };
}

function valCamt054(doc) {
  const D = doc["Document"] || doc["Doc:Document"];
  const reasons = [];
  const root = D?.["BkToCstmrDbtCdtNtfctn"] || D?.["Doc:BkToCstmrDbtCdtNtfctn"];
  if (!root) reasons.push("BkToCstmrDbtCdtNtfctn missing");
  const Ntfctn = root?.["Ntfctn"];
  if (!Ntfctn) reasons.push("Ntfctn missing");
  return { valid: reasons.length === 0, reasons };
}

/* -------------------- XML builders -------------------- */
function TSIN006(b) {
  return `${xmlHeader()}
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:tsin.006.001.01">
  <ReqForTrdPtyTpSetPric>
    <GrpHdr><MsgId>${b.msgId}</MsgId><CreDtTm>${b.creDtTm}</CreDtTm></GrpHdr>
    <Assgmt>
      <Sellr>${b.sellerLEI}</Sellr>
      <Buyr>${b.buyerLEI}</Buyr>
      <Dbtr>${b.debtorLEI}</Dbtr>
      <InvId>${b.invoiceId}</InvId>
      <InvcAmt Ccy="${b.ccy}">${b.amount}</InvcAmt>
      <DueDt>${b.dueDate}</DueDt>
    </Assgmt>
  </ReqForTrdPtyTpSetPric>
</Document>`;
}

function TSIN007(b) {
  return `${xmlHeader()}
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:tsin.007.001.01">
  <TrdPtyTpSetPricSts>
    <GrpHdr><MsgId>${b.msgId}</MsgId><CreDtTm>${b.creDtTm}</CreDtTm></GrpHdr>
    <OrgnlMsgId>${b.relatedMsgId}</OrgnlMsgId>
    <Sts>${b.statusCode}</Sts>${b.reason ? `<Rsn>${b.reason}</Rsn>` : ""}
  </TrdPtyTpSetPricSts>
</Document>`;
}

function TSIN008(b) {
  return `${xmlHeader()}
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:tsin.008.001.01">
  <NtfctnOfPmtInstrUpd>
    <GrpHdr><MsgId>${b.msgId}</MsgId><CreDtTm>${b.creDtTm}</CreDtTm></GrpHdr>
    <Dbtr>${b.debtorLEI}</Dbtr>
    <InvId>${b.invoiceId}</InvId>
    <NewPmtInstr>
      <BenefLEI>${b.newOwnerLEI}</BenefLEI>
      <IBAN>${b.newPayToIBAN || ""}</IBAN>
      <OnChain>${b.newPayToWallet || ""}</OnChain>
    </NewPmtInstr>
  </NtfctnOfPmtInstrUpd>
</Document>`;
}

function PACS008(b) {
  return `${xmlHeader()}
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pacs.008.001.08">
  <FIToFICstmrCdtTrf>
    <GrpHdr><MsgId>${b.msgId}</MsgId><CreDtTm>${b.creDtTm}</CreDtTm><NbOfTxs>1</NbOfTxs><SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf></GrpHdr>
    <CdtTrfTxInf>
      <PmtId><InstrId>${b.instrId}</InstrId><EndToEndId>${b.e2eId}</EndToEndId><TxId>${b.txId}</TxId></PmtId>
      <Amt><InstdAmt Ccy="${b.ccy}">${b.amount}</InstdAmt></Amt>
      <Dbtr><Nm>${b.debtorName}</Nm></Dbtr>
      <DbtrAcct><Id><IBAN>${b.debtorIBAN}</IBAN></Id></DbtrAcct>
      <DbtrAgt><FinInstnId><BICFI>${b.debtorBIC}</BICFI></FinInstnId></DbtrAgt>
      <CdtrAgt><FinInstnId><BICFI>${b.creditorBIC}</BICFI></FinInstnId></CdtrAgt>
      <Cdtr><Nm>${b.creditorName}</Nm></Cdtr>
      <CdtrAcct><Id><IBAN>${b.creditorIBAN}</IBAN></Id></CdtrAcct>
      <RmtInf><Ustrd>${b.remRef}</Ustrd></RmtInf>
    </CdtTrfTxInf>
  </FIToFICstmrCdtTrf>
</Document>`;
}

function CAMT054(b) {
  return `${xmlHeader()}
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.054.001.08">
  <BkToCstmrDbtCdtNtfctn>
    <GrpHdr><MsgId>${b.msgId}</MsgId><CreDtTm>${b.creDtTm}</CreDtTm></GrpHdr>
    <Ntfctn>
      <Id>${b.msgId}-N1</Id>
      <Acct><Id><IBAN>${b.acctIBAN}</IBAN></Id></Acct>
      <Ntry>
        <NtryRef>${b.entryRef}</NtryRef>
        <Amt Ccy="${b.ccy}">${b.amount}</Amt>
        <CdtDbtInd>CRDT</CdtDbtInd>
        <AddtlNtryInf>${b.remRef}</AddtlNtryInf>
      </Ntry>
    </Ntfctn>
  </BkToCstmrDbtCdtNtfctn>
</Document>`;
}

/* -------------------- metrics -------------------- */
const metrics = {
  healthz: 0,
  validate_in: 0,
  gen_in: 0,
  list_in: 0,
  get_xml_in: 0,
};

/* -------------------- minimal idempotency shim (5s TTL, no Redis) + DEBUG -------------------- */
const __IDEM_CACHE_TTL_MS = 5000; // 5 seconds
const __IDEM_LOCK_TTL_MS = 5000;  // 5 seconds
const __idemCache = new Map();    // key -> { v: string(json), exp: number }
const __idemLocks = new Map();    // key -> exp timestamp

function __stableStringify(x) {
  if (x === null || typeof x !== "object") return JSON.stringify(x);
  if (Array.isArray(x)) return "[" + x.map(__stableStringify).join(",") + "]";
  const keys = Object.keys(x).sort();
  return "{" + keys.map(k => JSON.stringify(k) + ":" + __stableStringify(x[k])).join(",") + "}";
}

function __hashKey(req) {
  return crypto.createHash("sha256")
    .update(req.method + " " + req.path + "\n" + __stableStringify(req.body || {}))
    .digest("hex");
}

function __idemWrap(computeOnce /* (req) => Promise<object> */) {
  return async (req, res) => {
    const key = __hashKey(req);
    const cacheKey = "idem:" + key;
    const now = Date.now();

    // cached?
    const hit = __idemCache.get(cacheKey);
    if (hit && hit.exp > now) {
      log("debug", "idem:cache_hit", { path: req.path, key });
      res.setHeader("X-Idempotency-Key", key);
      return res.status(200).type("application/json").send(hit.v);
    } else if (hit) {
      __idemCache.delete(cacheKey);
    }

    // someone else computing?
    const lockExp = __idemLocks.get(cacheKey) || 0;
    if (lockExp > now) {
      log("debug", "idem:lock_wait", { path: req.path, key });
      const deadline = now + 800; // brief poll
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 50));
        const h2 = __idemCache.get(cacheKey);
        if (h2 && h2.exp > Date.now()) {
          log("debug", "idem:cache_hit_after_wait", { path: req.path, key });
          res.setHeader("X-Idempotency-Key", key);
          return res.status(200).type("application/json").send(h2.v);
        }
      }
      log("debug", "idem:pending_202", { path: req.path, key });
      res.setHeader("Retry-After", "1");
      res.setHeader("X-Idempotency-Key", key);
      return res.status(202).json({ status: "pending" });
    }

    // become leader
    log("debug", "idem:leader", { path: req.path, key });
    __idemLocks.set(cacheKey, now + __IDEM_LOCK_TTL_MS);
    try {
      const obj = await computeOnce(req); // must be deterministic for same inputs
      const body = __stableStringify(obj);
      __idemCache.set(cacheKey, { v: body, exp: Date.now() + __IDEM_CACHE_TTL_MS });
      log("debug", "idem:cache_store", { path: req.path, key, ttl_ms: __IDEM_CACHE_TTL_MS });
      res.setHeader("X-Idempotency-Key", key);
      return res.status(200).type("application/json").send(body);
    } catch (e) {
      return res.status(500).json({ error: "compute_failed", message: String(e && e.message || e) });
    } finally {
      __idemLocks.delete(cacheKey);
    }
  };
}

/* -------------------- routes -------------------- */
app.get("/healthz", (_req, res) => {
  metrics.healthz++;
  res.json({ ok: true, service: "iso20022", ts: nowISO() });
});

app.post("/validate-lite", (req, res) => {
  metrics.validate_in++;
  const { messageType, payloadXml } = req.body || {};
  log("info", "validate:in", { messageType, body: bodyPreview(req.body) });

  if (!messageType || !payloadXml) {
    return res.status(400).json({ error: "messageType, payloadXml required" });
  }

  let doc;
  try {
    doc = parser.parse(payloadXml);
  } catch (e) {
    const msg = e && e.message ? e.message : String(e);
    log("warn", "validate:xml_parse_error", { error: msg });
    return res.json({ valid: false, reasons: [`XML not well-formed: ${msg}`] });
  }

  const mt = String(messageType).toLowerCase();
  let result = { valid: false, reasons: ["unsupported messageType"] };
  if (mt.startsWith("pacs.008")) result = valPacs008(doc);
  if (mt.startsWith("camt.054")) result = valCamt054(doc);

  const docHash = hexKeccak(payloadXml);
  log("info", "validate:out", { valid: result.valid, reasons: result.reasons, docHash });
  res.json({ ...result, docHash });
});

function ensureBase(body) {
  return { ...body, creDtTm: (body && body.creDtTm) || nowISO() };
}

// === Wrapped message builders: first call computes & saves; others read cached JSON ===
app.post("/iso/:tokenId/tsin006", __idemWrap(async (req) => {
  metrics.gen_in++;
  const tokenId = String(req.params.tokenId);
  const b = ensureBase(req.body);
  log("info", "tsin006:in", { tokenId, body: bodyPreview(req.body) });
  const xml = TSIN006(b);
  return save(tokenId, "tsin", "006", xml, b);
}));

app.post("/iso/:tokenId/tsin007", __idemWrap(async (req) => {
  metrics.gen_in++;
  const tokenId = String(req.params.tokenId);
  const b = ensureBase(req.body);
  log("info", "tsin007:in", { tokenId, body: bodyPreview(req.body) });
  const xml = TSIN007(b);
  return save(tokenId, "tsin", "007", xml, b);
}));

app.post("/iso/:tokenId/tsin008", __idemWrap(async (req) => {
  metrics.gen_in++;
  const tokenId = String(req.params.tokenId);
  const b = ensureBase(req.body);
  log("info", "tsin008:in", { tokenId, body: bodyPreview(req.body) });
  const xml = TSIN008(b);
  return save(tokenId, "tsin", "008", xml, b);
}));

app.post("/iso/:tokenId/pacs008", __idemWrap(async (req) => {
  metrics.gen_in++;
  const tokenId = String(req.params.tokenId);
  const b = ensureBase(req.body);
  log("info", "pacs008:in", { tokenId, body: bodyPreview(req.body) });
  const xml = PACS008(b);
  return save(tokenId, "pacs", "008", xml, b);
}));

app.post("/iso/:tokenId/camt054", __idemWrap(async (req) => {
  metrics.gen_in++;
  const tokenId = String(req.params.tokenId);
  const b = ensureBase(req.body);
  log("info", "camt054:in", { tokenId, body: bodyPreview(req.body) });
  const xml = CAMT054(b);
  return save(tokenId, "camt", "054", xml, b);
}));

app.get("/iso/:tokenId/messages", (req, res) => {
  metrics.list_in++;
  const tokenId = String(req.params.tokenId);
  const bucket = store.get(tokenId);
  const list = !bucket
    ? []
    : [...bucket.entries()].map(([id, v]) => ({
        id,
        kind: v.kind,
        type: v.type,
        createdAt: v.createdAt,
        hash: v.hash,
        meta: v.meta,
      }));
  const sorted = list.sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1));
  log("debug", "messages:list", { tokenId, count: sorted.length });
  res.json(sorted);
});

app.get("/iso/:tokenId/messages/:msgId.xml", (req, res) => {
  metrics.get_xml_in++;
  const tokenId = String(req.params.tokenId);
  const msgId = String(req.params.msgId);
  const bucket = store.get(tokenId);
  if (!bucket || !bucket.has(msgId)) {
    log("warn", "messages:get_not_found", { tokenId, msgId });
    return res.status(404).send("not found");
  }
  const xml = bucket.get(msgId).xml;
  log("debug", "messages:get_xml", { tokenId, msgId, bytes: Buffer.byteLength(xml, "utf8") });
  res.setHeader("Content-Type", "application/xml; charset=utf-8");
  res.send(xml);
});

/* -------------------- periodic summary -------------------- */
if (SUMMARY_INTERVAL_SEC > 0) {
  setInterval(() => {
    let totalMsgs = 0;
    for (const bucket of store.values()) totalMsgs += bucket.size;
    const summary = { totalTokenIds: store.size, totalMsgs, metrics };
    log("info", "summary", summary);
  }, SUMMARY_INTERVAL_SEC * 1000);
}

/* -------------------- start -------------------- */
app.listen(PORT, () => {
  log("info", "server:start", {
    port: PORT,
    JSON_LIMIT,
    ALLOWED_ORIGINS: ALLOWED_ORIGINS.length ? ALLOWED_ORIGINS : "(any)",
    LOG_LEVEL,
    LOG_BODY,
    LOG_PRETTY,
    LOG_SUMMARY_INTERVAL: SUMMARY_INTERVAL_SEC,
    LOG_BODY_PREVIEW_LIMIT: BODY_PREVIEW_LIMIT,
  });
});
