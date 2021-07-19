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
    token_address = "0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e"  # YFI
    yield interface.ERC20(token_address)


@pytest.fixture
def tokenB(interface):
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"  # WETH
    yield interface.ERC20(token_address)


@pytest.fixture
def oracleA():
    feed = "0xA027702dbb89fbd58938e4324ac03B58d812b0E1"  # YFI/USD
    yield Contract(feed)


@pytest.fixture
def oracleB():
    feed = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"  # ETH/USD
    yield Contract(feed)


@pytest.fixture
def transferToRando(accounts, tokenA, tokenB, rando):
    amount = 1000 * 10 ** tokenA.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.

    # YFI whale
    reserve = accounts.at("0x3ff33d9162aD47660083D7DC4bC02Fb231c81677", force=True)

    tokenA.transfer(rando, amount, {"from": reserve})

    amount = 10000 * 10 ** tokenB.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.

    # WETH whale
    reserve = accounts.at("0x2F0b23f53734252Bda2277357e97e1517d6B042A", force=True)
    tokenB.transfer(rando, amount, {"from": reserve})


@pytest.fixture
def amountA(accounts, tokenA, user):
    amount = 1000 * 10 ** tokenA.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.

    # YFI whale
    reserve = accounts.at("0x3ff33d9162aD47660083D7DC4bC02Fb231c81677", force=True)

    tokenA.transfer(user, amount, {"from": reserve})

    yield amount


@pytest.fixture
def amountB(accounts, tokenB, user):
    amount = 10000 * 10 ** tokenB.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.

    # WETH whale
    reserve = accounts.at("0x2F0b23f53734252Bda2277357e97e1517d6B042A", force=True)
    tokenB.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def vaultA(pm, gov, rewards, guardian, management, tokenA):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(tokenA, gov, rewards, "", "", guardian, management, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def vaultB(pm, gov, rewards, guardian, management, tokenB):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(tokenB, gov, rewards, "", "", guardian, management, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def bpt():
    bpt = Contract("0xfA00D65F0873059d2858f1CF7e9a0822754418dd")
    yield bpt


@pytest.fixture
def rebalancer(strategist, bpt, Rebalancer, gov):
    rebalancer = strategist.deploy(Rebalancer, gov, bpt)
    yield rebalancer


@pytest.fixture
def providerA(strategist, keeper, vaultA, JointProvider, gov, rebalancer, oracleA):
    strategy = strategist.deploy(JointProvider, vaultA, rebalancer, oracleA)
    strategy.setKeeper(keeper)
    vaultA.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def providerB(strategist, keeper, vaultB, JointProvider, gov, rebalancer, oracleB):
    strategy = strategist.deploy(JointProvider, vaultB, rebalancer, oracleB)
    strategy.setKeeper(keeper)
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
def owner(accounts):
    yield accounts.at("0x1F93b58fb2cF33CfB68E73E94aD6dD7829b1586D", force=True)


@pytest.fixture
def pool(rebalancer):
    yield Contract(rebalancer.pool())


@pytest.fixture
def crv():
    yield Contract("0xD533a949740bb3306d119CC777fa900bA034cd52")


@pytest.fixture
def crv_whale(accounts):
    yield accounts.at("0xd2D43555134dC575BF7279F4bA18809645dB0F1D", force=True)


# Bal
@pytest.fixture
def reward():
    yield Contract("0xba100000625a3754423978a60c9317c58a424e3D")


@pytest.fixture
def reward_whale(accounts):
    yield accounts.at("0xb618F903ad1d00d6F7b92f5b0954DcdC056fC533", force=True)


@pytest.fixture
def setup(rebalancer, providerA, providerB, gov, bpt, owner, user):
    rebalancer.setProviders(providerA, providerB, {'from': gov})
    bpt.transfer(rebalancer, bpt.balanceOf(owner), {'from': owner})
    bpt.setController(rebalancer, {'from': owner})
    rebalancer.whitelistLiquidityProvider(rebalancer, {'from': gov})


@pytest.fixture
def testSetup(tokenA, vaultA, amountA, tokenB, vaultB, amountB, user):
    tokenA.approve(vaultA.address, amountA, {"from": user})
    vaultA.deposit(amountA, {"from": user})
    assert tokenA.balanceOf(vaultA.address) == amountA
    print(f'\ndeposited {amountA / 1e18} tokenA to vaultA\n')

    tokenB.approve(vaultB.address, amountB, {"from": user})
    vaultB.deposit(amountB, {"from": user})
    assert tokenB.balanceOf(vaultB.address) == amountB
    print(f'deposited {amountB / 1e18} tokenB to vaultB\n')


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
