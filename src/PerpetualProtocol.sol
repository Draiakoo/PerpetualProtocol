// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Custom, AggregatorV3Interface} from "./Interfaces.sol";

contract PerpetualProtocol is ERC4626 {

    using SafeERC20 for IERC20;

    error PositionAlreadyExisting();
    error InvalidValues();
    error NonExistingPosition();
    error StalePrice();

    struct Position {
        bool isOpen;
        uint256 collateralAmount;
        uint256 borrowedAmountUnderlyingToken;
        uint256 priceWhenBorrowed;
        bool isShort;
    }

    uint256 public immutable maxLeverage;
    uint256 public immutable utilizationCap;
    IERC20 public immutable collateralToken;
    IERC20 public immutable indexToken;
    address public immutable indexTokenPriceFeed;
    uint256 public immutable priceFeedHeartbeat;
    uint256 public immutable normalizingDecimalsCollateral;
    uint256 public immutable normalizingDecimalsIndex;
    uint256 public immutable normalizingDecimalsDataFeedIndex;
    mapping(address trader => Position position) public positions;
    uint256 public totalAmountBorrowedShorts;
    uint256 public averagePriceShorts;
    uint256 public totalAmountBorrowedLongs;
    uint256 public averagePriceLongs;

    modifier existingPosition(address trader){
        if(!positions[trader].isOpen){
            revert NonExistingPosition();
        }
        _;
    }

    constructor(
        // leverage must be in wad units. Eg. if maxLeverage is 15x, this immutable will be 15_00000000_0000000000
        uint256 _maxLeverage,
        uint256 _utilizationCap,
        IERC20 _collateralToken,
        IERC20 _indexToken,
        address _indexTokenPriceFeed,
        uint256 _priceFeedHeartbeat
    ) 
        ERC4626(_collateralToken)
        ERC20("PerpShares", "PS")
    {
        utilizationCap = _utilizationCap;
        maxLeverage = _maxLeverage;
        collateralToken = _collateralToken;
        indexToken = _indexToken;
        indexTokenPriceFeed = _indexTokenPriceFeed;
        priceFeedHeartbeat = _priceFeedHeartbeat;
        // It is assumed that decimals for both tokens and data feed are below or equal to 18
        normalizingDecimalsCollateral = 10 ** (18 - IERC20Custom(address(_collateralToken)).decimals());
        normalizingDecimalsIndex = 10 ** (18 - IERC20Custom(address(_indexToken)).decimals());
        normalizingDecimalsDataFeedIndex = 10 ** (18 - AggregatorV3Interface(_indexTokenPriceFeed).decimals());
    }
    
    // For liquidity providers
    function depositLiquidity(uint256 amountOfUsdc) external {
        deposit(amountOfUsdc, msg.sender);
    }

    function withdrawLiquidity(uint256 amountOfShares) external {
        redeem(amountOfShares, msg.sender, msg.sender);
    }

    event DEBUG(uint256);
    event DEBUG2(int256);

    // For traders

    // amountOfCollateral and amountToBorrow must be in their own decimals
    function openPosition(bool _isShort, uint256 amountOfCollateral, uint256 amountToBorrow) external {
        if(positions[msg.sender].isOpen){
            revert PositionAlreadyExisting();
        }
        uint256 normalizedCollateral = amountOfCollateral * normalizingDecimalsCollateral;
        uint256 normalizedIndex = amountToBorrow * normalizingDecimalsIndex;
        uint256 currentIndexPrice = getIndexPrice();
        // @notice amountToBorrow is in index token decimals, currentIndexPrice also
        if(
            amountOfCollateral == 0 || 
            amountToBorrow == 0 || 
            // normalizedIndex * currentIndexPrice > normalizedCollateral * maxLeverage ||
            normalizedIndex * currentIndexPrice > getUsableLiquidity() * 1 ether
        ){
            revert InvalidValues();
        }

        SafeERC20.safeTransferFrom(collateralToken, msg.sender, address(this), amountOfCollateral);

        positions[msg.sender] = Position({
            isOpen: true,
            collateralAmount: normalizedCollateral,
            borrowedAmountUnderlyingToken: normalizedIndex,
            priceWhenBorrowed: currentIndexPrice,
            isShort: _isShort
        });

        if(_isShort){
            averagePriceShorts = (totalAmountBorrowedShorts * averagePriceShorts + normalizedIndex * getIndexPrice()) / (totalAmountBorrowedShorts + normalizedIndex);
            totalAmountBorrowedShorts += normalizedIndex;
        } else {
            averagePriceLongs = (totalAmountBorrowedLongs * averagePriceLongs + normalizedIndex * getIndexPrice()) / (totalAmountBorrowedLongs + normalizedIndex);
            totalAmountBorrowedLongs += normalizedIndex;
        }
    }
    function increaseCollateral(uint256 collateralIncrease) external existingPosition(msg.sender){
        SafeERC20.safeTransferFrom(collateralToken, msg.sender, address(this), collateralIncrease);
        positions[msg.sender].collateralAmount += collateralIncrease * normalizingDecimalsCollateral;
    }

    function increasePositionSize(uint256 newAmountOfAssetsToBorrow) external existingPosition(msg.sender){
        uint256 oldAmountUnderlyingAssets = positions[msg.sender].borrowedAmountUnderlyingToken;
        uint256 oldPrice = positions[msg.sender].priceWhenBorrowed;
        uint256 currentIndexPrice = getIndexPrice();
        uint256 normalizedNewBorrow = newAmountOfAssetsToBorrow * normalizingDecimalsIndex;
        uint256 newBorrowedPrice = (oldAmountUnderlyingAssets * oldPrice + normalizedNewBorrow * currentIndexPrice) / (oldAmountUnderlyingAssets + normalizedNewBorrow);
        uint256 leverage;
        if(positions[msg.sender].isShort){
            uint256 newAveragePriceShorts = (totalAmountBorrowedShorts * averagePriceShorts + normalizedNewBorrow * currentIndexPrice) / (totalAmountBorrowedShorts + normalizedNewBorrow);
            totalAmountBorrowedShorts += normalizedNewBorrow;
            averagePriceShorts = newAveragePriceShorts;
            int256 pnl = (int256(newAveragePriceShorts) - int256(currentIndexPrice)) * int256(oldAmountUnderlyingAssets + normalizedNewBorrow);
            uint256 collateral = pnl < 0 ? positions[msg.sender].collateralAmount - uint256(pnl) : positions[msg.sender].collateralAmount;
            leverage = newBorrowedPrice * (oldAmountUnderlyingAssets + normalizedNewBorrow) / collateral;
        } else {
            uint256 newAveragePriceLongs = (totalAmountBorrowedLongs * averagePriceLongs + normalizedNewBorrow * currentIndexPrice) / (totalAmountBorrowedLongs + normalizedNewBorrow);
            totalAmountBorrowedLongs += normalizedNewBorrow;
            averagePriceLongs = newAveragePriceLongs;
            int256 pnl = (int256(currentIndexPrice) - int256(newAveragePriceLongs)) * int256(oldAmountUnderlyingAssets + normalizedNewBorrow);
            uint256 collateral = pnl < 0 ? positions[msg.sender].collateralAmount - uint256(pnl) : positions[msg.sender].collateralAmount;
            leverage = newBorrowedPrice * (oldAmountUnderlyingAssets + normalizedNewBorrow) / collateral;
        }
        if(
            normalizedNewBorrow * currentIndexPrice > getUsableLiquidity() ||
            leverage > maxLeverage
        ){
            revert InvalidValues();
        }
        positions[msg.sender].borrowedAmountUnderlyingToken = oldAmountUnderlyingAssets + normalizedNewBorrow;
        positions[msg.sender].priceWhenBorrowed = newBorrowedPrice;
    }

    function closePosition() external {}


    function getIndexPrice() public view returns(uint256){
        (, int256 price, , uint256 updatedAt, ) = AggregatorV3Interface(indexTokenPriceFeed).latestRoundData();

        if (updatedAt < block.timestamp - priceFeedHeartbeat) {
            revert StalePrice();
        }

        return uint256(price) * normalizingDecimalsDataFeedIndex;
    }

    function getUsableLiquidity() public view returns(uint256){
        return totalAssets();
    }


    ///////////////////////////////////////////////////////////////
    //////////////////      Internal function       ///////////////
    ///////////////////////////////////////////////////////////////

    function totalAssets() public view override returns(uint256){
        uint256 currentIndexPrice = getIndexPrice();
        int256 pnlShorts = int256(totalAmountBorrowedShorts) * (int256(averagePriceShorts) - int256(currentIndexPrice));
        int256 pnlLongs = int256(totalAmountBorrowedLongs) * (int256(currentIndexPrice) - int256(averagePriceLongs));
        return uint256(int256(collateralToken.balanceOf(address(this)) * normalizingDecimalsCollateral * utilizationCap / 100) + pnlLongs + pnlShorts);
    }
}
