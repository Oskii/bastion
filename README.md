# Bastion

Bastion is a session wallet. The owner of a normal Ethereum account signs one permission. A factory turns that signature into a short-lived session account. An operator key can then spend a limited number of tokens from the owner and make calls as that session.

The session is built on [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702). That Ethereum change lets an ordinary address (an EOA, an externally owned account, the kind that holds a private key) temporarily run contract code. Bastion does not ask the owner to type a special 7702 signature in a wallet popup. The owner signs a familiar EIP-712 typed message called an `Approval`. The factory recovers who signed it, then uses the same signature numbers `(v, r, s)` to compute the session address. One signature does two jobs: it says who granted the spend, and it names the address that will do the spending.

This repository is labeled `0.0.0-beta`.

## Who the pieces are

There are four roles worth keeping straight before you read the rest.

The **owner** is Alice in the stories below. She holds the main key. She signs an `Approval` that names a token, a number of tokens, a 20-byte operator key, and a salt. That signed number is the lifetime budget for pulling tokens out of her wallet through the factory.

The **operator** is Bob. He is the key Alice named. He is allowed to call `executeWithAllowance` on the session: ask the factory to take some of the remaining budget from Alice, then run a list of calls as the session. If Bob’s key leaks, pulls from Alice should still stop at the signed amount.

The **factory** is `BastionFactory`. It checks the signature (`checkSig`), records a second budget in its own storage (`allowance[owner][session][token]`), and later debits that budget (`consume`) before `transferFrom` on the token.

The **session** is a Bastion account derived from the signature. It is not a separately deployed clone that Alice picks. Same signature numbers, same session address. Tokens that already sit on that address (for example coins moved there by an earlier spend) are session custody. Bob can already send those. That is not the same thing as taking more tokens from Alice.

Two different “allowances” show up in tests and in this README. Do not mix them up.

1. The ERC-20 `approve(factory, …)` on the token contract. Apps often leave a large one. The official test uses 5000.
2. The factory mapping. That is the product cap. The official test signs 100. After two spends it is supposed to read 90, then 80.

The 5000 is leftover slack on the token. The 100 is what Alice meant to grant.

A **digest** is the hash of the typed message Alice signed. Recovering a digest with `(v, r, s)` should produce exactly one signer. If the factory does not remember that a digest was already used, anyone who saw the signature can present it again.

A **chain id** is the number that names a network (1 for Ethereum, and so on). EIP-7702 also treats `0` as a wildcard. If the factory takes a chain id as a free argument and does not put that number in the signed digest, two different numbers can produce two different session addresses from one signature.

The **EntryPoint** is the ERC-4337 contract that accepts a **UserOp** (a packaged account-abstraction transaction) and asks the account to validate it. Bastion implements `validateUserOp` so a bundler can run the session that way.

**RIP-7212** is the precompile that checks P256 signatures, the curve used by many passkeys and secure elements. Bastion has a 64-byte operator path that talks to that precompile.

## What this pull request changes

Hackerbane reviewed `Bastion.sol`, `BastionFactory.sol`, and `types/Structs.sol` at `fb1e67edf5b956a1fb2b56b1ea4faaad194d1ccc`. The public report is here:

**https://hackerbane.com/report/zerodev-bastion**

(The file itself is also at `https://hackerbane.com/reports/hackerbane-HB-AR-2026.10-zerodev-bastion.html`.)

The bugs were not “the operator can do things on the session.” That is the product. The bugs were ways to take more of Alice’s tokens than the signed 100, or to leave a live factory budget pointed at her after the operator slot changed, or to mint a second session from the same signature by passing a different chain id.

This PR keeps the public `checkSig(Approval, uint256 _chainId, uint8 v, bytes32 r, bytes32 s)` shape. `_chainId` must now equal `block.chainid`. The signed `Approval` typehash is unchanged. Rotate the operator with `changeOperator` (`OnlyOwner`).

The rest of this README walks each fix the way a junior engineer who has not seen the audit would need it. Ticket codes are B01 through B07. Those codes match the report. We are not re-opening severity.

## B01. Replay used to refill the factory budget

### The situation

Alice signs `amount = 100` and names Bob. She also does a normal ERC-20 `approve(factory, 5000)`, the way `test/Bastion.t.sol` already does. The factory recovers Alice, derives the session, stores Bob, and writes `allowance[Alice][session][MOCK] = 100`. Bob spends 10. The mapping should now be 90, and should stay 90.

