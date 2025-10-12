// risk-adapter-public.js
const express = require("express");
const cors = require("cors");
const crypto = require("crypto");

/* ---------- config via env ---------- */
const PORT = Number(process.env.PORT || 18888); // matches your RiskRouter default
const JSON_LIMIT = process.env.JSON_LIMIT || "256kb";
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || "")
  .split(",").map(s => s.trim()).filter(Boolean);

// Logging knobs
const LOG_LEVEL = (process.env.LOG_LEVEL || "info").toLowerCase(); // info|debug|warn|error
const LOG_BODY = ["1","true","yes"].includes(String(process.env.LOG_BODY || "0").toLowerCase());
const LOG_PRETTY = ["1","true","yes"].includes(String(process.env.LOG_PRETTY || "0").toLowerCase());
const SUMMARY_INTERVAL_SEC = Number(process.env.LOG_SUMMARY_INTERVAL || "30"); // 0 to disable
const BODY_PREVIEW_LIMIT = Number(process.env.LOG_BODY_PREVIEW_LIMIT || "800");

/* ---------- logger ---------- */
const LEVEL_WEIGHT = { debug: 10, info: 20, warn: 30, error: 40 };
const THRESHOLD = LEVEL_WEIGHT[["debug","info","warn","error"].includes(LOG_LEVEL) ? LOG_LEVEL : "info"];

function bodyPreview(val) {
  if (!LOG_BODY) return undefined;
  try {
    const s = JSON.stringify(val ?? {});
    if (!s || s === "{}") return undefined;
    return s.length <= BODY_PREVIEW_LIMIT ? val : { _truncated: true, preview: s.slice(0, BODY_PREVIEW_LIMIT) + "…" };
  } catch {
    return { _unserializable: true };
  }
}

function log(level, event, extra = {}) {
  if (LEVEL_WEIGHT[level] < THRESHOLD) return;
  const rec = { ts: new Date().toISOString(), level, event, ...extra };
  const line = LOG_PRETTY ? JSON.stringify(rec, null, 2) : JSON.stringify(rec);
  console.log(line);
}

/* ---------- app ---------- */
const app = express();
app.use(express.json({ limit: JSON_LIMIT }));
app.use((_, res, next) => {
  res.setHeader("X-Content-Type-Options","nosniff");
  res.setHeader("X-Frame-Options","DENY");
  res.setHeader("Referrer-Policy","no-referrer");
  next();
});
app.use(cors({
  origin: (origin, cb) => {
    if (!origin || ALLOWED_ORIGINS.length === 0 || ALLOWED_ORIGINS.includes(origin)) return cb(null, true);
    return cb(new Error("CORS"), false);
  }
}));

/* ---------- counters & store ---------- */
const counters = { total: 0, getRisk: 0, postScore: 0, health: 0 };
const store = new Map(); // tokenId -> { riskBps, updatedAt }

