// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts@1.4.0/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts@1.4.0/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts@1.4.0/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/**
 * RiskOracleRouter
 * - Calls inline JavaScript that POSTs to your risk microservice, then GETs (if needed)
 * - Expects microservice to expose:
 *     POST {base}/risk/score   body: { tokenId, amount?, ccy?, industry?, pastDelinquencies?, discountBps? }
 *     GET  {base}/risk/:tokenId   -> { riskBps: <0..10000> } (or key variants)
 * - Returns to fulfill: (uint256 score, string evidenceURI)
 */
contract RiskOracleRouter is FunctionsClient, ConfirmedOwner {
  using FunctionsRequest for FunctionsRequest.Request;

  struct RiskRecord {
    bool exists;
    uint256 score;      // riskBps
    string evidenceURI; // e.g., <base>/risk/<tokenId>
  }

  mapping(uint256 => RiskRecord) public riskByToken; // tokenId -> last score
  mapping(bytes32 => uint256)   private _pendingToken;

  // ---- Config ----
  bytes32 public donId;        // e.g. bytes32("fun-ethereum-sepolia-1")
  uint64  public subId;        // your subscription id
  uint32  public gasLimit = 150_000; // recommended for callback on Sepolia
  string  public baseUrl = "http://85.217.184.178:18888"; // default microservice base

  event Config(uint64 subId, bytes32 donId, uint32 gasLimit);
  event BaseUrl(string baseUrl);
  event RiskRequested(bytes32 reqId, uint256 tokenId);
  event RiskFulfilled(bytes32 reqId, uint256 tokenId, uint256 score, string evidenceURI);
  event RiskFailed(bytes32 reqId, uint256 tokenId, bytes err);

  constructor(address functionsRouter) FunctionsClient(functionsRouter) ConfirmedOwner(msg.sender) {}

  function setFunctionsConfig(uint64 _subId, bytes32 _donId, uint32 _gasLimit) external onlyOwner {
    subId = _subId;
    donId = _donId;
    gasLimit = _gasLimit;
    emit Config(subId, donId, gasLimit);
  }

  function setBaseUrl(string calldata _base) external onlyOwner {
    baseUrl = _base;
    emit BaseUrl(_base);
  }

  /**
   * Request a risk score.
   * @param tokenId   Invoice token id
   * @param args      [amountMinorUnits, ccy, industry, pastDelinquencies, discountBps]
   */
  function requestRisk(uint256 tokenId, string[] calldata args) external returns (bytes32 requestId) {
    require(subId != 0 && donId != bytes32(0), "Functions config missing");

    FunctionsRequest.Request memory req;
    req.initializeRequestForInlineJavaScript(_source());

    // JS expects args = [baseUrl, tokenId, amount, ccy, industry, pastDelinquencies, discountBps]
    string[] memory fullArgs = new string[](7);
    fullArgs[0] = baseUrl;
    fullArgs[1] = _uToString(tokenId);
    // fill optionals ("" if not provided)
    fullArgs[2] = args.length > 0 ? args[0] : "";
    fullArgs[3] = args.length > 1 ? args[1] : "";
    fullArgs[4] = args.length > 2 ? args[2] : "";
    fullArgs[5] = args.length > 3 ? args[3] : "";
    fullArgs[6] = args.length > 4 ? args[4] : "";
    req.setArgs(fullArgs);

    requestId = _sendRequest(req.encodeCBOR(), subId, gasLimit, donId);
    _pendingToken[requestId] = tokenId;
    emit RiskRequested(requestId, tokenId);
  }

  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
    uint256 tokenId = _pendingToken[requestId];
    require(tokenId != 0, "unknown req");
    delete _pendingToken[requestId];

    if (err.length > 0) {
      emit RiskFailed(requestId, tokenId, err);
      return;
    }

    // (uint256 score, string evidenceURI)
    (uint256 score, string memory evidenceURI) = abi.decode(response, (uint256, string));
    riskByToken[tokenId] = RiskRecord({ exists: true, score: score, evidenceURI: evidenceURI });
    emit RiskFulfilled(requestId, tokenId, score, evidenceURI);
  }

  // -------- inline JS (POST -> GET; returns abi.encode(uint256, string)) --------
  function _source() internal pure returns (string memory) {
    return string.concat(
      "/** Inline JS: POST -> GET (no timeouts), returns (uint256 score, string evidenceURI) */\n",
      "function normalizeBase(u){if(!u||String(u).trim()===\"\")throw Error(\"base missing\");let s=String(u).trim();if(!/^https?:\\/\\//i.test(s))s=\"http://\"+s;return s.replace(/\\/$/,\"\");}\n",
      "function toUint16Safe(n,fb=1000){const x=Number(n);if(Number.isFinite(x)&&x>=0&&x<=65535)return Math.floor(x);return fb;}\n",
      "function hexStr(s){return s;}\n",
      "async function http(req){try{return await Functions.makeHttpRequest(req);}catch(e){return{error:String(e)}}}\n",

      // args: [baseUrl, tokenId, amount, ccy, industry, pastDelinquencies, discountBps]
      "const base=normalizeBase(args[0]);\n",
      "const tokenIdStr=String(args[1]??\"\");\n",
      "if(!tokenIdStr){ return Functions.encodeUint256(0n); }\n", // fallback; not used

      // Optionals
      "const amount=(args.length>2&&args[2]!==\"\"&&args[2]!==undefined)?String(args[2]):undefined;\n",
      "const ccy=(args.length>3&&args[3]!==\"\"&&args[3]!==undefined)?String(args[3]):undefined;\n",
      "const industry=(args.length>4&&args[4]!==\"\"&&args[4]!==undefined)?String(args[4]):undefined;\n",
      "const pastDelinquencies=(args.length>5&&args[5]!==\"\"&&args[5]!==undefined)?Number(args[5]):undefined;\n",
      "const discountBps=(args.length>6&&args[6]!==\"\"&&args[6]!==undefined)?Number(args[6]):undefined;\n",

      "async function postScore(){ const data={tokenId:tokenIdStr}; if(amount!==undefined)data.amount=amount; if(ccy!==undefined)data.ccy=ccy; if(industry!==undefined)data.industry=industry; if(Number.isFinite(pastDelinquencies))data.pastDelinquencies=Number(pastDelinquencies); if(Number.isFinite(discountBps))data.discountBps=Number(discountBps); return http({ url:`${base}/risk/score`, method:\"POST\", data, headers:{\"Content-Type\":\"application/json; charset=utf-8\",\"Accept\":\"application/json\"} }); }\n",
      "async function getScore(){ return http({ url:`${base}/risk/${encodeURIComponent(tokenIdStr)}`, method:\"GET\" }); }\n",

      "// POST first (idempotent), then GET if POST lacked riskBps\n",
      "let resp=await postScore();\n",
      "let v=resp?.data?.riskBps ?? resp?.data?.riskbps ?? resp?.data?.scoreBps ?? resp?.data?.scorebps ?? resp?.data?.risk_bps;\n",
      "if(v==null){ const r2=await getScore(); v=r2?.data?.riskBps ?? r2?.data?.riskbps ?? r2?.data?.scoreBps ?? r2?.data?.scorebps ?? r2?.data?.risk_bps; }\n",
      "const score=toUint16Safe(v,1000);\n",
      "const evidenceURI=`${base}/risk/${encodeURIComponent(tokenIdStr)}`;\n",
      "return Functions.encodeAbiEncoded([\"uint256\",\"string\"],[score.toString(), evidenceURI]);\n"
    );
  }

  // -------- utils --------
  function _uToString(uint256 v) internal pure returns (string memory) {
    if (v == 0) return "0";
    uint256 j = v; uint256 len;
    while (j != 0) { len++; j /= 10; }
    bytes memory b = new bytes(len);
    uint256 k = len;
    while (v != 0) { k--; b[k] = bytes1(uint8(48 + v % 10)); v /= 10; }
    return string(b);
  }
}
