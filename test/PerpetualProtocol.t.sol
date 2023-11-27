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
    address public trader = makeAddr("trader");

    uint256 public constant WBTC_DECIMALS = 10 ** 8;
    uint256 public constant USDC_DECIMALS = 10 ** 6;

    function setUp() public {
        oracle = new MockOracle(8, int256(10_000 * WBTC_DECIMALS));
        usdcMock = new ERC20Mock(6, "USDC", "USDC");
        wbtcMock = new ERC20Mock(8, "Wrapped Bitcoin", "WBTC");
        protocol = new PerpetualProtocol(15 ether, 80, IERC20(address(usdcMock)), IERC20(address(wbtcMock)), address(oracle), 1 days);
        usdcMock.mint(liquidityProvider, 100_000 * USDC_DECIMALS);
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
        vm.expectRevert(PerpetualProtocol.InvalidValues.selector);
        protocol.openPosition(false, 1_500 * USDC_DECIMALS, 1 * WBTC_DECIMALS);       // 1 BTC @ 30.000 $ -> 30.000 $, leverage 20

        // Revert when there is not enough available liquidity
        usdcMock.approve(address(protocol), 7_000 * USDC_DECIMALS);
        vm.expectRevert(PerpetualProtocol.InvalidValues.selector);
        protocol.openPosition(false, 7_000 * USDC_DECIMALS, 3 * WBTC_DECIMALS);         // 3 BTC @ 30.000 $ -> 90.000 $, but available liquidity is 80.000$
        

    }

    function testOpenPositionSuccess() public {
        provideLiquidity(100_000 * USDC_DECIMALS);        // 100.000 $ but only 80.000 $ usable
        vm.startPrank(trader);
        usdcMock.approve(address(protocol), 7_000 * USDC_DECIMALS);
        protocol.openPosition(false, 7_000 * USDC_DECIMALS, 1 * WBTC_DECIMALS); // 1 BTC @ 30.000 -> leverage 4.3
        vm.stopPrank();
    }

    function testNotEnoughLiquidity() public {}

    function testOpenPosition() public {}

    function testPositionAlreadyExisting() public {}

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
