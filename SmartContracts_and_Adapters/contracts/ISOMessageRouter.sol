// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts@1.4.0/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts@1.4.0/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts@1.4.0/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/**
 * ISOMessageRouter
 * - Uses Chainlink Functions inline JS to call your ISO microservice on :18887
 * - POSTs to: /iso/:tokenId/{tsin006|tsin007|tsin008|pacs008|camt054}
 * - Expects response: { id, hash, ... } and returns (bytes32 docHash, string evidenceURI)
 * - Args are flexible "key=value" strings (e.g., ["msgId=ABC","amount=1000","ccy=EUR"])
 */
contract ISOMessageRouter is FunctionsClient, ConfirmedOwner {
  using FunctionsRequest for FunctionsRequest.Request;

  // Match your backend endpoints
  enum MessageType { TSIN_006, TSIN_007, TSIN_008, PACS_008, CAMT_054 }

  struct MessageRecord {
    bool exists;
    bytes32 docHash;
    string evidenceURI;
  }

  // (tokenId, messageType) -> record
  mapping(uint256 => mapping(uint8 => MessageRecord)) public messages;

  struct Pending { uint256 tokenId; uint8 messageType; }
  mapping(bytes32 => Pending) private _pending;

  // Chainlink Functions config
  bytes32 public donId;          // e.g. bytes32("fun-ethereum-sepolia-1")
  uint64  public subId;          // subscription id
  uint32  public gasLimit = 150_000; // good Sepolia default
  string  public baseUrl;        // e.g. "http://85.217.184.178:18887"

  event MessageRequested(bytes32 indexed reqId, uint256 indexed tokenId, uint8 indexed messageType);
  event MessageFulfilled(bytes32 indexed reqId, uint256 indexed tokenId, uint8 indexed messageType, bytes32 docHash, string evidenceURI);
  event MessageFailed(bytes32 indexed reqId, uint256 indexed tokenId, uint8 indexed messageType, bytes error);
  event Config(uint64 subId, bytes32 donId, uint32 gasLimit);
  event BaseUrl(string baseUrl);


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
   * Trigger an ISO/TSIN message build/store via Functions.
   * @param tokenId  Invoice NFT id
   * @param msgType  enum value: TSIN_006, TSIN_007, TSIN_008, PACS_008, CAMT_054
   * @param args     flexible key=value list (e.g., ["msgId=ABC","amount=1000","ccy=EUR"])
   */
  function requestISOMessage(uint256 tokenId, MessageType msgType, string[] calldata args)
    external
    returns (bytes32 requestId)
  {
    require(subId != 0 && donId != bytes32(0), "Functions config missing");

    FunctionsRequest.Request memory req;
    req.initializeRequestForInlineJavaScript(_source());

    // Inline JS expects: [baseUrl, tokenId, msgTypeIndex, ...kvPairs]
    string[] memory fullArgs = new string[](3 + args.length);
    fullArgs[0] = baseUrl;
    fullArgs[1] = _uToString(tokenId);
    fullArgs[2] = _uToString(uint8(msgType));
    for (uint256 i = 0; i < args.length; ++i) fullArgs[3 + i] = args[i];
    req.setArgs(fullArgs);

    requestId = _sendRequest(req.encodeCBOR(), subId, gasLimit, donId);
    _pending[requestId] = Pending({tokenId: tokenId, messageType: uint8(msgType)});
    emit MessageRequested(requestId, tokenId, uint8(msgType));
  }

  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
    Pending memory p = _pending[requestId];
    require(p.tokenId != 0 || p.messageType <= uint8(type(MessageType).max), "unknown request");
    delete _pending[requestId];

    if (err.length > 0) {
      emit MessageFailed(requestId, p.tokenId, p.messageType, err);
      return;
    }

    // (bytes32 docHash, string evidenceURI)
    (bytes32 docHash, string memory evidenceURI) = abi.decode(response, (bytes32, string));
    MessageRecord storage rec = messages[p.tokenId][p.messageType];
    rec.exists = true;
    rec.docHash = docHash;
    rec.evidenceURI = evidenceURI;

    emit MessageFulfilled(requestId, p.tokenId, p.messageType, docHash, evidenceURI);
  }

  // -------- inline JS (POST builder on :18887; returns abi.encode(bytes32, string)) --------
  function _source() internal pure returns (string memory) {
    return string.concat(
      "/** Inline JS to ISO service :18887. Args = [baseUrl, tokenId, msgTypeIdx, ...key=value] */\n",
      "function normBase(u){let s=String(u||\"\").trim(); if(!s) throw Error(\"base missing\"); if(!/^https?:\\/\\//i.test(s)) s=\"http://\"+s; return s.replace(/\\/$/,\"\");}\n",
      "function endpoint(i){ const n=Number(i); if(n===0) return \"tsin006\"; if(n===1) return \"tsin007\"; if(n===2) return \"tsin008\"; if(n===3) return \"pacs008\"; if(n===4) return \"camt054\"; throw Error(\"bad msgType\"); }\n",
      "function buildBody(kv){ const o={}; for(const s of kv){ if(!s||typeof s!=='string') continue; const j=s.indexOf('='); if(j<=0) continue; const k=s.slice(0,j).trim(); const v=s.slice(j+1); if(!k) continue; o[k]=v; } return o; }\n",
      "function toHex32(h){ let x=String(h||\"\"); if(x.startsWith(\"0x\")) x=x.slice(2); if(x.length!==64) throw Error(\"hash not 32 bytes\"); return \"0x\"+x; }\n",
      "// --- minimal ABI encoder for (bytes32,string) ---\n",
      "function toHexBytes(u8){let s=\"\"; for(const b of u8){ s+=b.toString(16).padStart(2,'0'); } return s; }\n",
      "function u32(n){ let h=n.toString(16); if(h.length%2) h='0'+h; let bytesLen=Math.ceil(h.length/2); const pad=64 - bytesLen*2; return '0'.repeat(Math.max(0,pad))+h; }\n",
      "function pad32(hex){ const len=hex.length/2; const rem=len%32; const pad= rem? (32-rem):0; return hex + '00'.repeat(pad); }\n",
      "function encBytes32String(b32, str){\n",
      "  const head0 = b32.slice(2); // 32 bytes\n",
      "  const head1 = u32(64);      // offset to dynamic (0x40)\n",
      "  const data  = Buffer.from(str, 'utf8');\n",
      "  const len   = u32(data.length);\n",
      "  const body  = pad32(toHexBytes(data));\n",
      "  const hex   = '0x' + head0 + head1 + len + body;\n",
      "  const out   = new Uint8Array(hex.length/2 - 1);\n",
      "  for(let i=2, k=0; i<hex.length; i+=2, k++) out[k]=parseInt(hex.slice(i,i+2),16);\n",
      "  return out;\n",
      "}\n",
      "async function http(req){ try{ return await Functions.makeHttpRequest(req);}catch(e){ return { error:String(e) }; } }\n",
      "const base   = normBase(args[0]);\n",
      "const token  = String(args[1]||\"\"); if(!token) throw Error('tokenId missing');\n",
      "const mIdx   = String(args[2]||\"\"); const ep = endpoint(mIdx);\n",
      "const body   = buildBody(args.slice(3));\n",
      "// Optional auth via DON-hosted secret INTERNAL_TOKEN\n",
      "const headers = {}; try{ if(secrets && typeof secrets.INTERNAL_TOKEN==='string' && secrets.INTERNAL_TOKEN.length>0){ headers['Authorization'] = `Bearer ${secrets.INTERNAL_TOKEN}`; } }catch(_){ }\n",
      "const url = `${base}/iso/${encodeURIComponent(token)}/${ep}`;\n",
      "const resp = await http({ url, method:'POST', data: body, headers });\n",
      "if(resp?.error) throw Error(`HTTP: ${resp.error}`);\n",
      "if(!resp?.data) throw Error('empty body');\n",
      "const id   = resp.data.id;    // message id in store\n",
      "const hash = resp.data.hash;  // 32-byte hex\n",
      "if(!id || !hash) throw Error('id/hash missing');\n",
      "const docHash = toHex32(hash);\n",
      "const evidenceURI = `${base}/iso/${encodeURIComponent(token)}/messages/${encodeURIComponent(id)}.xml`;\n",
      "return encBytes32String(docHash, evidenceURI);\n"
    );
  }

  // utils
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
