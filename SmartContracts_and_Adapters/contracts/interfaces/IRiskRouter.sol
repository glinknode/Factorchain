// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRiskRouter {
  function requestRisk(uint256 tokenId, string[] calldata args) external returns (bytes32 requestId);
  function riskByToken(uint256 tokenId) external view returns (bool exists, uint256 score, string memory evidenceURI);
}
