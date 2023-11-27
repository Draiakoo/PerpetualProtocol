// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {PerpetualProtocol, IERC20} from "../src/PerpetualProtocol.sol";
import {MockOracle} from "./MockOracle.sol";
import {ERC20} from "@solady/src/tokens/ERC20.sol";

contract ERC20Mock is ERC20 {

    uint8 private _decimals;
    string private _name;
    string private _symbol;
    constructor(uint8 Decimals, string memory Name, string memory Symbol){
        _decimals = Decimals;
        _name = Name;
        _symbol = Symbol;
    }

    function name() public view override returns (string memory){
        return _name;
    }

    function symbol() public view override returns (string memory){
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract PerpetualProtocolTest is Test {
    PerpetualProtocol public protocol;
    MockOracle public oracle;
    ERC20Mock public usdcMock;
    ERC20Mock public wbtcMock;

    address public liquidityProvider = makeAddr("liquidityProvider");
    address public liquidityProvider2 = makeAddr("liquidityProvider2");
    address public trader = makeAddr("trader");

    uint256 public constant WBTC_DECIMALS = 10 ** 8;
    uint256 public constant USDC_DECIMALS = 10 ** 6;

    function setUp() public {
        oracle = new MockOracle(8, int256(10_000 * WBTC_DECIMALS));
        usdcMock = new ERC20Mock(6, "USDC", "USDC");
        wbtcMock = new ERC20Mock(8, "Wrapped Bitcoin", "WBTC");
        protocol = new PerpetualProtocol(15 ether, 80, IERC20(address(usdcMock)), IERC20(address(wbtcMock)), address(oracle), 1 days);
        usdcMock.mint(liquidityProvider, 100_000 * USDC_DECIMALS);
        usdcMock.mint(liquidityProvider2, 100_000 * USDC_DECIMALS);
        usdcMock.mint(trader, 100_000 * USDC_DECIMALS);

        skip(100 days);

        // Initial price for WBTC 30.000 USDC
        oracle.updatePrice(int256(30_000 * WBTC_DECIMALS));
    }

    function testDepositOfLiquidity() public {
        vm.startPrank(liquidityProvider);
        usdcMock.approve(address(protocol), 100_000 * USDC_DECIMALS);
        protocol.depositLiquidity(100_000 * USDC_DECIMALS);
        vm.stopPrank();
    }

    function testOpenPositionReverts() public {
        provideLiquidity(100_000 * USDC_DECIMALS);        // 100.000 $ but only 80.000 $ usable

        vm.startPrank(trader);
        // Revert when collateral or borrowing amount is 0
        vm.expectRevert(PerpetualProtocol.InvalidValues.selector);
        protocol.openPosition(false, 0, 2 * 10 ** 8);

        vm.expectRevert(PerpetualProtocol.InvalidValues.selector);
        protocol.openPosition(false, 100_000 * 10 ** 6, 0);

        // Revert when leverage is greater than 15
        usdcMock.approve(address(protocol), 1_500 * USDC_DECIMALS);
        vm.expectRevert(PerpetualProtocol.LeverageExceeded.selector);
        protocol.openPosition(false, 1_500 * USDC_DECIMALS, 1 * WBTC_DECIMALS);       // 1 BTC @ 30.000 $ -> 30.000 $, leverage 20

        // Revert when there is not enough available liquidity
        usdcMock.approve(address(protocol), 7_000 * USDC_DECIMALS);
        vm.expectRevert(PerpetualProtocol.NotEnoughLiquidity.selector);
        protocol.openPosition(false, 7_000 * USDC_DECIMALS, 3 * WBTC_DECIMALS);         // 3 BTC @ 30.000 $ -> 90.000 $, but available liquidity is 80.000$
        
        vm.stopPrank();
    }

    function testOpenPositionSuccess() public {
        provideLiquidity(100_000 * USDC_DECIMALS);        // 100.000 $ but only 80.000 $ usable
        vm.startPrank(trader);
        usdcMock.approve(address(protocol), 7_000 * USDC_DECIMALS);
        protocol.openPosition(false, 7_000 * USDC_DECIMALS, 1 * WBTC_DECIMALS); // 1 BTC @ 30.000 -> leverage 4.3
        vm.stopPrank();

        (bool isOpen, uint256 collateralAmount, uint256 borrowedAmountUnderlying, uint256 priceWhenBorrowed, bool isShort) = protocol.positions(trader);
        assertEq(isOpen, true);
        assertEq(collateralAmount, 7_000 ether);
        assertEq(borrowedAmountUnderlying, 1 ether);
        assertEq(priceWhenBorrowed, 30_000 ether);
        assertEq(isShort, false);
    }

    function testIncreasePositionSizeReverts() public {
        provideLiquidity(100_000 * USDC_DECIMALS);        // 100.000 $ but only 80.000 $ usable

        // First opens a position
        vm.startPrank(trader);
        usdcMock.approve(address(protocol), 1_000 * USDC_DECIMALS);
        protocol.openPosition(false, 1_000 * USDC_DECIMALS, 0.2 * 10 ** 8); // 0.2 BTC @ 30.000 -> 6 000 -> leverage 6x

        vm.expectRevert(PerpetualProtocol.InvalidValues.selector);
        protocol.increasePositionSize(0);

        vm.expectRevert(PerpetualProtocol.NotEnoughLiquidity.selector);
        protocol.increasePositionSize(5 * WBTC_DECIMALS);

        vm.expectRevert(PerpetualProtocol.LeverageExceeded.selector);
        protocol.increasePositionSize(1 * WBTC_DECIMALS);       // 1.2 BTC @ 30.000 -> 36.000 -> leverage 36x
        
        vm.stopPrank();
    }

    function testSameTraderDifferentPriceBorrowing() public {}

    function testDifferentTradersOpenPositions() public {}

    function testIncreaseCollateral() public {
        provideLiquidity(100_000 * USDC_DECIMALS);        // 100.000 $ but only 80.000 $ usable
        vm.startPrank(trader);
        usdcMock.approve(address(protocol), 7_000 * USDC_DECIMALS);
        protocol.openPosition(false, 7_000 * USDC_DECIMALS, 1 * WBTC_DECIMALS); // 1 BTC @ 30.000 -> leverage 4.3
        (, uint256 collateralAmount, , ,) = protocol.positions(trader);
        assertEq(collateralAmount, 7_000 ether);

        usdcMock.approve(address(protocol), 1_000 * USDC_DECIMALS);
        protocol.increaseCollateral(1_000 * USDC_DECIMALS);
        (, collateralAmount, , ,) = protocol.positions(trader);
        assertEq(collateralAmount, 8_000 ether);
        vm.stopPrank();
    }

    function testStalePrice() public {
        provideLiquidity(100_000 * USDC_DECIMALS);
        // 2 days passes without updating the price
        skip(2 days);

        // Trader tries to open the position
        vm.startPrank(trader);
        usdcMock.approve(address(protocol), 7_000 * USDC_DECIMALS);
        vm.expectRevert(PerpetualProtocol.StalePrice.selector);
        protocol.openPosition(false, 7_000 * USDC_DECIMALS, 1 * WBTC_DECIMALS); // 1 BTC @ 30.000 -> leverage 4.3
        vm.stopPrank();
    }

    function testWithdrawProfitTwoUsers() public {
        console.log(protocol.totalAssets());
        vm.startPrank(liquidityProvider);
        usdcMock.approve(address(protocol), 80_000 * USDC_DECIMALS);
        protocol.depositLiquidity(80_000 * USDC_DECIMALS);
        vm.stopPrank();
        console.log(protocol.totalAssets());
        vm.startPrank(liquidityProvider2);
        usdcMock.approve(address(protocol), 20_000 * USDC_DECIMALS);
        protocol.depositLiquidity(20_000 * USDC_DECIMALS);
        vm.stopPrank();

        // At this point liquidityProvider1 has 80% of the shares and the second 20%

        vm.startPrank(trader);
        usdcMock.approve(address(protocol), 10_000 * USDC_DECIMALS);
        protocol.openPosition(false, 10_000 * USDC_DECIMALS, 1 * WBTC_DECIMALS); // 1 BTC @ 30.000 -> leverage 3x
        vm.stopPrank();

        // Price of BTC drops to 20.000, that means that users's 10k of collateral now belong to LPs
        oracle.updatePrice(int256(20_000 * WBTC_DECIMALS));

        uint256 lp1BalanceBefore = usdcMock.balanceOf(liquidityProvider);
        uint256 lp2BalanceBefore = usdcMock.balanceOf(liquidityProvider2);

        vm.prank(liquidityProvider);
        protocol.withdrawLiquidity(1);

        vm.prank(liquidityProvider2);
        protocol.withdrawLiquidity(1);

        uint256 lp1BalanceAfter = usdcMock.balanceOf(liquidityProvider);
        uint256 lp2BalanceAfter = usdcMock.balanceOf(liquidityProvider2);

        assertEq(lp1BalanceAfter - lp1BalanceBefore, 8_000 * USDC_DECIMALS);
        assertEq(lp2BalanceAfter - lp2BalanceBefore, 2_000 * USDC_DECIMALS);
    }
    //////////////////////////////////////////////////////////////
    //////////////////      Helper funcitons       ///////////////
    //////////////////////////////////////////////////////////////

    function provideLiquidity(uint256 amount) internal {
        usdcMock.mint(liquidityProvider, amount);
        vm.startPrank(liquidityProvider);
        usdcMock.approve(address(protocol), amount);
        protocol.depositLiquidity(amount);
        vm.stopPrank();
    }

}
