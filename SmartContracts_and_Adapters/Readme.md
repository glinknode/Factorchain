
# Implementation Doc (Sepolia • REAL)

**Network:** Ethereum Sepolia  
**USDC (Sepolia):** `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (6 decimals, token units)  
**Invoice `amount`:** **microunits (1e6)** of the invoice currency → `1 USD/EUR = 1_000_000`  
**Flags (always):** `0x0000000000000000000000000000000000000000000000000000000000000000` (32-byte zero)

---

## Contract Addresses (Real, Sepolia)

- **PartyRegistry (Registry):** `0x09Cda949b11Bb54073bFE079adc2bA3D4B048F0b`
- **InvoiceNFT:** `0xa8F621EAB45E0185835D4D37A3626EFD66891518`
- **PaymentRouter:** `0x45090c93299B9309Be89A725ff37990F4C4c7757`
- **InvoiceMarketplace:** `0x044CabAaf879A1DC61B78E6B568e3D86b6056af1`
- **ISOMessageRouter (ISO):** `0x34194eB355E327BF7e74A7a84EC654Af4016f5e1`
- **RiskOracleRouter (Risk):** `0x1efD4E72d146eB29c5E0549C01Fa2506F16594DE`
- **PaymentSettlementAutomation (optional):** `0x530f14ade491c8158099c40f9a2bfcf73d405fe6`

---

## Constants (Copy & Paste)

```txt
USD (bytes3)     = 0x555344
EUR (bytes3)     = 0x455552
ZERO_FLAGS       = 0x0000000000000000000000000000000000000000000000000000000000000000
DOC_HASH_EXAMPLE = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ONE_USDC         = 1000000          # 1.00 USDC (6 decimals)
MICRO_1          = 1000000          # 1.00 USD/EUR as microunits (1e6)
DISCOUNT_BPS_10  = 1000             # 10% → net = 90%
DUE_DATE_30D     = <UNIX_TS_30_days_in_future>  # e.g., 1761000000

# Chainlink Functions (Sepolia)
CL_FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0
CL_DON_ID           = "fun-ethereum-sepolia-1"
````

---


## 0) Base Configuration (Routers, Functions, Feeds)

### 0.1 One-time wiring inside InvoiceNFT

```solidity
// InvoiceNFT @ 0x96c532913ebaA1C479DCbd5bcB34343eBc15F983
setRouter(0x7F805E2f7431Ad140d32FfD1e83B45BEeC493Fe2)      // PaymentRouter
setISORouter(0x7F805E2f7431Ad140d32FfD1e83B45BEeC493Fe2)   // ISOMessageRouter
setRiskRouter(0x4D498BEE7B1F10055D769D55f58127f9B790B02f)  // RiskOracleRouter
```

> These setters are **one-time**.

### 0.2 Chainlink Functions setup (for all Functions-enabled contracts)

On **ISOMessageRouter**, **PaymentRouter** (for fiat sweep), **InvoiceMarketplace** (if it triggers ISO), **RiskOracleRouter**, and **PartyRegistry** (if auto-vLEI):

```solidity
setFunctionsConfig(<subId>, "fun-ethereum-sepolia-1", 300000)
setBaseUrl("http://<SERVICE_HOST>:<PORT>")   // ISO:18887, Risk:18888, vLEI:18889
```

### 0.3 Price feeds & asset whitelist (PaymentRouter; mirror on Marketplace if quoting)

```solidity
// PaymentRouter @ 0x7F805E2f7431Ad140d32FfD1e83B45BEeC493Fe2
setAssetWhitelist(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, true)  // whitelist USDC

// Token → USD(1e8)
setTokenUsdFeed(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, <USDC_USD_FEED>)

// FX (bytes3) → USD(1e8)
setCcyUsdFeed(0x555344, <USD_USD_FEED>)  // "USD" → USD (1.0 proxy/mocked if needed)
setCcyUsdFeed(0x455552, <EUR_USD_FEED>)  // "EUR" → USD
```

## 1) Sanity Checks (READ-ONLY)

Before **any write** in Remix/UI:

* InvoiceNFT → `registry()` **=** `0xBBa1E20B1E8506Be5019Bc6C8394683DbEb142b5`
* PaymentRouter → `invoiceNFT()` **=** `0x96c532913ebaA1C479DCbd5bcB34343eBc15F983`
* InvoiceNFT → `router()` **=** `0x5cb08df43984EFb3fC4a13eC22FC388d6f643e08`
* InvoiceNFT → `isoRouter()` **=** `0x7F805E2f7431Ad140d32FfD1e83B45BEeC493Fe2`
* InvoiceNFT → `riskRouter()` **=** `0x4D498BEE7B1F10055D769D55f58127f9B790B02f`

