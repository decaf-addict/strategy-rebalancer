// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
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

    Rebalancer public balancer;
    IPriceFeed public oracle;
    uint256 constant public max = type(uint256).max;

    constructor(address _vault, address _balancer, address _oracle) public BaseStrategy(_vault) {
        _initializeStrat(_balancer, _oracle);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _balancer,
        address _oracle
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_balancer, _oracle);
    }

    function _initializeStrat(address _balancer, address _oracle) internal {
        want.approve(_balancer, max);
        oracle = IPriceFeed(_oracle);
        balancer = Rebalancer(_balancer);
    }

    event Cloned(address indexed clone);

    function cloneProvider(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _balancer,
        address _oracle
    ) external returns (address newStrategy) {
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
            _balancer,
            _oracle
        );

        emit Cloned(newStrategy);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return string(
            abi.encodePacked(balancer.name(), ISymbol(address(want)).symbol(), "Provider")
        );
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return want.balanceOf(address(this)).add(balancer.balanceOf(want));
    }

    function harvestTrigger(uint256 callCostInWei) public view override returns (bool){
        return super.harvestTrigger(callCostInWei) && balancer.shouldHarvest();
    }

    event Debug(string msg, uint256 c);

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment) {
        emit Debug("prepareReturn", _debtOutstanding);
        uint256 _before = balanceOfWant();
        emit Debug("before reap", _debtOutstanding);
        balancer.collectTradingFees();
        balancer.sellRewards();
        emit Debug("after reap", _debtOutstanding);

        uint256 _after = balanceOfWant();
        if (_after > _before) {
            _profit = _after.sub(_before);
        }

        if (_debtOutstanding > 0) {
            emit Debug("if check", _debtOutstanding);
            if (vault.strategies(address(this)).debtRatio == 0) {
                _debtPayment = balancer.liquidateAllPositions(want, address(this));
                if (_debtPayment > _debtOutstanding) {
                    _profit.add(_debtPayment.sub(_debtOutstanding));
                    _debtPayment = _debtOutstanding;
                } else {
                    _loss = _debtOutstanding.sub(_debtPayment);
                }
            } else {
                (_debtPayment, _loss) = balancer.liquidatePosition(_debtOutstanding, want, address(this));
            }
        }
    }


    event Debug(address addr, uint256 c);

    function adjustPosition(uint256 _debtOutstanding) internal override {
        want.transfer(address(balancer), balanceOfWant());
        balancer.adjustPosition();
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 _loose = balanceOfWant();
        if (_amountNeeded > _loose) {
            uint256 _amountNeededMore = _amountNeeded.sub(_loose);
            balancer.liquidatePosition(_amountNeededMore, want, address(this));
            _liquidatedAmount = balanceOfWant();
            _loss = _amountNeeded.sub(_liquidatedAmount);
            emit Debug("_liquidatedAmount", _liquidatedAmount);
            emit Debug("_loss", _loss);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        balancer.liquidateAllPositions(want, address(this));
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function prepareMigration(address _newStrategy) internal override {
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        balancer.migrateProvider(_newStrategy);
    }

    function migrateRebalancer(address _newRebalancer) external {
        require(msg.sender == address(balancer), "Not rebalancer!");
        balancer = Rebalancer(_newRebalancer);
        want.approve(_newRebalancer, max);
    }

    function protectedTokens() internal view override returns (address[] memory) {

    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256) {

    }

    // Helpers //
    function balanceOfWant() public view returns (uint256 _balance){
        return want.balanceOf(address(this));
    }

    function totalDebt() public view returns (uint256 _debt){
        return vault.strategies(address(this)).totalDebt;
    }

    // mind the decimals
    function getPriceFeed() public view returns (uint256 _lastestAnswer){
        return oracle.latestAnswer();
    }

    function getPriceFeedDecimals() public view returns (uint256 _dec){
        return oracle.decimals();
    }
}
