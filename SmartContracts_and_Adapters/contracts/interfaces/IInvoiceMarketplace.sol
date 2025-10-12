// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IInvoiceMarketplace
/// @notice Minimal surface used by Automation against your marketplace.
interface IInvoiceMarketplace {
  /// @dev Triggers a Chainlink Functions sweep for marketplace bank receipts (e.g., CAMT.054).
  function requestFiatSweepPurchase(uint256 tokenId) external returns (bytes32);

  /// @dev Returns true if the token is currently listed for sale in the marketplace.
  function isListed(uint256 tokenId) external view returns (bool);
}
