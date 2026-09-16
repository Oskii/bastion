// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bastion} from "src/Bastion.sol";
import {BastionFactory} from "src/BastionFactory.sol";
import {Approval, Call} from "src/types/Structs.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {AuditBase} from "./AuditBase.sol";

/// B07: checkSig(..., 0) or a foreign chainId reverts WrongChainId.
/// Live chainid inits one row. Operator cannot pull 200.
contract B07_WrongChainId is AuditBase {
    function setUp() external {
        _deployFactory(address(0));
    }

    function test_B07_chainIdZeroRevertsWrongChainId() public {
        _fundOwner();
        Approval memory approval = _baseApproval();
        (uint8 v, bytes32 r, bytes32 s, address session, Approval memory out) = _grind(approval);
        _attach(v, r, s);

        vm.expectRevert(BastionFactory.WrongChainId.selector);
        factory.checkSig(out, 0, v, r, s);

        assertEq(factory.allowance(owner, session, address(token)), 0);
    }

    function test_B07_foreignChainIdRevertsWrongChainId() public {
        _fundOwner();
        Approval memory approval = _baseApproval();
        (uint8 v, bytes32 r, bytes32 s, address session, Approval memory out) = _grind(approval);
        _attach(v, r, s);

        vm.expectRevert(BastionFactory.WrongChainId.selector);
        factory.checkSig(out, block.chainid + 1, v, r, s);

        assertEq(factory.allowance(owner, session, address(token)), 0);
    }

    function test_B07_liveChainIdInitsOneRow_operatorCannotPull200() public {
        (uint8 v, bytes32 r, bytes32 s, Approval memory approval, Bastion bastion) = _officialGrant();
        address sessionC = address(bastion);
        address session0 = factory.getBastionAddress(0, v, r, s);
        assertTrue(session0 != address(0) && session0 != sessionC);

        vm.expectRevert(BastionFactory.WrongChainId.selector);
        factory.checkSig(approval, 0, v, r, s);

        assertEq(factory.allowance(owner, sessionC, address(token)), SIGNED_AMOUNT);
        assertEq(factory.allowance(owner, session0, address(token)), 0);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(token),
            value: 0,
            data: abi.encodeWithSelector(ERC20.transfer.selector, attacker, SIGNED_AMOUNT)
        });
        vm.prank(operator);
        bastion.executeWithAllowance(calls, address(token), SIGNED_AMOUNT);

        bytes memory designator = abi.encodePacked(hex"ef0100", address(factory.impl()));
        vm.etch(session0, designator);
        vm.prank(operator);
        vm.expectRevert();
        Bastion(session0).executeWithAllowance(calls, address(token), SIGNED_AMOUNT);

        assertEq(token.balanceOf(attacker), SIGNED_AMOUNT);
        assertEq(token.balanceOf(owner), MINTED - SIGNED_AMOUNT);
        assertLe(MINTED - token.balanceOf(owner), SIGNED_AMOUNT);
    }
}
