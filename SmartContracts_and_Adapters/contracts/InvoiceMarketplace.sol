// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IInvoiceNFT.sol";
import "./interfaces/IPartyRegistry.sol";
import "./interfaces/IPaymentRouter.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IISOMessageRouter.sol";

// Chainlink Functions v1.0.0
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/**
 * @title InvoiceMarketplace
 * @notice Feed-aware buys: ERC-20 and SWIFT/fiat, valued in USD(1e8).
 *         IMPORTANT: A buy changes the invoice's payment receiver (owner). It does NOT settle the invoice.
 */
interface AggregatorV3Interface {
  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
  function decimals() external view returns (uint8);
}

contract InvoiceMarketplace is FunctionsClient {
  using FunctionsRequest for FunctionsRequest.Request;

  // ---- Ownership & reentrancy ----
  address public owner;
  modifier onlyOwner(){ require(msg.sender == owner, "only owner"); _; }
  uint256 private _locked;
  modifier nonReentrant(){ require(_locked==0,"reentrancy"); _locked=1; _; _locked=0; }

  // ---- Core refs ----
  IInvoiceNFT        public immutable inv;
  IPartyRegistry     public immutable reg;
  IPaymentRouter     public immutable policy;
  IISOMessageRouter  public isoRouter; // settable

  // ---- Chainlink Functions config ----
  uint64  public subId;
  bytes32 public donId;
  uint32  public gasLimit = 150_000;
  string  public baseUrl  = "http://85.217.184.178:18887"; // ISO 20022 microservice

  // reqId => tokenId for fiat sweep (purchase)
  mapping(bytes32 => uint256) private _fiatReqToken;

  // Fiat sweep bookkeeping to avoid double-credit (per token / listing)
  mapping(uint256 => string) public lastFiatMsgId;

  // Intended buyer for next fiat-qualified purchase
  mapping(uint256 => address) public intendedBuyer;

  // ---- Feeds ----
  mapping(address => AggregatorV3Interface) public tokenUsdFeed; // token→USD
  mapping(bytes3  => AggregatorV3Interface) public ccyUsdFeed;   // ccy→USD

  // ---- Events ----
  event OwnerTransferred(address indexed prev, address indexed curr);

  event TokenUsdFeedSet(address indexed token, address indexed aggregator, uint8 decimals);
  event CcyUsdFeedSet(bytes3 indexed ccy, address indexed aggregator, uint8 decimals);

  // Payment event (price paid & channel), does NOT imply settlement
  event BuyStable(
    uint256 indexed tokenId,
    address indexed buyer,
    address indexed seller,
    address asset,
    uint256 amountPaid,
    uint256 usdDelta8
  );

  event PaymentReceiverUpdated(
    uint256 indexed tokenId,
    address indexed oldReceiver,
    address indexed newReceiver,
    string   channel,   // "ERC20" or "FIAT"
    string   remRef
  );


  event FiatCreditedFromCAMT(uint256 indexed tokenId, string msgId, uint256 amountMinor, bytes3 ccy, uint256 usdDelta8);

  event FunctionsConfig(uint64 subId, bytes32 donId, uint32 gasLimit);
  event BaseUrlSet(string baseUrl);
  event ISORouterSet(address isoRouter);

  constructor(address invoiceNFT, address partyRegistry, address paymentRouterPolicy, address functionsRouter)
    FunctionsClient(functionsRouter)
  {
    owner  = msg.sender;
    inv    = IInvoiceNFT(invoiceNFT);
    reg    = IPartyRegistry(partyRegistry);
    policy = IPaymentRouter(paymentRouterPolicy);
  }

  // ---- Owner ops ----
  function transferOwnership(address n) external onlyOwner { emit OwnerTransferred(owner,n); owner = n; }
  function setISORouter(address r) external onlyOwner { isoRouter = IISOMessageRouter(r); emit ISORouterSet(r); }

  function setFunctionsConfig(uint64 _subId, bytes32 _donId, uint32 _gasLimit) external onlyOwner {
    subId = _subId; donId = _donId; gasLimit = _gasLimit; emit FunctionsConfig(subId, donId, gasLimit);
  }
  function setBaseUrl(string calldata _base) external onlyOwner { baseUrl = _base; emit BaseUrlSet(_base); }

  // ---- Feeds ----
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

  // token -> USD(1e8) using tokenUsdFeed
  function _tokenToUsd8(address token, uint256 amount) internal view returns (uint256 usd8) {
    AggregatorV3Interface pf = tokenUsdFeed[token]; require(address(pf) != address(0), "token feed");
    (, int256 px,,,) = pf.latestRoundData(); require(px > 0, "token px");
    uint8 d = pf.decimals();
    if (d == 8) return uint256(px) * amount;
    if (d > 8)  return (uint256(px) * amount) / (10 ** (d - 8));
    return (uint256(px) * amount) * (10 ** (8 - d));
  }

  // ---- Views ----
  function isListed(uint256 tokenId) public view returns (bool listed) {
    (, , , , listed) = inv.invoiceMeta(tokenId);
  }
  function netPrice(uint256 tokenId) public view returns (uint256) {
    return inv.getNetPrice(tokenId);
  }

  function _ccyToUsd8(bytes3 ccy, uint256 valMinor) internal view returns (uint256 usd8) {
    AggregatorV3Interface fx = ccyUsdFeed[ccy];
    if (ccy == bytes3("USD") && address(fx) == address(0)) return valMinor * 1e8;
    require(address(fx) != address(0), "ccy feed");
    (, int256 px,,,) = fx.latestRoundData(); require(px > 0, "ccy px");
    uint8 d = fx.decimals();
    if (d == 8) return uint256(px) * valMinor;
    if (d > 8)  return (uint256(px) * valMinor) / (10 ** (d - 8));
    return (uint256(px) * valMinor) * (10 ** (8 - d));
  }

  function _usd8ToToken(address token, uint256 usd8) internal view returns (uint256 tokenAmt) {
    AggregatorV3Interface pf = tokenUsdFeed[token]; require(address(pf) != address(0), "token feed");
    (, int256 px,,,) = pf.latestRoundData(); require(px > 0, "token px");
    uint8 d = pf.decimals();
    tokenAmt = (usd8 * (10 ** d)) / (uint256(px) * 1e8);
  }

  function quoteBuyUsd8(uint256 tokenId) public view returns (uint256) {
    ( , bytes3 ccy, , , , , ) = inv.invoices(tokenId);
    uint256 np = inv.getNetPrice(tokenId);
    // netPrice is amount*(1-discountBps); but ccy conversion should be for net amount in ccy minors
    // If your net price is stored in ccy minors already, convert that; otherwise convert `amount` and then apply discount off-chain.
    return _ccyToUsd8(ccy, np);
  }

  function quoteBuyAmount(address erc20, uint256 tokenId) public view returns (uint256 tokenAmt) {
    require(policy.assetWhitelist(erc20), "asset not allowed");
    uint256 usd8 = quoteBuyUsd8(tokenId);
    tokenAmt = _usd8ToToken(erc20, usd8);
  }

  // ---- ERC-20 BUY (stable-like); emits PaymentReceiverUpdated (NOT settled) ----
  function buyWithStable(address erc20, uint256 tokenId, uint256 maxPay) external nonReentrant {
    require(isListed(tokenId), "not listed");
    require(reg.isTrusted(msg.sender), "buyer not trusted");
    require(policy.assetWhitelist(erc20), "asset not allowed");

    uint256 need = quoteBuyAmount(erc20, tokenId);
    require(need <= maxPay, "slippage");

    address seller = inv.ownerOf(tokenId);
    require(IERC20Minimal(erc20).transferFrom(msg.sender, seller, need), "transferFrom");

    uint256 usdDelta8 = _tokenToUsd8(erc20, need); // value via token/USD feed for event
    emit BuyStable(tokenId, msg.sender, seller, erc20, need, usdDelta8);

    // Transfer ownership → new payment receiver
    inv.safeTransferFrom(seller, msg.sender, tokenId);
    policy.updatePayTo(tokenId,msg.sender);
    
    string memory remRef = string(abi.encodePacked("OWNER-CHANGED-", _uToString(tokenId)));
    emit PaymentReceiverUpdated(tokenId, seller, msg.sender, "ERC20", remRef);

    // ISO note: TSIN.008 on owner change / payee update
    if (address(isoRouter) != address(0)) {
      // Inline JS expects: [baseUrl, tokenId, msgTypeIndex, ...kvPairs]
    string[] memory isoPay = new string[](4);
      isoPay[0] = "event=OwnerChanged";
      isoPay[1] = string(abi.encodePacked("newPayTo=", _addrToHex(msg.sender)));
      isoPay[2] = "channel=ERC20";
      isoPay[3] = string(abi.encodePacked("remRef=", remRef));
      isoRouter.requestISOMessage(tokenId, IISOMessageRouter.MessageType.TSIN_008, isoPay);
    }
  }

  // ---- FIAT BUY via Chainlink Functions sweep (CAMT.054); emits PaymentReceiverUpdated ----
  event FiatPurchaseRequested(uint256 indexed tokenId, bytes32 requestId);

  function requestFiatSweepPurchase(uint256 tokenId) external onlyOwner returns (bytes32 requestId) {
    require(isListed(tokenId), "not listed");
    require(subId != 0 && donId != bytes32(0), "Functions config missing");

    FunctionsRequest.Request memory req;
    req.initializeRequestForInlineJavaScript(_sourceFiatSweep());

    // args = [baseUrl, tokenId, opIndex("0"), "lastMsgId=<...>"]
    string[] memory a = new string[](4);
    a[0] = baseUrl;
    a[1] = _uToString(tokenId);
    a[2] = "0";
    a[3] = string(abi.encodePacked("lastMsgId=", lastFiatMsgId[tokenId]));
    req.setArgs(a);

    requestId = _sendRequest(req.encodeCBOR(), subId, gasLimit, donId);
    _fiatReqToken[requestId] = tokenId;
    emit FiatPurchaseRequested(tokenId, requestId);
  }

  // Set intended buyer for a token prior to a fiat purchase sweep
  function setIntendedBuyer(uint256 tokenId, address buyer) external onlyOwner {
    require(buyer != address(0), "buyer zero");
    require(reg.isTrusted(buyer), "buyer not trusted");
    intendedBuyer[tokenId] = buyer;
  }

  // ---- Chainlink Functions fulfillment ----
  // response ABI: (string newestMsgId, uint256 creditedAmountMinor, bytes3 ccy)
  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*err*/) internal override nonReentrant {
    uint256 tokenId = _fiatReqToken[requestId];
    if (tokenId == 0) return;

    (string memory newestId, uint256 amountMinor, bytes3 ccy) = abi.decode(response, (string, uint256, bytes3));

    if (bytes(newestId).length > 0) {
      lastFiatMsgId[tokenId] = newestId;
    }

    if (amountMinor > 0) {
      uint256 usdDelta = _ccyToUsd8(ccy, amountMinor);
      uint256 priceUsd8 = quoteBuyUsd8(tokenId);

      emit FiatCreditedFromCAMT(tokenId, newestId, amountMinor, ccy, usdDelta);

      if (usdDelta >= priceUsd8) {
        address seller = inv.ownerOf(tokenId);
        address buyer = intendedBuyer[tokenId];
        require(buyer != address(0), "buyer not set");
        require(reg.isTrusted(buyer), "buyer not trusted");
        intendedBuyer[tokenId] = address(0);

        // Transfer ownership → new payment receiver
        inv.safeTransferFrom(seller, buyer, tokenId);

        string memory remRef = string(abi.encodePacked("OWNER-CHANGED-", _uToString(tokenId)));
        emit PaymentReceiverUpdated(tokenId, seller, buyer, "FIAT", remRef);

        if (address(isoRouter) != address(0)) {
          string[] memory isoPay = new string[](4);
          isoPay[0] = "event=OwnerChanged";
          isoPay[1] = string(abi.encodePacked("newPayTo=", _addrToHex(buyer)));
          isoPay[2] = "channel=FIAT";
          isoPay[3] = string(abi.encodePacked("remRef=", remRef));
          isoRouter.requestISOMessage(tokenId, IISOMessageRouter.MessageType.TSIN_008, isoPay);
        }
      }
    }

    delete _fiatReqToken[requestId];
  }

    // ---- Buyer resolution ----
    function _payoutBuyer(uint256 /*tokenId*/) internal view returns (address) {
        address buyer = msg.sender;
        require(buyer != address(0), "no buyer");
        require(reg.isTrusted(buyer), "buyer not trusted");
        return buyer;
    }
    
  // ---- Inline JS (fiat sweep) – same as PaymentRouter parity ----
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

  function _addrToHex(address a) internal pure returns (string memory) {
    bytes20 b = bytes20(a);
    bytes16 hexSymbols = 0x30313233343536373839616263646566; // "0123456789abcdef"
    bytes memory str = new bytes(42);
    str[0] = "0"; str[1] = "x";
    for (uint i = 0; i < 20; i++) {
      str[2 + i*2]   = hexSymbols[uint8(b[i] >> 4)];
      str[3 + i*2]   = hexSymbols[uint8(b[i] & 0x0f)];
    }
    return string(str);
  }
}
