// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/IJointProvider.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/Uniswap.sol";
import "../interfaces/Weth.sol";
import "../interfaces/ISymbol.sol";
import "./BalancerLib.sol";

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
    IJointProvider public providerA;
    IJointProvider public providerB;
    IUniswapV2Router02 public uniswap;
    IWETH9 private constant weth = IWETH9(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ILiquidityBootstrappingPoolFactory public lbpFactory;
    ILiquidityBootstrappingPool public lbp;
    IBalancerVault public bVault;
    IAsset[] public assets;
    uint[] private minAmountsOut;

    uint constant private max = type(uint).max;
    bool internal isOriginal = true;
    bool internal initJoin;
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
        initJoin = true;
        uniswap = IUniswapV2Router02(address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
        reward = IERC20(address(0xba100000625a3754423978a60c9317c58a424e3D));
        reward.approve(address(uniswap), max);

        _setProviders(_providerA, _providerB);

        minAmountsOut = new uint[](2);
        tendBuffer = 0.001 * 1e18;

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint[] memory initialWeights = new uint[](2);
        initialWeights[0] = uint(0.5 * 1e18);
        initialWeights[1] = uint(0.5 * 1e18);

        lbpFactory = ILiquidityBootstrappingPoolFactory(_lbpFactory);
        lbp = ILiquidityBootstrappingPool(
            lbpFactory.create(
                string(abi.encodePacked(name()[0], name()[1])),
                string(abi.encodePacked(name()[1], " yBPT")),
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

    function name() public view returns (string[] memory) {
        string[] memory names = new string[](2);
        names[0] = "Rebalancer ";
        names[1] = string(abi.encodePacked(ISymbol(address(tokenA)).symbol(), "-", ISymbol(address(tokenB)).symbol()));
        return names;
    }

    // collect profit from trading fees
    function collectTradingFees() public onlyAllowed {
        uint debtA = providerA.totalDebt();
        uint debtB = providerB.totalDebt();

        if (debtA == 0 || debtB == 0) return;

        uint pooledA = pooledBalanceA();
        uint pooledB = pooledBalanceB();
        uint lbpTotal = balanceOfLbp();

        // there's profit
        if (pooledA >= debtA && pooledB >= debtB) {
            uint gainA = pooledA.sub(debtA);
            uint gainB = pooledB.sub(debtB);
            uint looseABefore = looseBalanceA();
            uint looseBBefore = looseBalanceB();

            uint[] memory amountsOut = new uint[](2);
            amountsOut[0] = gainA;
            amountsOut[1] = gainB;
            _exitPool(abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, balanceOfLbp()));

            if (gainA > 0) {
                tokenA.transfer(address(providerA), looseBalanceA().sub(looseABefore));
            }

            if (gainB > 0) {
                tokenB.transfer(address(providerB), looseBalanceB().sub(looseBBefore));
            }
        }
    }

    // sell reward and distribute evenly to each provider
    function sellRewards() public onlyAllowed {
        uint _rewards = balanceOfReward();
        if (_rewards > 0) {
            uint rewardsA = _rewards.mul(currentWeightA()).div(1e18);
            uint rewardsB = _rewards.sub(rewardsA);
            // TODO migrate to ySwapper when ready
            uniswap.swapExactTokensForTokens(rewardsA, 0, _getPath(reward, tokenA), address(providerA), now);
            uniswap.swapExactTokensForTokens(rewardsB, 0, _getPath(reward, tokenB), address(providerB), now);
        }
    }

    function shouldHarvest() public view returns (bool _shouldHarvest){
        uint debtA = providerA.totalDebt();
        uint debtB = providerB.totalDebt();
        uint pooledA = pooledBalanceA();
        uint pooledB = pooledBalanceB();
        return (pooledA >= debtA && pooledB > debtB) || (pooledA > debtA && pooledB >= debtB);
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
        uint amountOut = BalancerMathLib.calcOutGivenIn(balanceIn, weightIn, balanceOut, weightOut, amountIn, 0);

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

        // exit entire position
        uint lbpBalance = balanceOfLbp();
        if (lbpBalance > 0) {
            _exitPool(abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, lbpBalance));
        }

        uint debtAUsd = providerA.totalDebt().mul(providerA.getPriceFeed()).div(10 ** providerA.getPriceFeedDecimals());
        uint debtBUsd = providerB.totalDebt().mul(providerB.getPriceFeed()).div(10 ** providerB.getPriceFeedDecimals());
        uint debtTotalUsd = debtAUsd.add(debtBUsd);

        // update weights to their appropriate priced balances
        uint[] memory newWeights = new uint[](2);
        newWeights[0] = Math.max(Math.min(debtAUsd.mul(1e18).div(debtTotalUsd), 0.96 * 1e18), 0.04 * 1e18);
        newWeights[1] = 1e18 - newWeights[0];
        lbp.updateWeightsGradually(now, now, newWeights);
        bool atLimit = newWeights[0] == 0.96 * 1e18 || newWeights[0] == 0.04 * 1e18;

        uint looseA = looseBalanceA();
        uint looseB = looseBalanceB();

        uint[] memory maxAmountsIn = new uint[](2);
        maxAmountsIn[0] = looseA;
        maxAmountsIn[1] = looseB;

        // re-enter pool with max funds at the appropriate weights
        uint[] memory amountsIn = new uint[](2);
        amountsIn[0] = looseA;
        amountsIn[1] = looseB;

        // 24 comes from 96%/4%. Limiting factor comes from the asset that hits the lower bound.
        if (newWeights[0] == 0.04 * 1e18) {
            amountsIn[1] = looseA.mul(24).mul(providerA.getPriceFeed()).div(providerB.getPriceFeed());
        } else if (newWeights[1] == 0.04 * 1e18) {
            amountsIn[0] = looseB.mul(24).mul(providerB.getPriceFeed()).div(providerA.getPriceFeed());
        }

        bytes memory userData;
        if (initJoin) {
            userData = abi.encode(IBalancerVault.JoinKind.INIT, amountsIn);
            initJoin = false;
        } else {
            userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, amountsIn, 0);
        }
        IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
        bVault.joinPool(lbp.getPoolId(), address(this), address(this), request);

    }

    function liquidatePosition(uint _amountNeeded, IERC20 _token, address _to) public toOnlyAllowed(_to) onlyAllowed returns (uint _liquidated, uint _short){
        uint index = tokenIndex(_token);
        uint loose = _token.balanceOf(address(this));

        if (_amountNeeded > loose) {
            uint _pooled = pooledBalance(index);
            uint _amountNeededMore = Math.min(_amountNeeded.sub(loose), _pooled);

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
        uint looseA = looseBalanceA();
        uint looseB = looseBalanceB();
        uint debtA = providerA.totalDebt();
        uint debtB = providerB.totalDebt();
        uint amount;
        address[] memory path;

        if (looseA > debtA && looseB < debtB) {
            // we have more A than B, sell some A
            amount = looseA.sub(debtA);
            path = _getPath(tokenA, tokenB);
        } else if (looseB > debtB && looseA < debtA) {
            // we have more B than A, sell some B
            amount = looseB.sub(debtB);
            path = _getPath(tokenB, tokenA);
        }
        if (amount > 0) {
            uniswap.swapExactTokensForTokens(amount, 0, path, address(this), now);
        }
    }


    // Helpers //
    function _exitPool(bytes memory _userData) internal {
        IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, _userData, false);
        bVault.exitPool(lbp.getPoolId(), address(this), address(this), request);
    }

    function _setProviders(address _providerA, address _providerB) internal {
        providerA = IJointProvider(_providerA);
        providerB = IJointProvider(_providerB);
        tokenA = providerA.want();
        tokenB = providerB.want();
        tokenA.approve(address(uniswap), max);
        tokenB.approve(address(uniswap), max);
    }

    function setReward(address _reward) public onlyGov {
        reward.approve(address(uniswap), 0);
        reward = IERC20(_reward);
        reward.approve(address(uniswap), max);
    }

    function _getPath(IERC20 _in, IERC20 _out) internal pure returns (address[] memory _path){
        bool isWeth = address(_in) == address(weth) || address(_out) == address(weth);
        _path = new address[](isWeth ? 2 : 3);
        _path[0] = address(_in);
        if (isWeth) {
            _path[1] = address(_out);
        } else {
            _path[1] = address(weth);
            _path[2] = address(_out);
        }
        return _path;
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
        IJointProvider newProvider = IJointProvider(_newProvider);
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
        (, uint[] memory balances,) = bVault.getPoolTokens(lbp.getPoolId());
        return balances[index];
    }

    function totalBalanceOf(IERC20 _token) public view returns (uint){
        uint pooled = pooledBalance(tokenIndex(_token));
        uint loose = _token.balanceOf(address(this));
        return pooled.add(loose);
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

    receive() external payable {}
}

