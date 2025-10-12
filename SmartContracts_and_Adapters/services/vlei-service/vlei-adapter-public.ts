import express, { type Request, type Response, type NextFunction } from "express";
import cors from "cors";
import axios from "axios";

/* ---------- config via env ---------- */
const PORT = Number(process.env.PORT || 18889);
const PUBLIC_BASE_URL = process.env.PUBLIC_BASE_URL || `http://localhost:${PORT}`;
const APIX_BASE = process.env.APIX_BASE || ""; // e.g. https://apix.example.com
const APIX_TOKEN = process.env.APIX_TOKEN || ""; // bearer
const APIX_BASIC_USER = process.env.APIX_BASIC_USER || "";
const APIX_BASIC_PASS = process.env.APIX_BASIC_PASS || "";
const SUBMIT_TIMEOUT_MS = Number(process.env.SUBMIT_TIMEOUT_MS || "120000"); // long-poll

/* ---------- structured logging knobs ---------- */
const LOG_LEVEL = (process.env.LOG_LEVEL || "info").toLowerCase(); // info|debug|warn|error
const LOG_BODY = ["1", "true", "yes"].includes(String(process.env.LOG_BODY || "0").toLowerCase());
const LOG_PRETTY = ["1", "true", "yes"].includes(String(process.env.LOG_PRETTY || "0").toLowerCase());
const SUMMARY_INTERVAL_SEC = Number(process.env.LOG_SUMMARY_INTERVAL || "0"); // 0=off
const BODY_PREVIEW_LIMIT = Number(process.env.LOG_BODY_PREVIEW_LIMIT || "800");

/* ---------- logger ---------- */
type Level = "debug" | "info" | "warn" | "error";
const LEVEL_WEIGHT: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const THRESHOLD = LEVEL_WEIGHT[(["debug","info","warn","error"].includes(LOG_LEVEL) ? LOG_LEVEL : "info") as Level];
function bodyPreview(val: unknown) {
  if (!LOG_BODY) return undefined;
  try {
    const s = JSON.stringify(val);
    return s.length <= BODY_PREVIEW_LIMIT ? s : s.slice(0, BODY_PREVIEW_LIMIT) + "…(trunc)";
  } catch {
    const s = String(val);
    return s.length <= BODY_PREVIEW_LIMIT ? s : s.slice(0, BODY_PREVIEW_LIMIT) + "…(trunc)";
  }
}
function log(level: Level, event: string, meta: Record<string, unknown> = {}) {
  if (LEVEL_WEIGHT[level] < THRESHOLD) return;
  const rec = { ts: new Date().toISOString(), level, event, ...meta };
  const out = LOG_PRETTY ? JSON.stringify(rec, null, 2) : JSON.stringify(rec);
  console.log(out);
}

/* ---------- app & middleware ---------- */
const app = express();
app.use(express.json({ limit: "512kb" }));
app.use((_req: Request, res: Response, next: NextFunction) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Referrer-Policy", "no-referrer");
  next();
});
app.use(cors({ origin: true }));

/* ---------- helpers ---------- */
function apixHeaders(): Record<string, string> {
  const h: Record<string, string> = {};
  if (APIX_TOKEN) {
    h.Authorization = `Bearer ${APIX_TOKEN}`;
  } else if (APIX_BASIC_USER || APIX_BASIC_PASS) {
    const b64 = Buffer.from(`${APIX_BASIC_USER}:${APIX_BASIC_PASS}`).toString("base64");
    h.Authorization = `Basic ${b64}`;
  }
  return h;
}
function safeJson(res: Response, code: number, body: unknown) {
  if (!res.headersSent) res.status(code).json(body);
}

/* ---------- state ---------- */
type Rec = {
  status: "pending" | "verified" | "rejected";
  lei?: string;
  validTo?: string;
  raw?: unknown;
  ts: number;
  rejectReason?: string;
};
const vlei = new Map<string, Rec>(); // presentationId -> record

type Waiter = { res: Response; timer: NodeJS.Timeout; started: number; mode: "submit" | "verify"; expectedLEI?: string };
const waiters = new Map<string, Waiter[]>();

const metrics = { verify_in: 0, webhook_in: 0, status_get: 0, timeouts: 0, forward_begin: 0, forward_ok: 0, forward_err: 0 };

function flushWaiters(id: string, s: Rec) {
  const list = waiters.get(id);
  if (!list || list.length === 0) return;
  waiters.delete(id);
  for (const w of list) {
    let out: Rec & { waitedMs: number } = { ...s, waitedMs: Date.now() - w.started };
    if (w.mode === "verify" && s.status === "verified" && w.expectedLEI) {
      if (!s.lei || String(s.lei) !== String(w.expectedLEI)) {
        out = { ...s, status: "rejected", rejectReason: "expected_lei_mismatch", waitedMs: out.waitedMs };
      }
    }
    safeJson(w.res, 200, { ok: true, presentationId: id, ...out });
  }
}
function addWaiter(id: string, res: Response, mode: "submit" | "verify", expectedLEI?: string) {
  const list = waiters.get(id) || [];
  const started = Date.now();
  const timer = setTimeout(() => {
    const s = vlei.get(id) || { status: "pending", ts: Date.now() };
    const waitedMs = Date.now() - started;
    metrics.timeouts++;
    log("warn", "waiterTimeout", { id, status: (s as Rec).status ?? "pending", waitedMs, mode });
    safeJson(res, 200, { ok: true, presentationId: id, ...(s as object), timeout: true, waitedMs });
    const rest = (waiters.get(id) || []).filter(w => w.res !== res);
    if (rest.length) waiters.set(id, rest); else waiters.delete(id);
  }, SUBMIT_TIMEOUT_MS);
  list.push({ res, timer, started, mode, expectedLEI });
  waiters.set(id, list);
  log("debug", "addWaiter", { id, totalWaiters: list.length, timeoutMs: SUBMIT_TIMEOUT_MS, mode, expectedLEI: expectedLEI ? "set" : "unset" });

  const curr = vlei.get(id);
  if (curr && curr.status !== "pending") flushWaiters(id, curr);
}

