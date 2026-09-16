pragma solidity ^0.8.0;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Call, PackedUserOperation} from "./types/Structs.sol";
import {BastionFactory} from "./BastionFactory.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

address constant RIP7212_VERIFIER = 0x0000000000000000000000000000000000000100;

contract Bastion {
    address public immutable ENTRYPOINT;

    address public owner;

    bytes public operator;

    BastionFactory public immutable FACTORY;

    error OnlyFactory();
    error OnlyOwnerOrOperator();
    error OnlyEntryPoint();
    error OnlyOwner();
    error CallFailed();
    error InvalidOperatorData();
    error AlreadyInitialized();
    error EthNotAllowed();

    constructor(address ep) {
        FACTORY = BastionFactory(msg.sender);
        ENTRYPOINT = ep;
    }

    function initialize(address _owner, bytes calldata _operator) external {
        require(msg.sender == address(FACTORY), OnlyFactory());
        require(_operator.length == 20 || _operator.length == 64, InvalidOperatorData());
        if (owner != address(0)) {
            require(owner == _owner, AlreadyInitialized());
            require(keccak256(operator) == keccak256(_operator), AlreadyInitialized());
            return;
        }
        owner = _owner;
        operator = _operator;
    }

    function transferOwner(address _owner) external {
        require(msg.sender == owner, OnlyOwner());
        owner = _owner;
    }

    function changeOperator(bytes calldata _operator) external {
        require(msg.sender == owner, OnlyOwner());
        require(_operator.length == 20 || _operator.length == 64, InvalidOperatorData());
        operator = _operator;
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        payable
        returns (uint256 validationData)
    {
        require(msg.sender == ENTRYPOINT, OnlyEntryPoint());
        validationData = _verifySignature(userOpHash, userOp.signature) ? 0 : 1;
        if (validationData == 0 && missingAccountFunds != 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds, gas: type(uint256).max}("");
            ok;
        }
    }

    function executeWithAllowance(Call[] calldata calls, address _token, uint256 _amount) external {
        bool isOperator = operator.length == 20 && msg.sender == address(bytes20(operator));
        require(msg.sender == owner || msg.sender == ENTRYPOINT || isOperator, OnlyOwnerOrOperator());
        FACTORY.consume(owner, _token, _amount);
        for (uint256 i = 0; i < calls.length; i++) {
            Call calldata c = calls[i];
            if (isOperator && c.value != 0) revert EthNotAllowed();
            (bool success, bytes memory ret) = c.to.call{value: c.value}(c.data);
            if (!success) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }

    function _verifySignature(bytes32 hash, bytes calldata signature) internal view returns (bool) {
        if (operator.length == 20) {
            return address(bytes20(operator)) == ECDSA.recover(hash, signature);
        } else if (operator.length == 64) {
            if (signature.length < 64) return false;
            // Storage/memory `bytes` cannot be sliced in Solidity 0.8.x (calldata only).
            // Load qx||qy from the stored 64-byte operator, then pack RIP-7212's 160-byte input.
            bytes memory op = operator;
            bytes32 qx;
            bytes32 qy;
            assembly {
                qx := mload(add(op, 0x20))
                qy := mload(add(op, 0x40))
            }
            bytes memory args = abi.encodePacked(hash, bytes32(signature[0:32]), bytes32(signature[32:64]), qx, qy);
            (bool success, bytes memory ret) = RIP7212_VERIFIER.staticcall(args);
            if (success == false || ret.length == 0) {
                return false;
            }
            return abi.decode(ret, (uint256)) == 1;
        } else {
            revert InvalidOperatorData();
        }
    }
}