If anything differs → fix wiring (UI cannot auto-fix).


---

## 2) Onboarding (Registry / vLEI)

Each party (creditor, buyer, debtor) onboards using **their own wallet**:

Use: `registerAndVerifyAuto(lei, vleiHash)`.

---

## 3) Mint Invoice (as **Creditor**)

```solidity
// InvoiceNFT @ 0x96c532913ebaA1C479DCbd5bcB34343eBc15F983
mintInvoice(
  /* to */           <CREDITOR_ADDRESS>,
  /* amount */       1000000,               // 1.00 USD/EUR in microunits (1e6)
  /* ccy */          0x555344,              // "USD" (or 0x455552 = "EUR")
  /* dueDate */      DUE_DATE_30D,
  /* debtor */       <DEBTOR_ADDRESS>,
  /* docHash */      DOC_HASH_EXAMPLE,
  /* flags */        ZERO_FLAGS,            // exactly 32-byte zero
  /* uploader */     <CREDITOR_ADDRESS>,
  /* discountBps */  1000,                  // 10%
  /* riskBps */      800,
  /* listed */       true,                  // list immediately (optional)
  /* industry */     "Healthcare"
)
```

**Expected:** `Transfer` / `InvoiceMinted` events, new `tokenId`, `payTo = creditor`.

---

## 4) Listing & Pricing (as **current owner**)

Common reads (depending on build):

```solidity
// InvoiceMarketplace @ 0xee83bcdaf322abb93541ace9471b9295864e6e76
isListed(<tokenId>)                              // true/false
netPrice(<tokenId>)                              // invoice net in microunits (1e6)
quoteBuyUsd8(<tokenId>)                          // valuation in USD(1e8)
quoteBuyAmount(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, <tokenId>)  // USDC needed (6 decimals)
```

> Adjust listing/discount via your available setters (e.g., during mint or dedicated functions).

---

## 5) Marketplace Purchase

### 5.1 Approvals

**Buyer → InvoiceMarketplace (USDC):**

```solidity
// USDC @ 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 (with buyer wallet)
approve(0xee83bcdaf322abb93541ace9471b9295864e6e76, 900000)  // ≥ required USDC (6 decimals)
```

*(Only if your flow requires NFT operator rights — many flows don’t):*
**Owner → InvoiceMarketplace (NFT):**

```solidity
// InvoiceNFT @ 0x96c532913ebaA1C479DCbd5bcB34343eBc15F983
setApprovalForAll(0xee83bcdaf322abb93541ace9471b9295864e6e76, true)
// or approve(0xee83bcdaf322abb93541ace9471b9295864e6e76, <tokenId>)
```

### 5.2 Buy with stablecoin (USDC)

```solidity
// InvoiceMarketplace @ 0xee83bcdaf322abb93541ace9471b9295864e6e76
buyWithStable(
  0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,  // USDC
  <tokenId>,
  900000                                       // maxPay (USDC units, 6 decimals)
)
```

### 5.3 Buy with fiat / SWIFT

```solidity
// InvoiceMarketplace @ 0xee83bcdaf322abb93541ace9471b9295864e6e76
requestFiatSweepPurchase(<tokenId>)
```

**Expected:** ownership/payee updates to buyer; listing cleared.

---

## 6) ISO Messages (via ISOMessageRouter)

**Contract:** ISOMessageRouter @ `0x7F805E2f7431Ad140d32FfD1e83B45BEeC493Fe2`
`msgType`: `0=tsin006`, `1=tsin007`, `2=tsin008`, `3=pacs008`, `4=camt054`
All args are `"key=value"` strings.

```solidity
// Notify owner change (TSIN.008)
requestISOMessage(
  <tokenId>,
  2,
  [
    "event=OwnerChanged",
    "amount=1000000",        // microunits (1e6)
    "ccy=USD",
    "debtor=<DEBTOR_WALLET>",
    "creditor=<CURRENT_OWNER_WALLET>",
    "iban=AT00 1234 5678 9000 0000",
    "note=Marketplace buy"
  ]
)

// Payment messages (PACS.008) are typically emitted automatically by PaymentRouter on final settlement.
```

*(Optional for assignments / statements in your process):*
`tsin006`, `tsin007`, `camt054` available via the same API.

---

## 7) Payment & Settlement

### 7.1 Stablecoin Settlement (USDC)

**Prereqs:** USDC whitelisted; settlement asset set; debtor has USDC + approval.

```solidity
// PaymentRouter @ 0x5cb08df43984EFb3fC4a13eC22FC388d6f643e08
setSettlementAsset(<tokenId>, 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)

// Debtor: approve USDC to router (6 decimals)
approve(0x5cb08df43984EFb3fC4a13eC22FC388d6f643e08, 1000000)

// Debtor pays
payStable(
  0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,  // USDC
  <tokenId>,
  1000000                                       // 1.00 USDC
)
```

