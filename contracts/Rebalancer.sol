// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import "./JointProvider.sol";
import "../interfaces/BalancerV2.sol";
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

    IERC20 public reward;
    IERC20 public tokenA;
    IERC20 public tokenB;
    JointProvider public providerA;
    JointProvider public providerB;
    IUniswapV2Router02 public uniswap;
    IWETH9 private constant weth = IWETH9(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ILiquidityBootstrappingPoolFactory public lbpFactory;
    ILiquidityBootstrappingPool public lbp;
    IBalancerVault public bVault;

    address[] private pathAB;
    address[] private pathBA;
    address[] private pathRewardA;
    address[] private pathRewardB;
    address[] private pathWethA;
    address[] private pathWethB;
    uint256[] private minAmountsOut;

    // This is a negligible amount of asset (~$4 = 100 bpt) donated by the strategist to initialize the balancer pool
    // This amount is always kept in the pool to aid in rebalancing and also prevent pool from ever being fully empty
    uint256 constant private max = type(uint256).max;
    uint256 constant private percent4 = 0.04 * 1e18;
    uint256 constant private percent96 = 0.96 * 1e18;
    bool internal isOriginal = true;
    uint public tendBuffer;

    modifier toOnlyAllowed(address _to){
        require(
            _to == address(providerA) ||
            _to == address(providerB) ||
            _to == providerA.getGovernance(), "!allowed");
        _;
    }
    modifier onlyAllowed{
        require(
            msg.sender == address(providerA) ||
            msg.sender == address(providerB) ||
            msg.sender == providerA.getGovernance(), "!allowed");
        _;
    }

    modifier onlyGov{
        require(msg.sender == providerA.getGovernance(), "!governance");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == providerA.strategist() || msg.sender == providerA.getGovernance(), "!authorized");
        _;
    }

    constructor(address _providerA, address _providerB, address _lbpFactory) public {
        _initialize(_providerA, _providerB, _lbpFactory);
    }

    function initialize(
        address _providerA,
        address _providerB,
        address _lbpFactory
    ) external {
        require(address(providerA) == address(0x0) && address(tokenA) == address(0x0), "Already initialized!");
        require(address(providerB) == address(0x0) && address(tokenB) == address(0x0), "Already initialized!");
        _initialize(_providerA, _providerB, _lbpFactory);
    }

    function _initialize(address _providerA, address _providerB, address _lbpFactory) internal {
        uniswap = IUniswapV2Router02(address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
        reward = IERC20(address(0xba100000625a3754423978a60c9317c58a424e3D));
        reward.approve(address(uniswap), max);
        minAmountsOut = new uint256[](2);
        tendBuffer = 0.001 * 1e18;

        lbpFactory = ILiquidityBootstrappingPoolFactory(_lbpFactory);
        _setProviders(_providerA, _providerB);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint[] memory initialWeights = new uint[](2);
        initialWeights[0] = uint(50 * 1e18);
        initialWeights[1] = uint(50 * 1e18);

        lbp = ILiquidityBootstrappingPool(
            lbpFactory.create(
                "YFI-WETH Pool", "YFI-WETH yBPT",
                tokens,
                initialWeights,
                0.01 * 1e18,
                address(this),
                true)
        );
    }

    event Cloned(address indexed clone);

    function cloneRebalancer(address _providerA, address _providerB, address _lbpFactory) external returns (address payable newStrategy) {
        require(isOriginal);

        bytes20 addressBytes = bytes20(address(this));

        assembly {
        // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Rebalancer(newStrategy).initialize(_providerA, _providerB, _lbpFactory);

        emit Cloned(newStrategy);
    }

    function name() external view returns (string[] memory) {
        string[] memory names;
        names[0] = "Rebalancer";
        names[1] = string(abi.encode(ISymbol(address(tokenA)).symbol(), "-", ISymbol(address(tokenB)).symbol()));
        return names;
    }

    // collect profit from trading fees
    function collectTradingFees() public onlyAllowed {
        uint256 _debtA = providerA.totalDebt();
        uint256 _debtB = providerB.totalDebt();

        if (_debtA == 0 || _debtB == 0) return;

        uint256 _pooledA = pooledBalanceA();
        uint256 _pooledB = pooledBalanceB();
        uint256 _lbpTotal = balanceOfLbp();

        // there's profit
        if (_pooledA >= _debtA && _pooledB >= _debtB) {
            uint256 _gainA = _pooledA.sub(_debtA);
            uint256 _gainB = _pooledB.sub(_debtB);
            uint256 _looseABefore = looseBalanceA();
            uint256 _looseBBefore = looseBalanceB();

            uint256[] memory amountsOut = new uint256[](2);
            amountsOut[0] = _gainA;
            amountsOut[1] = _gainB;
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, balanceOfLbp());
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets(), minAmountsOut, userData, false);
            bVault.exitPool(lbp.getPoolId(), address(this), address(this), request);

            if (_gainA > 0) {
                tokenA.transfer(address(providerA), looseBalanceA().sub(_looseABefore));
            }

            if (_gainB > 0) {
                tokenB.transfer(address(providerB), looseBalanceB().sub(_looseBBefore));
            }
        }
    }

    // sell reward and distribute evenly to each provider
    function sellRewards() public onlyAllowed {
        uint256 _rewards = balanceOfReward();
        if (_rewards > 0) {
            uint256 _rewardsA = _rewards.mul(currentWeightA()).div(1e18);
            uint256 _rewardsB = _rewards.sub(_rewardsA);
            // TODO migrate to ySwapper when ready
            uniswap.swapExactTokensForTokens(_rewardsA, 0, pathRewardA, address(providerA), now);
            uniswap.swapExactTokensForTokens(_rewardsB, 0, pathRewardB, address(providerB), now);
        }
    }

    function shouldHarvest() public view returns (bool _shouldHarvest){
        uint256 _debtA = providerA.totalDebt();
        uint256 _debtB = providerB.totalDebt();
        uint256 _pooledA = pooledBalanceA();
        uint256 _pooledB = pooledBalanceB();
        return (_pooledA >= _debtA && _pooledB > _debtB) || (_pooledA > _debtA && _pooledB >= _debtB);
    }

    // If positive slippage caused by market movement is more than our swap fee, adjust position to erase positive slippage
    // since positive slippage for user = negative slippage for pool aka loss for strat
    function shouldTend() public view returns (bool _shouldTend){
        uint256 _debtAUsd = providerA.totalDebt().mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals());
        uint256 _debtBUsd = providerB.totalDebt().mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals());
        uint256 _idealAUsd = _debtAUsd.add(_debtBUsd).mul(currentWeightA()).div(1e18);
        uint256 _idealBUsd = _debtAUsd.add(_debtBUsd).sub(_idealAUsd);

        // Using arrays otherwise we get "CompilerError: Stack too deep, try removing local variables."
        uint256[] memory _balanceInOut = new uint256[](2);
        uint256[] memory _weightInOut = new uint256[](2);
        uint256 _amountIn;
        uint256 _amountOutIfNoSlippage;
        uint256 _outDecimals;

        if (_idealAUsd > _debtAUsd) {
            // if value of A is lower, users are incentivized to trade in A for B to make pool evenly balanced
            _weightInOut[0] = currentWeightA();
            _weightInOut[1] = currentWeightB();
            _balanceInOut[0] = pooledBalanceA();
            _balanceInOut[1] = pooledBalanceB();
            _amountIn = _idealAUsd.sub(_debtAUsd).mul(10 ** providerA.getPriceFeedDecimals()).div(providerA.getPriceFeed());
            _amountOutIfNoSlippage = _debtBUsd.sub(_idealBUsd).mul(10 ** providerB.getPriceFeedDecimals()).div(providerB.getPriceFeed());
            _outDecimals = decimals(tokenB);

        } else {
            // if value of B is lower, users are incentivized to trade in B for A to make pool evenly balanced
            _weightInOut[0] = currentWeightB();
            _weightInOut[1] = currentWeightA();
            _balanceInOut[0] = pooledBalanceB();
            _balanceInOut[1] = pooledBalanceA();
            _amountIn = _idealBUsd.sub(_debtBUsd).mul(10 ** providerB.getPriceFeedDecimals()).div(providerB.getPriceFeed());
            _amountOutIfNoSlippage = _debtAUsd.sub(_idealAUsd).mul(10 ** providerA.getPriceFeedDecimals()).div(providerA.getPriceFeed());
            _outDecimals = decimals(tokenA);
        }

        // calculate the actual amount out from trade if there were no trading fees
        uint256 _amountOut = calcOutGivenIn(_balanceInOut[0], _weightInOut[0], _balanceInOut[1], _weightInOut[1], _amountIn, 0);

        // maximum positive slippage for user trading. Evaluate that against our fees.
        if (_amountOut > _amountOutIfNoSlippage) {
            uint256 _slippage = _amountOut.sub(_amountOutIfNoSlippage).mul(10 ** _outDecimals).div(_amountOutIfNoSlippage);
            return _slippage > lbp.getSwapFeePercentage().sub(tendBuffer);
        } else {
            return false;
        }
    }


    // pull from providers
    function adjustPosition() public onlyAllowed {
        if (providerA.totalDebt() == 0 || providerB.totalDebt() == 0) return;
        tokenA.transferFrom(address(providerA), address(this), providerA.balanceOfWant());
        tokenB.transferFrom(address(providerB), address(this), providerB.balanceOfWant());


        uint256 _debtAUsd = providerA.totalDebt().mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals());
        uint256 _debtBUsd = providerB.totalDebt().mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals());
        uint256 _debtTotalUsd = _debtAUsd.add(_debtBUsd);
        bool _atWeightLimit;

        uint256 _weightA = Math.max(Math.min(_debtAUsd.mul(1e18).div(_debtTotalUsd), percent96), percent4);
        if (_weightA == percent4 || _weightA == percent96) {
            _atWeightLimit = true;
        }
        uint weightB = 100 * 1e18 - _weightA;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = looseBalanceA();
        maxAmountsIn[1] = looseBalanceB();

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = looseBalanceA();
        amountsIn[1] = looseBalanceB();
        bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, amountsIn, 0);
        IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets(), maxAmountsIn, userData, false);
        bVault.joinPool(lbp.getPoolId(), address(this), address(this), request);
    }

    function liquidatePosition(uint256 _amountNeeded, IERC20 _token, address _to) public onlyAllowed returns (uint256 _liquidated, uint256 _short){
        uint index = tokenIndex(_token);
        uint256 _loose = _token.balanceOf(address(this));

        if (_amountNeeded > _loose) {
            uint256 _pooled = pooledBalance(index);
            uint256 _amountNeededMore = Math.min(_amountNeeded.sub(_loose), _pooled);

            uint256[] memory amountsOut = new uint256[](2);
            amountsOut[index] = _amountNeededMore;
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, balanceOfLbp());
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets(), minAmountsOut, userData, false);
            bVault.exitPool(lbp.getPoolId(), address(this), address(this), request);
            _liquidated = Math.min(_amountNeeded, _token.balanceOf(address(this)));
        } else {
            _liquidated = _amountNeeded;
        }

        _token.transfer(_to, _liquidated);
        _short = _amountNeeded.sub(_liquidated);
    }

    function liquidateAllPositions(IERC20 _token, address _to) public toOnlyAllowed(_to) onlyAllowed returns (uint256 _liquidatedAmount){
        uint256 lbpBalance = balanceOfLbp();
        if (lbpBalance > 0) {
            // exit entire position
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, lbpBalance);
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets(), minAmountsOut, userData, false);
            bVault.exitPool(lbp.getPoolId(), address(this), address(this), request);
        }
        _liquidatedAmount = _token.balanceOf(address(this));
        _token.transfer(_to, _liquidatedAmount);
    }

    // only applicable when pool is skewed and strat wants to completely pull out. Sells one token for another
    function evenOut() public onlyAllowed {
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

    function _setProviders(address _providerA, address _providerB) internal {
        IERC20[] memory tokens = tokens();
        providerA = JointProvider(_providerA);
        require(tokens[0] == providerA.want());
        tokenA = providerA.want();
        tokenA.approve(address(bVault), max);
        tokenA.approve(address(uniswap), max);

        providerB = JointProvider(_providerB);
        require(tokens[1] == providerB.want());
        tokenB = providerB.want();
        tokenB.approve(address(bVault), max);
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
        reward.approve(address(uniswap), 0);
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

    function setSwapFee(uint256 _fee) external onlyAuthorized {
        lbp.setSwapFeePercentage(_fee);
    }

    function setPublicSwap(bool _isPublic) external onlyGov {
        lbp.setSwapEnabled(_isPublic);
    }

    function setTendBuffer(uint _newBuffer) external onlyAuthorized {
        require(_newBuffer < lbp.getSwapFeePercentage());
        tendBuffer = _newBuffer;
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
    function migrateRebalancer(address payable _newRebalancer) external onlyGov {
        lbp.transfer(_newRebalancer, balanceOfLbp());
        providerA.migrateRebalancer(_newRebalancer);
        providerB.migrateRebalancer(_newRebalancer);
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

    function balanceOfReward() public view returns (uint256){
        return reward.balanceOf(address(this));
    }

    function balanceOfLbp() public view returns (uint256) {
        return lbp.balanceOf(address(this));
    }

    function looseBalanceA() public view returns (uint256) {
        return tokenA.balanceOf(address(this));
    }

    function looseBalanceB() public view returns (uint256) {
        return tokenB.balanceOf(address(this));
    }

    function pooledBalanceA() public view returns (uint256) {
        return pooledBalance(0);
    }

    function pooledBalanceB() public view returns (uint256) {
        return pooledBalance(1);
    }

    function pooledBalance(uint index) public view returns (uint256) {
        (,uint[] memory balances,) = bVault.getPoolTokens(lbp.getPoolId());
        return balances[index];
    }

    function totalBalanceOf(IERC20 _token) public view returns (uint256){
        uint256 _pooled = pooledBalance(tokenIndex(_token));
        uint256 _loose = _token.balanceOf(address(this));
        return _pooled.add(_loose);
    }

    function currentWeightA() public view returns (uint256) {
        return lbp.getNormalizedWeights()[0];
    }

    function currentWeightB() public view returns (uint256) {
        return lbp.getNormalizedWeights()[1];
    }

    function decimals(IERC20 _token) internal view returns (uint _decimals){
        return ERC20(address(_token)).decimals();
    }

    function tokens() public view returns (IERC20[] memory _tokens){
        (_tokens,,) = bVault.getPoolTokens(lbp.getPoolId());
    }

    function assets() public view returns (IAsset[] memory _assets){
        IERC20[] memory _tokens = tokens();
        for (uint i = 0; i < _tokens.length; i++) {
            _assets[i] = IAsset(address(_tokens[i]));
        }
        return _assets;
    }

    function tokenIndex(IERC20 _token) public view returns (uint _tokenIndex){
        IERC20[] memory t = tokens();
        if (t[0] == _token) {
            _tokenIndex = 0;
        } else if (t[1] == _token) {
            _tokenIndex = 1;
        } else {
            revert();
        }
        return _tokenIndex;
    }

    function calcOutGivenIn(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint tokenAmountIn,
        uint swapFee
    ) public pure returns (uint tokenAmountOut){
        //        uint weightRatio = bdiv(tokenWeightIn, tokenWeightOut);
        //        uint adjustedIn = bsub(BONE, swapFee);
        //        adjustedIn = bmul(tokenAmountIn, adjustedIn);
        //        uint y = bdiv(tokenBalanceIn, badd(tokenBalanceIn, adjustedIn));
        //        uint foo = bpow(y, weightRatio);
        //        uint bar = bsub(1e18, foo);
        //        tokenAmountOut = bmul(tokenBalanceOut, bar);
        //        return tokenAmountOut;
        return 0;
    }

    receive() external payable {}
}

