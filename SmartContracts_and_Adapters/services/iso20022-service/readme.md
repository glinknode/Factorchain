# ISO20022 Adapter – Frontend Integration Guide (EN)

This guide shows how to consume the HTTP API from a web frontend: **CORS**, **endpoints**, **payloads**, **responses**, **curl & fetch examples**, plus a **tiny TypeScript client** and a **React table**.

> Quick facts
>
> * No auth (public). **Access control via CORS** (`ALLOWED_ORIGINS`).
> * Messages are stored **in-memory** per `tokenId` (volatile; cleared on restart).
> * Message IDs look like `kind:type:<timestamp>`.
> * Lightweight XML checks via `/validate-lite` (pacs.008, camt.054).

---

## 1) Base URL & Health

* **Base URL:** `http://<host>:18887` (or your `PORT`)
* **Health check:** `GET /healthz` → `{ ok: true, service: "iso20022", ts: "<ISO8601>" }`

```bash
curl -s http://localhost:18887/healthz
```

---

## 2) CORS & Environment

* If `ALLOWED_ORIGINS` is **empty**, all origins are allowed.
* Otherwise, only the **comma-separated whitelist** is allowed.

**Server `.env` example**

```
PORT=18887
ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5173
LOG_LEVEL=info
LOG_BODY=0
LOG_PRETTY=0
```

> In production: put the service behind a reverse proxy, **lock down CORS**, and restrict network access.

---

## 3) Endpoints

| Method | Path                                | Purpose                                     | Body                          | Response                                      |
| ------ | ----------------------------------- | ------------------------------------------- | ----------------------------- | --------------------------------------------- |
| GET    | `/healthz`                          | Liveness                                    | –                             | `{ ok, service, ts }`                         |
| POST   | `/validate-lite`                    | Lightweight XML check (pacs.008 / camt.054) | `{ messageType, payloadXml }` | `{ valid, reasons[], docHash }`               |
| POST   | `/iso/:tokenId/tsin006`             | Generate & store **tsin.006**               | JSON                          | stored entry (incl. `xml`)                    |
| POST   | `/iso/:tokenId/tsin007`             | Generate & store **tsin.007**               | JSON                          | stored entry (incl. `xml`)                    |
| POST   | `/iso/:tokenId/tsin008`             | Generate & store **tsin.008**               | JSON                          | stored entry (incl. `xml`)                    |
| POST   | `/iso/:tokenId/pacs008`             | Generate & store **pacs.008**               | JSON                          | stored entry (incl. `xml`)                    |
| POST   | `/iso/:tokenId/camt054`             | Generate & store **camt.054**               | JSON                          | stored entry (incl. `xml`)                    |
| GET    | `/iso/:tokenId/messages`            | List message metadata                       | –                             | `[{ id, kind, type, createdAt, hash, meta }]` |
| GET    | `/iso/:tokenId/messages/:msgId.xml` | Fetch raw XML                               | –                             | `application/xml`                             |

**Stored entry shape (for all generators):**

```json
{
  "id": "tsin:006:1739039123456",
  "kind": "tsin",
  "type": "006",
  "xml": "<?xml ...>",
  "createdAt": "2025-10-12T15:42:03.123Z",
  "hash": "0xabc123...",
  "meta": { /* your request body + auto creDtTm if omitted */ }
}
```

---

## 4) Request Payloads (required fields)

> `creDtTm` is auto-filled server-side if omitted.

### 4.1 `POST /iso/:tokenId/tsin006`

```ts
type TSIN006Body = {
  msgId: string;
  sellerLEI: string;
  buyerLEI: string;
  debtorLEI: string;
  invoiceId: string;
  ccy: string;        // "EUR"
  amount: string;     // "123.45"
  dueDate: string;    // YYYY-MM-DD
  creDtTm?: string;   // ISO datetime
}
```

### 4.2 `POST /iso/:tokenId/tsin007`

