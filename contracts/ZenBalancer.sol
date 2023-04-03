// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AutomationRegistryInterface2_0.sol";
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';

contract ZenBalancer is ERC20, Ownable, AutomationCompatible {
    address public token1PriceFeed;
    address public token2PriceFeed;
    address public linkPriceFeed;

    address public token1;
    address public token2;
    address public link = "0x326C977E6efc84E512bB9C30f76E30c160eD06FB";

    uint public token1share;
    uint public token2share;

    uint public upkeepId;
    address public upkeepRegistry;

    address public weth = "0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6";
    address public usdc = "0x07865c6E87B9F70255377e024ace6630C1Eaa37F";

    ISwapRouter public immutable swapRouter;

    // For this example, we will set the pool fee to 0.3%.
    uint public constant poolFee = 3000;

    event Rebalanced(uint token1, uint token2);
    event LiquidityDeposit(address depositor, uint weth, uint lp);
    event LiquidityWithdrawl(address withdrawer, uint weth, uint lp);
    event FundUpkeep(uint link, uint amountSwapped, address token);

    constructor(
        address token1Feed,
        address token2Feed,
        address linkFeed,
        address _upkeepRegistry,
        ISwapRouter _swapRouter
    ) ERC20("WETH-USDC", "WETHUSDC") {
        token1PriceFeed = token1Feed;
        token2PriceFeed = token2Feed;
        linkPriceFeed = linkFeed;
        upkeepRegistry = _upkeepRegistry;
        swapRouter = _swapRouter;
    }
    
    function deposit(uint amount, address token) external {

    }

    function withdraw(uint amount) external {
        require(balanceOf(msg.sender) <= amount, "Insufficient balance");
    }

    function calculatePercentage(uint amount, uint bps) public pure returns (uint) {
        require((amount * bps) >= 10_000);
        // example 200 = 2% converted to basis points for proper division is 200
        return (amount * bps )/ 10_000;
    }

    function performRebalance() internal {
        (
            uint token1Balance,
            uint token2Balance,
            bool needsRebalance
        ) = rebalancingValues();

        if (needsRebalance) {
            if (token1Balance < token1Reserves()) {
                uint amountIn = swapExactOutputSingle(token1, token2, token2Balance, 3000);
            } else {
                uint amountIn = swapExactOutputSingle(token2, token1, token1Balance, 3000);
            }

            emit Rebalanced(token1Reserves(), token2Reserves());
        }
    }

    function rebalancingValues() internal view returns (uint token1, uint token2, bool needsRebalance) {
        uint token1PriceInUSD = priceFeedValue(token1PriceFeed);
        uint token2PriceInUSD = priceFeedValue(token2PriceFeed);

        uint token1ReservesInUSD = token1Reserves() * token1PriceInUSD;
        uint token2ReservesInUSD = token2Reserves() * token2PriceInUSD;

        uint total = token1ReservesInUSD + token2ReservesInUSD;

        uint token1SupposedShare = calculatePercentage(total, token1share);
        uint token2SupposedShare = calculatePercentage(total, token2share);

        return (token1SupposedShare / token1ReservesInUSD, token2SupposedShare / token2ReservesInUSD, token1SupposedShare != token1ReservesInUSD);
    }

    function token1Reserves() public returns (uint) {
        return IERC20(token1).balanceOf(address(this));
    }

    function token2Reserves() public returns (uint) {
        return IERC20(token2).balanceOf(address(this));
    }

    function linkReserves() public returns (uint) {
        return IERC20(link).balanceOf(address(this));
    }

    function setShares(uint _token1Share, uint _token2Share) external {
        require((_token1Share + _token2Share) == 10_000, "Invalid amounts");

        token1share = _token1Share;
        token2share = _token2Share;
    }

    function setToken1PriceFeed(address feedAddress) external onlyOwner {
        token1PriceFeed = feedAddress;
    }

    function setToken2PriceFeed(address feedAddress) external onlyOwner {
        token2PriceFeed = feedAddress;
    }

    function setLinkPriceFeed(address feedAddress) external onlyOwner {
        linkPriceFeed = feedAddress;
    }

    function priceFeedValue(address feedAddress) public view returns (int)  {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(feedAddress);

        (
            /* uint80 roundID */,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();

        return price;
    }

    function addFundsToKeeper(uint amount, address tokenIn) internal {
        uint amountIn = swapExactOutputSingle(tokenIn, link, amount, 3000);
        
        AutomationRegistryBaseInterface automationInterface = AutomationRegistryBaseInterface(upkeepRegistry);

        automationInterface.addFunds(upkeepId, amount);
        emit FundUpkeep(amount, amountIn, token1);
    }

    /**
     * Chainlink Upkeep logic
     */
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory) {
        (
            uint token1Balance,
            uint token2Balance,
            bool needsRebalance
        ) = rebalancingValues();

        return (needsRebalance, checkData);
    }
    
    function performUpkeep(bytes calldata performData) external {
        addFundsToKeeper(2);
        performRebalance();
    }

    function swapExactOutputSingle(
        address _tokenIn,
        address _tokenOut,
        uint _amountOut,
        uint _amountInMaximum
    ) internal returns (uint amountIn) {
        ISwapRouter.ExactOutputSingleParams memory params =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: poolFee,
                recipient:  address(this),
                deadline: block.timestamp,
                amountOut: _amountOut,
                amountInMaximum: _amountInMaximum,
                sqrtPriceLimitX96: 0
            });

        // Executes the swap returning the amountIn needed to spend to receive the desired amountOut.
        return swapRouter.exactOutputSingle(params);
    }

    /**
     * Receive function issue the basic token if msg.sender is paying directly
     */
    receive() external payable {}
}
