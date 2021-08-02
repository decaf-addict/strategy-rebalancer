// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import "./JointProvider.sol";
import "../interfaces/Balancer.sol";
import "../interfaces/Uniswap.sol";
import "../interfaces/Weth.sol";


interface ISymbol {
    function symbol() external view returns (string memory);
}
/**
 * Maintains liquidity pool and dynamically rebalances pool weights to minimize impermanent loss
 */
contract Rebalancer {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    struct RebalancerParams {
        uint256 seedBptAmount;
        uint256 joinPoolMultiplier;
        uint256 exitPoolMultiplier;
        uint256 joinPoolMaxTries;
        uint256 tendBuffer;
    }

    IERC20 public reward;
    IERC20 public tokenA;
    IERC20 public tokenB;
    JointProvider public providerA;
    JointProvider public providerB;
    IBalancerPoolToken public bpt;
    IBalancerPool public pool;
    IUniswapV2Router02 public uniswap;
    IWETH9 public constant weth = IWETH9(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    RebalancerParams public params;

    address public government;
    address[] public pathAB;
    address[] public pathBA;
    address[] public pathRewardA;
    address[] public pathRewardB;
    address[] public pathWethA;
    address[] public pathWethB;

    // This is a negligible amount of asset (~$4 = 100 bpt) donated by the strategist to initialize the balancer pool
    // This amount is always kept in the pool to aid in rebalancing and also prevent pool from ever being fully empty
    uint256 constant public max = type(uint256).max;
    uint256 constant public percent4 = 0.04 * 1e18;
    uint256 constant public percent96 = 0.96 * 1e18;
    uint256 public totalDenormWeight;

    modifier onlyAllowed{
        require(
            msg.sender == address(providerA) ||
            msg.sender == address(providerB) ||
            msg.sender == government);
        _;
    }

    modifier onlyGov{
        require(msg.sender == government);
        _;
    }

    constructor(address _government, address _bpt) public {
        _initialize(_government, _bpt);
    }

    function initialize(
        address _government,
        address _bpt
    ) external {
        require(address(bpt) == address(0x0), "Strategy already initialized");
        _initialize(_government, _bpt);
    }

    function _initialize(address _government, address _bpt) internal {
        government = _government;
        bpt = IBalancerPoolToken(_bpt);
        pool = IBalancerPool(bpt.bPool());
        uniswap = IUniswapV2Router02(address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
        reward = IERC20(address(0xba100000625a3754423978a60c9317c58a424e3D));
        reward.approve(address(uniswap), max);
        totalDenormWeight = pool.getTotalDenormalizedWeight();
        params = RebalancerParams(100 * 1e18, 98, 1001, 20, .001 * 1e18);
    }

    event Cloned(address indexed clone);

    function cloneRebalancer(address _government, address _bpt) external returns (address newStrategy) {
        bytes20 addressBytes = bytes20(address(this));

        assembly {
        // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Rebalancer(newStrategy).initialize(_government, _bpt);

        emit Cloned(newStrategy);
    }

    function name() external view returns (string memory) {
        if (address(providerA) == address(0x0) || address(providerB) == address(0x0)) {
            return "";
        } else {
            return string(
                abi.encodePacked("Rebalancer", ISymbol(address(tokenA)).symbol(), "-", ISymbol(address(tokenB)).symbol(), " ")
            );
        }
    }

    // collect profit from trading fees
    function collectTradingFees() public onlyAllowed {
        // there's profit
        uint256 _debtA = providerA.totalDebt();
        uint256 _debtB = providerB.totalDebt();

        if (_debtA == 0 && _debtB == 0) return;

        uint256 _pooledA = pooledBalanceA();
        uint256 _pooledB = pooledBalanceB();
        uint256 _bptTotal = balanceOfBpt();

        if (_pooledA >= _debtA && _pooledB >= _debtB) {
            uint256 _gainA = _pooledA.sub(_debtA);
            uint256 _gainB = _pooledB.sub(_debtB);
            uint256 _looseABefore = looseBalanceA();
            uint256 _looseBBefore = looseBalanceB();

            if (_gainA > 0) {
                bpt.exitswapExternAmountOut(address(tokenA), _gainA, balanceOfBpt());
                tokenA.transfer(address(providerA), looseBalanceA().sub(_looseABefore));

            }

            if (_gainB > 0) {
                bpt.exitswapExternAmountOut(address(tokenB), _gainB, balanceOfBpt());
                tokenB.transfer(address(providerB), looseBalanceB().sub(_looseBBefore));
            }
        }
    }

    // sell reward and distribute evenly to each provider
    function sellRewards() public onlyAllowed {
        uint256 _rewards = balanceOfReward();
        if (_rewards > 0) {
            uint256 _half = balanceOfReward().div(2);
            // TODO migrate to ySwapper when ready
            uniswap.swapExactTokensForTokens(_half, 0, pathRewardA, address(providerA), now);
            uniswap.swapExactTokensForTokens(_half, 0, pathRewardB, address(providerB), now);
        }
    }

    function shouldHarvest() public view returns (bool _shouldHarvest){
        uint256 _debtA = providerA.totalDebt();
        uint256 _debtB = providerB.totalDebt();
        uint256 _pooledA = pooledBalanceA();
        uint256 _pooledB = pooledBalanceB();
        return _pooledA >= _debtA && _pooledB >= _debtB && (_pooledA != _debtA && _pooledB != _debtB);
    }

    // If positive slippage caused by market movement is more than our swap fee, adjust position to erase positive slippage
    // since positive slippage for user = negative slippage for pool aka loss for strat
    function shouldTend() public view returns (bool _shouldTend, uint256, uint256){
        uint256 _debtAUsd = providerA.totalDebt().mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals());
        uint256 _debtBUsd = providerB.totalDebt().mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals());
        uint256 _idealAUsd = _debtAUsd.add(_debtBUsd).mul(pool.getNormalizedWeight(address(tokenA))).div(1e18);
        uint256 _idealBUsd = _debtAUsd.add(_debtBUsd).sub(_idealAUsd);

        uint256 _balanceIn;
        uint256 _balanceOut;
        uint256 _weightIn;
        uint256 _weightOut;
        uint256 _amountIn;
        uint256 _amountOutIfNoSlippage;

        if (_idealAUsd > _debtAUsd) {
            // if value of A is lower, users are incentivized to trade in A for B to make pool evenly balanced
            _weightIn = currentWeightA();
            _weightOut = currentWeightB();
            _balanceIn = pooledBalanceA();
            _balanceOut = pooledBalanceB();
            _amountIn = _idealAUsd.sub(_debtAUsd).mul(10 ** providerA.getPriceFeedDecimals()).div(providerA.getPriceFeed());
            _amountOutIfNoSlippage = _debtBUsd.sub(_idealBUsd).mul(10 ** providerB.getPriceFeedDecimals()).div(providerB.getPriceFeed());

        } else {
            // if value of B is lower, users are incentivized to trade in B for A to make pool evenly balanced
            _weightIn = currentWeightB();
            _weightOut = currentWeightA();
            _balanceIn = pooledBalanceB();
            _balanceOut = pooledBalanceA();
            _amountIn = _idealBUsd.sub(_debtBUsd).mul(10 ** providerB.getPriceFeedDecimals()).div(providerB.getPriceFeed());
            _amountOutIfNoSlippage = _debtAUsd.sub(_idealAUsd).mul(10 ** providerA.getPriceFeedDecimals()).div(providerA.getPriceFeed());
        }

        // calculate the actual amount out from trade
        uint256 _amountOut = pool.calcOutGivenIn(_balanceIn, _weightIn, _balanceOut, _weightOut, _amountIn, 0);

        // maximum positive slippage for user trading.
        if (_amountOut > _amountOutIfNoSlippage) {
            uint256 _slippage = _amountOut.sub(_amountOutIfNoSlippage).mul(1e18).div(_amountOutIfNoSlippage);
            return (_slippage > pool.getSwapFee().sub(params.tendBuffer), _amountOutIfNoSlippage, _amountOut);
        } else {
            return (false, _amountOutIfNoSlippage, _amountOut);
        }
    }


    // pull from providers
    function adjustPosition() public onlyAllowed {
        if (providerA.totalDebt() == 0 || providerB.totalDebt() == 0) return;
        tokenA.transferFrom(address(providerA), address(this), providerA.balanceOfWant());
        tokenB.transferFrom(address(providerB), address(this), providerB.balanceOfWant());

        uint256[] memory _minAmounts = new uint256[](2);
        _minAmounts[0] = 0;
        _minAmounts[1] = 0;
        uint256 _bpt = balanceOfBpt();
        if (_bpt > params.seedBptAmount) {
            bpt.exitPool(_bpt.sub(params.seedBptAmount), _minAmounts);
        }

        uint256 _debtAUsd = providerA.totalDebt().mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals());
        uint256 _debtBUsd = providerB.totalDebt().mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals());
        uint256 _debtTotalUsd = _debtAUsd.add(_debtBUsd);
        bool _atWeightLimit;

        uint256 _weightA = Math.max(Math.min(_debtAUsd.mul(1e18).div(_debtTotalUsd), percent96), percent4);
        if (_weightA == percent4 || _weightA == percent96) {
            _atWeightLimit = true;
        }
        uint256 _weightDenormedA = totalDenormWeight.mul(_weightA).div(1e18);
        uint256 _weightDenormedB = totalDenormWeight.sub(_weightDenormedA);
        bpt.updateWeight(address(tokenA), _weightDenormedA);
        bpt.updateWeight(address(tokenB), _weightDenormedB);
        uint256 _ratioA = looseBalanceA().div(pooledBalanceA());
        uint256 _ratioB = looseBalanceB().div(pooledBalanceB());
        uint256 _ratio = Math.min(_ratioA, _ratioB);
        uint256 _bptOut = bpt.totalSupply().mul(_ratio);

        uint256[] memory _maxAmountIn = new uint256[](2);
        _maxAmountIn[0] = looseBalanceA();
        _maxAmountIn[1] = looseBalanceB();
        _bptOut = _bptOut.mul(params.joinPoolMultiplier).div(100);
        bpt.joinPool(_bptOut, _maxAmountIn);

        // when at limit, don't pool in rest of balance since
        // it'll just create positive slippage opportunities for arbers
        if (!_atWeightLimit) {
            joinPoolSingles();
        }

    }

    function joinPoolSingles() public {
        uint8 count;
        while (count < params.joinPoolMaxTries) {
            count++;
            uint256 _looseA = looseBalanceA();
            uint256 _looseB = looseBalanceB();

            if (_looseA > 0 || _looseB > 0) {
                if (_looseA > 0) bpt.joinswapExternAmountIn(address(tokenA), Math.min(_looseA, pooledBalanceA() / 2), 0);
                if (_looseB > 0) bpt.joinswapExternAmountIn(address(tokenB), Math.min(_looseB, pooledBalanceB() / 2), 0);
            } else {
                return;
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded, IERC20 _token, address _to) public onlyAllowed returns (uint256 _liquidated, uint256 _short){
        require(_to == address(providerA) || _to == address(providerB));
        uint256 _loose = _token.balanceOf(address(this));

        if (_amountNeeded > _loose) {
            uint256 _amountNeededMore = _amountNeeded.sub(_loose);
            uint256 _pooled = pool.getBalance(address(_token));
            uint256[] memory _minAmountsOut = new uint256[](2);
            uint256 _bptTotal = balanceOfBpt();
            _minAmountsOut[0] = 0;
            _minAmountsOut[1] = 0;
            uint256 _percentBptNeeded = _amountNeededMore.mul(1e18).div(_pooled);
            uint256 _bptNeeded = _bptTotal.mul(_percentBptNeeded).div(1e18);

            // Withdraw a little more than needed since pool exits a little short sometimes.
            // This is harmless, as any extras will just be redeposited
            _bptNeeded = _bptNeeded.mul(params.exitPoolMultiplier).div(1000);

            uint256 _bptOut = Math.min(_bptNeeded, _bptTotal.sub(params.seedBptAmount));
            if (_bptOut > 0) {
                bpt.exitPool(_bptOut, _minAmountsOut);
                _liquidated = Math.min(_amountNeeded, _token.balanceOf(address(this)));
            }
        } else {
            _liquidated = _amountNeeded;
        }

        _token.transfer(_to, _liquidated);
        _short = _amountNeeded.sub(_liquidated);
    }

    function liquidateAllPositions(IERC20 _token, address _to) public onlyAllowed returns (uint256 _liquidatedAmount){
        require(_to == address(providerA) || _to == address(providerB));
        uint256[] memory _minAmountsOut = new uint256[](2);
        // tolerance can be tweaked
        _minAmountsOut[0] = pooledBalanceA().mul(99).div(100);
        _minAmountsOut[1] = pooledBalanceB().mul(99).div(100);
        uint256 _bptOut = bpt.balanceOf(address(this)).sub(params.seedBptAmount);
        if (_bptOut > 0) {
            bpt.exitPool(_bptOut, _minAmountsOut);
            evenOut();
        }
        _liquidatedAmount = _token.balanceOf(address(this));
        _token.transfer(_to, _liquidatedAmount);
    }

    // only applicable when pool is skewed and strat wants to completely pull out. Sells one token for another
    function evenOut() internal {
        uint256 _looseA = looseBalanceA();
        uint256 _looseB = looseBalanceB();
        uint256 _debtA = providerA.totalDebt();
        uint256 _debtB = providerB.totalDebt();
        uint256 _amount;
        address[] memory path;

        if (_looseA > _debtA && _looseB < _debtB) {
            // we have more A than B, sell some A
            _amount = _looseA.sub(_debtA);
            path = pathAB;
        } else if (_looseB > _debtB && _looseA < _debtA) {
            // we have more B than A, sell some B
            _amount = _looseB.sub(_debtB);
            path = pathBA;
        }
        if (_amount > 0) {
            uniswap.swapExactTokensForTokens(_amount, 0, path, address(this), now);
        }
    }


    // Helpers //

    function setProviders(address _providerA, address _providerB) public onlyGov {
        require(address(providerA) == address(0x0) && address(tokenA) == address(0x0), "Already initialized!");
        require(address(providerB) == address(0x0) && address(tokenB) == address(0x0), "Already initialized!");

        providerA = JointProvider(_providerA);
        require(pool.getCurrentTokens()[0] == address(providerA.want()));
        tokenA = providerA.want();
        tokenA.approve(address(bpt), max);
        tokenA.approve(address(uniswap), max);

        providerB = JointProvider(_providerB);
        require(pool.getCurrentTokens()[1] == address(providerB.want()));
        tokenB = providerB.want();
        tokenB.approve(address(bpt), max);
        tokenB.approve(address(uniswap), max);

        if (address(tokenA) == address(weth) || address(tokenB) == address(weth)) {
            pathAB = [address(tokenA), address(tokenB)];
            pathBA = [address(tokenB), address(tokenA)];
            if (address(tokenA) == address(weth)) {
                pathRewardA = [address(reward), address(tokenA)];
                pathRewardB = [address(reward), address(weth), address(tokenB)];
            } else {
                pathRewardA = [address(reward), address(weth), address(tokenA)];
                pathRewardB = [address(reward), address(tokenB)];
            }
        } else {
            pathAB = [address(tokenA), address(weth), address(tokenB)];
            pathBA = [address(tokenB), address(weth), address(tokenA)];
            pathRewardA = [address(reward), address(weth), address(tokenA)];
            pathRewardB = [address(reward), address(weth), address(tokenB)];
        }
    }

    function setReward(address _reward) external onlyGov {
        reward = IERC20(_reward);
        reward.approve(address(uniswap), max);
        if (address(tokenA) == address(weth) || address(tokenB) == address(weth)) {
            if (address(tokenA) == address(weth)) {
                pathRewardA = [address(reward), address(tokenA)];
                pathRewardB = [address(reward), address(weth), address(tokenB)];
            } else {
                pathRewardA = [address(reward), address(weth), address(tokenA)];
                pathRewardB = [address(reward), address(tokenB)];
            }
        } else {
            pathRewardA = [address(reward), address(weth), address(tokenA)];
            pathRewardB = [address(reward), address(weth), address(tokenB)];
        }
    }

    // WARNING: IRREVERSIBLE OPERATION
    // Relinquishing controller right will lose control over pool actions
    function setController(address _controller) external onlyGov {
        bpt.setController(_controller);
    }

    function setSwapFee(uint256 _fee) external onlyGov {
        bpt.setSwapFee(_fee);
    }

    function setPublicSwap(bool _isPublic) external onlyGov {
        bpt.setPublicSwap(_isPublic);
    }

    function setGovernment(address _gov) external onlyGov {
        government = _gov;
    }

    function whitelistLiquidityProvider(address _lp) external onlyGov {
        bpt.whitelistLiquidityProvider(_lp);
    }

    function removeWhitelistedLiquidityProvider(address _lp) external onlyGov {
        bpt.removeWhitelistedLiquidityProvider(_lp);
    }

    function setRebalancerParams(RebalancerParams memory _params) external onlyGov {
        params = _params;
    }

    //  called by providers
    function migrateProvider(address _newProvider) external onlyAllowed {
        JointProvider newProvider = JointProvider(_newProvider);
        if (newProvider.want() == tokenA) {
            providerA = newProvider;
        } else if (newProvider.want() == tokenB) {
            providerB = newProvider;
        } else {
            revert("Unsupported token");
        }
    }

    // TODO switch to ySwapper when ready
    function ethToWant(address _want, uint256 _amtInWei) external view returns (uint256 _wantAmount){
        if (_amtInWei > 0) {
            address[] memory path = new address[](2);
            if (_want == address(weth)) {
                return _amtInWei;
            } else {
                path[0] = address(weth);
                path[1] = _want;
            }
            return uniswap.getAmountsOut(_amtInWei, path)[1];
        }
    }

    //  updates providers
    function migrateRebalancer(address _newRebalancer) external onlyGov {
        bpt.transfer(_newRebalancer, balanceOfBpt());
        providerA.migrateRebalancer(_newRebalancer);
        providerB.migrateRebalancer(_newRebalancer);
    }

    function balanceOfReward() public view returns (uint256){
        return reward.balanceOf(address(this));
    }

    function balanceOfBpt() public view returns (uint256) {
        return bpt.balanceOf(address(this));
    }

    function looseBalanceA() public view returns (uint256) {
        return tokenA.balanceOf(address(this));
    }

    function looseBalanceB() public view returns (uint256) {
        return tokenB.balanceOf(address(this));
    }

    function pooledBalanceA() public view returns (uint256) {
        return pool.getBalance(address(tokenA));
    }

    function pooledBalanceB() public view returns (uint256) {
        return pool.getBalance(address(tokenB));
    }

    function balanceOf(IERC20 _token) public view returns (uint256){
        uint256 _pooled = pool.getBalance(address(_token));
        uint256 _loose = _token.balanceOf(address(this));
        return _pooled.add(_loose);
    }

    function currentWeightA() public view returns (uint256) {
        return pool.getDenormalizedWeight(address(tokenA));
    }

    function currentWeightB() public view returns (uint256) {
        return pool.getDenormalizedWeight(address(tokenB));
    }
}