/* ---------- periodic summary ---------- */
if (SUMMARY_INTERVAL_SEC > 0) {
  setInterval(() => {
    const inFlight = Array.from(waiters.values()).reduce((a, l) => a + l.length, 0);
    log("info", "summary", { inFlightWaiters: inFlight, knownIds: vlei.size, metrics });
  }, SUMMARY_INTERVAL_SEC * 1000);
}

/* ---------- routes ---------- */
app.get("/healthz", (_req: Request, res: Response) => res.json({ ok: true }));

/**
 * POST /vlei/verify
 * Chainlink one-call:
 *  - If {presentation} provided → forward to APIX (/gleif/vlei/presentations) and wait for webhook
 *  - If not provided → do NOT forward → just wait for webhook (wallet submitted externally)
 * body: { presentationId: string, expectedLEI?: string, presentation?: any }
 */
app.post("/vlei/verify", async (req: Request, res: Response) => {
  const { presentation, presentationId, expectedLEI } = req.body as { presentation?: unknown; presentationId?: string; expectedLEI?: string };
  if (!presentationId) return res.status(400).json({ error: "presentationId required" });
  const id = String(presentationId).trim();
  metrics.verify_in++;

  log("info", "verify:in", { id, hasPresentation: !!presentation, expLEI: expectedLEI ? "set" : "unset", body: bodyPreview(req.body) });

  try {
    vlei.set(id, { status: "pending", ts: Date.now(), raw: presentation ? { note: "verify+submit" } : { note: "verify-wait" } });
    addWaiter(id, res, "verify", expectedLEI);

    if (presentation && APIX_BASE) {
      const callbackUrl = `${PUBLIC_BASE_URL}/vlei/apix/webhook`;
      const headers = apixHeaders();
      metrics.forward_begin++;
      const t0 = Date.now();
      log("debug", "verify:forward_begin", { id, callbackUrl, auth: headers.Authorization ? "yes" : "no" });

      await axios.post(
        `${APIX_BASE}/gleif/vlei/presentations`,
        { presentation, presentationId: id, callbackUrl },
        { timeout: 20000, headers }
      );

      metrics.forward_ok++;
      log("debug", "verify:forward_end", { id, ms: Date.now() - t0 });
      // Response to Chainlink will be flushed by webhook/timeout
    } else {
      log("debug", "verify:wait_only", { id });
    }
  } catch (e) {
    metrics.forward_err++;
    const detail = (e as Error)?.message || String(e);
    log("error", "verify:error", { id, detail });
    // remove this waiter and return error immediately
    const list = waiters.get(id) || [];
    const rest = list.filter(w => w.res !== res);
    if (rest.length) waiters.set(id, rest); else waiters.delete(id);
    return res.status(502).json({ error: "apix_submit_error", detail });
  }
});

/** Webhook from APIX vLEI system. */
app.post("/vlei/apix/webhook", (req: Request, res: Response) => {
  const { presentationId, valid, lei, validTo, raw } = req.body as {
    presentationId?: string; valid?: boolean; lei?: string; validTo?: string; raw?: unknown;
  };
  if (!presentationId) return res.status(400).json({ error: "presentationId required" });
  const id = String(presentationId).trim();
  metrics.webhook_in++;

  const prev = vlei.get(id);
  const record: Rec = { status: valid ? "verified" : "rejected", lei, validTo, raw, ts: Date.now() };
  vlei.set(id, record);

  log("info", "webhook:in", {
    id, valid, lei, prevStatus: prev?.status, nowStatus: record.status,
    waiters: (waiters.get(id) || []).length,
    body: bodyPreview(req.body)
  });

  flushWaiters(id, record);
  return res.json({ ok: true });
});

/** Status viewer (debug) */
app.get("/vlei/apix/status/:id", (req: Request, res: Response) => {
  const id = String(req.params.id).trim();
  metrics.status_get++;
  const s = vlei.get(id);
  log("debug", "status:get", { id, found: !!s, status: s?.status });
  if (!s) return res.status(404).json({ error: "not_found" });
  res.json(s);
});

/* ---------- start ---------- */
app.listen(PORT, () => {
  log("info", "server:start", {
    port: PORT,
    PUBLIC_BASE_URL,
    APIX_BASE: APIX_BASE || "(not set, wait-only mode when presentation omitted)",
    outboundAuth: APIX_TOKEN ? "Bearer" : (APIX_BASIC_USER || APIX_BASIC_PASS) ? "Basic" : "none",
    SUBMIT_TIMEOUT_MS,
    LOG_LEVEL, LOG_BODY, LOG_PRETTY, SUMMARY_INTERVAL_SEC, BODY_PREVIEW_LIMIT
  });
});
