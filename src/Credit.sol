//SPDX-License-Identifier: MIT

// FOR ABHIVANSH - SOME FUNCTION NEEDS CORRECTION. They are ai generated and not checked. You can start integerating though as it only need function names.

pragma solidity ^0.8.18;

// import {PRBMathUD60x18} from "@prb/math/src/PRBMathUD60x18.sol";
// import {UD60x18} from "@prb/math/src/UD60x18.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title A math heavy credit score implementaion for credit lending based on a time period specified by the user
 * @author Anand , Aryan , Abhivansh
 * @notice Credit score will be calculated based on the following factors:
 * @notice 1. Payment history(40%) Psuedo Done
 * @notice 2. Credit utilization(30%) Doing
 * @notice 3. Collateral derisking(20%) Done
 * @notice 5. Length of credit history(10%) Done
 * @notice 6. Credit score will be between 0 to 1000 (IDK why baks keeps 300-850)
 * @notice Interest Rate will depend on the credit score you have.
 * @notice This project is set in the future where common people uses crypto and it will act as replacement to traditional bank. Usually banks fear that a person might default a loan but this protocol is not scared of that. Instead it is more interested in giving out credit as long as collateral meets the requirement. Actually Liquidation is bad for the protocol in the sense that it is more interested in interest accumulated on the person.
 */
