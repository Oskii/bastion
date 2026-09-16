// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bastion} from "src/Bastion.sol";
import {BastionFactory} from "src/BastionFactory.sol";
import {Approval, Call} from "src/types/Structs.sol";
import {AuditBase} from "./AuditBase.sol";

/// B01: same (v,r,s) after consume must not refill. Second checkSig reverts AlreadyUsed.
contract B01_ReplayBlocked is AuditBase {
    function setUp() external {
        _deployFactory(address(0));
    }

    function test_B01_firstCheckSigStillWorks() public {
        (,,,, Bastion bastion) = _officialGrant();
        assertEq(token.balanceOf(owner), MINTED);
        assertEq(factory.allowance(owner, address(bastion), address(token)), SIGNED_AMOUNT);
    }

    function test_B01_replayAfterPartialConsumeDoesNotRefill() public {
        (uint8 v, bytes32 r, bytes32 s, Approval memory approval, Bastion bastion) = _officialGrant();

        Call[] memory calls = new Call[](0);
        vm.prank(operator);
        bastion.executeWithAllowance(calls, address(token), PARTIAL);

        uint256 remainingAfterPartial = factory.allowance(owner, address(bastion), address(token));
        assertEq(remainingAfterPartial, SIGNED_AMOUNT - PARTIAL);

        vm.expectRevert(BastionFactory.AlreadyUsed.selector);
        factory.checkSig(approval, block.chainid, v, r, s);

        assertEq(factory.allowance(owner, address(bastion), address(token)), remainingAfterPartial);

        uint256 pulled = PARTIAL;
        uint256 mappingAfterReplay = factory.allowance(owner, address(bastion), address(token));
        while (token.allowance(owner, address(factory)) > 0) {
            uint256 row = factory.allowance(owner, address(bastion), address(token));
            uint256 erc20Left = token.allowance(owner, address(factory));
            uint256 chunk = row < erc20Left ? row : erc20Left;
            if (chunk == 0) break;
            vm.prank(operator);
            bastion.executeWithAllowance(calls, address(token), chunk);
            pulled += chunk;
            try factory.checkSig(approval, block.chainid, v, r, s) {} catch {}
        }

        assertLe(pulled, SIGNED_AMOUNT, "B01: pulled past signed amount");
        assertGe(token.balanceOf(owner), MINTED - SIGNED_AMOUNT);
        assertLe(token.balanceOf(address(bastion)), SIGNED_AMOUNT);
        assertEq(mappingAfterReplay, remainingAfterPartial);
    }

    function test_B01_replayAfterFullConsumeRevertsAlreadyUsedNotAllowanceZero() public {
        (uint8 v, bytes32 r, bytes32 s, Approval memory approval, Bastion bastion) = _officialGrant();

        Call[] memory calls = new Call[](0);
        vm.prank(operator);
        bastion.executeWithAllowance(calls, address(token), SIGNED_AMOUNT);
        assertEq(factory.allowance(owner, address(bastion), address(token)), 0);

        vm.expectRevert(BastionFactory.AlreadyUsed.selector);
        factory.checkSig(approval, block.chainid, v, r, s);

        assertEq(factory.allowance(owner, address(bastion), address(token)), 0);
        assertEq(token.balanceOf(address(bastion)), SIGNED_AMOUNT);
        assertEq(token.balanceOf(owner), MINTED - SIGNED_AMOUNT);

        vm.prank(operator);
        vm.expectRevert();
        bastion.executeWithAllowance(calls, address(token), 1);
    }
}
