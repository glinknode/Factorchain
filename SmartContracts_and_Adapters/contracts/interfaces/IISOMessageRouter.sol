// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IISOMessageRouter {
  // Keep enum in the same order as your implementation
  enum MessageType { TSIN_006, TSIN_007, TSIN_008, PACS_008, CAMT_054 }

  /**
   * Request an ISO/TSIN message build/store.
   * @param tokenId  Invoice NFT id
   * @param msgType  One of the supported message types
   * @param args     Flexible key=value args consumed by the inline JS/microservice
   * @return requestId  Chainlink Functions requestId
   */
  function requestISOMessage(
    uint256 tokenId,
    MessageType msgType,
    string[] calldata args
  ) external returns (bytes32 requestId);
}