```ts
type TSIN007Body = {
  msgId: string;
  relatedMsgId: string;  // e.g., tsin006.msgId
  statusCode: string;    // "ACPT", "RJCT", ...
  reason?: string;
  creDtTm?: string;
}
```

### 4.3 `POST /iso/:tokenId/tsin008`

```ts
type TSIN008Body = {
  msgId: string;
  debtorLEI: string;
  invoiceId: string;
  newOwnerLEI: string;
  newPayToIBAN?: string;
  newPayToWallet?: string;
  creDtTm?: string;
}
```

### 4.4 `POST /iso/:tokenId/pacs008`

```ts
type PACS008Body = {
  msgId: string;
  instrId: string;
  e2eId: string;
  txId: string;
  ccy: string;            // "EUR"
  amount: string;         // "123.45"
  debtorName: string;
  debtorIBAN: string;
  debtorBIC: string;
  creditorBIC: string;
  creditorName: string;
  creditorIBAN: string;
  remRef: string;         // remittance info
  creDtTm?: string;
}
```

### 4.5 `POST /iso/:tokenId/camt054`

```ts
type CAMT054Body = {
  msgId: string;
  acctIBAN: string;
  entryRef: string;
  ccy: string;
  amount: string;
  remRef: string;
  creDtTm?: string;
}
```

### 4.6 `POST /validate-lite`

```ts
type ValidateLiteBody = {
  messageType: string;  // e.g., "pacs.008.001.08" or "camt.054.001.08"
  payloadXml: string;   // raw XML as string
}

type ValidateLiteResult = {
  valid: boolean;
  reasons: string[];
  docHash: string; // keccak256 over payloadXml (0x...)
}
```

---

## 5) Curl examples

**Generate tsin.006**

```bash
curl -s -X POST http://localhost:18887/iso/3/tsin006 \
  -H "Content-Type: application/json" \
  -d '{
    "msgId":"TSIN006-001",
    "sellerLEI":"529900T8BM49AURSDO55",
    "buyerLEI":"5493001KJTIIGC8Y1R12",
    "debtorLEI":"213800D1EI4J2W7XYZ89",
    "invoiceId":"INV-2025-0001",
    "ccy":"EUR",
    "amount":"1234.56",
    "dueDate":"2025-11-01"
  }'
```

**Generate pacs.008**

```bash
curl -s -X POST http://localhost:18887/iso/3/pacs008 \
  -H "Content-Type: application/json" \
  -d '{
    "msgId":"PACS008-001",
    "instrId":"INSTR-1",
    "e2eId":"E2E-1",
    "txId":"TX-1",
    "ccy":"EUR",
    "amount":"123.45",
    "debtorName":"ACME GmbH",
    "debtorIBAN":"AT611904300234573201",
    "debtorBIC":"SPFKAT2BXXX",
    "creditorBIC":"OBKLAT2LXXX",
    "creditorName":"Widgets AG",
    "creditorIBAN":"DE02120300000000202051",
    "remRef":"Invoice INV-2025-0001"
  }'
```

**List messages for `tokenId=3`**

```bash
curl -s http://localhost:18887/iso/3/messages | jq .
```

**Fetch XML (use an `id` from the list)**

```bash
curl -s http://localhost:18887/iso/3/messages/tsin:006:1739039123456.xml
```

**Validate-lite**

```bash
curl -s -X POST http://localhost:18887/validate-lite \
  -H "Content-Type: application/json" \
  -d '{
    "messageType":"pacs.008.001.08",
    "payloadXml":"<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.008.001.08\">...</Document>"
  }'
```

---

## 6) Minimal TypeScript client