/* ---------- minimal idempotency shim (5s TTL) + DEBUG ---------- */
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

    const hit = __idemCache.get(cacheKey);
    if (hit && hit.exp > now) {
      log("debug", "idem:cache_hit", { path: req.path, key });
      res.setHeader("X-Idempotency-Key", key);
      return res.status(200).type("application/json").send(hit.v);
    } else if (hit) {
      __idemCache.delete(cacheKey);
    }

    const lockExp = __idemLocks.get(cacheKey) || 0;
    if (lockExp > now) {
      log("debug", "idem:lock_wait", { path: req.path, key });
      const deadline = now + 800;
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

    log("debug", "idem:leader", { path: req.path, key });
    __idemLocks.set(cacheKey, now + __IDEM_LOCK_TTL_MS);
    try {
      const obj = await computeOnce(req);
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

/* ---------- GET in-flight dedupe (Option A) + DEBUG ---------- */
function __coalesceGet(computeOnce /* (req) => Promise<{status?:number, body?:any} | any> */) {
  const inflight = new Map(); // key -> Promise<{ status:number, bodyStr:string }>
  function stableQuery(q) {
    const obj = Object.fromEntries(Object.keys(q || {}).sort().map(k => [k, q[k]]));
    return __stableStringify(obj);
  }
  return async (req, res) => {
    const raw = req.method + " " + req.path + "\n" + stableQuery(req.query);
    const key = crypto.createHash("sha256").update(raw).digest("hex");
    const send = (pack) => res.status(pack.status).type("application/json").send(pack.bodyStr);

    if (inflight.has(key)) {
      log("debug", "coalesce:join", { path: req.path, key });
      try { return send(await inflight.get(key)); }
      catch (e) { return res.status(500).json({ error: "compute_failed", message: String(e && e.message || e) }); }
    }

    log("debug", "coalesce:new", { path: req.path, key });
    const p = (async () => {
      const out = await computeOnce(req);
      const status = (out && typeof out.status === "number") ? out.status : 200;
      const body = (out && Object.prototype.hasOwnProperty.call(out, "body")) ? out.body : out;
      const bodyStr = __stableStringify(body);
      return { status, bodyStr };
    })();

    inflight.set(key, p);
    try {
      const pack = await p;
      log("debug", "coalesce:resolve", { path: req.path, key, status: pack.status });
      return send(pack);
    } finally {
      inflight.delete(key);
    }
  };
}

/* ---------- request logging middleware ---------- */
app.use((req, res, next) => {
  const id = crypto.randomUUID();
  res.setHeader("X-Request-Id", id);
  const t0 = process.hrtime.bigint();
  const bodyForLog = bodyPreview(req.body);

  res.on("finish", () => {
    const durMs = Number((process.hrtime.bigint() - t0) / 1000000n);
    counters.total++;
    if (req.method === "GET" && (req.path === "/health" || req.path === "/healthz")) counters.health++;
    if (req.method === "GET" && req.path.startsWith("/risk/")) counters.getRisk++;
    if (req.method === "POST" && req.path === "/risk/score") counters.postScore++;

    log("info", "http_request", {
      id,
      method: req.method,
      path: req.originalUrl || req.url,
      status: res.statusCode,
      duration_ms: durMs,
      ip: req.headers["x-forwarded-for"] || req.socket.remoteAddress,
      query: Object.keys(req.query || {}).length ? req.query : undefined,
      body: bodyForLog
    });
  });

  next();
});

/* ---------- scoring ---------- */
function score({ amount, ccy, industry, pastDelinquencies, discountBps }) {
  let base = 1000; // 10.00%
  const delinq = Number.isFinite(pastDelinquencies) ? pastDelinquencies : 0;
  const disc = Number.isFinite(discountBps) ? discountBps : 0;

  base += delinq * 75;          // +0.75% per delinquency
  base -= Math.min(disc, 300);  // cap discount effect at 3.00%
  if (ccy && String(ccy).toUpperCase() === "EUR") base -= 25;
  if (industry && /construction|bau/i.test(industry)) base += 50;

  return Math.max(0, Math.min(10000, Math.round(base)));
}

/* ---------- endpoints (PUBLIC) ---------- */
app.get("/health", (_req, res) => {
  res.json({ ok: true, ts: Date.now(), counts: counters, tokens: store.size });
});
app.get("/healthz", (_req, res) => {
  res.json({ ok: true });
});

/* --- GET /risk/:tokenId coalesced (keeps original 404 when not found) --- */
app.get("/risk/:tokenId", __coalesceGet(async (req) => {
  const tokenId = String(req.params.tokenId);
  const item = store.get(tokenId);
  if (!item) {
    log("debug", "risk_read_miss", { tokenId });
    return { status: 404, body: { error: "not_found" } };
  }
  log("debug", "risk_read_hit", { tokenId, riskBps: item.riskBps });
  return { status: 200, body: { tokenId, riskBps: item.riskBps, updatedAt: item.updatedAt } };
}));

/* --- POST /risk/score idempotent: first identical POST in 5s computes; others reuse result --- */
app.post("/risk/score", __idemWrap(async (req) => {
  const { tokenId, amount, ccy, industry } = req.body || {};
  let { pastDelinquencies, discountBps } = req.body || {};
  if (!tokenId) return { error: "tokenId required" }; // simple 200+error to keep wrapper minimal

  pastDelinquencies = Number(pastDelinquencies);
  discountBps = Number(discountBps);

  const riskBps = score({ amount, ccy, industry, pastDelinquencies, discountBps });

  // Update in-memory store ONCE for this input during the 5s window
  store.set(String(tokenId), { riskBps, updatedAt: new Date().toISOString() });

  log("info", "risk_scored", {
    tokenId: String(tokenId),
    riskBps,
    inputs: {
      amount: amount ?? null,
      ccy: ccy ?? null,
      industry: industry ?? null,
      pastDelinquencies: Number.isFinite(pastDelinquencies) ? pastDelinquencies : null,
      discountBps: Number.isFinite(discountBps) ? discountBps : null
    }
  });

  return { tokenId: String(tokenId), riskBps };
}));

/* ---------- periodic summary ---------- */
if (SUMMARY_INTERVAL_SEC > 0) {
  setInterval(() => {
    log("info", "summary", {
      uptime_s: Math.round(process.uptime()),
      counts: counters,
      tokens: store.size
    });
  }, SUMMARY_INTERVAL_SEC * 1000).unref();
}

/* ---------- start ---------- */
app.listen(PORT, () => {
  log("info", "risk-service_start", {
    port: PORT,
    LOG_LEVEL, LOG_BODY, LOG_PRETTY,
    LOG_SUMMARY_INTERVAL: SUMMARY_INTERVAL_SEC,
    LOG_BODY_PREVIEW_LIMIT: BODY_PREVIEW_LIMIT,
    JSON_LIMIT,
    ALLOWED_ORIGINS: ALLOWED_ORIGINS.length ? ALLOWED_ORIGINS : "(any)"
  });
});