### What was possible before

`checkSig` had no memory that a digest was used. On every valid recover it assigned the signed amount again. Anyone who saw the Approval blob (mempool, logs, a helper who submitted the first call) could call `checkSig` with the same `(v, r, s)`. The row jumped back to 100. Bob spent again. They could repeat that until the 5000 ERC-20 approve was empty.

A control without a second `checkSig` stopped at 100. The next 1-token pull reverted. So the extra 4900 was the replay, not `consume` by itself.

### Why that is bad

Alice thought she granted 100. The leftover 4900 on the token contract was slack, not a second grant. Replay turned that slack into a working spend path for the current operator.

This stayed High rather than Critical because spend still needed Bob (or Alice, or the EntryPoint). A stranger could refill the row. They could not finish `consume` unless they were the current operator.

### What the code does now

`BastionFactory` keeps `mapping(bytes32 digest => bool used) public usedDigest`. After Solady `ECDSA.recover`, `checkSig` reverts `AlreadyUsed()` if that digest is already true, then sets it true before `initialize` and the allowance write.

`require(allowance == 0)` would not have been enough. After a full consume the row is 0, and replay would have worked again.

A new grant is a new salt, which is already in `APPROVAL_TYPE_HASH`, so it is a new digest. Same published `(v, r, s)` plus the same Approval hits `AlreadyUsed()`.

A mutated Approval is a different digest. That is B02, not this mapping.

### How to tell it worked

`test/audit/B01_ReplayBlocked.t.sol`

- `test_B01_firstCheckSigStillWorks` still writes the first row.
- `test_B01_replayAfterPartialConsumeDoesNotRefill` spends 10, then a second `checkSig` reverts `AlreadyUsed`, and the mapping stays 90.

## B02. A second init used to spend Alice’s leftover row

### The situation

The session address is a function of `(chainId, implementation, nonce=0, v, r, s)`. It does not depend on the Approval struct. A new struct under the old signature numbers still lands on the same session.

Alice has already run `checkSig`. Bob is stored as the operator. `allowance[Alice][session][token]` still has leftover budget (100 if nobody spent, 90 if Bob already pulled 10).

### What was possible before

`initialize` had no once-flag. The factory was the only caller, but `checkSig` was open, so that was not a gate. A stranger reused Alice’s published `(v, r, s)` with a new Approval: new salt, operator = attacker. Recovering the new digest yielded some other address, not one the attacker picked. `initialize` overwrote the operator slot. The factory row for Alice was not deleted.

The new operator then called `executeWithAllowance` with `_amount = 0` and a two-call batch: `factory.consume(Alice, token, leftover)`, then `token.transfer(attacker, leftover)`. `consume` keyed the row by the `owner` argument you passed in, not by `bastion.owner()`. The leftover mapping still belonged to Alice.

On a leftover-100 row, Alice went 10000 to 9900 and the attacker received 100. After a 10-token seed pull, Alice went 9990 to 9900 and the attacker received 90.

Tokens already sitting on the session were not this bug. The incumbent operator could already send those.

### Why that is bad

Alice’s unused factory budget was still a live `transferFrom` against her wallet. Changing the operator on the session should not keep that budget pointed at her.

Loss stayed at or under the leftover mapping, not the 5000 slack. The new storage owner was a random recover. Same High bar as B01: leftover `approve(factory)` and a 20-byte operator path.

### What the code does now

`Bastion.initialize` is one-shot. Factory-only. Operator length must be 20 or 64. If `owner` is already set, the same owner and operator return without writing. A different config reverts `AlreadyInitialized()`.

`BastionFactory.consume` now requires `_owner == Bastion(msg.sender).owner()` before the debit and `transferFrom`. A session whose stored owner is no longer Alice cannot `consume(Alice, leftover)`.

Rotate Bob with `changeOperator`. That path is `OnlyOwner`. If you ever rotate through a new `checkSig`, delete the old row first. This PR does not add that delete, because the intended rotate is `changeOperator`.

### How to tell it worked

`test/audit/B02_ReinitBlocked.t.sol`

