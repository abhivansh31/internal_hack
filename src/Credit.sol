//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@prb/math/src/UD60x18.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title A math heavy credit score implementaion for credit lending based on a time period specified by the user
 * @author Anand , Aryan , Abhivansh
 * @notice Credit score will be calculated based on the following factors:
 * @notice 1. Payment history(40%)
 * @notice 2. Credit utilization(30%)
 * @notice 3. Collateral derisking(10%)
 * @notice 4. Credit inquiries(10%)
 * @notice 5. Length of credit history(10%)
 * @notice 6. Credit score will be between 0 to 1000 (IDK why baks keeps 300-850)
 * @notice Interest Rate will depend on the credit score you have.
 * @notice This project is set in the future where common people uses crypto and it will act as replacement to traditional bank. Usually banks fear that a person might default a loan but this protocol is not scared of that. Instead it is more interested in giving out credit as long as collateral meets the requirement. Actually Liquidation is bad for the protocol in the sense that it is more interested in interest accumulated on the person.
 */
contract CreditScore is ReentrancyGuard {
    using UD60x18 for uint256; // Check the library name issue

    IERC20 public immutable TB;
    address public addressOfB;
    address BPriceFeed;
    address[] private collateralTokens;

    /////////////////MAPPINGS////////////////////
    mapping(address => uint256) public ADeposited;
    mapping(address token => address priceFeed) private collateralPriceFeeds; //token -> pricefeeds

    ///////////////CONSTANTS/////////////////////

    /**
     * @dev This is for protocol applier to fix according to them.
     */
    uint256 DEBT_TIME_NORMALISER = 172800000; // 20 days - 100$ each day
    uint256 ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 PRECISION = 1e18;

    ///////////////EVENTs/////////////////////
    event CS__Collateral_Deposited(address token, uint256 amount);

    //////////////ERRORS/////////////////////
    error CS__InvalidCollateralTokenAddress(address token);
    error CS__AmountMustBeMoreThanZero();
    error CS__InvalidDebtTokenAddress(address token);
    error CS_TokenAddressesAndPriceFeedAddressesMustBeSameLength();

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

    // Need to fix this
    modifier validCollateralToken(address token) {
        require(token == addressOfA, CS__InvalidCollateralTokenAddress(token));
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
     * @param amount Amount of the token to be deposited\
     * @dev This function will transfer the collateral token from the user to the contract
     * @dev No checks other than zero amount needed because the more collateral the better
     */
    function depositCollateral(address token, uint256 amount) public moreThanZero(amount) validCollateralToken(token) {
        TA.transferFrom(msg.sender, address(this), amount);
        ADeposited[msg.sender] += amount;
        emit CS__Collateral_Deposited(token, amount);
    }

    function totalCollateralValue() public {}

    ///////////INTERNAL FUNCTIONS////////////////////

    /**
     * @notice Calculates time since debt taken*amount
     */
    function totalDebtTimeValue(address user) internal returns (uint256 debtTimeValue) {}

    function calcuateCreditUtilizationScore(address user, uint256 amount) internal view returns (uint256) {}

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
        uint256 normalisedDebtTimeValue = debtTimeValue.div(DEBT_TIME_NORMALISER);
        score = (negativeExp(normalisedDebtTimeValue) * 100) / 1e18;
    }

    //////////////HELPER FUNCTIONS////////////////////

    /**
     *
     * @param x : value to be exponentiated
     * @notice take x and calculate 1 - e^(-x)
     * @dev Since the result will be always between 0 and 1, we multiply by 1e18 to get a more precise result
     * @dev Multiply the return value with your normalisation scalar and if not multiply by 100. Finally divide by 1e18 to get the final result
     */
    function negativeExp(uint256 x) internal pure returns (uint256) {
        return ((x.exp() - 1).mul(1e18)).div(x.exp);
    }

    /**
     * @notice This function will get the price of the token in USD in e18 precision
     * @param token Address of the token
     * @param amount Amount of the token
     * @dev Do any calculation on the price and finally divide by e18 to get the final result
     */
    function getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(collateralPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount);
    }
}
