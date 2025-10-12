// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IInvoiceNFT {
  // --- ERC721 minimal surface used externally ---
  event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
  event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
  event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

  function ownerOf(uint256 tokenId) external view returns (address);
  function approve(address spender, uint256 tokenId) external;
  function setApprovalForAll(address operator, bool approved) external;
  function transferFrom(address from, address to, uint256 tokenId) external;
  function safeTransferFrom(address from, address to, uint256 tokenId) external;
  function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;

  // --- Domain ops expected by router/marketplace ---
  function markSettled(uint256 tokenId) external;

  // --- Views required across the system (router/marketplace/UX) ---
  function invoices(uint256 tokenId) external view returns (
    uint256 amount,
    bytes3 ccy,
    uint64 dueDate,
    address debtor,
    bytes32 docHash,
    bytes32 flags,
    bool settled
  );

  function invoiceMeta(uint256 tokenId) external view returns (
    address kreditor,
    address uploader,
    uint16 discountBps,
    uint16 riskBps,
    bool listed
  );

  function getNetPrice(uint256 tokenId) external view returns (uint256);
  function netPrice(uint256 tokenId) external view returns (uint256);

  function getPricing(uint256 tokenId) external view returns (
    uint256 amount,
    uint16 discountBps,
    uint16 riskBps,
    uint256 netPrice
  );

  function industryOf(uint256 tokenId) external view returns (string memory);
}
