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

    uint256 public constant WTB_DECIMALS = 10 ** 8;

    function setUp() public {
        oracle = new MockOracle(8, int256(10_000 * WTB_DECIMALS));
        usdcMock = new ERC20Mock(6, "USDC", "USDC");
        wbtcMock = new ERC20Mock(8, "Wrapped Bitcoin", "WBTC");
        protocol = new PerpetualProtocol(15 ether, 80, IERC20(address(usdcMock)), IERC20(address(wbtcMock)), address(oracle), 1 days);
        usdcMock.mint(trader, 100_000 * 10 ** 6);

        // Initial price for WBTC 30.000 USDC
        oracle.updatePrice(int256(30_000 * WTB_DECIMALS));
    }

    function testOpenPositionReverts() public {
        provideLiquidity(100 * WTB_DECIMALS);        // 100 WBTC

        vm.startPrank(trader);
        // Revert when collateral or borrowing amount is 0
        vm.expectRevert(PerpetualProtocol.InvalidValues.selector);
        protocol.openPosition(false, 0, 2 * 10 ** 8);

        vm.expectRevert(PerpetualProtocol.InvalidValues.selector);
        protocol.openPosition(false, 100_000 * 10 ** 6, 0);


        // usdcMock.approve(address(protocol));

    }

    function testNotEnoughLiquidity() public {}

    function testOpenPosition() public {}

    function testPositionAlreadyExisting() public {}

    //////////////////////////////////////////////////////////////
    //////////////////      Helper funcitons       ///////////////
    //////////////////////////////////////////////////////////////

    function provideLiquidity(uint256 amount) internal {
        wbtcMock.mint(liquidityProvider, amount);
        vm.startPrank(liquidityProvider);
        wbtcMock.approve(address(protocol), amount);
        protocol.depositLiquidity(amount);
        vm.stopPrank();
    }

}