- A mutated Approval under the old `(v, r, s)` reverts `AlreadyInitialized()`.
- Alice’s tokens stay put.
- Same owner and operator may call `checkSig` again only until B01 marks the digest used. After that, replay is `AlreadyUsed()` anyway.

`consume(originalOwner)` after `transferOwner` also reverts `OnlyOwner`. That is the leftover-row guard, not just the init flag.

## B03. A native 7702 authorization used to look like an Approval

### The situation

EIP-7702 authorization signatures and EIP-712 Approval signatures are different hashes. They can still share the same `(v, r, s)` shape on the wire. `getBastionAddress` recovers the 7702 hash to find the session. `checkSig` recovers the Approval digest to find the signer.

### What was possible before

`checkSig` only required a successful recover. A type-4 authorization over `[chainId, impl, 0]` recovers the authority as the session. A relayer could then `checkSig` with an attacker-chosen operator and initialize that session as itself.

Raising this would have needed a product user who attached this implementation from a funded EOA. The old README never asked for that. The product path is 712 Approval, then a derived session.

### Why that is bad

If someone did type-4 this implementation from a key they fund, the same numbers that set the code could also walk into `checkSig` and set an operator the owner did not name. That is a footgun, not the happy path. We logged it as Informational and still closed the hole.

### What the code does now

After recover, `checkSig` requires `signer != session` and reverts `DelegationSigReuse()`. `signer == address(0)` still reverts `InvalidSigFormat()`. Recover goes through Solady `ECDSA`, which rejects high-`s` and bad `v`.

`usedDigest` (B01) does not fix this. The auth signature is a different hash than `getDigest(approval)`.

Do not `SET_CODE` this implementation from an EOA you fund.

### How to tell it worked

`test/audit/B03_DelegationSigReuse.t.sol`

- `test_B03_requireSignerNotSession_revertsDelegationSigReuse` makes both recover legs return the same nonzero address (Foundry mock of precompile `0x1`) and expects `DelegationSigReuse()`.

## B04. The operator used to send any ETH already on the session

### The situation

`Approval.amount` caps `FACTORY.consume` of Alice’s tokens. It does not talk about ETH. `executeWithAllowance` lets Bob run the same `Call[]` list as Alice, including `value`.

The session has no `receive` / `fallback`. A normal `transfer` / `send` to a 7702 account after delegation often reverts. ETH has to be force-credited (`SELFDESTRUCT` / coinbase / test `vm.deal`) or already sitting on the address before the type-4 attach.

### What was possible before

If 5 ether was already on the session, Bob could call `executeWithAllowance` with `_amount = 0` and `Call{to: attacker, value: 5 ether}`. Session to 0, attacker plus 5 ether. Alice’s EOA ETH did not move.

Session ERC-20 already on the host is executor custody. Tokens parked there by an earlier `consume` could already be sent by Bob. That is not this ticket. This ticket is only the ETH `value` field.

### Why that is bad

The signed budget did not mean anything for ETH on the session. If you wanted “operator spends tokens, owner keeps native,” the code did not say that. We scored it Low because there is no owner-EOA ETH loss path on this pin, and getting ETH onto a 7702 host is awkward in the first place.

### What the code does now

On the 20-byte operator path (`operator.length == 20 && msg.sender == address(bytes20(operator))`), `Call.value != 0` reverts `EthNotAllowed()`. Alice and the EntryPoint may still send value.

### How to tell it worked

`test/audit/B04_OperatorEthBlocked.t.sol`

- `test_B04_operatorValueRevertsEthNotAllowed` deals 5 ether to the session, then Bob’s valued call reverts.
- The owner can still send session ETH.

## B05. validateUserOp used to ignore missingAccountFunds

### The situation

ERC-4337’s EntryPoint tells the account how much ETH it still needs as a deposit for this UserOp. That argument is `missingAccountFunds`. The usual IAccount pattern is: if the signature is good, send that amount to `msg.sender` (the EntryPoint) and ignore the success flag. The EntryPoint checks its own deposit.

### What was possible before

Bastion took the argument and never used it. The first UserOp without a paymaster or a prior deposit could fail with AA21. Nothing moved to an attacker. The official test constructed the factory with `ep = address(0)` and never reached this function on a real call.

### Why that is bad

A session that cannot post its own prefund is dead on the first bundler submission. That is a liveness problem, not a theft path. Low, not Info, because AA21 is a real failure mode for anyone trying to use the 4337 path.

