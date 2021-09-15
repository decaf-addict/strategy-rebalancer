// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./Rebalancer.sol";
import "../interfaces/Chainlink.sol";


/**
 * Adapts Vault hooks to Balancer Contract and JointAdapter pair
 */
contract JointProvider is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    Rebalancer public rebalancer;
    IPriceFeed public oracle;
    uint256 constant public max = type(uint256).max;
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
    }

    function setRebalancer(address _rebalancer) external onlyAuthorized {
        require(address(rebalancer) == address(0x0), "Rebalancer already set");
        want.approve(_rebalancer, max);
        rebalancer = Rebalancer(_rebalancer);
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

    function estimatedTotalAssets() public view override returns (uint256) {
        return want.balanceOf(address(this)).add(rebalancer.balanceOf(want));
    }

    function harvestTrigger(uint256 callCostInWei) public view override returns (bool){
        return super.harvestTrigger(callCostInWei) && rebalancer.shouldHarvest();
    }

    function tendTrigger(uint256 callCostInWei) public view override returns (bool){
        return rebalancer.shouldTend();
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment) {
        uint256 _before = balanceOfWant();
        rebalancer.collectTradingFees();
        rebalancer.sellRewards();

        uint256 _after = balanceOfWant();

        if (_after > _before) {
            _profit = _after.sub(_before);
        }

        if (_debtOutstanding > 0) {
            if (vault.strategies(address(this)).debtRatio == 0) {
                _debtPayment = rebalancer.liquidateAllPositions(want, address(this));
                if (_debtPayment > _debtOutstanding) {
                    _profit.add(_debtPayment.sub(_debtOutstanding));
                    _debtPayment = _debtOutstanding;
                } else {
                    _loss = _debtOutstanding.sub(_debtPayment);
                }
            } else {
                (_debtPayment, _loss) = rebalancer.liquidatePosition(_debtOutstanding, want, address(this));
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        rebalancer.adjustPosition();
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 _loose = balanceOfWant();
        if (_amountNeeded > _loose) {
            uint256 _amountNeededMore = _amountNeeded.sub(_loose);
            rebalancer.liquidatePosition(_amountNeededMore, want, address(this));
            _liquidatedAmount = balanceOfWant();
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        rebalancer.liquidateAllPositions(want, address(this));
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function prepareMigration(address _newStrategy) internal override {
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        rebalancer.migrateProvider(_newStrategy);
    }

    // only called by rebalancer
    function migrateRebalancer(address _newRebalancer) external {
        require(msg.sender == address(rebalancer), "Not rebalancer!");
        rebalancer = Rebalancer(_newRebalancer);
        want.approve(_newRebalancer, max);
    }

    function protectedTokens() internal view override returns (address[] memory) {
    }

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256) {
        return rebalancer.ethToWant(address(want), _amtInWei);
    }

    // Helpers //
    function balanceOfWant() public view returns (uint256 _balance){
        return want.balanceOf(address(this));
    }

    function totalDebt() public view returns (uint256 _debt){
        return vault.strategies(address(this)).totalDebt;
    }

    function getPriceFeed() public view returns (uint256 _lastestAnswer){
        return oracle.latestAnswer();
    }

    function getPriceFeedDecimals() public view returns (uint256 _dec){
        return oracle.decimals();
    }
}
