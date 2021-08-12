import util
import pytest
import brownie


def test_clone_provider(providerA, providerB, setup, vaultA, vaultB, strategist, rewards, keeper, rebalancer, oracleA,
                        oracleB):
    # providerB is already a clone of providerA, operations with clones are covered in all other tests
    # See providerB fixture
    with brownie.reverts("Strategy already initialized"):
        providerA.initialize(vaultA, strategist, rewards, keeper, oracleA, {'from': strategist})
    assert providerA.name() == "RebalancerYFI-WETH YFIProvider"
    with brownie.reverts("Strategy already initialized"):
        providerB.initialize(vaultB, strategist, rewards, keeper, oracleB, {'from': strategist})
    assert providerB.name() == "RebalancerYFI-WETH WETHProvider"


def test_clone_rebalancer(rebalancer, Rebalancer, setup, testSetup, gov, bpt, tokenA, tokenB, providerA, providerB,
                          pool, rando, transferToRando,
                          reward, reward_whale, vaultA, vaultB, chain):
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    with brownie.reverts("Strategy already initialized"):
        rebalancer.initialize(providerA, providerB, gov, bpt)

    transaction = rebalancer.cloneRebalancer(providerA, providerB, gov, bpt, {"from": gov})
    cloned_rebalancer = Rebalancer.at(transaction.return_value)

    # cloned rebalancer should not have control over the same pool
    with brownie.reverts("ERR_NOT_CONTROLLER"):
        cloned_rebalancer.whitelistLiquidityProvider(cloned_rebalancer, {'from': gov})

    # pass controller to cloned rebalancer
    rebalancer.setController(cloned_rebalancer, {'from': gov})
    cloned_rebalancer.whitelistLiquidityProvider(cloned_rebalancer, {'from': gov})

    bpts = rebalancer.balanceOfBpt()
    rebalancer.migrateRebalancer(cloned_rebalancer, {'from': gov})
    assert cloned_rebalancer.balanceOfBpt() == bpts

    # profitable harvest with new cloned rebalancer
    util.simulate_2_sided_trades(cloned_rebalancer, tokenA, tokenB, providerA, providerB, pool, rando)
    util.simulate_bal_reward(cloned_rebalancer, reward, reward_whale)
    util.stateOfStrat("after bal reward", cloned_rebalancer, providerA, providerB)

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultB.pricePerShare()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    util.stateOfStrat("harvest after swap", cloned_rebalancer, providerA, providerB)

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB
