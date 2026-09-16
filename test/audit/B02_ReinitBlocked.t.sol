// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bastion} from "src/Bastion.sol";
import {BastionFactory} from "src/BastionFactory.sol";
import {Approval, Call} from "src/types/Structs.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {AuditBase} from "./AuditBase.sol";

/// B02: mutated Approval + old (v,r,s) reverts AlreadyInitialized. Owner tokens stay.
contract B02_ReinitBlocked is AuditBase {
    function setUp() external {
        _deployFactory(address(0));
    }

    function test_B02_mutatedApprovalRevertsAlreadyInitialized_ownerTokensStay() public {
        (uint8 v, bytes32 r, bytes32 s, Approval memory approval, Bastion bastion) = _officialGrant();

        Approval memory second = Approval({
            operator: abi.encodePacked(attacker),
            token: approval.token,
            amount: approval.amount,
            domain: approval.domain,
            salt: keccak256("leftover-row-steal")
        });
        address newSigner = ecrecover(factory.getDigest(second), v, r, s);
        require(newSigner != address(0), "second digest recovered address(0)");

        vm.expectRevert(Bastion.AlreadyInitialized.selector);
        factory.checkSig(second, block.chainid, v, r, s);

        assertEq(bastion.owner(), owner);
        assertEq(bastion.operator(), abi.encodePacked(operator));
        assertEq(factory.allowance(owner, address(bastion), address(token)), SIGNED_AMOUNT);
        assertEq(token.balanceOf(owner), MINTED);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_B02_initializeIdempotentSameOwnerOperator_elseRevert() public {
        (,,,, Bastion bastion) = _officialGrant();

        vm.prank(address(factory));
        bastion.initialize(owner, abi.encodePacked(operator));
        assertEq(bastion.owner(), owner);
        assertEq(bastion.operator(), abi.encodePacked(operator));

        vm.prank(address(factory));
        vm.expectRevert(Bastion.AlreadyInitialized.selector);
        bastion.initialize(attacker, abi.encodePacked(operator));

        vm.prank(address(factory));
        vm.expectRevert(Bastion.AlreadyInitialized.selector);
        bastion.initialize(owner, abi.encodePacked(attacker));
    }

    function test_B02_consumeOriginalOwnerAfterTransferOwnerReverts() public {
        (,,,, Bastion bastion) = _officialGrant();

        vm.prank(owner);
        bastion.transferOwner(attacker);

        assertEq(bastion.owner(), attacker);
        assertEq(factory.allowance(owner, address(bastion), address(token)), SIGNED_AMOUNT);

        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            to: address(factory),
            value: 0,
            data: abi.encodeWithSelector(BastionFactory.consume.selector, owner, address(token), SIGNED_AMOUNT)
        });
        calls[1] = Call({
            to: address(token),
            value: 0,
            data: abi.encodeWithSelector(ERC20.transfer.selector, attacker, SIGNED_AMOUNT)
        });

        vm.prank(attacker);
        vm.expectRevert(BastionFactory.OnlyOwner.selector);
        bastion.executeWithAllowance(calls, address(token), 0);

        assertEq(token.balanceOf(owner), MINTED);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(factory.allowance(owner, address(bastion), address(token)), SIGNED_AMOUNT);
    }
}
