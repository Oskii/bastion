// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LibRLP} from "solady/utils/LibRLP.sol";
import {BastionFactory} from "src/BastionFactory.sol";
import {Approval} from "src/types/Structs.sol";
import {AuditBase} from "./AuditBase.sol";

/// Hits the factory `require(signer != session)` by making both ecrecover
/// legs return the same nonzero address (Foundry mock of precompile 0x1).
/// A natural auth_hash collision (digest == 7702 hash) is not constructible here.
contract B03_DelegationSigReuse is AuditBase {
    using LibRLP for LibRLP.List;

    function setUp() external {
        _deployFactory(address(0));
    }

    function test_B03_requireSignerNotSession_revertsDelegationSigReuse() public {
        _fundOwner();
        Approval memory approval = _baseApproval();
        (uint8 v, bytes32 r, bytes32 s, address session, Approval memory out) = _grind(approval);
        _attach(v, r, s);

        address same = makeAddr("forced-signer-and-session");
        vm.mockCall(address(1), bytes(""), abi.encode(same));

        vm.expectRevert(BastionFactory.DelegationSigReuse.selector);
        factory.checkSig(out, block.chainid, v, r, s);

        vm.clearMockedCalls();
        assertEq(session.code.length != 0, true, "delegation attached before mock");
    }

    function test_B03_requireSignerNotSession_probeBranch() public {
        B03RequireProbe probe = new B03RequireProbe();
        probe.allow(owner, operator);
        vm.expectRevert(BastionFactory.DelegationSigReuse.selector);
        probe.allow(owner, owner);
    }

    /// Auth-hash (v,r,s) + attacker Approval: 712 recover is not the authority,
    /// so DelegationSigReuse does not fire. The written require is that branch only.
    function test_B03_authHashDoesNotEqualApprovalSignerNaturally() public {
        (address victim, uint256 victimKey) = makeAddrAndKey("Victim7702");
        bytes32 authH = keccak256(
            abi.encodePacked(hex"05", LibRLP.p(block.chainid).p(address(factory.impl())).p(uint256(0)).encode())
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(victimKey, authH);
        assertEq(factory.getBastionAddress(block.chainid, v, r, s), victim);

        Approval memory approval = Approval({
            operator: abi.encodePacked(attacker),
            token: address(token),
            amount: 0,
            domain: keccak256("attacker"),
            salt: bytes32(uint256(1))
        });
        while (ecrecover(factory.getDigest(approval), v, r, s) == address(0)) {
            approval.salt = keccak256(abi.encodePacked(approval.salt));
        }
        address signer712 = ecrecover(factory.getDigest(approval), v, r, s);
        assertTrue(signer712 != victim, "auth_hash sig is not a 712 sig by the authority");
        assertTrue(factory.getDigest(approval) != authH);
    }
}

contract B03RequireProbe {
    function allow(address signer, address session) external pure {
        require(signer != session, BastionFactory.DelegationSigReuse());
    }
}