**Expected:**
Funds flow to current owner; when fully covered → `markSettled(<tokenId>)` on NFT; **PACS.008** emitted via ISOMessageRouter.

### 7.2 Fiat Settlement (SWIFT)

1. **Request a CAMT statement sweep** via Functions:

```solidity
// PaymentRouter
requestFiatSweep(<tokenId>)
```

2. **Automatic credit** on DON fulfillment:
   Router converts credited amount to USD(1e8), accumulates paid total; on full coverage → `markSettled` + **PACS.008**.

3. **Manual fallback (operator/owner)**:

```solidity
// amountCcy is microunits (1e6) in bank currency; bankCcy is bytes3
fulfillFiatReceipt(0x00, <tokenId>, 1250000000, 0x455552, 0x00)  // €1,250.00
```

---

## 8) Risk Scoring (via RiskOracleRouter)

**Contract:** `0x4D498BEE7B1F10055D769D55f58127f9B790B02f`

```solidity
// set once if needed:
setFunctionsConfig(<subId>, "fun-ethereum-sepolia-1", 300000)
setBaseUrl("http://<RISK_SERVICE_HOST>:18888")

// request a score:
requestRisk(
  <tokenId>,
  [
    "1250000000",   // amount microunits (e.g., €1,250.00)
    "EUR",          // ccy
    "Retail",       // industry
    "0",            // pastDelinquencies
    "200"           // discountBps
  ]
)
```

---

## 9) Automation (optional)

**Contract:** PaymentSettlementAutomation @ `0x530f14ade491c8158099c40f9a2bfcf73d405fe6`

Typical usage (depending on your implementation):

* Add invoices to watchlists (router/marketplace).
* Batch check & perform pending actions (sweeps or settlements).

*(Use your contract’s exposed methods, e.g., `addRouterToken`, `addMarketToken`, etc.)*

---

## 10) Troubleshooting (quick checks)

* **Mint reverts**

  * InvoiceNFT `router()` == PaymentRouter
  * PaymentRouter `invoiceNFT()` == InvoiceNFT
  * PartyRegistry `isTrusted(<to>) == true`
* **Marketplace buy reverts**

  * `isListed(tokenId) == true`
  * Registry `isTrusted(buyer) == true`
  * USDC `allowance(buyer, Marketplace) ≥ required`
  * (If required) NFT `isApprovedForAll(owner, Marketplace) == true` or `getApproved(tokenId) == Marketplace`
  * Router `assetWhitelist(USDC) == true`
  * `maxPay ≥ quoted amount`
* **Debtor payment reverts**

  * Router `assetWhitelist(USDC) == true`
  * USDC `allowance(debtor, Router) ≥ amount`
  * Router `settlementAsset(tokenId) == USDC` (if enforced)

---

## 11) Handy Copy & Paste

**Chainlink Functions (Sepolia)**

```txt
Router: 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0
DON ID: "fun-ethereum-sepolia-1"
```

**Currencies (bytes3)**

```txt
USD = 0x555344
EUR = 0x455552
```

**All-zero flags (32 bytes)**

```txt
0x0000000000000000000000000000000000000000000000000000000000000000
```

**Approvals**

```solidity
// Buyer → InvoiceMarketplace (USDC 6 decimals)
approve(0xee83bcdaf322abb93541ace9471b9295864e6e76, 10000000)  // 10 USDC

// Debtor → PaymentRouter (USDC)
approve(0x7F805E2f7431Ad140d32FfD1e83B45BEeC493Fe2, 10000000)  // 10 USDC

// (Only if needed for your flow) Owner → Marketplace (NFT)
setApprovalForAll(0xee83bcdaf322abb93541ace9471b9295864e6e76, true)
```

**Quotes & Pays**

```solidity
// Marketplace quotes
quoteBuyAmount(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, <tokenId>)  // USDC amount
quoteBuyUsd8(<tokenId>)                                            // USD(1e8)

// Buy with USDC
buyWithStable(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, <tokenId>, 10000000)

// Router quote & pay
quoteTokenToSettle(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, <tokenId>)
payStable(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, <tokenId>, 10000000)
```

**ISO & Risk (examples)**

```solidity
// ISO: TSIN.008
requestISOMessage(<tokenId>, 2, [
  "event=OwnerChanged",
  "amount=1250000000",
  "ccy=EUR",
  "debtor=<WALLET>",
  "creditor=<WALLET>",
  "iban=AT00 1234 5678 9000 0000",
  "note=Ownership update"
]);

// Risk
requestRisk(<tokenId>, ["1250000000","EUR","Retail","0","200"]);
``,
