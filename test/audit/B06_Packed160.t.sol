// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bastion} from "src/Bastion.sol";
import {Approval, PackedUserOperation} from "src/types/Structs.sol";
import {AuditBase} from "./AuditBase.sol";

/// B06: P256 path packs 160 bytes. Old 224-byte abi.encode is gone.
/// This Prague pin has no RIP-7212 at 0x100 — we do not claim a real P256 verify.
contract B06_Packed160 is AuditBase {
    address internal constant RIP7212 = address(0x0000000000000000000000000000000000000100);

    bytes32 internal constant HASH = bytes32(uint256(0x11));
    bytes32 internal constant R = bytes32(uint256(0x22));
    bytes32 internal constant S = bytes32(uint256(0x33));
    bytes32 internal constant QX = bytes32(uint256(0x44));
    bytes32 internal constant QY = bytes32(uint256(0x55));

    address internal ep;

    function setUp() external {
        ep = makeAddr("EP");
        _deployFactory(ep);
    }

    function test_B06_packedArgsLengthIs160_old224PathGone() public {
        bytes memory packed = abi.encodePacked(HASH, R, S, QX, QY);
        bytes memory abiBlob = abi.encode(HASH, R, S, _operator());
        assertEq(packed.length, 160, "RIP-7212 packed input");
        assertEq(abiBlob.length, 224, "legacy ABI blob must not be sent");

        Bastion bastion = _spawnP256();
        assertEq(RIP7212.code.length, 0, "prague pin has no RIP-7212 unless etched");

        vm.expectCall(RIP7212, packed);
        vm.prank(ep);
        uint256 validationData = bastion.validateUserOp(_userOp(address(bastion), _sig()), HASH, 0);
        assertEq(validationData, 1, "empty 0x100: encoding proven via expectCall, not a real P256 verify");
    }

    function test_B06_strict160LengthGateReceivesPackedNotAbi() public {
        vm.etch(RIP7212, type(Strict160P256Verify).runtimeCode);
        bytes memory packed = abi.encodePacked(HASH, R, S, QX, QY);
        bytes memory abiBlob = abi.encode(HASH, R, S, _operator());

        (bool okPacked, bytes memory retPacked) = RIP7212.staticcall(packed);
        (bool okAbi, bytes memory retAbi) = RIP7212.staticcall(abiBlob);
        assertTrue(okPacked);
        assertEq(abi.decode(retPacked, (uint256)), 1);
        assertEq(retAbi.length, 0, "224-byte ABI still fails the 160-byte gate");

        Bastion bastion = _spawnP256();
        vm.expectCall(RIP7212, packed);
        vm.prank(ep);
        uint256 validationData = bastion.validateUserOp(_userOp(address(bastion), _sig()), HASH, 0);
        assertEq(validationData, 0, "length-gate etch only, not a real RIP-7212 verify");
        assertTrue(okAbi);
    }

    function test_B06_shortSignatureReturnsFalse() public {
        Bastion bastion = _spawnP256();
        vm.prank(ep);
        uint256 validationData = bastion.validateUserOp(_userOp(address(bastion), hex"11"), HASH, 0);
        assertEq(validationData, 1);
    }

    function _operator() internal pure returns (bytes memory) {
        return abi.encodePacked(QX, QY);
    }

    function _sig() internal pure returns (bytes memory) {
        return abi.encodePacked(R, S);
    }

    function _userOp(address sender, bytes memory signature) internal pure returns (PackedUserOperation memory userOp) {
        userOp.sender = sender;
        userOp.signature = signature;
    }

    function _spawnP256() internal returns (Bastion bastion) {
        _fundOwner();
        Approval memory approval = Approval({
            operator: _operator(),
            token: address(token),
            amount: SIGNED_AMOUNT,
            domain: keccak256(abi.encodePacked("https://dashboard.zerodev.app")),
            salt: bytes32(0)
        });
        address session;
        uint8 v;
        bytes32 r;
        bytes32 s;
        (v, r, s, session, approval) = _grind(approval);
        _attach(v, r, s);
        factory.checkSig(approval, block.chainid, v, r, s);
        bastion = Bastion(session);
        assertEq(bastion.operator().length, 64);
    }
}

/// Length gate only. `vm.etch` at 0x100 is test-only. Not RIP-7212 curve math.
contract Strict160P256Verify {
    fallback() external {
        if (msg.data.length == 160) {
            assembly {
                mstore(0, 1)
                return(0, 32)
            }
        }
    }
}
