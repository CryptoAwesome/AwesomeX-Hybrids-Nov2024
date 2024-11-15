// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "erc721a/contracts/ERC721A.sol";
import "./interfaces/IWETH9.sol";
import "./lib/OracleLibrary.sol";
import "./lib/TickMath.sol";
import "./lib/constants.sol";

/// @title AwesomeX NFTs contract
contract AwesomeXNFTs is ERC721A, Ownable2Step {
    using SafeERC20 for IERC20;
    using Strings for uint8;

    // --------------------------- STATE VARIABLES --------------------------- //

    bool public isSaleActive;
    string private baseURI;
    string public contractURI;

    mapping (uint256 tokenId => uint8) public tiers;

    /// @notice Time used for TWAP calculation.
    uint32 public secondsAgo = 5 * 60;
    /// @notice Allowed deviation of the maxAmountIn from historical price.
    uint32 public deviation = 2000;

    // --------------------------- ERRORS & EVENTS --------------------------- //

    error SaleInactive();
    error IncorrectTier();
    error ZeroInput();
    error TWAP();
    error Prohibited();
    error Unauthorized();
    error NonExistentToken();

    event SaleStarted();
    event Mint(uint256 amount);
    event Claim(uint256 amount);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event ContractURIUpdated();

    // --------------------------- CONSTRUCTOR --------------------------- //

    constructor(address owner_, string memory contractURI_, string memory baseURI_)
        ERC721A("AwesomeX NFTs", "AWXN")
        Ownable(owner_)
    {
        if (bytes(contractURI_).length == 0) revert ZeroInput();
        if (bytes(baseURI_).length == 0) revert ZeroInput();
        contractURI = contractURI_;
        baseURI = baseURI_;
    }

    // --------------------------- PUBLIC FUNCTIONS --------------------------- //

    /// @notice Mints a specified amount of NFTs to the sender using AwesomeX.
    /// @param tieredNfts The list of NFT tiers to mint.
    function mintWithAwesomeX(uint8[] memory tieredNfts) external {
        if (!isSaleActive) revert SaleInactive();
        uint256 amount = tieredNfts.length;
        if (amount == 0) revert ZeroInput();
        (uint256 price, uint256 treasuryFee, uint256 launchpadFee, ) = _processNftMint(tieredNfts, amount);
        IERC20 awesomeX = IERC20(AWESOMEX);
        awesomeX.safeTransferFrom(msg.sender, address(this), price);
        awesomeX.safeTransferFrom(msg.sender, AWESOMEX_TREASURY, treasuryFee);
        awesomeX.safeTransferFrom(msg.sender, AWESOMEX_LAUNCHPAD, launchpadFee);
        _safeMint(msg.sender, amount);
        emit Mint(amount);
    }

    /// @notice Mints a specified amount of NFTs to the sender using TitanX.
    /// @param tieredNfts The list of NFT tiers to mint.
    /// @param titanXAmount Max TitanX amount to use for the swap.
    /// @param deadline Deadline for the transaction.
    function mintWithTitanX(uint8[] memory tieredNfts, uint256 titanXAmount, uint256 deadline) external {
        if (!isSaleActive) revert SaleInactive();
        uint256 amount = tieredNfts.length;
        if (amount == 0) revert ZeroInput();
        IERC20(TITANX).safeTransferFrom(msg.sender, address(this), titanXAmount);
        (, uint256 treasuryFee, uint256 launchpadFee, uint256 total) = _processNftMint(tieredNfts, amount);
        _swapTitanXForAwesomeX(titanXAmount, total, deadline);
        _disperseTokens(treasuryFee, launchpadFee);
        _safeMint(msg.sender, amount);
        emit Mint(amount);
    }

    /// @notice Mints a specified amount of NFTs to the sender using TitanX.
    /// @param tieredNfts The list of NFT tiers to mint.
    /// @param dragonXAmount Max DragonX amount to use for the swap.
    /// @param deadline Deadline for the transaction.
    function mintWithDragonX(uint8[] memory tieredNfts, uint256 dragonXAmount, uint256 deadline) external {
        if (!isSaleActive) revert SaleInactive();
        uint256 amount = tieredNfts.length;
        if (amount == 0) revert ZeroInput();
        IERC20(DRAGONX).safeTransferFrom(msg.sender, address(this), dragonXAmount);
        (, uint256 treasuryFee, uint256 launchpadFee, uint256 total) = _processNftMint(tieredNfts, amount);
        _swapDragonXForAwesomeX(dragonXAmount, total, deadline);
        _disperseTokens(treasuryFee, launchpadFee);
        _safeMint(msg.sender, amount);
        emit Mint(amount);
    }

    /// @notice Mints a specified amount of NFTs to the sender using ETH.
    /// @param tieredNfts The list of NFT tiers to mint.
    /// @param deadline Deadline for the transaction.
    function mintWithEth(uint8[] calldata tieredNfts, uint256 deadline) public payable {
        if (!isSaleActive) revert SaleInactive();
        uint256 amount = tieredNfts.length;
        if (amount == 0) revert ZeroInput();
        (, uint256 treasuryFee, uint256 launchpadFee, uint256 total) = _processNftMint(tieredNfts, amount);
        _swapETHForAwesomeX(total, deadline);
        _disperseTokens(treasuryFee, launchpadFee);
        _safeMint(msg.sender, amount);
        emit Mint(amount);
    }

    /// @notice Burns NFTs and claim locked AWX amount (less the burn fee).
    /// @param tokenIds The list of token IDs to claim and burn.
    function claim(uint256[] calldata tokenIds) external {
        uint256 amount = tokenIds.length;
        if (amount == 0) revert ZeroInput();
        address originalOwner = ownerOf(tokenIds[0]);
        if (originalOwner != msg.sender) revert Unauthorized();
        (uint256 totalClaim, uint256 launchpadFee) = _processNftBurn(tokenIds, amount, originalOwner);
        IERC20 awesomeX = IERC20(AWESOMEX);
        awesomeX.safeTransfer(AWESOMEX_LAUNCHPAD, launchpadFee);
        awesomeX.safeTransfer(msg.sender, totalClaim);
        emit Claim(amount);
    }

    // --------------------------- ADMINISTRATIVE FUNCTIONS --------------------------- //

    /// @notice Sets the base URI for the token metadata.
    /// @param uri The new base URI to set.
    function setBaseURI(string memory uri) external onlyOwner {
        if (bytes(uri).length == 0) revert ZeroInput();
        baseURI = uri;
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    /// @notice Sets the contract-level metadata URI.
    /// @param uri The new contract URI to set.
    function setContractURI(string memory uri) external onlyOwner {
        if (bytes(uri).length == 0) revert ZeroInput();
        contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @notice Toggles the sale state (active/inactive).
    function enableSale() external onlyOwner {
        isSaleActive = true;
        emit SaleStarted();
    }

    /// @notice Sets the number of seconds to look back for TWAP price calculations.
    /// @param limit The number of seconds to use for TWAP price lookback.
    function setSecondsAgo(uint32 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        secondsAgo = limit;
    }

    /// @notice Sets the allowed price deviation for TWAP checks.
    /// @param limit The allowed deviation in basis points (e.g., 500 = 5%).
    function setDeviation(uint32 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        if (limit > 10000) revert Prohibited();
        deviation = limit;
    }

    // --------------------------- VIEW FUNCTIONS --------------------------- //

    /// @notice Returns total number of minted NFTs.
    function totalMinted() external view returns (uint256) {
        return _totalMinted();
    }

    /// @notice Returns total number of burned NFTs.
    function totalBurned() external view returns (uint256) {
        return _totalBurned();
    }

    /// @notice Returns all token IDs owned by a specific account.
    /// @param account The address of the token owner.
    /// @return tokenIds An array of token IDs owned by the account.
    /// @dev Should not be called by contracts.
    function tokenIdsOf(address account) external view returns (uint256[] memory tokenIds) {
        uint256 totalTokenIds = _nextTokenId();
        uint256 userBalance = balanceOf(account);
        tokenIds = new uint256[](userBalance);
        if (userBalance == 0) return tokenIds;
        uint256 counter;
        for (uint256 tokenId = 1; tokenId < totalTokenIds; tokenId++) {
            if (_exists(tokenId) && ownerOf(tokenId) == account) {
                tokenIds[counter] = tokenId;
                counter++;
                if (counter == userBalance) return tokenIds;
            }
        }
    }

    /// @notice Returns the total number of NFTs per tier.
    /// @param start Token id to start with.
    /// @param limit Limit of the results returned.
    /// @return total An array where each index corresponds to the total NFTs for a specific tier.
    /// @dev Should not be called by contracts.
    function getTotalNftsPerTiers(uint256 start, uint256 limit) external view returns (uint256[] memory total) {
        uint256 totalTokenIds = _nextTokenId();
        uint256 end = start + limit > totalTokenIds ? totalTokenIds : start + limit; 
        total = new uint256[](24);
        for (uint256 tokenId = start; tokenId < end; tokenId++) {
            if (_exists(tokenId)) {
                total[tiers[tokenId] - 1]++;
            }
        }
    }

    /// @notice Returns the tiers of the NFTs.
    /// @param tokenIds An array of token ids to query.
    /// @return nftTiers An array of corresponding tiers.
    /// @dev Should not be called by contracts.
    function batchGetTiers(uint256[] memory tokenIds) external view returns (uint8[] memory nftTiers) {
        nftTiers = new uint8[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (_exists(tokenId)) {
                nftTiers[i] = tiers[tokenId];
            } else {
                revert NonExistentToken();
            }
        }
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        return string(abi.encodePacked(baseURI, tiers[tokenId].toString(), ".json"));
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721A) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // --------------------------- INTERNAL FUNCTIONS --------------------------- //

    function _startTokenId() internal view virtual override returns (uint256) {
        return 1;
    }

    function _processNftMint(uint8[] memory tieredNfts, uint256 amount) internal returns (uint256 price, uint256 treasuryFee, uint256 launchpadFee, uint256 total) {
        uint256 currentIndex = _nextTokenId();
        for (uint i = 0; i < amount; i++) {
            uint8 tier = tieredNfts[i];
            if (tier < MIN_TIER || tier > MAX_TIER) revert IncorrectTier();
            tiers[currentIndex + i] = tier;
            price += _getTierPrice(tier);
        }
        treasuryFee = price * TREASURY_FEE / PERCENTAGE_BASE;
        launchpadFee = price * LAUNCHPAD_FEE / PERCENTAGE_BASE;
        total = price + treasuryFee + launchpadFee;
    }

    function _processNftBurn(uint256[] memory tokenIds, uint256 amount, address originalOwner) internal returns (uint256 totalClaim, uint256 launchpadFee) {
        for (uint i = 0; i < amount; i++) {
            uint256 tokenId = tokenIds[i];
            uint8 tier = tiers[tokenId];
            if (ownerOf(tokenId) != originalOwner) revert Unauthorized();
            _burn(tokenId);
            totalClaim += _getTierPrice(tier);
        }
        launchpadFee = totalClaim * LAUNCHPAD_FEE_ON_CLAIM / PERCENTAGE_BASE;
        totalClaim -= launchpadFee;
    }

    function _getTierPrice(uint8 tier) internal pure returns (uint256) {
        uint8 modulo = tier % 3;
        if (modulo == 0) return ELITE_PRICE;
        if (modulo == 2) return GOLD_PRICE;
        return AWESOME_PRICE;
    }

    function _disperseTokens(uint256 treasuryFee, uint256 launchpadFee) internal {
        IERC20 awesomeX = IERC20(AWESOMEX);
        awesomeX.safeTransfer(AWESOMEX_TREASURY, treasuryFee);
        awesomeX.safeTransfer(AWESOMEX_LAUNCHPAD, launchpadFee);
    }

    function _swapETHForAwesomeX(uint256 minAmountOut, uint256 deadline) internal {
        IWETH9(WETH9).deposit{value: msg.value}();
        bytes memory path = abi.encodePacked(WETH9, POOL_FEE_1PERCENT, TITANX, POOL_FEE_1PERCENT, DRAGONX, POOL_FEE_1PERCENT, AWESOMEX);
        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: deadline,
            amountIn: msg.value,
            amountOutMinimum: minAmountOut
        });

        IERC20(WETH9).safeIncreaseAllowance(UNISWAP_V3_ROUTER, msg.value);
        uint256 amountOut = ISwapRouter(UNISWAP_V3_ROUTER).exactInput(params);
        if (amountOut > minAmountOut) {
            IERC20(AWESOMEX).safeTransfer(msg.sender, amountOut - minAmountOut);
        }
    }

    function _swapTitanXForAwesomeX(uint256 amountInMaximum, uint256 amountOut, uint256 deadline) internal {
        bytes memory path = abi.encodePacked(AWESOMEX, POOL_FEE_1PERCENT, DRAGONX, POOL_FEE_1PERCENT, TITANX);
        ISwapRouter.ExactOutputParams memory params = ISwapRouter.ExactOutputParams({
            path: path,
            recipient: address(this),
            deadline: deadline,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum
        });

        IERC20 titanX = IERC20(TITANX);
        titanX.safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountInMaximum);
        uint256 amountIn = ISwapRouter(UNISWAP_V3_ROUTER).exactOutput(params);
        if (amountIn < amountInMaximum) {
            uint256 diff = amountInMaximum - amountIn;
            titanX.safeTransfer(msg.sender, diff);
            titanX.safeDecreaseAllowance(UNISWAP_V3_ROUTER, diff);
        }
    }

    function _swapDragonXForAwesomeX(uint256 amountInMaximum, uint256 amountOut, uint256 deadline) internal {
        _twapCheckExactOutput(DRAGONX, AWESOMEX, amountInMaximum, amountOut);
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: DRAGONX,
            tokenOut: AWESOMEX,
            fee: POOL_FEE_1PERCENT,
            recipient: address(this),
            deadline: deadline,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        IERC20 dragonX = IERC20(DRAGONX);
        dragonX.safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountInMaximum);
        uint256 amountIn = ISwapRouter(UNISWAP_V3_ROUTER).exactOutputSingle(params);

        if (amountIn < amountInMaximum) {
            uint256 diff = amountInMaximum - amountIn;
            dragonX.safeTransfer(msg.sender, diff);
            dragonX.safeDecreaseAllowance(UNISWAP_V3_ROUTER, diff);
        }
    }

    function _twapCheckExactOutput(address tokenIn, address tokenOut, uint256 maxAmountIn, uint256 amountOut)
        internal
        view
    {
        uint32 _secondsAgo = secondsAgo;

        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(DRAGONX_AWX_POOL);
        if (oldestObservation < _secondsAgo) {
            _secondsAgo = oldestObservation;
        }

        (int24 arithmeticMeanTick,) = OracleLibrary.consult(DRAGONX_AWX_POOL, _secondsAgo);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        uint256 twapAmountIn =
            OracleLibrary.getQuoteForSqrtRatioX96(sqrtPriceX96, uint128(amountOut), tokenOut, tokenIn);

        uint256 upperBound = (maxAmountIn * (10000 + deviation)) / 10000;

        if (upperBound < twapAmountIn) revert TWAP();
    }
}
