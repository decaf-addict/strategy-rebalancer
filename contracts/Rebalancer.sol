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
    using SafeMath for uint;

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
    IAsset[] public assets;

    address[] private pathAB;
    address[] private pathBA;
    address[] private pathRewardA;
    address[] private pathRewardB;
    address[] private pathWethA;
    address[] private pathWethB;
    uint[] private minAmountsOut;


    // This is a negligible amount of asset (~$4 = 100 bpt) donated by the strategist to initialize the balancer pool
    // This amount is always kept in the pool to aid in rebalancing and also prevent pool from ever being fully empty
    uint constant private max = type(uint).max;
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

        minAmountsOut = new uint[](2);
        tendBuffer = 0.001 * 1e18;

        _setProviders(_providerA, _providerB);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint[] memory initialWeights = new uint[](2);
        initialWeights[0] = uint(0.5 * 1e18);
        initialWeights[1] = uint(0.5 * 1e18);

        lbpFactory = ILiquidityBootstrappingPoolFactory(_lbpFactory);
        lbp = ILiquidityBootstrappingPool(
            lbpFactory.create(
                "YFI-WETH Pool", "YFI-WETH yBPT",
                tokens,
                initialWeights,
                0.01 * 1e18,
                address(this),
                true)
        );
        bVault = IBalancerVault(lbp.getVault());
        tokenA.approve(address(bVault), max);
        tokenB.approve(address(bVault), max);

        assets = [IAsset(address(tokenA)), IAsset(address(tokenB))];
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
        uint _debtA = providerA.totalDebt();
        uint _debtB = providerB.totalDebt();

        if (_debtA == 0 || _debtB == 0) return;

        uint _pooledA = pooledBalanceA();
        uint _pooledB = pooledBalanceB();
        uint _lbpTotal = balanceOfLbp();

        // there's profit
        if (_pooledA >= _debtA && _pooledB >= _debtB) {
            uint _gainA = _pooledA.sub(_debtA);
            uint _gainB = _pooledB.sub(_debtB);
            uint _looseABefore = looseBalanceA();
            uint _looseBBefore = looseBalanceB();

            uint[] memory amountsOut = new uint[](2);
            amountsOut[0] = _gainA;
            amountsOut[1] = _gainB;
            _exitPool(abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, balanceOfLbp()));

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
        uint _rewards = balanceOfReward();
        if (_rewards > 0) {
            uint _rewardsA = _rewards.mul(currentWeightA()).div(1e18);
            uint _rewardsB = _rewards.sub(_rewardsA);
            // TODO migrate to ySwapper when ready
            uniswap.swapExactTokensForTokens(_rewardsA, 0, pathRewardA, address(providerA), now);
            uniswap.swapExactTokensForTokens(_rewardsB, 0, pathRewardB, address(providerB), now);
        }
    }

    function shouldHarvest() public view returns (bool _shouldHarvest){
        uint _debtA = providerA.totalDebt();
        uint _debtB = providerB.totalDebt();
        uint _pooledA = pooledBalanceA();
        uint _pooledB = pooledBalanceB();
        return (_pooledA >= _debtA && _pooledB > _debtB) || (_pooledA > _debtA && _pooledB >= _debtB);
    }

    // If positive slippage caused by market movement is more than our swap fee, adjust position to erase positive slippage
    // since positive slippage for user = negative slippage for pool aka loss for strat
    function shouldTend() public view returns (bool _shouldTend){
        uint debtAUsd = providerA.totalDebt().mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals());
        uint debtBUsd = providerB.totalDebt().mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals());
        uint idealAUsd = debtAUsd.add(debtBUsd).mul(currentWeightA()).div(1e18);
        uint idealBUsd = debtAUsd.add(debtBUsd).sub(idealAUsd);

        uint weightIn = idealAUsd > debtAUsd ? currentWeightA() : currentWeightB();
        uint weightOut = idealAUsd > debtAUsd ? currentWeightB() : currentWeightA();
        uint balanceIn = idealAUsd > debtAUsd ? pooledBalanceA() : pooledBalanceB();
        uint balanceOut = idealAUsd > debtAUsd ? pooledBalanceB() : pooledBalanceA();
        uint amountIn = idealAUsd > debtAUsd
        ? idealAUsd.sub(debtAUsd).mul(10 ** providerA.getPriceFeedDecimals()).div(providerA.getPriceFeed())
        : idealBUsd.sub(debtBUsd).mul(10 ** providerB.getPriceFeedDecimals()).div(providerB.getPriceFeed());
        uint amountOutIfNoSlippage = idealAUsd > debtAUsd
        ? debtBUsd.sub(idealBUsd).mul(10 ** providerB.getPriceFeedDecimals()).div(providerB.getPriceFeed())
        : debtAUsd.sub(idealAUsd).mul(10 ** providerA.getPriceFeedDecimals()).div(providerA.getPriceFeed());
        uint outDecimals = idealAUsd > debtAUsd ? decimals(tokenB) : decimals(tokenA);

        // calculate the actual amount out from trade if there were no trading fees
        uint amountOut = calcOutGivenIn(balanceIn, weightIn, balanceOut, weightOut, amountIn, 0);

        // maximum positive slippage for user trading. Evaluate that against our fees.
        if (amountOut > amountOutIfNoSlippage) {
            uint slippage = amountOut.sub(amountOutIfNoSlippage).mul(10 ** outDecimals).div(amountOutIfNoSlippage);
            return slippage > lbp.getSwapFeePercentage().sub(tendBuffer);
        } else {
            return false;
        }
    }


    // pull from providers
    function adjustPosition() public onlyAllowed {
        if (providerA.totalDebt() == 0 || providerB.totalDebt() == 0) return;
        tokenA.transferFrom(address(providerA), address(this), providerA.balanceOfWant());
        tokenB.transferFrom(address(providerB), address(this), providerB.balanceOfWant());


        uint debtAUsd = providerA.totalDebt().mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals());
        uint debtBUsd = providerB.totalDebt().mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals());
        uint debtTotalUsd = debtAUsd.add(debtBUsd);

        uint[] memory newWeights = new uint[](2);
        newWeights[0] = Math.max(Math.min(debtAUsd.mul(1e18).div(debtTotalUsd), 0.96 * 1e18), 0.04 * 1e18);
        newWeights[1] = 1e18 - newWeights[0];

        lbp.updateWeightsGradually(now, now, newWeights);

        uint[] memory maxAmountsIn = new uint[](2);
        maxAmountsIn[0] = looseBalanceA();
        maxAmountsIn[1] = looseBalanceB();

        uint[] memory amountsIn = new uint[](2);
        amountsIn[0] = looseBalanceA();
        amountsIn[1] = looseBalanceB();
        bytes memory userData;
        if (balanceOfLbp() > 0) {
            userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, amountsIn, 0);
        } else {
            userData = abi.encode(IBalancerVault.JoinKind.INIT, amountsIn);
        }
        IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
        bVault.joinPool(lbp.getPoolId(), address(this), address(this), request);

    }

    function liquidatePosition(uint _amountNeeded, IERC20 _token, address _to) public toOnlyAllowed(_to) onlyAllowed returns (uint _liquidated, uint _short){
        uint index = tokenIndex(_token);
        uint _loose = _token.balanceOf(address(this));

        if (_amountNeeded > _loose) {
            uint _pooled = pooledBalance(index);
            uint _amountNeededMore = Math.min(_amountNeeded.sub(_loose), _pooled);

            uint[] memory amountsOut = new uint[](2);
            amountsOut[index] = _amountNeededMore;
            _exitPool(abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, balanceOfLbp()));
            _liquidated = Math.min(_amountNeeded, _token.balanceOf(address(this)));
        } else {
            _liquidated = _amountNeeded;
        }

        _token.transfer(_to, _liquidated);
        _short = _amountNeeded.sub(_liquidated);
    }

    function liquidateAllPositions(IERC20 _token, address _to) public toOnlyAllowed(_to) onlyAllowed returns (uint _liquidatedAmount){
        uint lbpBalance = balanceOfLbp();
        if (lbpBalance > 0) {
            // exit entire position
            _exitPool(abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, lbpBalance));
        }
        _liquidatedAmount = _token.balanceOf(address(this));
        _token.transfer(_to, _liquidatedAmount);
    }

    // only applicable when pool is skewed and strat wants to completely pull out. Sells one token for another
    function evenOut() public onlyAllowed {
        uint _looseA = looseBalanceA();
        uint _looseB = looseBalanceB();
        uint _debtA = providerA.totalDebt();
        uint _debtB = providerB.totalDebt();
        uint _amount;
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
    function _exitPool(bytes memory _userData) internal {
        IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, _userData, false);
        bVault.exitPool(lbp.getPoolId(), address(this), address(this), request);
    }

    function _setProviders(address _providerA, address _providerB) internal {
        providerA = JointProvider(_providerA);
        providerB = JointProvider(_providerB);
        tokenA = providerA.want();
        tokenB = providerB.want();

        tokenA.approve(address(uniswap), max);
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

    function setSwapFee(uint _fee) external onlyAuthorized {
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

    // TODO switch to ySwapper when ready
    function ethToWant(address _want, uint _amtInWei) external view returns (uint _wantAmount){
        if (_amtInWei > 0) {
            address[] memory path = new address[](2);
            if (_want == address(weth)) {
                return _amtInWei;
            } else {
                path[0] = address(weth);
                path[1] = _want;
            }
            return uniswap.getAmountsOut(_amtInWei, path)[1];
        } else {
            return 0;
        }
    }

    function balanceOfReward() public view returns (uint){
        return reward.balanceOf(address(this));
    }

    function balanceOfLbp() public view returns (uint) {
        return lbp.balanceOf(address(this));
    }

    function looseBalanceA() public view returns (uint) {
        return tokenA.balanceOf(address(this));
    }

    function looseBalanceB() public view returns (uint) {
        return tokenB.balanceOf(address(this));
    }

    function pooledBalanceA() public view returns (uint) {
        return pooledBalance(0);
    }

    function pooledBalanceB() public view returns (uint) {
        return pooledBalance(1);
    }

    function pooledBalance(uint index) public view returns (uint) {
        (,uint[] memory balances,) = bVault.getPoolTokens(lbp.getPoolId());
        return balances[index];
    }

    function totalBalanceOf(IERC20 _token) public view returns (uint){
        uint _pooled = pooledBalance(tokenIndex(_token));
        uint _loose = _token.balanceOf(address(this));
        return _pooled.add(_loose);
    }

    function currentWeightA() public view returns (uint) {
        return lbp.getNormalizedWeights()[0];
    }

    function currentWeightB() public view returns (uint) {
        return lbp.getNormalizedWeights()[1];
    }

    function decimals(IERC20 _token) internal view returns (uint _decimals){
        return ERC20(address(_token)).decimals();
    }

    function tokenIndex(IERC20 _token) public view returns (uint _tokenIndex){
        (IERC20[] memory t,,) = bVault.getPoolTokens(lbp.getPoolId());
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

