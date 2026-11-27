# utxo-contract

UtxoChain is a Solidity contract that holds ETH, or one ERC-20 token, as a
Bitcoin-style UTXO set. Lightning nodes use it as their chain: the
[evm-plugin](https://github.com/liquid-lightning/evm-plugin) presents the
contract to Core Lightning as a chain of Bitcoin blocks, so channels are
funded, closed and enforced by Bitcoin transactions that the contract
validates.

> **Status: MVP, not production ready.** The contract has not been audited.
> It is open-source code for test networks and must not hold funds that
> matter.

The Hardhat project is in [`evm/`](evm/), and [`evm/README.md`](evm/README.md)
covers the contracts, the tests and deployment. The contracts have no
external dependencies. The Python generator of the test vectors lives in the
evm-plugin repository.

## Related repositories

- [evm-plugin](https://github.com/liquid-lightning/evm-plugin), the Core Lightning backend plugin and the specification (`SPEC.md`, section 4)
- [Core Lightning fork](https://github.com/MarkCherepovskyi/lightning)

## Licence

MIT, see [LICENSE](LICENSE).
