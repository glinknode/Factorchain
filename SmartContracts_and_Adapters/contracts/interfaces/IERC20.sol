// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal ERC20 interface for Remix interactions
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

}