### What the code does now

After a passing signature check, `validateUserOp` sends `missingAccountFunds` to `msg.sender` with `gas: type(uint256).max`. A failed signature does not prefund. The call’s success flag is ignored on purpose. Do not `transfer` / `send` here (2300 gas). Construct the factory with a real EntryPoint if you want this path in production.

### How to tell it worked

`test/audit/B05_PrefundPosted.t.sol`

- `test_B05_goodSigPostsMissingAccountFundsToEntryPoint` uses a `MockEntryPoint`, deals 5 ether to the session, asks for 1 ether, and checks the EntryPoint received it.
- A failed signature does not send funds.

## B06. The P256 path used to send 224 bytes to a 160-byte precompile

### The situation

When `operator` is 64 bytes, Bastion treats it as a P256 public key (`qx || qy`) and asks the RIP-7212 precompile at `0x100` to check the UserOp signature.

RIP-7212 / EIP-7951 want packed `hash || r || s || qx || qy`. That is 160 bytes.

### What was possible before

The old code ABI-encoded `(bytes32 hash, bytes32 r, bytes32 s, bytes operator)`. That blob is 224 bytes. Word at `0x60` was a dynamic offset, not `qx`. A spec-length etch and a missing precompile both left `validateUserOp` at 1, never 0. Fail-closed. The comment in the source already called the path a demo.

### Why that is bad

If you advertised this as RIP-7212 support, it was not. It also did not open a spend, because validation never succeeded against a strict 160-byte checker. Informational.

### What the code does now

The 64-byte branch packs 160 bytes. Storage `operator` is copied to memory first. Solidity 0.8 cannot slice a storage `bytes`. Signature length must be at least 64. A failed staticcall or empty return is still false.

If you do not want RIP-7212, delete the 64-byte branch. Do not advertise the old 224-byte encoding as RIP-7212.

### How to tell it worked

`test/audit/B06_Packed160.t.sol`

- The packed length is 160, not 224.
- Short signatures return false.
- This Prague pin has no RIP-7212 at `0x100`. The file does not claim a live P256 verify.

## B07. A second chain id used to mint a second 100-token session

### The situation

`checkSig` still takes `_chainId`. That argument feeds `getBastionAddress`. It is not part of the EIP-712 digest Alice signed. The official test always passed `block.chainid`.

### What was possible before

Passing the live chain id produced one Ethereum address. Passing `0` (the 7702 wildcard) produced a different Ethereum address. They were two separate accounts, each with its own Bastion storage and its own factory budget row.

Same Approval, same `(v, r, s)`: `checkSig(block.chainid)` then `checkSig(0)` wrote two rows of 100. Bob could spend both. Alice lost 200 after signing 100.

A stranger could write the wildcard row. Only Bob could spend it. Unlike B01, this did not loop until the 5000 ERC-20 approve was gone. It was a single extra 100.

`require(_chainId == 0 || _chainId == block.chainid)` would not have fixed it. Those two values are two addresses, which is the bug.

### Why that is bad

Alice signed 100 once. The factory wrote 200 of spendable budget against her, on two hosts Bob already controlled. Medium, not High, because it is one extra 100 and the spender is still the signed operator. Not Info, because 200 after a signed 100 is still unauthorized under the same factory budget B01 uses.

### What the code does now

`checkSig` requires `_chainId == block.chainid` and reverts `WrongChainId()` otherwise. Then it derives with that same `_chainId`. Wildcard `0` and a foreign chain id both revert. They no longer mint a second spendable row.

If you need the type-4 wildcard (`chainId = 0`) for an off-chain `SET_CODE`, do that only in a view helper. Still write `allowance` against `getBastionAddress(block.chainid, v, r, s)`.

### How to tell it worked

`test/audit/B07_WrongChainId.t.sol`

- `checkSig(..., 0)` reverts `WrongChainId()`.
- A foreign chain id reverts the same way.
- Live chain id still inits one row. Bob cannot pull 200 from one Approval.

## How the pieces fit after the patches

Here is the path that should work, using the official numbers.

