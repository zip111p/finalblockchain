// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IChainlinkAdapter {
    function getPrice() external view returns (uint256);
    function getProofOfReserve() external view returns (uint256);
    function decimals() external view returns (uint8);
}
