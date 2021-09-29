from brownie import BalancerMathLib, Rebalancer, JointProvider, accounts, config, network, project, web3


def main():
    with open('./build/contracts/RebalancerFlat.sol', 'w') as f:
        f.write(Rebalancer.get_verification_info()['flattened_source'])
    with open('./build/contracts/JointProviderFlat.sol', 'w') as f:
        f.write(JointProvider.get_verification_info()['flattened_source'])
    with open('./build/contracts/BalancerMathLibFlat.sol', 'w') as f:
        f.write(BalancerMathLib.get_verification_info()['flattened_source'])