1. Alice signs an EIP-712 `Approval`: Bob as a 20-byte operator, MOCK as the token, `amount = 100`, a domain, a salt.
2. Alice also does `MOCK.approve(factory, 5000)` so `transferFrom` can succeed. That 5000 is slack. The factory mapping is still the cap.
3. Someone (Alice, a relayer, Bob, anyone) calls `factory.checkSig(approval, block.chainid, v, r, s)`.
4. The factory checks `_chainId == block.chainid`, recovers Alice with Solady ECDSA, rejects `address(0)`, rejects `signer == session`, rejects a used digest, marks the digest used, initializes the derived session with Alice and Bob, and writes `allowance[Alice][session][MOCK] = 100`.
5. Bob calls `session.executeWithAllowance(calls, MOCK, 10)`. The session asks the factory to `consume`. `consume` checks that the session’s stored owner is Alice, subtracts 10 from the mapping (100 to 90), and `transferFrom`s 10 MOCK from Alice to the session. Bob’s calls then run. If any of those calls has `value != 0`, the session reverts `EthNotAllowed()`.
6. A second 10-token spend takes the mapping to 80. Same as `test/Bastion.t.sol` and `test/audit/CombinedHappyPath.t.sol`.
7. A second `checkSig` with the same Approval reverts `AlreadyUsed()`. The mapping stays 80. Nobody can write 100 back.
8. A stranger with a new salt and their own operator, under Alice’s old `(v, r, s)`, reverts `AlreadyInitialized()`. They cannot overwrite Bob and `consume(Alice, leftover)`.
9. `checkSig(..., 0)` reverts `WrongChainId()`. There is one session address for this signature on this chain.

If Alice wants a new budget later, she signs a new Approval with a new salt. That is a new digest. The old one stays used.

If Alice wants a new operator on the same session, she calls `changeOperator`. She does not replay `checkSig`.

## Architecture (unchanged shape)

The system still has three parts.

1. **BastionFactory** verifies the Approval, derives the session address, and keeps the token budget.
2. **Bastion** is the session account. It runs `executeWithAllowance`, enforces owner / operator / EntryPoint, and validates UserOps.
3. **EIP-7702** is how the session address exists without Alice deploying a contract first.

`checkSig` and `getBastionAddress` still look like this, with the new guards inlined in `src/BastionFactory.sol`:

```solidity
function checkSig(Approval memory approval, uint256 _chainId, uint8 v, bytes32 r, bytes32 s) external {
    require(_chainId == block.chainid, WrongChainId());
    address session = getBastionAddress(_chainId, v, r, s);
    bytes32 digest = getDigest(approval);
    address signer = ECDSA.recover(digest, v, r, s);
    require(signer != address(0), InvalidSigFormat());
    require(signer != session, DelegationSigReuse());
    require(!usedDigest[digest], AlreadyUsed());
    usedDigest[digest] = true;
    Bastion(session).initialize(signer, approval.operator);
    allowance[signer][session][approval.token] = approval.amount;
}

function getBastionAddress(uint256 _chainId, uint8 _v, bytes32 _r, bytes32 _s) public view returns (address) {
    bytes32 h = keccak256(abi.encodePacked(hex"05", LibRLP.p(_chainId).p(address(impl)).p(0).encode()));
    return ecrecover(h, _v, _r, _s);
}
```

Users still create a session from a normal EIP-712 approval popup. They do not need a specialized 7702 signing flow.

## Use cases

- Session keys: a temporary operator with a limited token budget.
- Dapp interaction: a dapp that can run calls as the session without holding Alice’s main key.

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

That runs the original happy path in `test/Bastion.t.sol` and the B01–B07 files under `test/audit/`. On this branch that is 24 passed / 0 failed.

To run one fix:

```shell
forge test --match-path test/audit/B01_ReplayBlocked.t.sol
```

### Format

```shell
forge fmt
```

## Security

After this PR:

- A digest is used once. Replay cannot refill the factory mapping.
- `initialize` will not accept a different owner or operator on a live session.
- `consume` only debits the stored session owner.
- `_chainId` must be this chain. One Approval, one session row.
- A native 7702 authorization cannot initialize the derived session as itself.
- The 20-byte operator cannot send session ETH.
- A passing UserOp posts `missingAccountFunds` to the EntryPoint.
- The P256 path packs 160 bytes.

The ERC-20 `approve(factory)` on the token is still not the product cap. The factory mapping is. Leave leftover token approve only if you accept that slack as a second line of defense, not as the budget Alice signed.

## License

This project is licensed under the MIT License.
