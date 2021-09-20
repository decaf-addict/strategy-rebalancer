import util
import pytest
import brownie


# def test_clone_provider(providerA, providerB, setup, vaultA, vaultB, strategist, rewards, keeper, rebalancer, oracleA,
#                         oracleB):
#     # providerB is already a clone of providerA, operations with clones are covered in all other tests
#     # See providerB fixture
#     with brownie.reverts("Strategy already initialized"):
#         providerA.initialize(vaultA, strategist, rewards, keeper, oracleA, {'from': strategist})
#     assert providerA.name() == "Rebalancer YFI JointProvider YFI-WETH"
#     with brownie.reverts("Strategy already initialized"):
#         providerB.initialize(vaultB, strategist, rewards, keeper, oracleB, {'from': strategist})
#     assert providerB.name() == "Rebalancer WETH JointProvider YFI-WETH"


def test_clone_rebalancer(rebalancer, Rebalancer, setup, testSetup, gov, lbpFactory, tokenA, tokenB, providerA,
                          providerB, strategist, reward, reward_whale, vaultA, vaultB, chain, RELATIVE_APPROX):
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    with brownie.reverts("Already initialized!"):
        rebalancer.initialize(providerA, providerB, lbpFactory)

    transaction = rebalancer.cloneRebalancer(providerA, providerB, lbpFactory, {"from": gov})
    cloned_rebalancer = Rebalancer.at(transaction.return_value)

    bpts = rebalancer.balanceOfLbp()

    rebalancer.liquidateAllPositions(tokenA, providerA, {'from': gov})
    rebalancer.liquidateAllPositions(tokenB, providerB, {'from': gov})

    chain.sleep(3600)
    chain.mine(1)

    assert rebalancer.balanceOfLbp() == 0

    # setup
    providerA.setRebalancer(cloned_rebalancer, {'from': gov})
    providerB.setRebalancer(cloned_rebalancer, {'from': gov})

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    util.simulate_bal_reward(cloned_rebalancer, reward, reward_whale)
    util.stateOfStrat("after bal reward", cloned_rebalancer, providerA, providerB)

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultB.pricePerShare()

    providerA.harvest({"from": gov})
    util.stateOfStrat("harvestA after swap", cloned_rebalancer, providerA, providerB)
    providerB.harvest({"from": gov})
    util.stateOfStrat("harvestB after swap", cloned_rebalancer, providerA, providerB)

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB
