// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract PerpetualProtocol is ERC4626{

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
        uint256 _maxLeverage,
        uint256 _utilizationCap,
        IERC20 _collateralToken,
        IERC20 _indexToken,
        address _indexTokenPriceFeed,
        uint256 _priceFeedHeartbeat
    ) 
        ERC4626(_indexToken)
        ERC20("PerpShares", "PS")
    {
        utilizationCap = _utilizationCap;
        maxLeverage = _maxLeverage;
        collateralToken = _collateralToken;
        indexToken = _indexToken;
        indexTokenPriceFeed = _indexTokenPriceFeed;
        priceFeedHeartbeat = _priceFeedHeartbeat;
    }
    
    // For liquidity providers
    function depositLiquidity(uint256 amountOfWbtc) external {
        deposit(amountOfWbtc, msg.sender);
    }

    function withdrawLiquidity(uint256 amountOfShares) external {
        redeem(amountOfShares, msg.sender, msg.sender);
    }


    // For traders

    function openPosition(bool _isShort, uint256 amountOfCollateral, uint256 amountToBorrow) external {
        if(positions[msg.sender].isOpen){
            revert PositionAlreadyExisting();
        }
        uint256 currentIndexPrice = getIndexPrice();
        // @notice amountToBorrow is in index token decimals, currentIndexPrice also
        if(
            amountOfCollateral == 0 || 
            amountToBorrow == 0 || 
            amountToBorrow * currentIndexPrice > amountOfCollateral * maxLeverage ||
            amountToBorrow * currentIndexPrice > getUsableLiquidity()
        ){
            revert InvalidValues();
        }

        SafeERC20.safeTransferFrom(collateralToken, msg.sender, address(this), amountOfCollateral);

        positions[msg.sender] = Position({
            isOpen: true,
            collateralAmount: amountOfCollateral,
            borrowedAmountUnderlyingToken: amountToBorrow,
            priceWhenBorrowed: currentIndexPrice,
            isShort: _isShort
        });

        if(_isShort){
            averagePriceShorts = (totalAmountBorrowedShorts * averagePriceShorts + amountToBorrow * getIndexPrice()) / (totalAmountBorrowedShorts + amountToBorrow);
            totalAmountBorrowedShorts += amountToBorrow;
        } else {
            averagePriceLongs = (totalAmountBorrowedLongs * averagePriceLongs + amountToBorrow * getIndexPrice()) / (totalAmountBorrowedLongs + amountToBorrow);
            totalAmountBorrowedLongs += amountToBorrow;
        }
    }
    function increaseCollateral(uint256 collateralIncrease) external existingPosition(msg.sender){
        SafeERC20.safeTransferFrom(collateralToken, msg.sender, address(this), collateralIncrease);
        positions[msg.sender].collateralAmount += collateralIncrease;
    }

    function increasePositionSize(uint256 newAmountOfAssetsToBorrow) external existingPosition(msg.sender){
        uint256 oldAmountUnderlyingAssets = positions[msg.sender].borrowedAmountUnderlyingToken;
        uint256 oldPrice = positions[msg.sender].priceWhenBorrowed;
        uint256 currentIndexPrice = getIndexPrice();
        uint256 newBorrowedPrice = (oldAmountUnderlyingAssets * oldPrice + newAmountOfAssetsToBorrow * currentIndexPrice) / (oldAmountUnderlyingAssets + newAmountOfAssetsToBorrow);
        uint256 leverage;
        if(positions[msg.sender].isShort){
            uint256 newAveragePriceShorts = (totalAmountBorrowedShorts * averagePriceShorts + newAmountOfAssetsToBorrow * currentIndexPrice) / (totalAmountBorrowedShorts + newAmountOfAssetsToBorrow);
            totalAmountBorrowedShorts += newAmountOfAssetsToBorrow;
            averagePriceShorts = newAveragePriceShorts;
            int256 pnl = (int256(newAveragePriceShorts) - int256(currentIndexPrice)) * int256(oldAmountUnderlyingAssets + newAmountOfAssetsToBorrow);
            uint256 collateral = pnl < 0 ? positions[msg.sender].collateralAmount - uint256(pnl) : positions[msg.sender].collateralAmount;
            leverage = newBorrowedPrice * (oldAmountUnderlyingAssets + newAmountOfAssetsToBorrow) / collateral;
        } else {
            uint256 newAveragePriceLongs = (totalAmountBorrowedLongs * averagePriceLongs + newAmountOfAssetsToBorrow * currentIndexPrice) / (totalAmountBorrowedLongs + newAmountOfAssetsToBorrow);
            totalAmountBorrowedLongs += newAmountOfAssetsToBorrow;
            averagePriceLongs = newAveragePriceLongs;
            int256 pnl = (int256(currentIndexPrice) - int256(newAveragePriceLongs)) * int256(oldAmountUnderlyingAssets + newAmountOfAssetsToBorrow);
            uint256 collateral = pnl < 0 ? positions[msg.sender].collateralAmount - uint256(pnl) : positions[msg.sender].collateralAmount;
            leverage = newBorrowedPrice * (oldAmountUnderlyingAssets + newAmountOfAssetsToBorrow) / collateral;
        }
        if(
            newAmountOfAssetsToBorrow * currentIndexPrice > getUsableLiquidity() ||
            leverage > maxLeverage
        ){
            revert InvalidValues();
        }
        positions[msg.sender].borrowedAmountUnderlyingToken = oldAmountUnderlyingAssets + newAmountOfAssetsToBorrow;
        positions[msg.sender].priceWhenBorrowed = newBorrowedPrice;
    }

    function closePosition() external {}


    function getIndexPrice() public view returns(uint256){
        (, int256 price, , uint256 updatedAt, ) = AggregatorV3Interface(indexTokenPriceFeed).latestRoundData();

        if (updatedAt < block.timestamp - priceFeedHeartbeat) {
            revert StalePrice();
        }

        return uint256(price);
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
        return uint256(int256(collateralToken.balanceOf(address(this)) * utilizationCap / 100) + pnlLongs + pnlShorts);
    }
}
