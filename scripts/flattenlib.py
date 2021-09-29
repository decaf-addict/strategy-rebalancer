from brownie import BalancerMathLib, accounts, config, network, project, web3


def main():
    with open('./build/contracts/RebalancerFlat.sol', 'w') as f:
        f.write(BalancerMathLib.get_verification_info()['flattened_source'])
