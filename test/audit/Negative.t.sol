// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bastion} from "src/Bastion.sol";
import {Approval, Call} from "src/types/Structs.sol";
import {AuditBase} from "./AuditBase.sol";

/// Unused digest still grants. changeOperator still works for owner.
contract Negative is AuditBase {
    address internal operatorB;

    function setUp() external {
        _deployFactory(address(0));
        operatorB = makeAddr("OperatorB");
    }

    function test_negative_unusedDigestStillGrants() public {
        (,,,, Bastion first) = _officialGrant();
        assertEq(factory.allowance(owner, address(first), address(token)), SIGNED_AMOUNT);

        Approval memory second = _baseApproval();
        second.salt = keccak256("second-grant");
        second.amount = 40;
        (uint8 v, bytes32 r, bytes32 s, address session, Approval memory out) = _grind(second);
        _attach(v, r, s);
        factory.checkSig(out, block.chainid, v, r, s);

        assertEq(factory.allowance(owner, session, address(token)), 40);
        assertTrue(factory.usedDigest(factory.getDigest(out)));
        assertTrue(session != address(first));
    }

    function test_negative_changeOperatorStillWorksForOwner() public {
        (,,,, Bastion bastion) = _officialGrant();

        vm.prank(owner);
        bastion.changeOperator(abi.encodePacked(operatorB));
        assertEq(bastion.operator(), abi.encodePacked(operatorB));
        assertEq(factory.allowance(owner, address(bastion), address(token)), SIGNED_AMOUNT);

        Call[] memory calls = new Call[](0);
        vm.prank(operator);
        vm.expectRevert(Bastion.OnlyOwnerOrOperator.selector);
        bastion.executeWithAllowance(calls, address(token), 1);

        vm.prank(operatorB);
        bastion.executeWithAllowance(calls, address(token), 1);
        assertEq(factory.allowance(owner, address(bastion), address(token)), SIGNED_AMOUNT - 1);
    }
}
