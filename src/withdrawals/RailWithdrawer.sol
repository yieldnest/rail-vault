// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {QueuedRail} from "../QueuedRail.sol";
import {RailWithdrawalRequest} from "./RailWithdrawalRequest.sol";

contract RailWithdrawer is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    IERC20 public immutable rail;
    QueuedRail public immutable queuedRail;
    RailWithdrawalRequest public immutable withdrawalRequest;

    mapping(uint256 => uint256) public qRailReserved;
    uint256 public totalReservedQRAIL;

    event Reserved(uint256 indexed requestId, uint256 amount);
    event Settled(uint256 indexed requestId, address indexed bag, uint256 amount);

    constructor(address admin, IERC20 rail_, QueuedRail queuedRail_, RailWithdrawalRequest withdrawalRequest_) {
        rail = rail_;
        queuedRail = queuedRail_;
        withdrawalRequest = withdrawalRequest_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function reserve(uint256 requestId, uint256 amount) external onlyRole(RESOLVER_ROLE) {
        if (qRailReserved[requestId] != 0) revert AlreadyReserved();
        if (unreservedQRAIL() < amount) revert InsufficientQRAIL();
        qRailReserved[requestId] = amount;
        totalReservedQRAIL += amount;
        emit Reserved(requestId, amount);
    }

    function settle(uint256 requestId, address bag, uint256 amount) external onlyRole(RESOLVER_ROLE) {
        if (qRailReserved[requestId] != amount) revert InvalidReservation();
        if (rail.balanceOf(address(this)) < amount) revert InsufficientRAIL();
        qRailReserved[requestId] = 0;
        totalReservedQRAIL -= amount;
        queuedRail.burn(address(this), amount);
        rail.safeTransfer(bag, amount);
        emit Settled(requestId, bag, amount);
    }

    function unreservedQRAIL() public view returns (uint256) {
        return queuedRail.balanceOf(address(this)) - totalReservedQRAIL;
    }

    error AlreadyReserved();
    error InvalidReservation();
    error InsufficientQRAIL();
    error InsufficientRAIL();
}