contract CreditScore is ReentrancyGuard {
    // using PRBMathUD60x18 for uint256; // Fix library

    IERC20 public immutable TB; // Debt Token
    address public addressOfB;
    address BPriceFeed;
    address[] private collateralTokens;

    /////////////////STRUCTS////////////////////
    struct Debt {
        uint256 amountOfToken;
        uint256 timestamp;
        uint256 timePeriod;
        uint256 interestRate;
        uint256 actualRepaymentTimestamp;
        bool isRepaid;
    }

    /////////////////MAPPINGS////////////////////
    mapping(address token => address priceFeed) private collateralPriceFeeds; //token -> pricefeeds
    mapping(address user => mapping(address token => uint256 amount)) private collateralDeposited;
    mapping(address user => Debt[]) public userDebt;
    mapping(address user => uint256 score) public userCreditScore;

    ///////////////CONSTANTS/////////////////////

    /**
     * @dev This is for protocol applier to fix according to them.
     *
     */
    uint256 DEBT_TIME_NORMALISER = 172800000; // 20 days - 100$ each day
    uint256 ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 PRECISION = 1e18;
    uint256 DEBT_UTILISATION_CONSTANT = 52e18;
    uint256 LOG_FACTOR = 144e16;
    uint256 REFERENCE_LOAN_SIZE = 1000e18; // 1000$ loan size

    ///////////////EVENTs/////////////////////
    event CS__Collateral_Deposited(address token, uint256 amount);
    event CS__DebtBorrowed(uint256 amount);

    //////////////ERRORS/////////////////////
    error CS__InvalidCollateralTokenAddress(address token);
    error CS__AmountMustBeMoreThanZero();
    error CS__InvalidDebtTokenAddress(address token);
    error CS_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error CS__InsufficientLiquidity();
    error CS__DebtAreadyRepaid();

    // Array of acceptible collateral token
    // B is debt token
    constructor(
        address _B,
        address _BPriceFeed,
        address[] memory collateralAddresses,
        address[] memory collateralPriceFeedAddresses
    ) {
        if (collateralAddresses.length != collateralPriceFeedAddresses.length) {
            revert CS_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < collateralAddresses.length; i++) {
            collateralPriceFeeds[collateralAddresses[i]] = collateralPriceFeedAddresses[i];
            collateralTokens.push(collateralAddresses[i]);
        }
        TB = IERC20(_B);
        addressOfB = _B;
        BPriceFeed = _BPriceFeed;
    }

    /////////////MODIFIERS////////////////////

    modifier validDebtToken(address token) {
        require(token == addressOfB, CS__InvalidDebtTokenAddress(token));
        _;
    }

    modifier validCollateralToken(address token) {
        bool isValid = false;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            if (collateralTokens[i] == token) {
                isValid = true;
                break;
            }
        }
        require(isValid, CS__InvalidCollateralTokenAddress(token));
        _;
    }

    modifier moreThanZero(uint256 amount) {
        require(amount > 0, CS__AmountMustBeMoreThanZero());
        _;
    }

    /////////////////PUBLIC FUNCTIONS////////////////////

    /**
     * @notice Deposit Collateral
     * @param token Address of the token to be deposited
     * @param amount Amount of the token to be deposited
     * @dev This function will transfer the collateral token from the user to the contract
     * @dev No checks other than zero amount needed because the more collateral the better
     */
    function depositCollateral(address token, uint256 amount) public moreThanZero(amount) validCollateralToken(token) {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        collateralDeposited[msg.sender][token] += amount;
        emit CS__Collateral_Deposited(token, amount);
    }

    /**
     *
     * @param token : address of the token to be borrowed
     * @param amount : amount of the token to be borrowed
     * @param timeperiod : time period for which the token is borrowed
     * @dev time period is in seconds
     * @dev This function will transfer the debt token from the contract to the user
     * @notice we are setting repayment timestamp to be 0
     */
    function borrowdebt(address token, uint256 amount, uint256 timeperiod)
        public
        moreThanZero(amount)
        validDebtToken(token)
        nonReentrant
    {
        uint256 interestRate = getInterestRate(msg.sender); // e18 format
        userDebt[msg.sender].push(Debt(amount, block.timestamp, interestRate, timeperiod, 0, false));
        _revertIfColllaterizationRatioIsLow(msg.sender);
        require(TB.balanceOf(address(this)) > amount, CS__InsufficientLiquidity());
        TB.transfer(msg.sender, amount);
        emit CS__DebtBorrowed(amount);
    }

    /**
     *
     * @param debtIndex : index of the debt to be repaid
     * @notice Interest calculated on amount of token borrowed will be proportional to interest on value of token, so direct calculation works
     */
    function repayDebt(uint256 debtIndex) external nonReentrant {
        Debt storage debt = userDebt[msg.sender][debtIndex];
        require(!debt.isRepaid, CS__DebtAreadyRepaid());
        uint256 tokenAmount = tokenRepaymentAmount(debt);
        require(TB.transferFrom(msg.sender, address(this), tokenAmount));

        debt.isRepaid = true;
        debt.actualRepaymentTimestamp = block.timestamp;

        _updateCreditScore(msg.sender, debtIndex); // Update score on-chain, yet to be implemented
    }

    /**
     *
     * @param user : address of the user
     * @notice This function will calculate the total collateral value of the user
     * @dev This function will iterate through all the collateral tokens and sum up their value in USD
     */
    function totalCollateralValue(address user) public returns (uint256 totalValue) {
        mapping(address token => uint256 amount) userCollateral = collateralDeposited[user];
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 amount = userCollateral[token];
            uint256 tokenValue = getUsdValue(token, amount);
            totalValue += tokenValue;
        }
    }

    ///////////INTERNAL FUNCTIONS////////////////////

    /**
     * @notice Calculates sum of (debt amount * time held) for all user debts
     * @dev Time held is either repayment timestamp or current block.timestamp if not repaid
     * @param user Address to calculate debt-time value for
     * @return debtTimeValue Sum of (amount * time held) across all debts
     */
    function totalDebtTimeValue(address user) internal view returns (uint256 debtTimeValue) {
        Debt[] storage debts = userDebt[user];

        for (uint256 i = 0; i < debts.length; i++) {
            Debt storage debt = debts[i];
            uint256 endTime = debt.isRepaid ? debt.actualRepaymentTimestamp : block.timestamp;
            uint256 timeHeld = endTime - debt.timestamp;
            debtTimeValue += debt.amount * timeHeld;
        }
        return debtTimeValue;
    }

    /**
     * @notice Calculates credit utilization score (0-300 scale)
     * @param user Address to calculate score for
     * @return score Credit utilization score (part of the 30% component)
     * @dev Score is exponentially proportional to (D - U)/C ratio, where D = available debt, U = utilized debt, C = total collateral.
     * @dev There is a contant fine tuned to match our need. For eg: Base ratio: 1.5 but took 1.7 => approx 80% of 300 => 240-250 [Keep in mind that more the ratio, more is better for protocol as debt taken is inversely proportional to ratio]
     */
    function calculateCreditUtilizationScore(address user) internal view returns (uint256 score) {
        uint256 totalCollateral = totalCollateralValue(user);
        uint256 availableDebt = _calculateMaxAvailableDebt(user);
        uint256 debtUtilised = _getCurrentDebtUtilized(user);

        // Ensure we don't divide by zero
        if (totalCollateral == 0) return 0;

        // Calculate (D - U)/C ratio
        uint256 ratio = ((availableDebt - debtUtilised) * PRECISION) / totalCollateral; // e18 precision
        uint256 exponent = (ratio * DEBT_UTILISATION_CONSTANT) / 1e18;

        uint256 value = negativeExp(exponent); // e18 precision
        score = (300 * value) / 1e18;
    }

    /**
     * @dev Helper to get sum of all active debts
     */
    function _getCurrentDebtUtilized(address user) internal view returns (uint256) {
        uint256 total;
        Debt[] storage debts = userDebt[user];
        for (uint256 i = 0; i < debts.length; i++) {
            if (!debts[i].isRepaid) {
                total += debts[i].amount;
            }
        }
        return total;
    }

    /**
     * @param user Address to calculate max available debt for
     * @dev Helper to calculate max available debt based on collateral value and collaterization factor
     */
    function _calculateMaxAvailableDebt(address user) internal view returns (uint256) {
        uint256 totalCollateral = totalCollateralValue(user);
        uint256 collaterizationRatio = getCollateralizationRatio(user);
        uint256 maxDebt = (totalCollateral * PRECISION) / collaterizationRatio;
    }

    function _calculateCollaterizationRatio(address user) internal view returns (uint256 ratio) {}

    /**
     *
     * @param user : address of the user
     * @param token : address of the debt token
     * @notice This function gives score on the two factors:
     * 1. Amount the money owed
     * 2. Amount of time for money owed
     * @notice These are multiplied together and normalised. Then a graphing method is used to get score between 0-100
     */

    // check the precision of debtTimeValue => should be zero
    function calculateLengthOfCreditScore(address user, address token)
        internal
        validDebtToken(token)
        returns (uint256 score)
    {
        uint256 debtTimeValue = totalDebtTimeValue(user);
        uint256 normalisedDebtTimeValue = debtTimeValue / DEBT_TIME_NORMALISER;

        score = (negativeExp(normalisedDebtTimeValue) * 100) / 1e18;
    }

    /**
     *
     * @param user The user whose credit score is calculated
     * @notice This function calculates the collateral mix score based on the distribution of collateral tokens
     * @notice The score is calculated based on the number of different tokens and their proportions.
     * @notice Uses Entropy Function to evaluate how good the distribution is. eg: 30 30 30 is good while 90 0 0 is bad
     * @notice Takes account in the value of collateral and not the amount of token.
     * @notice The reason that this is important because the protocol is more interested in interest on debt rather than liquidation fees. By diversifying collateral, risk of getting liquidated is reduced.
     */
    function calculateCollateralMixScore(address user) internal pure returns (uint256) {
        uint256 tokenCount;
        uint256 totalValue = totalCollateralValue(user);
        mapping(address token => uint256 amount) userCollateral = collateralDeposited[user];

        // Calculate entropy (distribution effectiveness)
        uint256 entropy;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 amount = userCollateral[token];
            if (amount > 0) {
                tokenCount++;
                uint256 tokenValue = getUsdValue(token, amount);
                // Calculate proportion of each token's value to total value
                uint256 proportion = (tokenValue * PRECISION) / (totalValue); //For eg: 0.5e18
                uint256 proportionlog = log2(1e18 / (proportion)) * LOG_FACTOR; //For eg: ln(1/p e18) ---> x e18
                entropy += (proportion * proportionlog) / 1e18; // xe36
            }
        }
        if (tokenCount == 0) {
            return 0;
        }

        uint256 maxEntropy = log2(tokenCount) * LOG_FACTOR;
        uint256 entropyRatio = (entropy * 1e18) / (maxEntropy);

        // Calculate base score based on token count
        // Calculation not finalised yet
        // S_base = 100 + 100*(1 - e^(-(n-1)))
        uint256 exponent = negativeExp(tokenCount - 1); // e18 precision
        uint256 baseScore = 100 + (100 * exponent) / 1e18; // e18 precision

        // Combine factors and scale to 1-200
        uint256 score = baseScore * entropyRatio;
        // Clamp between 1-200
        if (score > 200) {
            return 200;
        } else if (score < 1) {
            return 1;
        } else {
            return score;
        }
    }

    function _calculatePaymentImpact(Debt memory debt) internal view returns (int256) {
        if (!debt.isRepaid) {
            uint256 dueDate = debt.timestamp + debt.timePeriod;
            if (block.timestamp > dueDate) {
                return -100; // Worst credit score for default
            }
            // Not repaid but still within time period
            return 200; // Neutral score while loan is active
        }

        uint256 dueDate = debt.timestamp + debt.timePeriod;
        bool isEarly = debt.actualRepaymentTimestamp < dueDate;
        bool isLate = debt.actualRepaymentTimestamp > dueDate;

        // Base points
        int256 basePoints = 0;
        if (isEarly) {
            basePoints = -2;
        } else if (isLate) {
            uint256 daysLate = (debt.actualRepaymentTimestamp - dueDate) / 86400;
            basePoints = -5 - int256(daysLate); // -5 for 1 day late, -6 for 2, etc.
        } else {
            basePoints = 10;
        } // On-time

        // Amount weight (1 + amount/reference)
        uint256 amountWeight = PRECISION + (debt.amount * PRECISION) / REFERENCE_LOAN_SIZE;

        // Duration weight (log2(days + 1))
        uint256 durationDays = debt.timePeriod / 86400;
        uint256 durationWeight = log2(durationDays + 1) * PRECISION;

        // Time decay (starts after 6 months, never <50%)
        uint256 monthsSinceRepayment = (block.timestamp - debt.actualRepaymentTimestamp) / 2592000;
        uint256 decayFactor;
        if (monthsSinceRepayment > 6) {
            uint256 calculatedDecay = PRECISION - (0.1 * (monthsSinceRepayment - 6) * PRECISION);
            decayFactor = calculatedDecay < (0.5 * PRECISION) ? (0.5 * PRECISION) : calculatedDecay;
        } else {
            decayFactor = PRECISION;
        }

        // Final impact
        return (basePoints * int256(amountWeight) * int256(durationWeight) * int256(decayFactor)) / (PRECISION ** 3);
    }

    function calculateMinimumHealthFactor(address user) internal view returns (uint256) {
        uint256 totalCollateral = totalCollateralValue(user);
        uint256 totalDebt = _getCurrentDebtUtilized(user);

        if (totalDebt == 0) {
            return type(uint256).max; // Infinite health factor if no debt
        }

        return (totalCollateral * 1e18) / totalDebt;
    }

    function _revertIfColllaterizationRatioIsLow(address user) internal view {
        uint256 healthFactor = calculateMinimumHealthFactor(user);
        require(healthFactor >= 1e18, "Collateralization ratio too low");
    }

    //////////////HELPER FUNCTIONS////////////////////

    /**
     *
     * @param x : value to be exponentiated
     * @notice take x and calculate 1 - e^(-x)
     * @dev Since the result will be always between 0 and 1, we multiply by 1e18 to get a more precise result
     * @dev Multiply the return value with your normalisation scalar and if not multiply by 100. Finally divide by 1e18 to get the final result
     */
    function negativeExp(uint256 x) public pure returns (uint256) {
        return ((x.exp() - 1).mul(1e18)).div(x.exp);
    }

    /**
     * @notice This function will get the price of the token in USD in e18 precision
     * @param token Address of the token
     * @param amount Amount of the token
     * @dev Do any calculation on the price and finally divide by e18 to get the final result
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(collateralPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount);
    }

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

    function calculateInterest(Debt memory debt) internal view returns (uint256) {
        uint256 timeHeld = debt.timePeriod;
        uint256 interest = (debt.amountOfToken * debt.interestRate * timeHeld) / (365 days * 1e18);
        return interest;
    }

    function _updateCreditScore(address user, uint256 debtIndex) internal {
        Debt storage debt = userDebt[user][debtIndex];
        int256 paymentImpact = _calculatePaymentImpact(debt);
        uint256 currentScore = userCreditScore[user];

        if (paymentImpact < 0) {
            userCreditScore[user] = currentScore > uint256(-paymentImpact) ? currentScore - uint256(-paymentImpact) : 0;
        } else {
            userCreditScore[user] = currentScore + uint256(paymentImpact);
        }
    }

    function tokenRepaymentAmount(Debt memory debt) internal view returns (uint256) {
        uint256 interestOnDebt = calculateInterest(debt);
        return debt.amountOfToken + interestOnDebt;
    }

    function valueOfTokenRepaymentAmount(Debt memory debt) internal view returns (uint256) {
        uint256 tokenAmount = tokenRepaymentAmount(debt);
        return getUsdValue(addressOfB, tokenAmount);
    }

    /**
     *
     * @param x : value whose log2 is to be calculated
     * @notice This function will calculate the log2 of the value
     * @dev This is taken from ethereum exchange
     */
    function log2(uint256 x) internal returns (uint256 y) {
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
            mstore(m, 0xf8f9cbfae6cc78fbefe7cdc3a1793dfcf4f0e8bbd8cec470b6a28a7a5a3e1efd)
            mstore(add(m, 0x20), 0xf5ecf1b3e9debc68e1d9cfabc5997135bfb7a7a3938b7b606b5b4b3f2f1f0ffe)
            mstore(add(m, 0x40), 0xf6e4ed9ff2d6b458eadcdf97bd91692de2d4da8fd2d0ac50c6ae9a8272523616)
            mstore(add(m, 0x60), 0xc8c0b887b0a8a4489c948c7f847c6125746c645c544c444038302820181008ff)
            mstore(add(m, 0x80), 0xf7cae577eec2a03cf3bad76fb589591debb2dd67e0aa9834bea6925f6a4a2e0e)
            mstore(add(m, 0xa0), 0xe39ed557db96902cd38ed14fad815115c786af479b7e83247363534337271707)
            mstore(add(m, 0xc0), 0xc976c13bb96e881cb166a933a55e490d9d56952b8d4e801485467d2362422606)
            mstore(add(m, 0xe0), 0x753a6d1b65325d0c552a4d1345224105391a310b29122104190a110309020100)
            mstore(0x40, add(m, 0x100))
            let magic := 0x818283848586878898a8b8c8d8e8f929395969799a9b9d9e9faaeb6bedeeff
            let shift := 0x100000000000000000000000000000000000000000000000000000000000000
            let a := div(mul(x, magic), shift)
            y := div(mload(add(m, sub(255, a))), shift)
            y := add(y, mul(256, gt(arg, 0x8000000000000000000000000000000000000000000000000000000000000000)))
        }
    }

    function calculatePaymentHistoryScore(address user) internal view returns (uint256) {
        Debt[] storage userDebts = userDebt[user];
        uint256 totalScore = 0;
        uint256 debtCount = userDebts.length;

        if (debtCount == 0) {
            return 0;
        }

        for (uint256 i = 0; i < debtCount; i++) {
            int256 impactScore = _calculatePaymentImpact(userDebts[i]);
            // Convert negative scores to 0 to avoid underflow
            if (impactScore > 0) {
                totalScore += uint256(impactScore);
            }
        }

        // Normalize score to be between 0-400
        uint256 normalizedScore = (totalScore * 400) / (debtCount * 100);
        return normalizedScore > 400 ? 400 : normalizedScore;
    }

    function calculateCreditScore(address user) internal {
        uint256 paymentScore = calculatePaymentHistoryScore(user);
        uint256 utilizationScore = calculateCreditUtilizationScore(user);
        uint256 collateralScore = calculateCollateralMixScore(user);
        uint256 lengthScore = calculateLengthOfCreditScore(user, addressOfB);

        // Combine all scores (40% + 30% + 20% + 10%)
        uint256 finalScore = (paymentScore + utilizationScore + collateralScore + lengthScore);

        userCreditScore[user] = finalScore;
    }

    function getCreditScore(address user) external view returns (uint256) {
        return userCreditScore[user];
    }

    ////////////////GETTERS////////////////////

    /**
     *
     * @param user : address of the user
     * @notice This function will get the collaterization ratio of the user
     */
    function getCollateralizationRatio(address user) public view returns (uint256 ratio) {
        ratio = _calculateCollaterizationRatio(user);
    }
}
