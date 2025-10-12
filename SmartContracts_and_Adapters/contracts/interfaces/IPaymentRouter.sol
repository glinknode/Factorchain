// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPaymentRouter {
    function updatePayTo(uint256 tokenId, address newOwner) external;
    function requestFiatSweep(uint256 tokenId) external returns (bytes32);
    function remainingUsd8(uint256 tokenId) external view returns (uint256);
    function assetWhitelist(address token) external view returns (bool);
}
