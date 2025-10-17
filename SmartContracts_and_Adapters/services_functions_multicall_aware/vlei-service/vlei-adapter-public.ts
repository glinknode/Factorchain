import express, { Request, Response, NextFunction } from "express";
import cors from "cors";
import axios from "axios";

/* ---------- config ---------- */
const PORT = Number(process.env.PORT || 18889);
const ONECHAIN_BASE = (process.env.ONECHAIN_BASE || "http://localhost:18882").replace(/\/+$/, "");
const ONECHAIN_TOKEN = process.env.ONECHAIN_TOKEN || "";
const ONECHAIN_BASIC_USER = process.env.ONECHAIN_BASIC_USER || "";
const ONECHAIN_BASIC_PASS = process.env.ONECHAIN_BASIC_PASS || "";
const LOG_PRETTY = ["1","true","yes"].includes(String(process.env.LOG_PRETTY || "0").toLowerCase());

/* ---------- tiny logger ---------- */
function log(event: string, meta: Record<string, unknown> = {}) {
  const rec = { ts: new Date().toISOString(), event, ...meta };
  console.log(LOG_PRETTY ? JSON.stringify(rec, null, 2) : JSON.stringify(rec));
}

/* ---------- helpers ---------- */
function onechainHeaders(): Record<string,string> {
  const h: Record<string,string> = { "content-type": "application/json" };
  if (ONECHAIN_TOKEN) h.Authorization = `Bearer ${ONECHAIN_TOKEN}`;
  else if (ONECHAIN_BASIC_USER || ONECHAIN_BASIC_PASS) {
    h.Authorization = `Basic ${Buffer.from(`${ONECHAIN_BASIC_USER}:${ONECHAIN_BASIC_PASS}`).toString("base64")}`;
  }
  return h;
}
const ok   = (res: Response, body: unknown) => res.status(200).json(body);
const err  = (res: Response, code: number, error: string, detail?: unknown) =>
  res.status(code).json({ error, ...(detail ? { detail } : {}) });

/* ---------- in-memory results for /status/:id ---------- */
type Rec = {
  status: "verified" | "rejected" | "pending";
  name: string;
  aidPrefix?: string;
  raw?: unknown;
  ts: number;
  rejectReason?: string;
};
const store = new Map<string, Rec>();

/* ---------- app ---------- */
const app = express();
app.use(express.json({ limit: "256kb" }));
app.use((_req: Request, res: Response, next: NextFunction) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Referrer-Policy", "no-referrer");
  next();
});
app.use(cors({ origin: true }));

/* health */
app.get("/healthz", (_req, res) => ok(res, { ok: true, upstream: ONECHAIN_BASE }));

/**
 * POST /vlei/verify
 * Body: { name: string, presentationId?: string }
 * Behavior:
 *   - Calls onechain GET /aids/:name
 *   - If found => status=verified, include prefix + raw
 *   - If 404 => status=rejected
 *   - Stores result under presentationId (auto-generated if missing) so /status works
 */
app.post("/vlei/verify", async (req: Request, res: Response) => {
  const name = String(req.body?.name || "").trim();
  if (!name) return err(res, 400, "name required");

  // keep presentationId for compatibility with your CL adapter
  const presentationId =
    String(req.body?.presentationId || `aid-${name}-${Date.now()}`);

  try {
    log("verify.begin", { name, presentationId });
    const r = await axios.get(`${ONECHAIN_BASE}/aids/${encodeURIComponent(name)}`, {
      headers: onechainHeaders(), timeout: 15000
    });

    const raw = r.data;
    const prefix = raw?.prefix ?? raw?.pre ?? raw?.state?.i ?? null;

    const record: Rec = {
      status: "verified",
      name,
      aidPrefix: prefix ?? undefined,
      raw,
      ts: Date.now(),
    };
    store.set(presentationId, record);

    log("verify.ok", { name, presentationId, prefix });
    return ok(res, {
      ok: true,
      presentationId,
      ...record,
    });
  } catch (e: any) {
    const status = e?.response?.status || 500;

    if (status === 404) {
      const record: Rec = {
        status: "rejected",
        name,
        ts: Date.now(),
        rejectReason: "aid_not_found",
      };
      store.set(presentationId, record);
      log("verify.not_found", { name, presentationId });
      return ok(res, { ok: true, presentationId, ...record });
    }

    const detail = e?.response?.data || e?.message || String(e);
    log("verify.error", { name, presentationId, status, detail });
    return err(res, 502, "upstream_error", detail);
  }
});

/**
 * GET /vlei/apix/status/:id
 * Returns the last verify result by presentationId (for compatibility).
 */
app.get("/vlei/apix/status/:id", (req: Request, res: Response) => {
  const id = String(req.params.id || "").trim();
  const rec = store.get(id);
  if (!rec) return err(res, 404, "not_found");
  return ok(res, { ok: true, presentationId: id, ...rec });
});

/**
 * POST /vlei/apix/webhook
 * Present but disabled (no webhook flow in this adapter).
 */
app.post("/vlei/apix/webhook", (_req, res) => {
  return res.status(410).json({ error: "webhook_disabled_in_adapter" });
});

/* ---------- start ---------- */
app.listen(PORT, () => {
  log("adapter.start", { port: PORT, ONECHAIN_BASE, endpoints: [
    "GET  /healthz",
    "POST /vlei/verify",
    "GET  /vlei/apix/status/:id",
    "POST /vlei/apix/webhook (disabled)",
  ]});
});
