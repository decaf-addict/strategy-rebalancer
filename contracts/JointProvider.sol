// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/IRebalancer.sol";
import "../interfaces/Chainlink.sol";
import "../interfaces/ISymbol.sol";


/**
 * Adapts Vault hooks to Balancer Contract and JointAdapter pair
 */
contract JointProvider is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint;

    IRebalancer public rebalancer;
    IPriceFeed public oracle;
    uint constant public max = type(uint).max;
    bool internal isOriginal = true;

    constructor(address _vault, address _oracle) public BaseStrategy(_vault) {
        _initializeStrat(_oracle);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _oracle
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_oracle);
    }

    function _initializeStrat(address _oracle) internal {
        oracle = IPriceFeed(_oracle);
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);
    }

    function setRebalancer(address payable _rebalancer) external onlyVaultManagers {
        want.approve(_rebalancer, max);
        rebalancer = IRebalancer(_rebalancer);
        require(rebalancer.tokenA() == want || rebalancer.tokenB() == want);
    }

    event Cloned(address indexed clone);

    function cloneProvider(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _oracle
    ) external returns (address newStrategy) {
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

        JointProvider(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _oracle
        );

        emit Cloned(newStrategy);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        if (address(rebalancer) == address(0x0)) {
            return string(abi.encodePacked(ISymbol(address(want)).symbol(), " JointProvider "));
        } else {
            return string(
                abi.encodePacked(rebalancer.name()[0], ISymbol(address(want)).symbol(), " JointProvider ", rebalancer.name()[1])
            );
        }
    }

    function estimatedTotalAssets() public view override returns (uint) {
        return want.balanceOf(address(this)).add(rebalancer.totalBalanceOf(want));
    }

    function harvestTrigger(uint callCostInWei) public view override returns (bool){
        return super.harvestTrigger(callCostInWei) && rebalancer.shouldHarvest();
    }

    function tendTrigger(uint callCostInWei) public view override returns (bool){
        return rebalancer.shouldTend();
    }

    function prepareReturn(uint _debtOutstanding) internal override returns (uint _profit, uint _loss, uint _debtPayment) {
        uint beforeWant = balanceOfWant();
        rebalancer.collectTradingFees();
        _profit += balanceOfWant().sub(beforeWant);

        if (_debtOutstanding > 0) {
            if (vault.strategies(address(this)).debtRatio == 0) {
                _debtPayment = _liquidateAllPositions();
                _loss = _debtOutstanding > _debtPayment ? _debtOutstanding.sub(_debtPayment) : 0;
            } else {
                (_debtPayment, _loss) = _liquidatePosition(_debtOutstanding);
            }
        }

        // Interestingly, if you overpay on debt payment, the overpaid amount just sits in the strat.
        // Report overpayment as profit
        if (_debtPayment > _debtOutstanding) {
            _profit += _debtPayment.sub(_debtOutstanding);
            _debtPayment = _debtOutstanding;
        }

        beforeWant = balanceOfWant();
        rebalancer.sellRewards();
        _profit += balanceOfWant().sub(beforeWant);

        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _profit = 0;
        }
    }

    // called by tend. 0 bc there's no change in debt
    function adjustPosition(uint _debtOutstanding) internal override {
        _adjustPosition(0);
    }

    // Called during withdraw in order to rebalance to the new debt.
    // This is necessary so that withdraws will rebalance immediately (instead of waiting for keeper)
    function _adjustPosition(uint _amountWithdrawn) internal {
        rebalancer.adjustPosition(_amountWithdrawn, want);
    }

    // without adjustPosition. Called internally by prepareReturn. Harvests will call adjustPosition after.
    function _liquidatePosition(uint _amountNeeded) internal returns (uint _liquidatedAmount, uint _loss) {
        uint loose = balanceOfWant();
        uint pooled = rebalancer.pooledBalance(rebalancer.tokenIndex(want));

        if (_amountNeeded > loose) {
            uint _amountNeededMore = _amountNeeded.sub(loose);
            if (_amountNeededMore >= pooled) {
                rebalancer.liquidateAllPositions(want, address(this));
            } else {
                rebalancer.liquidatePosition(_amountNeededMore, want, address(this));
            }
            _liquidatedAmount = balanceOfWant();
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
            _loss = 0;
        }
    }

    // called when user withdraws from vault. Rebalance after
    function liquidatePosition(uint _amountNeeded) internal override returns (uint _liquidatedAmount, uint _loss) {
        (_liquidatedAmount, _loss) = _liquidatePosition(_amountNeeded);
        _adjustPosition(_amountNeeded);
    }

    // without adjustPosition. Called internally by prepareReturn. Harvests will call adjustPosition after.
    function _liquidateAllPositions() internal returns (uint _amountFreed) {
        rebalancer.liquidateAllPositions(want, address(this));
        return want.balanceOf(address(this));
    }

    // called during emergency exit. Rebalance after to halt pool
    function liquidateAllPositions() internal override returns (uint _amountFreed) {
        _amountFreed = _liquidateAllPositions();
        _adjustPosition(type(uint).max);
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function prepareMigration(address _newStrategy) internal override {
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        rebalancer.migrateProvider(_newStrategy);
    }

    // only called by rebalancer
    function migrateRebalancer(address payable _newRebalancer) external {
        require(msg.sender == address(rebalancer), "Not rebalancer!");
        rebalancer = IRebalancer(_newRebalancer);
        want.approve(_newRebalancer, max);
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint _amtInWei) public view virtual override returns (uint) {
        return rebalancer.ethToWant(address(want), _amtInWei);
    }

    // Helpers //
    function balanceOfWant() public view returns (uint _balance){
        return want.balanceOf(address(this));
    }

    function totalDebt() public view returns (uint _debt){
        return vault.strategies(address(this)).totalDebt;
    }

    function getPriceFeed() public view returns (uint _lastestAnswer){
        return oracle.latestAnswer();
    }

    function getPriceFeedDecimals() public view returns (uint _dec){
        return oracle.decimals();
    }

    function isVaultManagers(address _address) public view returns (bool){
        return _address == vault.governance() || _address == vault.management();
    }
}
