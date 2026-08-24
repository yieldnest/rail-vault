// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {QueuedRailToken} from "../tokens/QueuedRailToken.sol";
import {RailStakingWithdrawer} from "../RailStakingWithdrawer.sol";

contract RailWithdrawalNFT is ERC721, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    struct Request {
        uint256 assets;
        uint256 shares;
        uint256 queuedRail;
        bool claimed;
    }

    QueuedRailToken public immutable queuedRailToken;
    RailStakingWithdrawer public immutable withdrawer;
    uint256 public nextTokenId = 1;
    mapping(uint256 => Request) public requests;

    event WithdrawalRequestMinted(uint256 indexed tokenId, address indexed owner, uint256 assets, uint256 shares);
    event QueuedRailBagged(uint256 indexed tokenId, uint256 amount);
    event Claimed(uint256 indexed tokenId, address indexed receiver, uint256 amount);

    constructor(address admin, QueuedRailToken queuedRailToken_, RailStakingWithdrawer withdrawer_)
        ERC721("RAILx Withdrawal", "RAILxW")
    {
        queuedRailToken = queuedRailToken_;
        withdrawer = withdrawer_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function mintRequest(address to, uint256 assets, uint256 shares)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 tokenId)
    {
        tokenId = nextTokenId++;
        requests[tokenId] = Request({assets: assets, shares: shares, queuedRail: 0, claimed: false});
        _mint(to, tokenId);
        emit WithdrawalRequestMinted(tokenId, to, assets, shares);
    }

    function bagQueuedRail(uint256 tokenId, uint256 amount) external {
        _requireOwned(tokenId);
        Request storage request = requests[tokenId];
        if (request.claimed) revert AlreadyClaimed();
        if (request.queuedRail + amount > request.assets) revert TooMuchQueuedRail();

        IERC20(address(queuedRailToken)).safeTransferFrom(msg.sender, address(this), amount);
        request.queuedRail += amount;
        emit QueuedRailBagged(tokenId, amount);
    }

    function claim(uint256 tokenId, address receiver) external returns (uint256 amount) {
        if (!_isAuthorized(ownerOf(tokenId), msg.sender, tokenId)) revert NotAuthorized();
        Request storage request = requests[tokenId];
        if (request.claimed) revert AlreadyClaimed();
        if (request.queuedRail < request.assets) revert RequestNotFilled();

        request.claimed = true;
        amount = request.assets;
        queuedRailToken.approve(address(withdrawer), amount);
        withdrawer.redeemQueuedRail(receiver, amount);
        _burn(tokenId);
        emit Claimed(tokenId, receiver, amount);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    error AlreadyClaimed();
    error RequestNotFilled();
    error TooMuchQueuedRail();
    error NotAuthorized();
}
