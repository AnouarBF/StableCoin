// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "lib/forge-std/src/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {StableCoin} from "../../src/StableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine engine;
    StableCoin sc;
    ERC20Mock weth;
    ERC20Mock wbtc;

    uint96 private constant MAX_DEPOSIT_AMOUNT = type(uint96).max;
    uint96 public called;
    address[] public users;
    mapping(address => bool) private hasDeposited;

    constructor(DSCEngine _engine, StableCoin _sc) {
        engine = _engine;
        sc = _sc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    function depositCollateral(uint collateralSeed, uint amountCollateral)
        external
    {
        address USER = msg.sender;

        ERC20Mock collateral = _getValidCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_AMOUNT);

        vm.startPrank(USER);
        collateral.mint(USER, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        if (hasDeposited[USER]) {
            return;
        } else {
            users.push(USER);
            hasDeposited[USER] = true;
        }
    }

    function mintSc(uint amountToMint, uint addressSeed) external {
        address SENDER;
        uint usersLength = users.length;

        if (usersLength == 0) return;
        else SENDER = users[addressSeed % usersLength];

        (uint totalScMinted, uint collateredValueInUsd) = engine
            .getAccountInformation(SENDER);

        int256 maxDscToMint = (int256(collateredValueInUsd) / 2) -
            int256(totalScMinted);

        vm.assume(uint(maxDscToMint) > 0);
        amountToMint = bound(amountToMint, 0, uint(maxDscToMint));
        vm.assume(amountToMint > 0);

        vm.startPrank(SENDER);
        engine.mintSc(amountToMint);
        vm.stopPrank();
        called += 1;
    }

    function redeemCollateral(uint collateralSeed, uint amountCollateral)
        external
    {
        ERC20Mock collateral = _getValidCollateralFromSeed(collateralSeed);
        uint maxCollateral = engine.getCollateralAmountDeposited(
            msg.sender,
            address(collateral)
        );
        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        vm.assume(amountCollateral > 0);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    function _getValidCollateralFromSeed(uint _collateral)
        private
        view
        returns (ERC20Mock)
    {
        if (_collateral % 2 == 0) return weth;
        else return wbtc;
    }
}
