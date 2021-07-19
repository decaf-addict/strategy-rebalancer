// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import "./JointProvider.sol";
import "../interfaces/Balancer.sol";
import "../interfaces/Uniswap.sol";
import "../interfaces/Weth.sol";


/**
 * Maintains liquidity pool and dynamically rebalances pool weights to minimize impermanent loss
 */
contract Rebalancer {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 public reward;
    IERC20 public tokenA;
    IERC20 public tokenB;
    JointProvider public providerA;
    JointProvider public providerB;
    IBalancerPoolToken public bpt;
    IBalancerPool public pool;
    IUniswapV2Router02 public uniswap;
    IWETH9 public constant weth = IWETH9(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    address public government;
    address[] public pathAB;
    address[] public pathBA;
    address[] public pathRewardA;
    address[] public pathRewardB;

    // This is a negligible amount of asset (~$4) donated by the strategist to initialize the balancer pool
    // This amount is always kept in the pool to aid in rebalancing and also prevent pool from ever being fully empty
    uint256 public seedBptAmount = 100 * 1e18;
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

    constructor(address _government, address _bpt) public {
        government = _government;
        bpt = IBalancerPoolToken(_bpt);
        pool = IBalancerPool(bpt.bPool());
        uniswap = IUniswapV2Router02(address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
        reward = IERC20(address(0xba100000625a3754423978a60c9317c58a424e3D));
        reward.approve(address(uniswap), max);
        totalDenormWeight = pool.getTotalDenormalizedWeight();
    }
    event Debug(string msg, uint256 c);
    event Debug(address addr, uint256 c);

    // collect profit from trading fees
    // TODO account for airdrop hitting withdraw limit
    function collectTradingFees() public onlyAllowed {
        // there's profit
        uint256 _debtA = providerA.totalDebt();
        uint256 _debtB = providerB.totalDebt();

        if (_debtA == 0 && _debtB == 0) return;
        uint256 _pooledA = pooledBalanceA();
        uint256 _pooledB = pooledBalanceB();
        uint256 _bptTotal = balanceOfBpt();
        emit Debug("_debtA", _debtA);
        emit Debug("_debtB", _debtB);
        emit Debug("_pooledA", _pooledA);
        emit Debug("_pooledB", _pooledB);
        emit Debug("_bptTotal", _bptTotal);

        if (_pooledA >= _debtA && _pooledB >= _debtB) {
            uint256 _gainA = _pooledA.sub(_debtA);
            uint256 _gainB = _pooledB.sub(_debtB);
            uint256 _looseABefore = looseBalanceA();
            uint256 _looseBBefore = looseBalanceB();
            emit Debug("_gainA", _gainA);
            emit Debug("_gainB", _gainB);
            emit Debug("_looseABefore", _looseABefore);
            emit Debug("_looseBBefore", _looseBBefore);

            if (_gainA > 0) {
                bpt.exitswapExternAmountOut(address(tokenA), _gainA, balanceOfBpt());
                tokenA.transfer(address(providerA), looseBalanceA().sub(_looseABefore));
                emit Debug("looseBalanceA()", looseBalanceA());
            }

            if (_gainB > 0) {
                bpt.exitswapExternAmountOut(address(tokenB), _gainB, balanceOfBpt());
                tokenB.transfer(address(providerB), looseBalanceB().sub(_looseBBefore));
                emit Debug("looseBalanceB()", looseBalanceB());
            }
        }
    }

    // sell reward and distribute evenly to each provider
    function sellRewards() public onlyAllowed {
        uint256 _rewards = balanceOfReward();
        if (_rewards > 0) {
            uint256 _half = balanceOfReward().div(2);
            uniswap.swapExactTokensForTokens(_half, 0, pathRewardA, address(providerA), now);
            uniswap.swapExactTokensForTokens(_half, 0, pathRewardB, address(providerB), now);
        }
    }

    function shouldHarvest() public view returns (bool _shouldHarvest){
        uint256 _debtA = providerA.totalDebt();
        uint256 _debtB = providerB.totalDebt();
        uint256 _pooledA = pooledBalanceA();
        uint256 _pooledB = pooledBalanceB();
        return _pooledA >= _debtA && _pooledB >= _debtB;
    }

    // pull from providers
    function adjustPosition() public onlyAllowed {
        emit Debug("adjustPosition", 0);
        if (providerA.totalDebt() == 0 || providerB.totalDebt() == 0) return;
        tokenA.transferFrom(address(providerA), address(this), providerA.balanceOfWant());
        tokenB.transferFrom(address(providerB), address(this), providerB.balanceOfWant());

        uint256[] memory _minAmounts = new uint256[](2);
        _minAmounts[0] = 0;
        _minAmounts[1] = 0;
        uint256 _bpt = balanceOfBpt();
        if (_bpt > seedBptAmount) {
            bpt.exitPool(_bpt.sub(seedBptAmount), _minAmounts);
        }

        // TODO enforce pool weight limts
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
        emit Debug("_debtA", _debtAUsd);
        emit Debug("_debtB", _debtBUsd);
        emit Debug("_debtTotal", _debtTotalUsd);
        emit Debug("totalDenormWeight", totalDenormWeight);
        emit Debug("_weightDenormedA", _weightDenormedA);
        emit Debug("_weightDenormedB", _weightDenormedB);
        bpt.updateWeight(address(tokenA), _weightDenormedA);
        bpt.updateWeight(address(tokenB), _weightDenormedB);
        emit Debug("pool.currentWeightA()", currentWeightA());
        emit Debug("pool.currentWeightB()", currentWeightB());
        uint256 _looseA = looseBalanceA();
        uint256 _looseB = looseBalanceB();
        uint256 _pooledA = pooledBalanceA();
        uint256 _pooledB = pooledBalanceB();
        uint256 _ratioA = _looseA.div(_pooledA);
        uint256 _ratioB = _looseB.div(_pooledB);
        uint256 _ratio = Math.min(_ratioA, _ratioB);
        uint256 _bptOut = bpt.totalSupply().mul(_ratio);
        emit Debug("_looseA", _looseA);
        emit Debug("_looseB", _looseB);
        emit Debug("_pooledA", _pooledA);
        emit Debug("_pooledB", _pooledB);
        emit Debug("_ratioA", _ratioA);
        emit Debug("_ratioB", _ratioB);
        emit Debug("_bptOut", _bptOut);

        uint256[] memory _maxAmountIn = new uint256[](2);
        _maxAmountIn[0] = _looseA;
        _maxAmountIn[1] = _looseB;
        _bptOut = _bptOut.mul(98).div(100);
        bpt.joinPool(_bptOut, _maxAmountIn);
        emit Debug("_looseA", looseBalanceA());
        emit Debug("_looseB", looseBalanceB());
        emit Debug("_pooledA", pooledBalanceA());
        emit Debug("_pooledB", pooledBalanceB());

        // when at limit, don't pool in rest of balance since
        // it'll just create positive slippage opportunities for arbers
        if (!_atWeightLimit) {
            bpt.joinswapExternAmountIn(address(tokenA), looseBalanceA(), 0);
            bpt.joinswapExternAmountIn(address(tokenB), looseBalanceB(), 0);
        }
    }

    function liquidatePosition(uint256 _amountNeeded, IERC20 _token, address _to) public onlyAllowed returns (uint256 _liquidated, uint256 _short){
        require(_to == address(providerA) || _to == address(providerB));
        uint256 _loose = _token.balanceOf(address(this));
        emit Debug("_amountNeeded", _amountNeeded);

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
            _bptNeeded = _bptNeeded.mul(1001).div(1000);

            emit Debug("_amountNeededMore", _amountNeededMore);
            emit Debug("_pooled", _pooled);
            emit Debug("_percentBptNeeded", _percentBptNeeded);
            emit Debug("_bptNeeded", _bptNeeded);
            uint256 _bptOut = Math.min(_bptNeeded, _bptTotal.sub(seedBptAmount));
            if (_bptOut > 0) {
                bpt.exitPool(_bptOut, _minAmountsOut);
                _liquidated = Math.min(_amountNeeded, _token.balanceOf(address(this)));
            }
        } else {
            _liquidated = _amountNeeded;
        }
        emit Debug("_amount", _liquidated);

        _token.transfer(_to, _liquidated);
        _short = _amountNeeded.sub(_liquidated);
    }

    function liquidateAllPositions(IERC20 _token, address _to) public onlyAllowed returns (uint256 _liquidatedAmount){
        emit Debug("liquidateAllPositions", 0);
        require(_to == address(providerA) || _to == address(providerB));
        uint256[] memory _minAmountsOut = new uint256[](2);
        // tolerance can be tweaked
        _minAmountsOut[0] = pooledBalanceA().mul(99).div(100);
        _minAmountsOut[1] = pooledBalanceB().mul(99).div(100);
        uint256 _bptOut = bpt.balanceOf(address(this)).sub(seedBptAmount);
        if (_bptOut > 0) {
            bpt.exitPool(_bptOut, _minAmountsOut);
            evenOut();
        }
        _liquidatedAmount = _token.balanceOf(address(this));
        _token.transfer(_to, _liquidatedAmount);
    }

    // only applicable when pool is skewed and strat wants to completely pull out
    function evenOut() internal {
        emit Debug("evenOut", 0);

        uint256 _looseA = looseBalanceA();
        uint256 _looseB = looseBalanceB();
        uint256 _debtA = providerA.totalDebt();
        uint256 _debtB = providerB.totalDebt();
        uint256 _amount;
        address[] memory path;
        emit Debug("_looseA", _looseA);
        emit Debug("_looseB", _looseB);
        emit Debug("_debtA", _debtA);
        emit Debug("_debtB", _debtB);

        if (_looseA > _debtA && _looseB < _debtB) {
            // we have more A than B, sell some A
            _amount = _looseA.sub(_debtA);
            path = pathAB;
        } else if (_looseB > _debtB && _looseA < _debtA) {
            // we have more B than A, sell some B
            _amount = _looseB.sub(_debtB);
            path = pathBA;
        }
        emit Debug("_amount", _amount);
        if (_amount > 0) {
            uniswap.swapExactTokensForTokens(_amount, 0, path, address(this), now);
        }
    }


    // Helpers //

    function setProviders(address _providerA, address _providerB) public onlyAllowed {
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

    function setReward(address _reward) external onlyAllowed {
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
    function setController(address _controller) external onlyAllowed {
        bpt.setController(_controller);
    }

    function setSwapFee(uint256 _fee) external onlyAllowed {
        bpt.setSwapFee(_fee);
    }

    function setPublicSwap(bool _isPublic) external onlyAllowed {
        bpt.setPublicSwap(_isPublic);
    }

    function whitelistLiquidityProvider(address _lp) external onlyAllowed {
        bpt.whitelistLiquidityProvider(_lp);
    }

    function removeWhitelistedLiquidityProvider(address _lp) external onlyAllowed {
        bpt.removeWhitelistedLiquidityProvider(_lp);
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

    //  updates providers
    function migrateRebalancer(address _newRebalancer) external onlyAllowed {
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

