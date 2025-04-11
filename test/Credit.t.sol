// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {CreditLiquiditySystem} from "../src/CreditLiquiditySystem.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../lib/openzeppelin-contracts/contracts/mocks/MockERC20.sol";

contract ProjectTest is Test {
    CreditLiquiditySystem creditLiquiditySystem;
    address user = address(0x123);
    uint256 TOKENS_COUNT = 5;
    MockERC20[5] tokens;
    address[5] priceFeeds;

    function setUp() public {
        // Deploy mock tokens and mock price feed addresses
        for (uint256 i = 0; i < TOKENS_COUNT; i++) {
            tokens[i] = new MockERC20(
                string(abi.encodePacked("Token", i)),
                string(abi.encodePacked("TKN", i)),
                18
            );
            priceFeeds[i] = address(uint160(i + 100));
        }

        // Deploy the CreditLiquiditySystem contract
        address[5] memory tokenAddresses;
        for (uint256 i = 0; i < TOKENS_COUNT; i++) {
            tokenAddresses[i] = address(tokens[i]);
        }
        creditLiquiditySystem = new CreditLiquiditySystem(tokenAddresses, priceFeeds);

        // Label addresses for better debugging
        vm.label(user, "User");
        for (uint256 i = 0; i < TOKENS_COUNT; i++) {
            vm.label(address(tokens[i]), string(abi.encodePacked("Token", i)));
            vm.label(priceFeeds[i], string(abi.encodePacked("PriceFeed", i)));
        }
    }

    function testAddLiquidity() public {
        uint256[] memory amounts = new uint256[](TOKENS_COUNT);
        for (uint256 i = 0; i < TOKENS_COUNT; i++) {
            amounts[i] = 1000 * 10 ** 18;
            tokens[i].mint(user, amounts[i]); // Mint tokens to the user
            vm.prank(user);
            tokens[i].approve(address(creditLiquiditySystem), amounts[i]);
        }

        vm.prank(user);
        uint256 lpTokens = creditLiquiditySystem.addLiquidity(amounts);

        assertEq(lpTokens, amounts[0], "LP tokens minted incorrectly");
        for (uint256 i = 0; i < TOKENS_COUNT; i++) {
            assertEq(
                tokens[i].balanceOf(address(creditLiquiditySystem)),
                amounts[i],
                "Token balance mismatch in contract"
            );
        }
    }

    function testRemoveLiquidity() public {
        uint256[] memory amounts = new uint256[](TOKENS_COUNT);
        for (uint256 i = 0; i < TOKENS_COUNT; i++) {
            amounts[i] = 1000 * 10 ** 18;
            tokens[i].mint(user, amounts[i]); // Mint tokens to the user
            vm.prank(user);
            tokens[i].approve(address(creditLiquiditySystem), amounts[i]);
        }

        vm.prank(user);
        uint256 lpTokens = creditLiquiditySystem.addLiquidity(amounts);

        vm.prank(user);
        uint256[] memory returnedTokens = creditLiquiditySystem.removeLiquidity(lpTokens);

        for (uint256 i = 0; i < TOKENS_COUNT; i++) {
            assertEq(
                returnedTokens[i],
                amounts[i],
                "Returned token amount mismatch"
            );
            assertEq(
                tokens[i].balanceOf(user),
                amounts[i],
                "User token balance mismatch after removal"
            );
        }
    }

    function testDepositAndBorrow() public {
        uint256 collateralAmount = 1000 * 10 ** 18;
        uint256 borrowAmount = 500 * 10 ** 18;
        uint256 timePeriod = 30 days;

        tokens[0].mint(user, collateralAmount);
        vm.prank(user);
        tokens[0].approve(address(creditLiquiditySystem), collateralAmount);

        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(tokens[0]);
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = collateralAmount;

        vm.prank(user);
        creditLiquiditySystem.depositAndBorrow(
            collateralTokens,
            collateralAmounts,
            address(tokens[1]),
            borrowAmount,
            timePeriod
        );

        assertEq(
            tokens[1].balanceOf(user),
            borrowAmount,
            "Borrowed token amount mismatch"
        );
    }

    function testRepayAndWithdraw() public {
        uint256 collateralAmount = 1000 * 10 ** 18;
        uint256 borrowAmount = 500 * 10 ** 18;
        uint256 timePeriod = 30 days;

        tokens[0].mint(user, collateralAmount);
        vm.prank(user);
        tokens[0].approve(address(creditLiquiditySystem), collateralAmount);

        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(tokens[0]);
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = collateralAmount;

        vm.prank(user);
        creditLiquiditySystem.depositAndBorrow(
            collateralTokens,
            collateralAmounts,
            address(tokens[1]),
            borrowAmount,
            timePeriod
        );

        tokens[1].mint(user, borrowAmount);
        vm.prank(user);
        tokens[1].approve(address(creditLiquiditySystem), borrowAmount);

        vm.prank(user);
        creditLiquiditySystem.repayAndWithdraw(0, address(tokens[0]), collateralAmount);

        assertEq(
            tokens[0].balanceOf(user),
            collateralAmount,
            "Collateral withdrawal mismatch"
        );
    }

    function testCalculateCreditScore() public {
        uint256 collateralAmount = 1000 * 10 ** 18;
        uint256 borrowAmount = 500 * 10 ** 18;
        uint256 timePeriod = 30 days;

        tokens[0].mint(user, collateralAmount);
        vm.prank(user);
        tokens[0].approve(address(creditLiquiditySystem), collateralAmount);

        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(tokens[0]);
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = collateralAmount;

        vm.prank(user);
        creditLiquiditySystem.depositAndBorrow(
            collateralTokens,
            collateralAmounts,
            address(tokens[1]),
            borrowAmount,
            timePeriod
        );

        vm.warp(block.timestamp + timePeriod); // Simulate time passing

        tokens[1].mint(user, borrowAmount);
        vm.prank(user);
        tokens[1].approve(address(creditLiquiditySystem), borrowAmount);

        vm.prank(user);
        creditLiquiditySystem.repayAndWithdraw(0, address(tokens[0]), 0);

        vm.prank(user);
        creditLiquiditySystem.calculateCreditScore(user);

        uint256 creditScore = creditLiquiditySystem.getCreditScore(user);
        assertGt(creditScore, 0, "Credit score calculation failed");
    }
}