import http from "node:http";
import { logger } from "./logger.js";
import { PORT, QVI_AID_NAME, QVI_LEI } from "./config.js";
import { ensureBootStrictAndConnect } from "./signify.js";
import { getAid, getOrCreateAid } from "./aid.js";
import { issueQVI, issueLegalEntityVLEI, type VLEISubject } from "./issuance.js";

function send(res: http.ServerResponse, code: number, body: any) {
  res.statusCode = code;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

async function parseBody(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(Buffer.from(c));
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { return {}; }
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    const method = (req.method ?? "GET").toUpperCase();

    if (method === "POST" && url.pathname === "/init") {
      await ensureBootStrictAndConnect();

      const body = await parseBody(req);
      const qviName = String((body?.qvi as any)?.name ?? QVI_AID_NAME);
      const qviLei  = String((body?.qvi as any)?.lei  ?? QVI_LEI);

      await getOrCreateAid(qviName, { transferable: true });

      await issueQVI(qviName, qviName, { lei: qviLei });

      return send(res, 200, { ok: true, qvi: qviName, lei: qviLei });
    }

   // POST /aids/create  { name, transferable?, toad? }
   if (method === "POST" && url.pathname === "/aids/create") {
    await ensureBootStrictAndConnect();
    const body = await parseBody(req);
    const name = String(body?.name ?? "");
    if (!name) return send(res, 400, { error: "name required" });

    const transferable = body?.transferable !== undefined ? Boolean(body.transferable) : true;
    const toad = body?.toad !== undefined ? Number(body.toad) : undefined;
    const out = await getOrCreateAid(name, { transferable, toad });
    return send(res, 200, { ok: true, aid: out });
  }

  // GET /aids/:name
  if (method === "GET" && url.pathname.startsWith("/aids/")) {
    await ensureBootStrictAndConnect();
    const name = decodeURIComponent(url.pathname.replace("/aids/", ""));
    const a = await getAid(name);
    if (!a) return send(res, 404, { error: "not found", detail: "" });
    return send(res, 200, a);
  }

  // POST /issue/vlei  { name, legalName, lei }
  if (method === "POST" && url.pathname === "/issue/vlei") {
    await ensureBootStrictAndConnect();
    const body = await parseBody(req);
    const name = String(body?.name ?? "");
    const legalName = String(body?.legalName ?? "");
    const lei = String(body?.lei ?? "");

    if (!name || !legalName || !lei) {
      return send(res, 400, { error: "missing fields", detail: "name, legalName, lei are required" });
    }

    // AID on demand (eth address can be used as name)
    await getOrCreateAid(name, { transferable: true });

    const subject: VLEISubject = { legalName, lei };
    const out = await issueLegalEntityVLEI(QVI_AID_NAME, name, subject);
    return send(res, 200, { ok: true, credential: out });
  }
      // Fallback
      send(res, 404, { error: "not found", detail: "" });
    } catch (e: any) {
      logger.error(e?.stack ?? String(e));
      send(res, 500, { error: e?.message ?? String(e) });
    }
  });
  
  server.listen(PORT, "0.0.0.0", () => {
    logger.info("[onechain] listening on http://0.0.0.0:%d", PORT);
  });
  