// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "erc721a/contracts/interfaces/IERC721A.sol";

/// @title Interface for AwesomeX Hybrid NFTs
interface IAwesomeXHybridNFTs is IERC721A {
    function tokenIdsOf(address account) external view returns (uint256[] memory tokenIds);
    function tiers(uint256 tokenId) external view returns (uint8);
    function batchGetTiers(uint256[] memory tokenIds) external view returns (uint8[] memory nftTiers);
}
