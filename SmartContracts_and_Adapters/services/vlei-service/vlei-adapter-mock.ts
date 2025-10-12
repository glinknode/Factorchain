import express, { type Request, type Response, type NextFunction } from "express";
import cors from "cors";

/* ---------- env ---------- */
const PORT = Number(process.env.PORT || 18890);
const SUBMIT_TIMEOUT_MS = Number(process.env.SUBMIT_TIMEOUT_MS || "30000");

/* ---------- logging knobs ---------- */
const LOG_LEVEL = (process.env.LOG_LEVEL || "info").toLowerCase();
const LOG_BODY = ["1", "true", "yes"].includes(String(process.env.LOG_BODY || "0").toLowerCase());
const LOG_PRETTY = ["1", "true", "yes"].includes(String(process.env.LOG_PRETTY || "0").toLowerCase());
const SUMMARY_INTERVAL_SEC = Number(process.env.LOG_SUMMARY_INTERVAL || "0");
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

/* ---------- app ---------- */
const app = express();
app.use(express.json({ limit: "512kb" }));
app.use((_req: Request, res: Response, next: NextFunction) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Referrer-Policy", "no-referrer");
  next();
});
app.use(cors({ origin: true }));

/* ---------- state ---------- */
type Rec = {
  status: "pending" | "verified" | "rejected";
  lei?: string;
  validTo?: string;
  raw?: unknown;
  ts: number;
  rejectReason?: string;
};
const vlei = new Map<string, Rec>();
type Waiter = { res: Response; timer: NodeJS.Timeout; started: number; mode: "submit" | "verify"; expectedLEI?: string };
const waiters = new Map<string, Waiter[]>();
const metrics = { verify_in: 0, webhook_in: 0, status_get: 0, timeouts: 0, auto_verified: 0 };

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
    if (!w.res.headersSent) w.res.status(200).json({ ok: true, presentationId: id, ...out });
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
    if (!res.headersSent) res.status(200).json({ ok: true, presentationId: id, ...(s as object), timeout: true, waitedMs });
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
 * POST /vlei/verify (mock)
 * body: { presentationId: string, expectedLEI?: string, presentation?: any }
 * Behavior:
 *  - with presentation: immediately mark verified (lei from expectedLEI or from presentation.lei || "MOCKLEI")
 *  - without: set pending and wait for /vlei/mock/webhook
 */
app.post("/vlei/verify", async (req: Request, res: Response) => {
  const { presentation, presentationId, expectedLEI } = req.body as { presentation?: any; presentationId?: string; expectedLEI?: string };
  if (!presentationId) return res.status(400).json({ error: "presentationId required" });
  const id = String(presentationId).trim();
  metrics.verify_in++;

  log("info", "verify:in", { id, hasPresentation: !!presentation, expLEI: expectedLEI ? "set" : "unset", body: bodyPreview(req.body) });

  vlei.set(id, { status: "pending", ts: Date.now(), raw: presentation ? { note: "mock:verify+submit" } : { note: "mock:verify-wait" } });
  addWaiter(id, res, "verify", expectedLEI);

  if (presentation) {
    // simulate a quick verification outcome
    const lei = expectedLEI || presentation?.lei || "MOCKLEI000000000000";
    const rec: Rec = { status: "verified", lei, ts: Date.now(), raw: presentation };
    vlei.set(id, rec);
    metrics.auto_verified++;
    log("debug", "mock:autoVerified", { id, lei });
    flushWaiters(id, rec);
  }
  // else: wait for /vlei/mock/webhook to finish
});

/** Mock webhook to complete pending verifications */
app.post("/vlei/mock/webhook", (req: Request, res: Response) => {
  const { presentationId, valid, lei, validTo, raw } = req.body as {
    presentationId?: string; valid?: boolean; lei?: string; validTo?: string; raw?: unknown;
  };
  if (!presentationId) return res.status(400).json({ error: "presentationId required" });
  const id = String(presentationId).trim();
  metrics.webhook_in++;

  const prev = vlei.get(id);
  const record: Rec = { status: valid ? "verified" : "rejected", lei, validTo, raw, ts: Date.now() };
  vlei.set(id, record);

  log("info", "webhook:mock_in", {
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
  log("debug", "status:get", { id, found: !!(!!s), status: s?.status });
  if (!s) return res.status(404).json({ error: "not_found" });
  res.json(s);
});

/* ---------- start ---------- */
app.listen(PORT, () => {
  log("info", "server:start", {
    port: PORT,
    mode: "mock",
    SUBMIT_TIMEOUT_MS,
    LOG_LEVEL, LOG_BODY, LOG_PRETTY, SUMMARY_INTERVAL_SEC, BODY_PREVIEW_LIMIT
  });
});
