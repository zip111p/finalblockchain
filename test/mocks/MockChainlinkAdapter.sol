// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChainlinkAdapter} from "../../src/interfaces/IChainlinkAdapter.sol";

contract MockChainlinkAdapter is IChainlinkAdapter {
    uint256 public price;
    uint256 public reserve;

    constructor(uint256 price_, uint256 reserve_) {
        price = price_;
        reserve = reserve_;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }

    function getProofOfReserve() external view returns (uint256) {
        return reserve;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function setReserve(uint256 r) external {
        reserve = r;
    }
}
