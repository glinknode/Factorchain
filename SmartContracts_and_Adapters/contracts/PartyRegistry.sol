// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/IPartyRegistry.sol";

// Chainlink Functions v1.0.0
import {FunctionsClient} from "@chainlink/contracts@1.4.0/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts@1.4.0/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/**
 * PartyRegistry (vLEI verification via one-call adapter endpoint)
 *
 * User provides ONLY: LEI + vLEI hash on-chain.
 * Contract:
 *  - stores LEI/hash
 *  - auto-generates presentationId (challenge)
 *  - auto-builds a compact presentation JSON
 *  - triggers Chainlink Functions → adapter POST /vlei/verify { presentationId, expectedLEI, presentation? }
 * Adapter:
 *  - if presentation present: submit to APIX & wait for webhook
 *  - if not: wait-only (wallet submits externally)
 */
contract PartyRegistry is AccessControl, Pausable, IPartyRegistry, FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant ADMIN_ROLE  = DEFAULT_ADMIN_ROLE;

    struct PartyEx {
        string  lei;        // LEI code
        bytes32 vleiHash;   // hash of vLEI credential (off-chain submitted)
        bool    isTrusted;  // true after verified
    }

    mapping(address => PartyEx) private parties;

    // ---- Chainlink Functions config ----
    uint64  public subscriptionId;
    bytes32 public donId;
    uint32  public gasLimit = 150_000;                 // default
    string  public baseUrl  = "http://85.217.184.178:18889"; // adapter base

    // reqId -> party being verified
    mapping(bytes32 => address) private _gleifReqToParty;

    // auto presentation id sequence
    uint256 private _presSeq;

    error NotRegistered();


    constructor(address admin, address functionsRouter)
        FunctionsClient(functionsRouter)
    {
        _grantRole(ADMIN_ROLE, admin);
    }

    // ---------------- Admin ----------------

    function setFunctionsConfig(uint64 subId, bytes32 _donId, uint32 _gasLimit)
        external
        onlyRole(ADMIN_ROLE)
    {
        subscriptionId = subId;
        donId = _donId;
        gasLimit = _gasLimit;
        emit Config(subscriptionId, donId, gasLimit); // IPartyRegistry
    }

    function setBaseUrl(string calldata _base) external onlyRole(ADMIN_ROLE) {
        baseUrl = _base;
        emit BaseUrl(_base); // IPartyRegistry
    }

    // ---------------- Core ----------------

    /// Simple register (no verification trigger)
    function registerParty(string calldata lei, bytes32 vleiHash) external whenNotPaused {
        parties[msg.sender] = PartyEx({lei: lei, vleiHash: vleiHash, isTrusted: false});
        emit PartyRegistered(msg.sender, lei, vleiHash);
    }

    /**
     * Register caller with LEI + vLEI hash and immediately trigger verification.
     * Auto-generates presentationId and a compact presentation JSON on-chain.
     * The adapter will receive both and can immediately submit to APIX.
     */
    function registerAndVerifyAuto(
        string calldata lei,
        bytes32 vleiHash
    ) external whenNotPaused returns (bytes32 reqId) {
        // 1) store party
        parties[msg.sender] = PartyEx({lei: lei, vleiHash: vleiHash, isTrusted: false});
        emit PartyRegistered(msg.sender, lei, vleiHash);

        // 2) auto-generate presentationId (challenge)
        _presSeq += 1;
        bytes32 pidHash = keccak256(
            abi.encodePacked(address(this), msg.sender, block.chainid, block.number, block.timestamp, _presSeq)
        );
        string memory presentationId = _bytes32ToHexString(pidHash);
        emit AutoVerificationRequested(msg.sender, presentationId);

        // 3) build compact presentation JSON
        //    {"party":"0x..","lei":"...","vleiHash":"0x..","challenge":"0x<id>"}
        string memory presJson = string.concat(
            '{"party":"', _addrToHex(msg.sender),
            '","lei":"', lei,
            '","vleiHash":"', _bytes32ToHexString(vleiHash),
            '","challenge":"', presentationId,
            '"}'
        );

        // 4) call verify with presentation (so adapter submits to APIX right away)
        reqId = _requestVerify(msg.sender, presentationId, presJson);
    }

    /// Internal: build and send Functions request → adapter /vlei/verify
    /// If presJson is empty string, we send wait-only (no submission).
    function _requestVerify(address party, string memory presentationId, string memory presJson)
        internal
        returns (bytes32 reqId)
    {
        PartyEx memory p = parties[party];
        require(bytes(p.lei).length != 0, "NotRegistered");
        require(subscriptionId != 0 && donId != bytes32(0), "Functions config missing");

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(_source());

        // Inline JS expects: [baseUrl, partyHex, presentationId, expectedLEI, ...kvPairs]
        // If presJson != "" we pass kv "presentation=<json>"
        uint256 extra = bytes(presJson).length == 0 ? 0 : 1;
        string[] memory fullArgs = new string[](4 + extra);
        fullArgs[0] = baseUrl;
        fullArgs[1] = _addrToHex(party);
        fullArgs[2] = presentationId;
        fullArgs[3] = p.lei; // expectedLEI
        if (extra == 1) {
            fullArgs[4] = string.concat("presentation=", presJson);
        }
        req.setArgs(fullArgs);

        reqId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId);
        _gleifReqToParty[reqId] = party;
        emit GLEIFVerificationRequested(party, reqId, presentationId); // IPartyRegistry
    }

    // fulfillment: single uint256 (1 = trusted)
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory) internal override {
        address party = _gleifReqToParty[requestId];
        if (party == address(0)) return;

        uint256 ok = abi.decode(response, (uint256));
        bool trusted = (ok == 1);
        parties[party].isTrusted = trusted;

        emit PartyTrustUpdated(party, trusted);       // IPartyRegistry
        delete _gleifReqToParty[requestId];
    }

    // ---------------- Views ----------------
    function isTrusted(address party) external view returns (bool) { return parties[party].isTrusted; }

    function partyOf(address party) external view returns (Party memory) {
        PartyEx memory p = parties[party];
        return Party({ lei: p.lei, vleiHash: p.vleiHash, isTrusted: p.isTrusted });
    }

    // ---------------- Inline JS ----------------
    // Args = [baseUrl, partyHex, presentationId, expectedLEI, ...kvPairs]
    // If kvPairs contains "presentation=...", include it in POST body.
    // POST {baseUrl}/vlei/verify
    //  body: { presentationId, expectedLEI?, presentation? }
    // Response: { status: "verified" | "rejected" | "pending", lei?: string }
    // Returns uint256 1 or 0
    function _source() internal pure returns (string memory) {
        return string.concat(
            "function normBase(u){let s=String(u||\"\").trim(); if(!s) throw Error(\"base missing\"); ",
            "if(!/^https?:\\/\\//i.test(s)) s=\"http://\"+s; return s.replace(/\\/$/,\"\");}\n",
            "function makeU256(n){ const out=new Uint8Array(32); out[31]=Number(n)&255; return out; }\n",
            "function getKV(kvList,key){ for(const kv of kvList){ if(typeof kv==='string' && kv.startsWith(key+'=')) return kv.slice(key.length+1); } return ''; }\n",
            "function tryParseJSON(s){ try{ return JSON.parse(s); }catch(_){ return s; } }\n",
            "async function http(req){ try { return await Functions.makeHttpRequest(req); } catch(e){ return { error:String(e) }; } }\n",
            "const base = normBase(args[0]);\n",
            "const pid  = String(args[2]||\"\").trim();\n",
            "const exp  = String(args[3]||\"\").trim();\n",
            "if(!pid) throw Error('presentationId required');\n",
            "const kvPairs = args.slice(4);\n",
            "const presStr = kvPairs.length ? String(getKV(kvPairs,'presentation')) : '';\n",
            "const body = exp ? { presentationId: pid, expectedLEI: exp } : { presentationId: pid };\n",
            "if(presStr) body.presentation = tryParseJSON(presStr);\n",
            "const url = `${base}/vlei/verify`;\n",
            "const resp = await http({ url, method:'POST', data: body, headers: { 'Content-Type':'application/json' } });\n",
            "if(resp?.error) throw Error(`HTTP: ${resp.error}`);\n",
            "const s = resp?.data || {};\n",
            "let ok = (s.status === 'verified') && !!s.lei; if(exp) ok = ok && (s.lei === exp);\n",
            "return makeU256(ok ? 1 : 0);\n"
        );
    }

    // ---------------- Utils ----------------
    function _addrToHex(address a) private pure returns (string memory) {
        bytes20 data = bytes20(a);
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0"; str[1] = "x";
        for (uint i = 0; i < 20; i++) {
            str[2 + i*2]   = hexSymbols[uint8(data[i] >> 4)];
            str[3 + i*2]   = hexSymbols[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    function _bytes32ToHexString(bytes32 data) private pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(data[i]);
            str[2 + i*2]     = hexSymbols[b >> 4];
            str[3 + i*2]     = hexSymbols[b & 0x0f];
        }
        return string(str);
    }
}
