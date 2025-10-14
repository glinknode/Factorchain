// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IInvoiceNFT.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IISOMessageRouter.sol";

// Chainlink Functions v1.0.0
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/**
 * @title PaymentRouter
 * @notice Feed-aware settlement: ERC-20 and SWIFT/fiat valued in USD(1e8).
 *         Adds: Chainlink Functions sweep for fiat (CAMT.054) and ISO PACS.008 on stable settlement.
 */
interface AggregatorV3Interface {
  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
  function decimals() external view returns (uint8);
}

contract PaymentRouter is FunctionsClient {
  using FunctionsRequest for FunctionsRequest.Request;

  // ---- Ownership & reentrancy ----
  address public owner;
  modifier onlyOwner(){ require(msg.sender == owner, "only owner"); _; }
  uint256 private _locked;
  modifier nonReentrant(){ require(_locked==0,"reentrancy"); _locked=1; _; _locked=0; }

  // --- Token owner auth (for per-token settings) ---
  modifier onlyTokenOwner(uint256 tokenId) {
    require(msg.sender == _ownerOfToken(tokenId), "only token owner");
    _;
  }


  // ---- Core refs ----
  IInvoiceNFT public immutable invoiceNFT;
  IISOMessageRouter public isoRouter; // settable

  // ---- Chainlink Functions config ----
  uint64  public subId;
  bytes32 public donId;
  uint32  public gasLimit = 150_000;
  string  public baseUrl  = "http://85.217.184.178:18887"; // ISO 20022 microservice

  // reqId => tokenId for fiat sweep
  mapping(bytes32 => uint256) private _fiatReqToken;

  // ---- Storage ----
  struct PayTo { address wallet; string iban; }
  mapping(uint256 => PayTo) private _payTo;

  mapping(address => bool) public assetWhitelist;
  mapping(uint256 => address) public settlementAsset;
  mapping(uint256 => uint256) public paidUsd8;

  mapping(address => AggregatorV3Interface) public tokenUsdFeed; // token→USD
  mapping(bytes3  => AggregatorV3Interface) public ccyUsdFeed;   // ccy→USD

  // Fiat sweep bookkeeping to avoid double-credit
  mapping(uint256 => string) public lastFiatMsgId;

  // ---- Events ----
  event OwnerTransferred(address indexed prev, address indexed curr);
  event InvoiceWired(address indexed nft);
  event PayToUpdated(uint256 indexed tokenId, address wallet, string iban);
  event AssetWhitelistSet(address indexed token, bool allowed);
  event SettlementAssetSet(uint256 indexed tokenId, address indexed token);
  event StablecoinPaid(uint256 indexed tokenId, address indexed payer, address indexed toOwner, address asset, uint256 amount, uint256 usdDelta8);
  event OverpaymentInfo(uint256 indexed tokenId, uint256 overUsd8);
  event TokenUsdFeedSet(address indexed token, address indexed aggregator, uint8 decimals);
  event CcyUsdFeedSet(bytes3 indexed ccy, address indexed aggregator, uint8 decimals);

  event FiatSweepRequested(uint256 indexed tokenId, bytes32 requestId);
  event FiatCreditedFromCAMT(uint256 indexed tokenId, string msgId, uint256 amountMinor, bytes3 ccy, uint256 usdDelta8);

  event FunctionsConfig(uint64 subId, bytes32 donId, uint32 gasLimit);
  event BaseUrlSet(string baseUrl);
  event ISORouterSet(address isoRouter);

  constructor(address nft, address functionsRouter)
    FunctionsClient(functionsRouter)
  {
    owner = msg.sender;
    invoiceNFT = IInvoiceNFT(nft);
    emit InvoiceWired(nft);
  }

  // ---- Owner ops ----
  function transferOwnership(address newOwner) external onlyOwner { emit OwnerTransferred(owner,newOwner); owner = newOwner; }
  function setISORouter(address r) external onlyOwner { isoRouter = IISOMessageRouter(r); emit ISORouterSet(r); }

  function setFunctionsConfig(uint64 _subId, bytes32 _donId, uint32 _gasLimit) external onlyOwner {
    subId = _subId; donId = _donId; gasLimit = _gasLimit; emit FunctionsConfig(subId, donId, gasLimit);
  }
  function setBaseUrl(string calldata _base) external onlyOwner { baseUrl = _base; emit BaseUrlSet(_base); }

  // ---- NFT hook ----
  function updatePayTo(uint256 tokenId, address newOwner) external {
    require(msg.sender == address(invoiceNFT), "only InvoiceNFT");
    _payTo[tokenId].wallet = newOwner;
    emit PayToUpdated(tokenId, newOwner, _payTo[tokenId].iban);
  }

  // ---- Settings ----
  function setAssetWhitelist(address token, bool allowed) external onlyOwner {
    assetWhitelist[token] = allowed; emit AssetWhitelistSet(token, allowed);
  }
  function setSettlementAsset(uint256 tokenId, address token) external onlyTokenOwner(tokenId) {
    settlementAsset[tokenId] = token; emit SettlementAssetSet(tokenId, token);
  }
  function setPayoutIBAN(uint256 tokenId, string calldata iban) external {
    _payTo[tokenId].iban = iban; emit PayToUpdated(tokenId, _payTo[tokenId].wallet, iban);
  }
  function setPayoutWallet(uint256 tokenId, address newWallet) external  {
    _payTo[tokenId].wallet = newWallet; emit PayToUpdated(tokenId, newWallet, _payTo[tokenId].iban);
  }

  function setTokenUsdFeed(address token, address aggregator) external onlyOwner {
    tokenUsdFeed[token] = AggregatorV3Interface(aggregator);
    uint8 d = aggregator!=address(0) ? AggregatorV3Interface(aggregator).decimals() : 0;
    emit TokenUsdFeedSet(token, aggregator, d);
  }
  function setCcyUsdFeed(bytes3 ccy, address aggregator) external onlyOwner {
    ccyUsdFeed[ccy] = AggregatorV3Interface(aggregator);
    uint8 d = aggregator!=address(0) ? AggregatorV3Interface(aggregator).decimals() : 0;
    emit CcyUsdFeedSet(ccy, aggregator, d);
  }

  // ---- USD helpers ----
  function _ccyToUsd8(bytes3 ccy, uint256 valMinor) internal view returns (uint256) {
    AggregatorV3Interface fx = ccyUsdFeed[ccy];
    if (ccy == bytes3("USD") && address(fx) == address(0)) return valMinor * 1e8; // implied 1:1
    require(address(fx)!=address(0), "ccy feed");
    (, int256 px,,,) = fx.latestRoundData(); require(px > 0, "ccy px");
    uint8 d = fx.decimals();
    if (d == 8) return uint256(px) * valMinor;
    if (d > 8)  return (uint256(px) * valMinor) / (10 ** (d - 8));
    return (uint256(px) * valMinor) * (10 ** (8 - d));
  }
  function _tokenToUsd8(address token, uint256 amount) internal view returns (uint256) {
    AggregatorV3Interface pf = tokenUsdFeed[token]; require(address(pf)!=address(0), "token feed");
    (, int256 px,,,) = pf.latestRoundData(); require(px > 0, "token px");
    uint8 d = pf.decimals();
    if (d == 8) return uint256(px) * amount;
    if (d > 8)  return (uint256(px) * amount) / (10 ** (d - 8));
    return (uint256(px) * amount) * (10 ** (8 - d));
  }

  // ---- Views ----
  function payoutWallet(uint256 tokenId) external view returns (address) { return _payTo[tokenId].wallet; }
  function payoutIBAN(uint256 tokenId) external view returns (string memory) { return _payTo[tokenId].iban; }

  function dueUsd8(uint256 tokenId) public view returns (uint256) {
    (uint256 due, bytes3 ccy,,,,, bool settled) = invoiceNFT.invoices(tokenId);
    if (settled) return 0;
    return _ccyToUsd8(ccy, due);
  }

  function quoteTokenToSettle(address asset, uint256 tokenId) public view returns (uint256) {
    require(assetWhitelist[asset], "asset");
    uint256 usdDue = dueUsd8(tokenId);
    if (usdDue == 0) return 0;
    uint256 rem = usdDue > paidUsd8[tokenId] ? (usdDue - paidUsd8[tokenId]) : 0;
    if (rem == 0) return 0;
    AggregatorV3Interface pf = tokenUsdFeed[asset]; require(address(pf)!=address(0), "token feed");
    (, int256 px,,,) = pf.latestRoundData(); require(px > 0, "token px");
    uint8 d = pf.decimals();
    return (rem * (10 ** d)) / (uint256(px) * 1e8);
  }

  function remainingUsd8(uint256 tokenId) external view returns (uint256) {
    uint256 due = dueUsd8(tokenId);
    uint256 paid = paidUsd8[tokenId];
    return due > paid ? (due - paid) : 0;
  }

  function remainingTokenNeeded(address asset, uint256 tokenId) external view returns (uint256) {
    return quoteTokenToSettle(asset, tokenId);
  }

  // ---- ERC-20 payments (stable) ----
  function payStable(address token, uint256 tokenId, uint256 amount) external nonReentrant {
    require(assetWhitelist[token], "asset");
    address expected = settlementAsset[tokenId];
    if (expected != address(0)) require(expected == token, "unexpected asset");

    (,, , , , , bool settled) = invoiceNFT.invoices(tokenId);
    require(!settled, "settled");

    address toOwner = _payTo[tokenId].wallet;
    require(IERC20Minimal(token).transferFrom(msg.sender, toOwner, amount), "transferFrom");

    uint256 usdDelta = _tokenToUsd8(token, amount);
    paidUsd8[tokenId] += usdDelta;

    emit StablecoinPaid(tokenId, msg.sender, toOwner, token, amount, usdDelta);

    uint256 usdDue = dueUsd8(tokenId);
    if (paidUsd8[tokenId] >= usdDue) {
      // Mark settled and send ISO PACS.008 via isoRouter (if set)
      invoiceNFT.markSettled(tokenId);

      if (address(isoRouter) != address(0)) {
        // Minimal args (key=value) for pacs008
        string[] memory isoPay = new string[](3);
        isoPay[0] = string(abi.encodePacked("amount=", _uToString(amount)));
        isoPay[1] = string(abi.encodePacked("ccy=USD")); // present as USD; adjust if needed
        isoPay[2] = string(abi.encodePacked("remRef=STABLE-SETTLED-", _uToString(tokenId)));
        isoRouter.requestISOMessage(tokenId, IISOMessageRouter.MessageType.PACS_008, isoPay);
      }

      if (paidUsd8[tokenId] > usdDue) emit OverpaymentInfo(tokenId, paidUsd8[tokenId] - usdDue);
    }
  }

  // ---- FIAT path (via Chainlink Functions sweep) ----
  // Arg packing: [ baseUrl, tokenId, opIndex, ...kvPairs ]
  // For sweep: opIndex = "0", kvPairs includes "lastMsgId=<id>"
  function requestFiatSweep(uint256 tokenId) public onlyOwner returns (bytes32 requestId) {
    (,, , , , , bool settled) = invoiceNFT.invoices(tokenId);
    require(!settled, "settled");
    require(subId != 0 && donId != bytes32(0), "Functions config missing");

    FunctionsRequest.Request memory req;
    req.initializeRequestForInlineJavaScript(_sourceFiatSweep());

    // Build args: [baseUrl, tokenId, opIndex("0"), "lastMsgId=<...>"]
    string[] memory a = new string[](4);  // <-- Declare and initialize array
    a[0] = baseUrl;
    a[1] = _uToString(tokenId);
    a[2] = "0"; // opIndex: SWEEP_FIAT
    a[3] = string(abi.encodePacked("lastMsgId=", lastFiatMsgId[tokenId]));
    req.setArgs(a);

    requestId = _sendRequest(req.encodeCBOR(), subId, gasLimit, donId);
    _fiatReqToken[requestId] = tokenId;
    emit FiatSweepRequested(tokenId, requestId);
  }

  // Manual credit fallback
  function fulfillFiatReceipt(
    bytes32 /*reqId*/,
    uint256 tokenId,
    uint256 amountCcy,
    bytes3 bankCcy,
    bytes32 /*proofHash*/
  ) external onlyOwner {
    (,, , , , , bool settled) = invoiceNFT.invoices(tokenId);
    require(!settled, "settled");

    uint256 usdDelta = _ccyToUsd8(bankCcy, amountCcy);
    paidUsd8[tokenId] += usdDelta;

    emit FiatCreditedFromCAMT(tokenId, "<manual>", amountCcy, bankCcy, usdDelta);

    uint256 usdDue = dueUsd8(tokenId);
    if (paidUsd8[tokenId] >= usdDue) {
      invoiceNFT.markSettled(tokenId);
      if (paidUsd8[tokenId] > usdDue) emit OverpaymentInfo(tokenId, paidUsd8[tokenId] - usdDue);
    }
  }

  // ---- Functions fulfillment ----
  // response ABI: (string newestMsgId, uint256 creditedAmountMinor, bytes3 ccy)
  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*err*/) internal override {
    uint256 tokenId = _fiatReqToken[requestId];
    if (tokenId == 0) return;

    (string memory newestId, uint256 amountMinor, bytes3 ccy) = abi.decode(response, (string, uint256, bytes3));

    if (bytes(newestId).length > 0) {
      lastFiatMsgId[tokenId] = newestId;
    }

    if (amountMinor > 0) {
      uint256 usdDelta = _ccyToUsd8(ccy, amountMinor);
      paidUsd8[tokenId] += usdDelta;
      emit FiatCreditedFromCAMT(tokenId, newestId, amountMinor, ccy, usdDelta);

      uint256 usdDue = dueUsd8(tokenId);
      if (paidUsd8[tokenId] >= usdDue) {
        invoiceNFT.markSettled(tokenId);
        if (paidUsd8[tokenId] > usdDue) emit OverpaymentInfo(tokenId, paidUsd8[tokenId] - usdDue);
      }
    }

    delete _fiatReqToken[requestId];
  }

  // ---- Inline JS (fiat sweep against ISO service) ----
  // Args = [baseUrl, tokenId, opIndex, ...kvPairs], with opIndex "0" == sweep
  function _sourceFiatSweep() internal pure returns (string memory) {
    return string.concat(
      "/** args = [baseUrl, tokenId, opIndex, ...kvPairs]; kvPairs may include 'lastMsgId=...' */\n",
      "function base(u){let s=String(u||'').trim(); if(!s) throw Error('base missing'); if(!/^https?:\\/\\//i.test(s)) s='http://'+s; return s.replace(/\\/$/,'');}\n",
      "function parseAmount(x){ if(x==null) return 0; const n = Number(x); return Number.isFinite(n)&&n>=0? Math.floor(n):0; }\n",
      "function getKV(kvList,key){ for(const kv of kvList){ if(typeof kv==='string' && kv.startsWith(key+'=')) return kv.slice(key.length+1); } return ''; }\n",
      "async function http(req){ try{ return await Functions.makeHttpRequest(req);} catch(e){ return {error:String(e)}; } }\n",
      "const b = base(args[0]);\n",
      "const tokenId = String(args[1]||''); if(!tokenId) throw Error('tokenId');\n",
      "const opIndex = String(args[2]||''); if(opIndex!== '0') throw Error('unsupported op');\n",
      "const kvPairs = args.slice(3);\n",
      "const lastId  = String(getKV(kvPairs,'lastMsgId'));\n",
      "// --- auth header if INTERNAL_TOKEN is set ---\n",
      "const headers = {};\n",
      "try{ if(secrets && typeof secrets.INTERNAL_TOKEN==='string' && secrets.INTERNAL_TOKEN.length>0){ headers['Authorization'] = `Bearer ${secrets.INTERNAL_TOKEN}`; } }catch(_){ }\n",
      "const url = `${b}/iso/${encodeURIComponent(tokenId)}/messages`;\n",
      "const resp = await http({ url, method:'GET', headers });\n",
      "if(resp?.error) throw Error(`HTTP: ${resp.error}`);\n",
      "const list = Array.isArray(resp?.data)? resp.data: [];\n",
      "// Find newest CAMT.054 with id > lastId (lexicographic compare)\n",
      "let newest = null;\n",
      "for(const m of list){\n",
      "  if(m?.kind==='camt' && m?.type==='054'){\n",
      "    if(!lastId || (String(m.id)>lastId)){\n",
      "      if(!newest || String(m.id)>String(newest.id)) newest=m;\n",
      "    }\n",
      "  }\n",
      "}\n",
      "let creditedMinor = 0; let ccy = 'USD';\n",
      "if(newest){ const meta=newest.meta||{}; creditedMinor = parseAmount(meta.amount); ccy = String(meta.ccy||'USD').slice(0,3).toUpperCase(); }\n",
      "// ABI: (string newestMsgId, uint256 creditedAmountMinor, bytes3 ccy)\n",
      "function encStrBytes3(id, amt, ccy){\n",
      "  function u256(n){ let h=BigInt(n).toString(16); if(h.length%2)h='0'+h; return h.padStart(64,'0'); }\n",
      "  function hexBytes(s){ const e=new TextEncoder(); const u=e.encode(s); let h=''; for(const b of u){ h+=b.toString(16).padStart(2,'0'); } return h; }\n",
      "  const idHex = hexBytes(id); const idLen=u256(idHex.length/2); const idPadded=idHex + '00'.repeat((32 - (idHex.length/2)%32)%32);\n",
      "  const head0=u256(64); const head1=u256(64+32+idPadded.length/2);\n",
      "  const amtHex=u256(amt);\n",
      "  let c=''; const e=new TextEncoder(); const u=e.encode(ccy.padEnd(3,' ')); for(const b of u){ c+=b.toString(16).padStart(2,'0'); }\n",
      "  c = c.slice(0,6); c = c.padEnd(64,'0');\n",
      "  const out='0x'+head0+head1+amtHex+idLen+idPadded+c; const arr=new Uint8Array(out.length/2-1); for(let i=2,k=0;i<out.length;i+=2,k++){arr[k]=parseInt(out.slice(i,i+2),16);} return arr;\n",
      "}\n",
      "return encStrBytes3(newest?String(newest.id):'', creditedMinor, ccy);\n"
    );
  }

  // ---- utils ----
  function _uToString(uint256 v) internal pure returns (string memory) {
    if (v == 0) return "0";
    uint256 j=v; uint256 len; while (j!=0){ len++; j/=10; }
    bytes memory b=new bytes(len); uint256 k=len; while(v!=0){ k--; b[k]=bytes1(uint8(48 + (v%10))); v/=10; }
    return string(b);
  }
   // Helper to read ERC-721 owner without changing IInvoiceNFT
  function _ownerOfToken(uint256 tokenId) internal view returns (address) {
    (bool ok, bytes memory data) = address(invoiceNFT).staticcall(
      abi.encodeWithSignature("ownerOf(uint256)", tokenId)
    );
    require(ok && data.length >= 32, "ownerOf");
    return abi.decode(data, (address));
  }
}

 
