// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPaymentRouter.sol";
import "../interfaces/IInvoiceMarketplace.sol";

/// @title Payment/Marketplace Settlement Automation
/// @notice Chainlink Automation-compatible keeper that sweeps both:
///         - PaymentRouter for invoice settlement (remainingUsd8 > 0)
///         - InvoiceMarketplace for purchases (if listed)
/// @dev    Uses separate watchlists and batches mixed actions into a single upkeep.
contract PaymentSettlementAutomation {
  // --- Ownership ---
  address public owner;
  modifier onlyOwner(){ require(msg.sender==owner,"only owner"); _; }

  // --- Targets ---
  IPaymentRouter public router;
  IInvoiceMarketplace public market;

  // --- Watchlists ---
  uint256[] private routerWatch;
  mapping(uint256 => bool) private inRouter;

  uint256[] private marketWatch;
  mapping(uint256 => bool) private inMarket;

  // --- Limits ---
  uint256 public maxBatch = 10; // 1..50

  // --- Action packing ---
  enum Kind { Router, Market } // 0=Router, 1=Market
  struct Action { uint8 kind; uint256 tokenId; }

  // --- Events ---
  event OwnerTransferred(address indexed prev, address indexed curr);
  event RouterSet(address indexed r);
  event MarketSet(address indexed m);
  event WatchedRouter(uint256 indexed tokenId);
  event UnwatchedRouter(uint256 indexed tokenId);
  event WatchedMarket(uint256 indexed tokenId);
  event UnwatchedMarket(uint256 indexed tokenId);
  event ForceCheckRouter(uint256 indexed tokenId, bytes32 reqId);
  event ForceCheckMarket(uint256 indexed tokenId, bytes32 reqId);

  constructor(address _router){
    owner = msg.sender;
    router = IPaymentRouter(_router);
    emit RouterSet(_router);
  }

  // --- Admin ---
  function transferOwnership(address n) external onlyOwner { emit OwnerTransferred(owner,n); owner = n; }
  function setRouter(address r) external onlyOwner { router = IPaymentRouter(r); emit RouterSet(r); }
  function setMarketplace(address m) external onlyOwner { market = IInvoiceMarketplace(m); emit MarketSet(m); }
  function setMaxBatch(uint256 n) external onlyOwner { require(n>0 && n<=50, "range"); maxBatch = n; }

  // --- Manage Router watchlist ---
  function addRouterToken(uint256 tokenId) external onlyOwner {
    if (!inRouter[tokenId]) { inRouter[tokenId]=true; routerWatch.push(tokenId); emit WatchedRouter(tokenId); }
  }
  function removeRouterToken(uint256 tokenId) external onlyOwner {
    if (!inRouter[tokenId]) return;
    inRouter[tokenId]=false;
    emit UnwatchedRouter(tokenId);
  }
  function listRouterWatched() external view returns (uint256[] memory ids) { return routerWatch; }

  // --- Manage Market watchlist ---
  function addMarketToken(uint256 tokenId) external onlyOwner {
    if (!inMarket[tokenId]) { inMarket[tokenId]=true; marketWatch.push(tokenId); emit WatchedMarket(tokenId); }
  }
  function removeMarketToken(uint256 tokenId) external onlyOwner {
    if (!inMarket[tokenId]) return;
    inMarket[tokenId]=false;
    emit UnwatchedMarket(tokenId);
  }
  function listMarketWatched() external view returns (uint256[] memory ids) { return marketWatch; }

  // --- Chainlink Automation interface (compatible) ---
  /// @notice Keeper-compatible check; scans watchlists and builds a mixed action batch.
  function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
    uint256 count=0;
    Action[] memory actions = new Action[](maxBatch);

    // 1) Router: sweep only if an invoice still has remaining USD
    if (address(router) != address(0)) {
      for (uint256 i=0; i<routerWatch.length && count<maxBatch; i++){
        uint256 t = routerWatch[i];
        if (!inRouter[t]) continue;
        if (router.remainingUsd8(t) > 0) {
          actions[count] = Action({ kind: uint8(Kind.Router), tokenId: t });
          count++;
        }
      }
    }

    // 2) Market: sweep while token is listed (idempotent — marketplace tracks lastMsgId)
    if (address(market) != address(0)) {
      for (uint256 j=0; j<marketWatch.length && count<maxBatch; j++){
        uint256 t2 = marketWatch[j];
        if (!inMarket[t2]) continue;
        if (market.isListed(t2)) {
          actions[count] = Action({ kind: uint8(Kind.Market), tokenId: t2 });
          count++;
        }
      }
    }

    if (count > 0){
      // Pack (Action[] fullArray, uint256 count). performUpkeep will read only the prefix [0..count)
      return (true, abi.encode(actions, count));
    }
    return (false, "");
  }

  /// @notice Executes the mixed action batch: router sweeps and market sweeps.
  function performUpkeep(bytes calldata performData) external {
    (Action[] memory actions, uint256 count) = abi.decode(performData,(Action[],uint256));

    for (uint256 i=0; i<count; i++){
      Action memory a = actions[i];

      if (a.kind == uint8(Kind.Router)) {
        if (!inRouter[a.tokenId]) continue;
        if (address(router) == address(0)) continue;
        router.requestFiatSweep(a.tokenId);
      } else if (a.kind == uint8(Kind.Market)) {
        if (!inMarket[a.tokenId]) continue;
        if (address(market) == address(0)) continue;
        market.requestFiatSweepPurchase(a.tokenId);
      }
    }
  }

  // --- Manual kicks (useful during testing) ---
  function forceCheckRouter(uint256 tokenId) external onlyOwner {
    require(address(router)!=address(0), "router not set");
    bytes32 reqId = router.requestFiatSweep(tokenId);
    emit ForceCheckRouter(tokenId, reqId);
  }
  function forceCheckMarket(uint256 tokenId) external onlyOwner {
    require(address(market)!=address(0), "market not set");
    bytes32 reqId = market.requestFiatSweepPurchase(tokenId);
    emit ForceCheckMarket(tokenId, reqId);
  }
}
