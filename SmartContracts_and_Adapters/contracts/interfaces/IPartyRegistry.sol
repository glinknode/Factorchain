// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPartyRegistry {
    // -------- Data --------
    struct Party {
        string  lei;        // LEI code
        bytes32 vleiHash;   // hash/fingerprint of vLEI credential (off-chain)
        bool    isTrusted;  // set true after successful verification
    }

    // -------- Events (emitted by implementation) --------
    event Config(uint64 subscriptionId, bytes32 donId, uint32 gasLimit);
    event BaseUrl(string baseUrl);

    event PartyRegistered(address indexed party, string lei, bytes32 vleiHash);
    event PartyMetaUpdated(address indexed party, string newLei, bytes32 newVleiHash);

    // Emitted when a Chainlink Functions request is kicked off
    event GLEIFVerificationRequested(address indexed party, bytes32 reqId, string presentationId);

    // Auto flow helper (presentationId generated on-chain)
    event AutoVerificationRequested(address indexed party, string presentationId);

    // Result of verification (via Functions fulfillment)
    event PartyTrustUpdated(address indexed party, bool trusted);

    // -------- Admin / Config --------
    function setFunctionsConfig(uint64 subId, bytes32 donId, uint32 gasLimit) external;
    function setBaseUrl(string calldata base) external;

    // -------- Core --------
    /// Register caller with LEI + vLEI hash (no verification triggered)
    function registerParty(string calldata lei, bytes32 vleiHash) external;

    /// Register caller and immediately trigger verification.
    /// Contract generates presentationId and compact presentation JSON internally.
    function registerAndVerifyAuto(string calldata lei, bytes32 vleiHash) external returns (bytes32 reqId);


    // -------- Views --------
    function isTrusted(address party) external view returns (bool);

    function partyOf(address party) external view returns (Party memory);
}
