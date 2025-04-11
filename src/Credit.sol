// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from '../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract CreditLiquiditySystem is ERC20, ReentrancyGuard {

    ////////////////////////////////////
    ////// CONSTANTS & IMMUTABLES //////
    ////////////////////////////////////

    uint256 constant TOKENS_COUNT = 5;
    uint256 constant PERCENTAGE_PER_TOKEN = 20;
    uint256 FEE_PERCENTAGE = 150;
    uint256 FEE_DENOMINATOR = 10000;
    uint256 constant PRECISION = 1e18;
    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 DEBT_TIME_NORMALISER = 172800000;
    uint256 DEBT_UTILISATION_CONSTANT = 52e18;
    uint256 LOG_FACTOR = 144e16;
    uint256 REFERENCE_LOAN_SIZE = 1000e18;

    /////////////////////////////
    ////// STATE VARIABLES //////
    /////////////////////////////

    IERC20[TOKENS_COUNT] public supportedTokens;
    bool public isInitialized;

    /////////////////////
    ////// STRUCTS //////
    /////////////////////

    /// @notice This struct holds the user information of the deposited collateral.
    /// @dev The `hasActiveCollateral` is set to true when the user deposits any collateral.
    /// @dev The `depositedTokens` array is used to keep track of the tokens deposited by the user.
    /// @dev The `tokenBalances` mapping is used to keep track of the amount of each token deposited by the user.

    struct UserCollateral {
        mapping(address => uint256) tokenBalances;
        address[] depositedTokens;
        bool hasActiveCollateral;
    }

    /// @notice This struct holds the user information of the borrowed debt.
    /// @dev The `actualRepaymentTimestamp` is set to 0 when the debt is created and updated when the debt is repaid.
    /// @dev The `isRepaid` is set to true when the debt is repaid.
    /// @dev The `interestRate` is set when the debt is created and used to calculate the interest on the debt.
    /// @dev The `timePeriod` is set when the debt is created and used to calculate the interest on the debt.
    /// @dev The `timestamp` is set when the debt is created and used to calculate the interest on the debt.
    /// @dev The `debtToken` is the address of the token borrowed by the user.
    /// @dev The `amount` is the amount of the token borrowed by the user.

    struct DebtPosition {
        address debtToken;
        uint256 amount;
        uint256 timestamp;
        uint256 timePeriod;
        uint256 interestRate;
        uint256 actualRepaymentTimestamp;
        bool isRepaid;
    }

    //////////////////////
    ////// MAPPINGS //////
    //////////////////////

    /// MAPPINGS FOR LIQUIDITY PROVIDERS

    /// @dev The `liquidityProviderDeposits` mapping is used to keep track of the deposits made by the liquidity providers.

    mapping(address => uint256[]) public liquidityProviderDeposits;

    /// MAPPINGS FOR USERS

    /// @dev The `userCollateral` mapping is used to keep track of the collateral deposits made by the users.
    /// @dev The `userDebts` mapping is used to keep track of the debts taken by the users.
    /// @dev The `userCreditScore` mapping is used to keep track of the credit score of the users.
    /// @dev The `isTokenSupported` mapping is used to check if the token is supported in the system.
    /// @dev The `tokenPriceFeeds` mapping is used to get the price of the token in USD.
    /// @dev The `accumulatedFees` mapping is used to keep track of the fees accumulated for each token.

    mapping(address => UserCollateral) public userCollateral;
    mapping(address => DebtPosition[]) public userDebts;
    mapping(address => uint256) public userCreditScore;
    mapping(address => bool) public isTokenSupported;
    mapping(address => address) public tokenPriceFeeds;
    mapping(IERC20 => uint256) public accumulatedFees;

    ////////////////////
    ////// EVENTS //////
    ////////////////////

    event CollateralDeposited(address user, address token, uint256 amount);
    event DebtTaken(address user, address token, uint256 amount);
    event DebtRepaid(address user, uint256 debtIndex);
    event CollateralWithdrawn(address user, address token, uint256 amount);
    event LiquidityAdded(
        address indexed provider,
        uint256[] amounts,
        uint256 lpTokens
    );
    event LiquidityRemoved(
        address indexed provider,
        uint256[] amounts,
        uint256 lpTokens
    );

    //////////////////////
    ////// MODIFIER //////
    //////////////////////

    constructor(
        address[TOKENS_COUNT] memory _tokens,
        address[TOKENS_COUNT] memory _priceFeeds
    ) ERC20("Liquidity Pool Token", "LPT") {
        for (uint i = 0; i < TOKENS_COUNT; i++) {
            supportedTokens[i] = IERC20(_tokens[i]);
            isTokenSupported[_tokens[i]] = true;
            tokenPriceFeeds[_tokens[i]] = _priceFeeds[i];
        }
    }

    /// FUNCTIONS FOR LIQUIDITY PROVIDERS

    /// @param amounts The amounts of each token to add as liquidity
    /// @return lpTokensToMint The amount of LP tokens minted
    /// @dev This function adds liquidity to the pool by transferring the specified amounts of each token from the user to the contract.
    /// @dev If the pool is not initialized, it initializes the pool with the provided amounts.

    function addLiquidity(
        uint256[] calldata amounts
    ) external returns (uint256) {
        require(amounts.length == TOKENS_COUNT, "Must provide 5 amounts");

        uint256[] memory balancesBefore = new uint256[](TOKENS_COUNT);
        for (uint i = 0; i < TOKENS_COUNT; i++) {
            balancesBefore[i] = supportedTokens[i].balanceOf(address(this));
        }

        if (!isInitialized) {
            return _addInitialLiquidity(amounts);
        }

        _verifyDistribution(amounts);

        for (uint i = 0; i < TOKENS_COUNT; i++) {
            supportedTokens[i].transferFrom(
                msg.sender,
                address(this),
                amounts[i]
            );
            calculateAndUpdateFee(amounts[i], supportedTokens[i]);
        }

        uint256 lpTokensToMint = _calculateLPTokens(amounts, balancesBefore);
        _mint(msg.sender, lpTokensToMint);

        liquidityProviderDeposits[msg.sender] = amounts;

        emit LiquidityAdded(msg.sender, amounts, lpTokensToMint);
        return lpTokensToMint;
    }

    /// @param lpTokenAmount The amount of LP tokens to burn
    /// @return tokensToReturn The amounts of each token to return to the user
    /// @dev This function removes liquidity from the pool by burning the specified amount of LP tokens and returning the corresponding amounts of each token to the user.

    function removeLiquidity(
        uint256 lpTokenAmount
    ) external returns (uint256[] memory) {
        require(lpTokenAmount > 0, "Amount must be > 0");
        require(
            balanceOf(msg.sender) >= lpTokenAmount,
            "Insufficient LP tokens"
        );

        uint256[] memory tokensToReturn = new uint256[](TOKENS_COUNT);
        uint256 totalSupply = totalSupply();

        for (uint i = 0; i < TOKENS_COUNT; i++) {
            uint256 tokenBalance = supportedTokens[i].balanceOf(address(this));
            uint256 feeAmount = accumulatedFees[supportedTokens[i]];
            uint256 balanceMinusFees = tokenBalance - feeAmount;

            tokensToReturn[i] =
                (balanceMinusFees * lpTokenAmount) /
                totalSupply;
            supportedTokens[i].transfer(msg.sender, tokensToReturn[i]);
        }

        _burn(msg.sender, lpTokenAmount);
        emit LiquidityRemoved(msg.sender, tokensToReturn, lpTokenAmount);

        return tokensToReturn;
    }

    /// @dev This function collects the accumulated fees for each token and transfers them to the user based on their share of the total supply of LP tokens.

    function collectFees() external {
        uint256 totalSupply = totalSupply();
        require(totalSupply > 0, "No liquidity");

        for (uint i = 0; i < TOKENS_COUNT; i++) {
            uint256 feeAmount = accumulatedFees[supportedTokens[i]];
            if (feeAmount > 0) {
                uint256 userShare = (feeAmount * balanceOf(msg.sender)) /
                    totalSupply;
                accumulatedFees[supportedTokens[i]] -= userShare;
                supportedTokens[i].transfer(msg.sender, userShare);
            }
        }
    }

    /// @param amounts The amounts of each token to add as liquidity
    /// @return initialLPTokens The amount of LP tokens minted
    /// @dev This function initializes the liquidity pool with the provided amounts of each token.

    function _addInitialLiquidity(
        uint256[] memory amounts
    ) private returns (uint256) {
        require(!isInitialized, "Already initialized");

        for (uint i = 0; i < TOKENS_COUNT; i++) {
            if (amounts[i] > 0) {
                supportedTokens[i].transferFrom(
                    msg.sender,
                    address(this),
                    amounts[i]
                );
            }
        }

        isInitialized = true;
        uint256 initialLPTokens = amounts[0];
        _mint(msg.sender, initialLPTokens);

        liquidityProviderDeposits[msg.sender] = amounts;
        emit LiquidityAdded(msg.sender, amounts, initialLPTokens);

        return initialLPTokens;
    }

    /// @param amounts The amounts of each token to add as liquidity
    /// @dev This function verifies that the distribution of tokens is 20% for each token.

    function _verifyDistribution(uint256[] memory amounts) private pure {
        uint256 total = 0;
        for (uint i = 0; i < TOKENS_COUNT; i++) {
            total += amounts[i];
        }

        for (uint i = 0; i < TOKENS_COUNT; i++) {
            require(
                (amounts[i] * 100) / total == PERCENTAGE_PER_TOKEN,
                "Must maintain 20% distribution"
            );
        }
    }

    /// @param amounts The amounts of each token to add as liquidity
    /// @param balancesBefore The balances of each token before adding liquidity
    /// @return lpTokensToMint The amount of LP tokens to mint
    /// @dev This function calculates the amount of LP tokens to mint based on the provided amounts and balances.

    function _calculateLPTokens(
        uint256[] memory amounts,
        uint256[] memory balancesBefore
    ) private view returns (uint256) {
        uint256[] memory ratios = new uint256[](TOKENS_COUNT);

        for (uint i = 0; i < TOKENS_COUNT; i++) {
            ratios[i] = (amounts[i] * 1e18) / balancesBefore[i];
        }

        uint256 minRatio = ratios[0];
        for (uint i = 1; i < TOKENS_COUNT; i++) {
            if (ratios[i] < minRatio) {
                minRatio = ratios[i];
            }
        }

        return (totalSupply() * minRatio) / 1e18;
    }

    /// @param amount The amount of the token to calculate the fee for
    /// @param token The address of the token to calculate the fee for
    /// @dev This function calculates the fee for the given amount of the token and updates the accumulated fees.

    function calculateAndUpdateFee(uint256 amount, IERC20 token) internal {
        uint256 fee = (amount * FEE_PERCENTAGE) / FEE_DENOMINATOR;
        accumulatedFees[token] += fee;
    }

    /// @dev This function returns the supported tokens in the system.
    /// @return supportedTokens The array of supported tokens

    function getTokens() external view returns (IERC20[TOKENS_COUNT] memory) {
        return supportedTokens;
    }

    /// @param provider The address of the liquidity provider to get the deposits for
    /// @return liquidityProviderDeposits The array of deposits made by the liquidity provider
    /// @dev This function returns the deposits made by the liquidity provider.

    function getLiquidityProviderDeposits(
        address provider
    ) external view returns (uint256[] memory) {
        return liquidityProviderDeposits[provider];
    }

    /// FUNCTIONS FOR USERS

    /// @param user The address of the user to get the collateral deposits for
    /// @return tokens The array of tokens deposited by the user
    /// @return amounts The array of amounts of each token deposited by the user
    /// @dev This function returns the collateral deposits made by the user.

    function getCollateralDeposits(
        address user
    )
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        UserCollateral storage collateral = userCollateral[user];
        tokens = collateral.depositedTokens;
        amounts = new uint256[](tokens.length);

        for (uint i = 0; i < tokens.length; i++) {
            amounts[i] = collateral.tokenBalances[tokens[i]];
        }

        return (tokens, amounts);
    }

    /// @param collateralTokens The array of tokens to deposit as collateral
    /// @param collateralAmounts The array of amounts of each token to deposit as collateral
    /// @param borrowToken The address of the token to borrow
    /// @param borrowAmount The amount of the token to borrow
    /// @param timePeriod The time period for the loan in seconds

    function depositAndBorrow(
        address[] calldata collateralTokens,
        uint256[] calldata collateralAmounts,
        address borrowToken,
        uint256 borrowAmount,
        uint256 timePeriod
    ) external nonReentrant {
        _depositMultipleCollateral(collateralTokens, collateralAmounts);
        _borrowToken(borrowToken, borrowAmount, timePeriod);
    }

    /// @param debtIndex The index of the debt position to repay
    /// @param withdrawToken The address of the token to withdraw as collateral
    /// @param withdrawAmount The amount of the token to withdraw as collateral
    /// @dev This function repays the specified debt and withdraws the specified amount of collateral.

    function repayAndWithdraw(
        uint256 debtIndex,
        address withdrawToken,
        uint256 withdrawAmount
    ) external nonReentrant {
        _repayDebt(debtIndex);
        if (withdrawAmount > 0) {
            _withdrawCollateral(withdrawToken, withdrawAmount);
        }
    }

    /// @param tokens The array of tokens to deposit as collateral
    /// @param amounts The array of amounts of each token to deposit as collateral
    /// @dev This function deposits multiple tokens as collateral for the user.

    function _depositMultipleCollateral(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) internal {
        require(tokens.length == amounts.length, "Arrays length mismatch");
        require(tokens.length > 0, "Empty arrays");

        UserCollateral storage collateral = userCollateral[msg.sender];

        for (uint i = 0; i < tokens.length; i++) {
            require(isTokenSupported[tokens[i]], "Token not supported");
            require(amounts[i] > 0, "Amount must be > 0");

            if (!collateral.hasActiveCollateral) {
                collateral.hasActiveCollateral = true;
            }

            if (collateral.tokenBalances[tokens[i]] == 0) {
                collateral.depositedTokens.push(tokens[i]);
            }

            collateral.tokenBalances[tokens[i]] += amounts[i];

            require(
                IERC20(tokens[i]).transferFrom(
                    msg.sender,
                    address(this),
                    amounts[i]
                ),
                "Transfer failed"
            );

            calculateAndUpdateFee(amounts[i], IERC20(tokens[i]));

            emit CollateralDeposited(msg.sender, tokens[i], amounts[i]);
        }
    }

    /// @param token The address of the token to borrow
    /// @param amount The amount of the token to borrow
    /// @param timePeriod The time period for the loan in seconds
    /// @dev This function allows the user to borrow a token by creating a debt position.
    /// @dev The user must have no active debts before borrowing.

    function _borrowToken(
        address token,
        uint256 amount,
        uint256 timePeriod
    ) internal {
        require(isTokenSupported[token], "Token not supported");
        require(amount > 0, "Amount must be > 0");

        DebtPosition[] storage debts = userDebts[msg.sender];

        for (uint i = 0; i < debts.length; i++) {
            require(debts[i].isRepaid, "Must repay all previous debts first");
        }

        uint256 interestRate = getInterestRate(msg.sender);

        userDebts[msg.sender].push(
            DebtPosition({
                debtToken: token,
                amount: amount,
                timestamp: block.timestamp,
                timePeriod: timePeriod,
                interestRate: interestRate,
                actualRepaymentTimestamp: 0,
                isRepaid: false
            })
        );

        _revertIfCollateralizationRatioIsLow(msg.sender);

        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");

        emit DebtTaken(msg.sender, token, amount);
    }

    /// @param debtIndex The index of the debt position to repay
    /// @dev This function allows the user to repay a debt position.

    function _repayDebt(uint256 debtIndex) internal nonReentrant {
        DebtPosition storage debt = userDebts[msg.sender][debtIndex];
        require(!debt.isRepaid, "Debt already repaid");

        uint256 repaymentAmount = calculateRepaymentAmount(debt);
        require(
            IERC20(debt.debtToken).transferFrom(
                msg.sender,
                address(this),
                repaymentAmount
            ),
            "Transfer failed"
        );

        debt.isRepaid = true;
        debt.actualRepaymentTimestamp = block.timestamp;

        _updateCreditScore(msg.sender, debtIndex);

        emit DebtRepaid(msg.sender, debtIndex);
    }

    /// @param token The address of the token to withdraw
    /// @param amount The amount of the token to withdraw
    /// @dev This function allows the user to withdraw collateral after repaying all debts.

    function _withdrawCollateral(address token, uint256 amount) internal {
        require(_userHasNoActiveDebt(msg.sender), "Active debt exists");

        UserCollateral storage collateral = userCollateral[msg.sender];
        require(
            collateral.tokenBalances[token] >= amount,
            "Insufficient balance"
        );

        collateral.tokenBalances[token] -= amount;

        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");

        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    /// @param user The address of the user to check for active debts
    /// @return true if the user has no active debts, false otherwise
    /// @dev This function checks if the user has any active debts.

    function _userHasNoActiveDebt(address user) internal view returns (bool) {
        DebtPosition[] storage debts = userDebts[user];
        for (uint i = 0; i < debts.length; i++) {
            if (!debts[i].isRepaid) return false;
        }
        return true;
    }

    /// @param user The address of the user to get the total collateral value for
    /// @return total The total value of the collateral in USD
    /// @dev This function calculates the total value of the collateral deposited by the user in USD.

    function totalCollateralValue(address user) public view returns (uint256) {
        UserCollateral storage userCollat = userCollateral[user];
        uint256 total;
        for (uint256 i = 0; i < userCollat.depositedTokens.length; i++) {
            address token = userCollat.depositedTokens[i];
            uint256 amount = userCollat.tokenBalances[token];
            if (amount > 0) {
                total += getUsdValue(token, amount);
            }
        }
        return total;
    }

    /// @param user The address of the user to get the current debt utilized for
    /// @return total The total value of the current debt utilized in USD
    /// @dev This function calculates the total value of the current debt utilized by the user in USD.

    function _getCurrentDebtUtilized(
        address user
    ) private view returns (uint256) {
        uint256 total;
        DebtPosition[] storage debts = userDebts[user];
        for (uint256 i = 0; i < debts.length; i++) {
            if (!debts[i].isRepaid) {
                total += getUsdValue(debts[i].debtToken, debts[i].amount);
            }
        }
        return total;
    }

    /// @param debt The debt position to calculate the repayment amount for
    /// @return repaymentAmount The total amount to be repaid including interest
    /// @dev This function calculates the total amount to be repaid including interest for the given debt position.

    function calculateRepaymentAmount(
        DebtPosition storage debt
    ) private view returns (uint256) {
        uint256 interest = calculateInterest(debt);
        return debt.amount + interest;
    }

    /// @param user The address of the user to check the collateralization ratio for
    /// @dev This function checks if the collateralization ratio is above 1.0.

    function _revertIfCollateralizationRatioIsLow(address user) private view {
        uint256 healthFactor = calculateMinimumHealthFactor(user);
        require(healthFactor >= 1e18, "Collateralization ratio too low");
    }

    /// @param user The address of the user to get the minimum health factor for
    /// @return healthFactor The minimum health factor for the user
    /// @dev This function calculates the minimum health factor for the user based on their collateral and debt.

    function calculateMinimumHealthFactor(
        address user
    ) private view returns (uint256) {
        uint256 totalCollateral = totalCollateralValue(user);
        uint256 totalDebt = _getCurrentDebtUtilized(user);

        if (totalDebt == 0) {
            return type(uint256).max; // Infinite health factor if no debt
        }

        return (totalCollateral * 1e18) / totalDebt;
    }

    /// @param token The address of the token to get the price for
    /// @param amount The amount of the token to get the price for
    /// @return usdValue The USD value of the token amount

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            tokenPriceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /// @param user The address of the user to get the interest rate for
    /// @return interestRate The interest rate for the user
    /// @dev This function returns the interest rate for the user based on their credit score.

    function getInterestRate(address user) public view returns (uint256) {
        uint256 creditScore = userCreditScore[user];
        if (creditScore >= 900) {
            return 5e16; // 5% annual interest rate
        } else if (creditScore >= 750) {
            return 10e16; // 10% annual interest rate
        } else if (creditScore >= 600) {
            return 15e16; // 15% annual interest rate
        } else {
            return 20e16; // 20% annual interest rate
        }
    }

    /// @param debt The debt position to calculate the interest for
    /// @return interest The interest amount for the debt position
    /// @dev This function calculates the interest amount for the given debt position based on the time held and interest rate.

    function calculateInterest(
        DebtPosition storage debt
    ) internal view returns (uint256) {
        uint256 timeHeld = debt.timePeriod;
        uint256 interest = (debt.amount * debt.interestRate * timeHeld) /
            (365 days * PRECISION);
        return interest;
    }

    /// @param x The value to calculate the logarithm for
    /// @return y The logarithm of x to the base 2
    /// @dev This function calculates the logarithm of x to the base 2 using bitwise operations.

    function log2(uint256 x) internal pure returns (uint256 y) {
        assembly {
            let arg := x
            x := sub(x, 1)
            x := or(x, div(x, 0x02))
            x := or(x, div(x, 0x04))
            x := or(x, div(x, 0x10))
            x := or(x, div(x, 0x100))
            x := or(x, div(x, 0x10000))
            x := or(x, div(x, 0x100000000))
            x := or(x, div(x, 0x10000000000000000))
            x := or(x, div(x, 0x100000000000000000000000000000000))
            x := add(x, 1)
            let m := mload(0x40)
            mstore(
                m,
                0xf8f9cbfae6cc78fbefe7cdc3a1793dfcf4f0e8bbd8cec470b6a28a7a5a3e1efd
            )
            mstore(
                add(m, 0x20),
                0xf5ecf1b3e9debc68e1d9cfabc5997135bfb7a7a3938b7b606b5b4b3f2f1f0ffe
            )
            mstore(
                add(m, 0x40),
                0xf6e4ed9ff2d6b458eadcdf97bd91692de2d4da8fd2d0ac50c6ae9a8272523616
            )
            mstore(
                add(m, 0x60),
                0xc8c0b887b0a8a4489c948c7f847c6125746c645c544c444038302820181008ff
            )
            mstore(
                add(m, 0x80),
                0xf7cae577eec2a03cf3bad76fb589591debb2dd67e0aa9834bea6925f6a4a2e0e
            )
            mstore(
                add(m, 0xa0),
                0xe39ed557db96902cd38ed14fad815115c786af479b7e83247363534337271707
            )
            mstore(
                add(m, 0xc0),
                0xc976c13bb96e881cb166a933a55e490d9d56952b8d4e801485467d2362422606
            )
            mstore(
                add(m, 0xe0),
                0x753a6d1b65325d0c552a4d1345224105391a310b29122104190a110309020100
            )
            mstore(0x40, add(m, 0x100))
            let
                magic
            := 0x818283848586878898a8b8c8d8e8f929395969799a9b9d9e9faaeb6bedeeff
            let
                shift
            := 0x100000000000000000000000000000000000000000000000000000000000000
            let a := div(mul(x, magic), shift)
            y := div(mload(add(m, sub(255, a))), shift)
            y := add(
                y,
                mul(
                    256,
                    gt(
                        arg,
                        0x8000000000000000000000000000000000000000000000000000000000000000
                    )
                )
            )
        }
    }

    /// @param x The exponent to calculate the negative exponential for
    /// @return result The negative exponential of x
    /// @dev This function calculates the negative exponential of x using the formula:

    function negativeExp(uint256 x) private pure returns (uint256) {
        return ((2 ** x - 1) * (1e18)) / (2 ** x);
    }

    /// @param user The address of the user to calculate the payment history score for
    /// @return score The payment history score for the user
    /// @dev This function calculates the payment history score for the user based on their repayment history.

    function calculatePaymentHistoryScore(
        address user
    ) private view returns (uint256) {
        DebtPosition[] storage _userDebts = userDebts[user];
        uint256 totalScore = 0;
        uint256 debtCount = _userDebts.length;

        if (debtCount == 0) {
            return 0;
        }

        for (uint256 i = 0; i < debtCount; i++) {
            int256 impactScore = _calculatePaymentImpact(_userDebts[i]);
            if (impactScore > 0) {
                totalScore += uint256(impactScore);
            }
        }

        uint256 normalizedScore = (totalScore * 400) / (debtCount * 100);
        return normalizedScore > 400 ? 400 : normalizedScore;
    }

    /// @param user The address of the user to calculate the credit utilization score for
    /// @return score The credit utilization score for the user
    /// @dev This function calculates the credit utilization score for the user based on their collateral and debt utilization.

    function calculateCreditUtilizationScore(
        address user
    ) private view returns (uint256) {
        uint256 totalCollateral = totalCollateralValue(user);
        uint256 availableDebt = totalCollateral; // In this implementation, available debt is same as collateral
        uint256 debtUtilised = _getCurrentDebtUtilized(user);

        if (totalCollateral == 0) return 0;

        uint256 ratio = ((availableDebt - debtUtilised) * PRECISION) /
            totalCollateral;
        uint256 exponent = (ratio * DEBT_UTILISATION_CONSTANT) / PRECISION;

        uint256 value = negativeExp(exponent);
        return (300 * value) / PRECISION;
    }

    /// @param user The address of the user to calculate the collateral mix score for
    /// @return score The collateral mix score for the user
    /// @dev This function calculates the collateral mix score for the user based on the diversity of their collateral.

    function calculateCollateralMixScore(
        address user
    ) private view returns (uint256) {
        uint256 tokenCount;
        uint256 totalValue = totalCollateralValue(user);

        UserCollateral storage userCollat = userCollateral[user];
        uint256 entropy;

        for (uint256 i = 0; i < userCollat.depositedTokens.length; i++) {
            address token = userCollat.depositedTokens[i];
            uint256 amount = userCollat.tokenBalances[token];
            if (amount > 0) {
                tokenCount++;
                uint256 tokenValue = getUsdValue(token, amount);
                uint256 proportion = (tokenValue * PRECISION) / totalValue;
                uint256 proportionlog = log2(PRECISION / proportion) *
                    LOG_FACTOR;
                entropy += (proportion * proportionlog) / PRECISION;
            }
        }

        if (tokenCount == 0) {
            return 0;
        }

        uint256 maxEntropy = log2(tokenCount) * LOG_FACTOR;
        uint256 entropyRatio = (entropy * PRECISION) / maxEntropy;

        uint256 exponent = negativeExp(tokenCount - 1);
        uint256 baseScore = 100 + (100 * exponent) / PRECISION;

        uint256 score = baseScore * entropyRatio;
        return score > 200 ? 200 : (score < 1 ? 1 : score);
    }

    /// @dev This function calculates the credit score for the user based on their payment history, utilization, and collateral mix.
    /// @param user The address of the user to calculate the credit score for

    function calculateCreditScore(address user) external {
        uint256 paymentScore = calculatePaymentHistoryScore(user);
        uint256 utilizationScore = calculateCreditUtilizationScore(user);
        uint256 collateralScore = calculateCollateralMixScore(user);
        uint256 lengthScore = paymentScore / 4; // Simplified version of length score

        uint256 finalScore = paymentScore +
            utilizationScore +
            collateralScore +
            lengthScore;

        // Ensure the final score does not exceed the maximum limit
        userCreditScore[user] = finalScore > 1000 ? 1000 : finalScore;
    }

    /// @param user The address of the user to get the credit score for
    /// @return creditScore The credit score of the user
    /// @dev This function returns the credit score of the user.

    function getCreditScore(address user) external view returns (uint256) {
        return userCreditScore[user];
    }

    /// @param debt The debt position to calculate the payment impact for
    /// @return impact The payment impact on the credit score
    /// @dev This function calculates the payment impact on the credit score based on the repayment history.

    function _calculatePaymentImpact(
        DebtPosition storage debt
    ) private view returns (int256) {
        if (!debt.isRepaid) {
            uint256 _dueDate = debt.timestamp + debt.timePeriod;
            if (block.timestamp > _dueDate) {
                return -100; // Worst credit score for default
            }
            return 0; // Neutral while loan is active
        }

        uint256 dueDate = debt.timestamp + debt.timePeriod;
        bool isEarly = debt.actualRepaymentTimestamp < dueDate;
        bool isLate = debt.actualRepaymentTimestamp > dueDate;

        // Base impact calculation
        int256 basePoints;
        if (isEarly) {
            basePoints = 10;
        } else if (isLate) {
            uint256 daysLate = (debt.actualRepaymentTimestamp - dueDate) /
                86400;
            basePoints = -5 - int256(daysLate);
        } else {
            basePoints = 5;
        }

        // Apply amount weight
        uint256 amountWeight = PRECISION +
            (debt.amount * PRECISION) /
            REFERENCE_LOAN_SIZE;

        // Apply time weight
        uint256 durationDays = debt.timePeriod / 86400;
        uint256 weight = (amountWeight * durationDays) / 365;

        return (basePoints * int256(weight)) / int256(PRECISION);
    }

    /// @param user The address of the user to update the credit score for
    /// @param debtIndex The index of the debt position to update the credit score for
    /// @dev This function updates the credit score of the user based on the repayment history of the debt position.

    function _updateCreditScore(address user, uint256 debtIndex) private {
        DebtPosition storage debt = userDebts[user][debtIndex];
        int256 paymentImpact = _calculatePaymentImpact(debt);
        uint256 currentScore = userCreditScore[user];

        if (paymentImpact < 0) {
            userCreditScore[user] = currentScore > uint256(-paymentImpact)
                ? currentScore - uint256(-paymentImpact)
                : 0;
        } else {
            uint256 maxScore = 1000;
            uint256 newScore = currentScore + uint256(paymentImpact);
            userCreditScore[user] = newScore > maxScore ? maxScore : newScore;
        }
    }

}
