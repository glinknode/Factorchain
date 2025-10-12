// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IInvoiceNFT.sol";
import "./interfaces/IPartyRegistry.sol";
import "./interfaces/IPaymentRouter.sol";
import "./interfaces/IISOMessageRouter.sol";
import "./interfaces/IRiskRouter.sol";

/**
 * @title InvoiceNFT
 * @notice ERC721-like minimal NFT specialized for invoice assignment.
 *  - ERC721 transfers (safe + non-safe) with PartyRegistry trust checks.
 *  - Mints & transfers gated by PartyRegistry.isTrusted(...):
 *      • minter (msg.sender) must be trusted
 *      • uploader (explicit param) must be trusted
 *      • recipient must be trusted
 *  - Auto-clear listing on any transfer AND emit ListingUpdated.
 *  - Router sync: calls PaymentRouter.updatePayTo on mint/transfer (if set).
 *  - Risk: on mint, calls RiskRouter.requestRisk(...) (async via DON); optional sync function provided.
 *  - ISO: on mint, calls ISOMessageRouter.requestISOMessage(..., TSIN_008, ...) to symbolize a Payee/Owner update.
 */
contract InvoiceNFT is IInvoiceNFT {   


    string public name;
    string public symbol;

    mapping(uint256 => address) private _ownerOf_;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function ownerOf(uint256 tokenId) public view override returns (address) {
        address o = _ownerOf_[tokenId]; require(o != address(0), "NFT: !exists"); return o;
    }

    function approve(address spender, uint256 tokenId) external {
        address o = ownerOf(tokenId);
        require(msg.sender == o || isApprovedForAll[o][msg.sender], "NFT: !auth");
        getApproved[tokenId] = spender;
        emit Approval(o, spender, tokenId);
    }

    function setApprovalForAll(address op, bool on) external {
        isApprovedForAll[msg.sender][op] = on;
        emit ApprovalForAll(msg.sender, op, on);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address o = ownerOf(tokenId);
        return (spender == o || isApprovedForAll[o][spender] || getApproved[tokenId] == spender);
    }

    // ERC721Receiver selector = 0x150b7a02
    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private returns (bool) {
        if (to.code.length == 0) return true;
        (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(0x150b7a02, msg.sender, from, tokenId, data));
        return ok && ret.length == 32 && bytes4(ret) == bytes4(0x150b7a02);
    }

    // --- Transfers ---

    // safeTransferFrom (3-arg)
    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        require(_isApprovedOrOwner(msg.sender, tokenId), "NFT: !auth");
        _transfer(from, to, tokenId, true, "");
    }

    // safeTransferFrom (4-arg)  <-- added
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external override {
        require(_isApprovedOrOwner(msg.sender, tokenId), "NFT: !auth");
        _transfer(from, to, tokenId, true, data);
    }

    // transferFrom (non-safe)
    function transferFrom(address from, address to, uint256 tokenId) external override {
        require(_isApprovedOrOwner(msg.sender, tokenId), "NFT: !auth");
        _transfer(from, to, tokenId, false, "");
    }

    // --- Domain storage ---
    IPartyRegistry      public registry;     // PartyRegistry with isTrusted(address) view
    IPaymentRouter      public router;       // PaymentRouter (updatePayTo)
    IRiskRouter         public riskRouter;   // RiskRouter (DON)
    IISOMessageRouter   public isoRouter;    // ISOMessageRouter (DON)

    uint256 public constant FLAG_NO_ASSIGN = 1 << 0;

    struct Invoice {
        uint256 amount;    // face amount in CCY minor units
        bytes3  ccy;       // "USD"=0x555344, "EUR"=0x455552
        uint64  dueDate;   // epoch seconds
        address debtor;    // debtor address (logical link)
        bytes32 docHash;   // off-chain doc hash
        bytes32 flags;     // bit flags
        bool    settled;   // true once settled

        uint16  discountBps;   // 0..10000
        uint16  riskBps;       // 0..10000 (initial; can be synced from RiskRouter)
        address kreditor;      // original creditor at mint
        address uploader;      // who uploaded the invoice (explicit param)
        bool    listed;        // for sale
        string  industry;      // e.g., "Healthcare"

        uint256 netPriceCached; // amount*(10000-discountBps)/10000
    }

    uint256 private _idSeq;
    mapping(uint256 => Invoice) private _inv;

    event InvoiceMinted(
        uint256 indexed tokenId,
        address indexed kreditor,
        address indexed debtor,
        uint256 amount,
        bytes3 ccy,
        uint64 dueDate,
        uint16 discountBps,
        uint16 riskBps,
        bool listed,
        string industry,
        address uploader
    );
    event InvoiceUpdated(uint256 indexed tokenId, bytes32 flags, bytes32 docHash, string industry);
    event InvoiceDiscountUpdated(uint256 indexed tokenId, uint16 discountBps);
    event ListingUpdated(uint256 indexed tokenId, bool listed, uint16 discountBps, uint256 netPrice);
    event Settled(uint256 indexed tokenId);
    event RiskSynced(uint256 indexed tokenId, uint16 riskBps, string evidenceURI);

    error TransferToUntrusted();
    error AssignBlockedByFlag();
    error AlreadySettled();
    error RouterAlreadySet();
    error RiskRouterAlreadySet();
    error ISORouterAlreadySet();

    constructor(address registry_) {
        name = "InvoiceNFT";
        symbol = "INV";
        registry = IPartyRegistry(registry_);
    }

    function setRouter(address routerAddr) external {
        if (address(router) != address(0)) revert RouterAlreadySet();
        router = IPaymentRouter(routerAddr);
    }
    function setRiskRouter(address riskRouterAddr) external {
        if (address(riskRouter) != address(0)) revert RiskRouterAlreadySet();
        riskRouter = IRiskRouter(riskRouterAddr);
    }
    function setISORouter(address isoRouterAddr) external {
        if (address(isoRouter) != address(0)) revert ISORouterAlreadySet();
        isoRouter = IISOMessageRouter(isoRouterAddr);
    }

    function _recalcNetPrice(Invoice storage inv_) internal {
        inv_.netPriceCached = (inv_.amount * (10_000 - inv_.discountBps)) / 10_000;
    }

    /**
     * @param uploader  business identity uploading this invoice (must be trusted)
     * @param to        initial NFT owner / payee (must be trusted)
     */
    function mintInvoice(
        address uploader,
        address to,
        uint256 amount,
        bytes3  ccy,
        uint64  dueDate,
        address debtor,
        bytes32 docHash,
        bytes32 flags,
        address kreditor,
        uint16  discountBps,
        uint16  riskBps,      // initial value; RiskRouter may compute asynchronously
        bool    listed,
        string calldata industry
    ) external returns (uint256 tokenId) {
        require(registry.isTrusted(msg.sender), "minter !trusted");
        require(registry.isTrusted(uploader),    "uploader !trusted");
        require(registry.isTrusted(to),          "to !trusted");
        require(discountBps <= 10_000 && riskBps <= 10_000, "bps");

        tokenId = ++_idSeq;
        _mint(to, tokenId);

        _inv[tokenId] = Invoice({
            amount: amount,
            ccy: ccy,
            dueDate: dueDate,
            debtor: debtor,
            docHash: docHash,
            flags: flags,
            settled: false,
            discountBps: discountBps,
            riskBps: riskBps,
            kreditor: kreditor,
            uploader: uploader,
            listed: listed,
            industry: industry,
            netPriceCached: 0
        });
        _recalcNetPrice(_inv[tokenId]);

        emit InvoiceMinted(
            tokenId, kreditor, debtor, amount, ccy, dueDate,
            discountBps, riskBps, listed, industry, uploader
        );

        // Sync pay-to for PaymentRouter (if configured)
        if (address(router) != address(0)) {
            router.updatePayTo(tokenId, to);
        }

        // Trigger RiskRouter (async). Args: [amountMinorUnits, ccy, industry, pastDelinquencies, discountBps]
        if (address(riskRouter) != address(0)) {
            string[] memory rargs = new string[](5);
            rargs[0] = _uToString(amount);
            rargs[1] = _bytes3ToString(ccy);
            rargs[2] = industry;
            rargs[3] = ""; // pastDelinquencies unknown at mint → empty
            rargs[4] = _uToString(discountBps);
            riskRouter.requestRisk(tokenId, rargs);
        }

        // ISO assignment/payee update: invoice already exists → TSIN_008
        if (address(isoRouter) != address(0)) {
            string[] memory isoArgs = new string[](7); // 7 elements for ISOMessageRouter
            isoArgs[0] = "event=OwnerChanged";
            isoArgs[1] = string(abi.encodePacked("newPayTo=", _addrToHex(to)));
            isoArgs[2] = string(abi.encodePacked("amount=", _uToString(amount)));
            isoArgs[3] = string(abi.encodePacked("ccy=", _bytes3ToString(ccy)));
            isoArgs[4] = string(abi.encodePacked("kreditor=", _addrToHex(kreditor)));
            isoArgs[5] = string(abi.encodePacked("uploader=", _addrToHex(uploader)));
            isoArgs[6] = string(abi.encodePacked("remRef=OWNER-CHANGED-", _uToString(tokenId)));
            isoRouter.requestISOMessage(tokenId, IISOMessageRouter.MessageType.TSIN_008, isoArgs);
        }
    }

    // Optional: sync riskBps from RiskRouter after fulfillment
    function syncRiskFromRouter(uint256 tokenId) external {
        address o = ownerOf(tokenId);
        require(msg.sender == o || msg.sender == address(this), "NFT: !auth");

        (bool exists, uint256 score, string memory evidenceURI) = riskRouter.riskByToken(tokenId);
        require(exists, "risk: none");
        uint16 rbps = uint16(score > 10000 ? 10000 : score);

        Invoice storage inv_ = _inv[tokenId];
        inv_.riskBps = rbps;

        emit RiskSynced(tokenId, rbps, evidenceURI);
    }

    function adminUpdateInvoice(
        uint256 tokenId,
        bytes32 newFlags,
        bytes32 newDocHash,
        string calldata newIndustry
    ) external {
        Invoice storage inv_ = _inv[tokenId];
        inv_.flags = newFlags;
        inv_.docHash = newDocHash;
        inv_.industry = newIndustry;
        _recalcNetPrice(inv_);
        emit InvoiceUpdated(tokenId, newFlags, newDocHash, newIndustry);
    }

    function ownerSetDiscountBps(uint256 tokenId, uint16 discountBps) external {
        require(ownerOf(tokenId) == msg.sender, "NFT: !owner");
        Invoice storage inv_ = _inv[tokenId];
        inv_.discountBps = discountBps;
        _recalcNetPrice(inv_);
        emit InvoiceDiscountUpdated(tokenId, discountBps);
    }

    function setListingStatus(uint256 tokenId, bool listed) external {
        require(ownerOf(tokenId) == msg.sender, "NFT: !owner");
        Invoice storage inv_ = _inv[tokenId];
        inv_.listed = listed;
        emit ListingUpdated(tokenId, listed, inv_.discountBps, inv_.netPriceCached);
    }

    function ownerListWithDiscount(uint256 tokenId, bool listed, uint16 discountBps) external {
        require(ownerOf(tokenId) == msg.sender, "NFT: !owner");
        Invoice storage inv_ = _inv[tokenId];
        inv_.discountBps = discountBps;
        inv_.listed = listed;
        _recalcNetPrice(inv_);
        emit InvoiceDiscountUpdated(tokenId, discountBps);
        emit ListingUpdated(tokenId, listed, discountBps, inv_.netPriceCached);
    }

    function markSettled(uint256 tokenId) external override {
        Invoice storage inv_ = _inv[tokenId];
        if (inv_.settled) revert AlreadySettled();
        inv_.settled = true;

        if (inv_.listed) {
            inv_.listed = false;
            emit ListingUpdated(tokenId, false, inv_.discountBps, inv_.netPriceCached);
        }
        emit Settled(tokenId);
    }

    // --- ERC721 internals ---
    function _mint(address to, uint256 id) internal {
        require(_ownerOf_[id] == address(0), "NFT: exists");
        _ownerOf_[id] = to;
        balanceOf[to]++;
        emit Transfer(address(0), to, id);
    }

    function _transfer(address from, address to, uint256 id, bool safe, bytes memory data) internal {
        require(ownerOf(id) == from, "NFT: !owner");
        require(to != address(0), "NFT: zero");
        require(_isApprovedOrOwner(msg.sender, id), "NFT: !auth");

        if (!registry.isTrusted(to)) revert TransferToUntrusted();
        if (((_inv[id].flags) & bytes32(FLAG_NO_ASSIGN)) != 0) revert AssignBlockedByFlag();

        balanceOf[from]--;
        balanceOf[to]++;
        _ownerOf_[id] = to;
        delete getApproved[id];

        // Auto-clear listing on transfer — emit as requested (plus Transfer)
        if (_inv[id].listed) {
            _inv[id].listed = false;
            emit ListingUpdated(id, false, _inv[id].discountBps, _inv[id].netPriceCached);
        }

        emit Transfer(from, to, id);

        if (address(router) != address(0)) {
            router.updatePayTo(id, to);
        }

        if (safe) {
            require(_checkOnERC721Received(from, to, id, data), "NFT: !receiver");
        }
    }

    // ---- IInvoiceNFT views ----
    function invoices(uint256 tokenId) external view override returns (
        uint256 amount,
        bytes3 ccy,
        uint64 dueDate,
        address debtor,
        bytes32 docHash,
        bytes32 flags,
        bool settled
    ) {
        Invoice memory inv_ = _inv[tokenId];
        return (inv_.amount, inv_.ccy, inv_.dueDate, inv_.debtor, inv_.docHash, inv_.flags, inv_.settled);
    }

    function invoiceMeta(uint256 tokenId) external view override returns (
        address kreditor,
        address uploader,
        uint16 discountBps,
        uint16 riskBps,
        bool listed
    ) {
        Invoice memory inv_ = _inv[tokenId];
        return (inv_.kreditor, inv_.uploader, inv_.discountBps, inv_.riskBps, inv_.listed);
    }

    function getNetPrice(uint256 tokenId) public view override returns (uint256) {
        return _inv[tokenId].netPriceCached;
    }

    // Alias for getNetPrice
    function netPrice(uint256 tokenId) external view override returns (uint256) {
        return getNetPrice(tokenId);
    }

    function getPricing(uint256 tokenId) external view override returns (
        uint256 amount,
        uint16 discountBps,
        uint16 riskBps,
        uint256 netPrice_
    ) {
        Invoice memory inv_ = _inv[tokenId];
        return (inv_.amount, inv_.discountBps, inv_.riskBps, inv_.netPriceCached);
    }

    function industryOf(uint256 tokenId) external view override returns (string memory) {
        return _inv[tokenId].industry;
    }

    // ---- utils ----
    function _uToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j=v; uint256 len; while (j!=0){ len++; j/=10; }
        bytes memory b=new bytes(len); uint256 k=len; while(v!=0){ k--; b[k]=bytes1(uint8(48 + (v%10))); v/=10; }
        return string(b);
    }
    function _addrToHex(address a) internal pure returns (string memory) {
        bytes20 b = bytes20(a);
        bytes16 hs = 0x30313233343536373839616263646566; // "0123456789abcdef"
        bytes memory str = new bytes(42);
        str[0] = "0"; str[1] = "x";
        for (uint256 i=0;i<20;i++){
            uint8 hi = uint8(b[i] >> 4);
            uint8 lo = uint8(b[i] & 0x0f);
            str[2+2*i]   = bytes1(hs[hi]);
            str[2+2*i+1] = bytes1(hs[lo]);
        }
        return string(str);
    }
    function _bytes3ToString(bytes3 b3) internal pure returns (string memory) {
        bytes memory b = new bytes(3);
        b[0] = b3[0]; b[1] = b3[1]; b[2] = b3[2];
        return string(b);
    }
}
