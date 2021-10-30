import pytest
from brownie import config
from brownie import Contract


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def rando(accounts):
    yield accounts.at("0x501D69d00d943EDD5fBE44CA1ab7550f7A518738", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts.at("0x1F93b58fb2cF33CfB68E73E94aD6dD7829b1586D", force=True)


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def tokenA(interface):
    # token_address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"  # USDC
    token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"  # wftm

    yield interface.ERC20(token_address)


@pytest.fixture
def tokenB(interface):
    token_address = "0x82f0B8B456c1A451378467398982d4834b6829c1"  # mim
    # token_address = "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75"  # usdc
    # token_address = "0x29b0Da86e484E1C0029B56e817912d778aC0EC69"  # ftmYFI

    yield interface.ERC20(token_address)


@pytest.fixture
def oracleA():
    feed = "0xf4766552D15AE4d256Ad41B6cf2933482B0680dc"  # wFTM/USD

    yield Contract(feed)


@pytest.fixture
def oracleB():
    feed = "0xf4766552D15AE4d256Ad41B6cf2933482B0680dc"  # USDC/USD
    feed = "0x28de48D3291F31F839274B8d82691c77DF1c5ceD"  # MIM/USD

    yield Contract(feed)


@pytest.fixture
def whaleA(accounts):
    whale = accounts.at("0x39B3bd37208CBaDE74D0fcBDBb12D606295b430a", force=True)  # wftm whale
    return whale


@pytest.fixture
def whaleB(accounts):
    return accounts.at("0x2dd7C9371965472E5A5fD28fbE165007c61439E1", force=True)  # mim whale


@pytest.fixture
def transferToRando(accounts, tokenA, tokenB, rando, whaleA, whaleB):
    amount = 1_000_000 * 10 ** tokenA.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.

    tokenA.transfer(rando, amount, {"from": whaleA})

    amount = 1_000_000 * 10 ** tokenB.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.

    tokenB.transfer(rando, amount, {"from": whaleB})


@pytest.fixture
def amountA(accounts, tokenA, user, whaleA):
    amount = 1_000_000 * 10 ** tokenA.decimals()
    tokenA.transfer(user, amount, {"from": whaleA})
    yield amount


@pytest.fixture
def amountB(accounts, tokenB, user, whaleB):
    amount = 1_000_000 * 10 ** tokenB.decimals()
    tokenB.transfer(user, amount, {"from": whaleB})
    yield amount


@pytest.fixture
def wftm():
    token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"
    yield Contract(token_address)


@pytest.fixture
def wftm_amount(user, wftm):
    wftm_amount = 10 ** wftm.decimals()
    user.transfer(wftm, wftm_amount)
    yield wftm_amount


@pytest.fixture
def vaultA(pm, gov, rewards, guardian, management, tokenA):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(tokenA, gov, rewards, "", "", guardian, management, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    vault.setManagementFee(0, {"from": gov})
    yield vault


@pytest.fixture
def vaultB(pm, gov, rewards, guardian, management, tokenB):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(tokenB, gov, rewards, "", "", guardian, management, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    vault.setManagementFee(0, {"from": gov})
    yield vault


@pytest.fixture
def lbpFactory():
    lbpFactory = Contract("0x458368B3724B5a1c1057A00b28eB03FEb5b64968")
    yield lbpFactory


@pytest.fixture(autouse=True)
def balancerMathLib(gov, BalancerMathLib):
    yield gov.deploy(BalancerMathLib)


@pytest.fixture
def rebalancer(strategist, Rebalancer, providerA, providerB, lbpFactory, balancerMathLib):
    rebalancer = strategist.deploy(Rebalancer, providerA, providerB, lbpFactory)
    rebalancer.init2({'from': strategist})
    yield rebalancer


@pytest.fixture
def rebalancerTestOracle(strategist, Rebalancer, providerATestOracle, providerBTestOracle, lbpFactory, balancerMathLib):
    rebalancer = strategist.deploy(Rebalancer, providerATestOracle, providerBTestOracle, lbpFactory)
    rebalancer.init2({'from': strategist})
    yield rebalancer


@pytest.fixture
def providerA(strategist, keeper, vaultA, JointProvider, gov, oracleA):
    strategy = strategist.deploy(JointProvider, vaultA, oracleA)
    strategy.setKeeper(keeper)
    vaultA.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def providerB(providerA, strategist, keeper, vaultB, JointProvider, gov, oracleB, rewards):
    transaction = providerA.cloneProvider(vaultB, strategist, rewards, keeper, oracleB,
                                          {"from": gov})
    strategy = JointProvider.at(transaction.return_value)
    strategy.setKeeper(keeper, {'from': gov})
    vaultB.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def providerATestOracle(strategist, keeper, vaultA, JointProvider, gov, testOracleA):
    strategy = strategist.deploy(JointProvider, vaultA, testOracleA)
    strategy.setKeeper(keeper)
    vaultA.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def providerBTestOracle(providerATestOracle, strategist, keeper, vaultB, JointProvider, gov, testOracleB,
                        rewards):
    transaction = providerATestOracle.cloneProvider(vaultB, strategist, rewards, keeper, testOracleB,
                                                    {"from": gov})
    strategy = JointProvider.at(transaction.return_value)
    strategy.setKeeper(keeper, {'from': gov})
    vaultB.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def testOracleA(TestOracle, strategist):
    testOracleA = strategist.deploy(TestOracle)
    yield testOracleA


@pytest.fixture
def testOracleB(TestOracle, strategist):
    testOracleB = strategist.deploy(TestOracle)
    yield testOracleB


@pytest.fixture
def crv():
    yield Contract("0x1E4F97b9f9F913c46F1632781732927B9019C68b")


@pytest.fixture
def crv_whale(accounts):
    yield accounts.at("0x374C8ACb146407Ef0AE8F82BaAFcF8f4EC1708CF", force=True)


# Bal
@pytest.fixture
def reward():
    yield Contract("0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e")


@pytest.fixture
def reward_whale(accounts):
    yield accounts.at("0xa2503804ec837D1E4699932D58a3bdB767DeA505", force=True)


@pytest.fixture
def setup(rebalancer, providerA, providerB, gov, user, strategist):
    providerA.setRebalancer(rebalancer, {'from': gov})
    providerB.setRebalancer(rebalancer, {'from': gov})

    # 0.3%
    rebalancer.setSwapFee(0.003 * 1e18, {'from': gov})


@pytest.fixture
def setupTestOracle(rebalancerTestOracle, providerATestOracle, providerBTestOracle, gov, user, strategist):
    providerATestOracle.setRebalancer(rebalancerTestOracle, {'from': gov})
    providerBTestOracle.setRebalancer(rebalancerTestOracle, {'from': gov})

    rebalancerTestOracle.setSwapFee(0.003 * 1e18, {'from': gov})


@pytest.fixture
def testSetup(tokenA, vaultA, amountA, tokenB, vaultB, amountB, user):
    tokenA.approve(vaultA.address, amountA, {"from": user})
    vaultA.deposit(amountA, {"from": user})
    assert tokenA.balanceOf(vaultA.address) == amountA

    print(f'\ndeposited {amountA / 10 ** tokenA.decimals()} tokenA to vaultA\n')

    tokenB.approve(vaultB.address, amountB, {"from": user})
    vaultB.deposit(amountB, {"from": user})
    assert tokenB.balanceOf(vaultB.address) == amountB
    print(f'deposited {amountB / 10 ** tokenB.decimals()} tokenB to vaultB\n')


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
