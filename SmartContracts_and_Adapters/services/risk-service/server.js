// risk-adapter-public.js
const express = require("express");
const cors = require("cors");
const crypto = require("crypto");

/* ---------- config via env ---------- */
const PORT = Number(process.env.PORT || 18888); // matches your RiskRouter default
const JSON_LIMIT = process.env.JSON_LIMIT || "256kb";
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || "")
  .split(",").map(s => s.trim()).filter(Boolean);

// Logging knobs (same style as your other adapters)
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

app.get("/risk/:tokenId", (req, res) => {
  const tokenId = String(req.params.tokenId);
  const item = store.get(tokenId);
  if (!item) {
    log("debug", "risk_read_miss", { tokenId });
    return res.status(404).json({ error: "not_found" });
  }
  log("debug", "risk_read_hit", { tokenId, riskBps: item.riskBps });
  return res.json({ tokenId, riskBps: item.riskBps, updatedAt: item.updatedAt });
});

app.post("/risk/score", (req, res) => {
  const { tokenId, amount, ccy, industry } = req.body || {};
  let { pastDelinquencies, discountBps } = req.body || {};
  if (!tokenId) return res.status(400).json({ error: "tokenId required" });

  pastDelinquencies = Number(pastDelinquencies);
  discountBps = Number(discountBps);

  const riskBps = score({ amount, ccy, industry, pastDelinquencies, discountBps });
  const record = { riskBps, updatedAt: new Date().toISOString() };
  store.set(String(tokenId), record);

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

  return res.json({ tokenId: String(tokenId), riskBps });
});

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
