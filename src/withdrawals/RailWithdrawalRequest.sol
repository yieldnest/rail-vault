// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {StakedRailStrategy} from "../StakedRailStrategy.sol";
import {RailWithdrawalBag} from "./RailWithdrawalBag.sol";

contract RailWithdrawalRequest is ERC721, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum RequestStatus {
        NONE,
        PENDING,
        QUEUED,
        CLAIMABLE,
        CLAIMED,
        CANCELLED
    }

    struct Request {
        uint256 shares;
        uint256 railEntitlement;
        uint256 claimed;
        address bag;
        RequestStatus status;
    }

    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    StakedRailStrategy public immutable stRail;
    IERC20 public immutable rail;
    uint256 public nextRequestId = 1;
    uint256 public firstUnresolvedRequestId = 1;
    mapping(uint256 => Request) public requests;

    event WithdrawalRequested(
        uint256 indexed requestId, address indexed owner, address indexed receiver, uint256 shares, address bag
    );
    event RequestQueued(uint256 indexed requestId, uint256 shares, uint256 railEntitlement);
    event RequestResolved(uint256 indexed requestId, uint256 railAmount);
    event RequestClaimed(uint256 indexed requestId, address indexed receiver, uint256 railAmount);
    event RequestCancelled(uint256 indexed requestId, address indexed receiver, uint256 shares);

    constructor(address admin, StakedRailStrategy stRail_, IERC20 rail_) ERC721("stRAIL Withdrawal Request", "stRAIL-WR") {
        stRail = stRail_;
        rail = rail_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function requestWithdrawal(uint256 shares, address receiver, bytes calldata)
        external
        nonReentrant
        returns (uint256 requestId, address bag)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        requestId = nextRequestId++;
        bag = address(new RailWithdrawalBag(rail, address(this)));
        requests[requestId] =
            Request({shares: shares, railEntitlement: 0, claimed: 0, bag: bag, status: RequestStatus.PENDING});

        IERC20(address(stRail)).safeTransferFrom(msg.sender, address(this), shares);
        _mint(receiver, requestId);
        emit WithdrawalRequested(requestId, msg.sender, receiver, shares, bag);
    }

    function markQueued(uint256 requestId, uint256 railEntitlement) external onlyRole(RESOLVER_ROLE) {
        Request storage request = requests[requestId];
        if (request.status != RequestStatus.PENDING) revert InvalidRequestStatus();
        request.railEntitlement = railEntitlement;
        request.status = RequestStatus.QUEUED;
        stRail.burnLockedShares(address(this), request.shares);
        emit RequestQueued(requestId, request.shares, railEntitlement);
    }

    function markResolved(uint256 requestId, uint256 railAmount) external onlyRole(RESOLVER_ROLE) {
        Request storage request = requests[requestId];
        if (request.status != RequestStatus.QUEUED) revert InvalidRequestStatus();
        if (railAmount != request.railEntitlement) revert InvalidRailAmount();
        request.status = RequestStatus.CLAIMABLE;
        emit RequestResolved(requestId, railAmount);
    }

    function cancelPending(uint256 requestId, address receiver) external nonReentrant {
        if (!_isAuthorized(ownerOf(requestId), msg.sender, requestId)) revert NotAuthorized();
        Request storage request = requests[requestId];
        if (request.status != RequestStatus.PENDING) revert InvalidRequestStatus();
        request.status = RequestStatus.CANCELLED;
        IERC20(address(stRail)).safeTransfer(receiver, request.shares);
        _burn(requestId);
        _advanceFirstUnresolved();
        emit RequestCancelled(requestId, receiver, request.shares);
    }

    function claim(uint256 requestId, address receiver) external nonReentrant returns (uint256 amount) {
        if (!_isAuthorized(ownerOf(requestId), msg.sender, requestId)) revert NotAuthorized();
        Request storage request = requests[requestId];
        if (request.status != RequestStatus.CLAIMABLE) revert InvalidRequestStatus();
        amount = request.railEntitlement - request.claimed;
        request.claimed = request.railEntitlement;
        request.status = RequestStatus.CLAIMED;
        RailWithdrawalBag(request.bag).release(receiver, amount);
        _burn(requestId);
        _advanceFirstUnresolved();
        emit RequestClaimed(requestId, receiver, amount);
    }

    function isPending(uint256 requestId) external view returns (bool) {
        return requests[requestId].status == RequestStatus.PENDING;
    }

    function isQueued(uint256 requestId) external view returns (bool) {
        return requests[requestId].status == RequestStatus.QUEUED;
    }

    function _advanceFirstUnresolved() internal {
        while (
            firstUnresolvedRequestId < nextRequestId
                && (
                    requests[firstUnresolvedRequestId].status == RequestStatus.CLAIMED
                        || requests[firstUnresolvedRequestId].status == RequestStatus.CANCELLED
                )
        ) {
            firstUnresolvedRequestId++;
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    error ZeroAmount();
    error ZeroAddress();
    error InvalidRequestStatus();
    error InvalidRailAmount();
    error NotAuthorized();
}