```ts
// isoClient.ts (ESM)
export type MessageMeta = Record<string, unknown>;

export type StoredMessage = {
  id: string;
  kind: "tsin" | "pacs" | "camt";
  type: string;             // "006"|"007"|"008" or "054"
  createdAt: string;        // ISO
  hash: string;             // 0x...
  meta: MessageMeta;        // original request body
};

export class ISOClient {
  constructor(private base = "http://localhost:18887") {}

  async health() {
    const r = await fetch(`${this.base}/healthz`);
    if (!r.ok) throw new Error(`health failed: ${r.status}`);
    return r.json();
  }

  async validateLite(messageType: string, payloadXml: string) {
    const r = await fetch(`${this.base}/validate-lite`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messageType, payloadXml }),
    });
    if (!r.ok) throw new Error(`validate-lite failed: ${r.status}`);
    return r.json();
  }

  async generate<T extends object>(
    tokenId: string | number,
    path: "tsin006" | "tsin007" | "tsin008" | "pacs008" | "camt054",
    body: T
  ) {
    const r = await fetch(`${this.base}/iso/${tokenId}/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new Error(`generate ${path} failed: ${r.status}`);
    return r.json() as Promise<StoredMessage & { xml: string }>;
  }

  async list(tokenId: string | number) {
    const r = await fetch(`${this.base}/iso/${tokenId}/messages`);
    if (!r.ok) throw new Error(`list failed: ${r.status}`);
    return r.json() as Promise<StoredMessage[]>;
  }

  xmlUrl(tokenId: string | number, msgId: string) {
    return `${this.base}/iso/${tokenId}/messages/${encodeURIComponent(msgId)}.xml`;
  }
}
```

### React usage example

```tsx
import { useEffect, useState } from "react";
import { ISOClient } from "./isoClient";

const api = new ISOClient(import.meta.env.VITE_ISO_BASE ?? "http://localhost:18887");

export function MessagesTable({ tokenId = 3 }) {
  const [rows, setRows] = useState<any[]>([]);

  useEffect(() => {
    api.list(tokenId).then(setRows).catch(console.error);
  }, [tokenId]);

  return (
    <table>
      <thead>
        <tr><th>ID</th><th>Kind</th><th>Type</th><th>Hash</th><th>XML</th></tr>
      </thead>
      <tbody>
        {rows.map(r => (
          <tr key={r.id}>
            <td>{r.id}</td>
            <td>{r.kind}</td>
            <td>{r.type}</td>
            <td title={r.hash}>{r.hash.slice(0, 14)}…</td>
            <td><a href={api.xmlUrl(tokenId, r.id)} target="_blank" rel="noreferrer">Open</a></td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
```

**Create a tsin.006 from the UI**

```ts
await api.generate(3, "tsin006", {
  msgId: "TSIN006-001",
  sellerLEI: "529900T8BM49AURSDO55",
  buyerLEI: "5493001KJTIIGC8Y1R12",
  debtorLEI: "213800D1EI4J2W7XYZ89",
  invoiceId: "INV-2025-0001",
  ccy: "EUR",
  amount: "1234.56",
  dueDate: "2025-11-01"
});
```

---

## 7) Errors & Handling

* **CORS error:** Browser console shows “CORS”. Fix `ALLOWED_ORIGINS` or proxy through your app’s origin.
* **400 @ `/validate-lite`**: Missing `messageType` or `payloadXml`, or non-parsable XML.
* **404 @ `.../:msgId.xml`**: Unknown `msgId` (refresh the list).
* **No persistence:** Messages are RAM-only. Plan a persistent store for production.

---

## 8) Validation notes

* `/validate-lite` performs **light structural checks** for `pacs.008` and `camt.054`.
* `docHash` (keccak256) helps deduplicate client-side.

---

## 9) Security & Ops

* Service is **unauthenticated** → restrict network access (firewall/VPN/reverse proxy) and **tighten CORS**.
* Generator responses include the full **XML**. Treat data accordingly.

---

## 10) End-to-End quick test

1. `POST /iso/3/tsin006` → 200 with stored entry
2. `GET /iso/3/messages` → copy an `id`
3. `GET /iso/3/messages/<id>.xml` → view/download XML
4. `POST /validate-lite` with that XML → `{ valid, reasons, docHash }`

---

If you want, I can also provide this as a small npm package (ESM, Node 20, `module: NodeNext`) and a ready-to-run **Vite React demo**.
