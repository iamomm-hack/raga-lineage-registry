// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IEAS } from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {
    ISchemaRegistry
} from "@ethereum-attestation-service/eas-contracts/contracts/ISchemaRegistry.sol";
import {
    ISchemaResolver
} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/ISchemaResolver.sol";

import { RagaRegistry } from "../src/RagaRegistry.sol";

contract DeployBaseSepolia is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    address internal constant BASE_SEPOLIA_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant BASE_SEPOLIA_SCHEMA_REGISTRY =
        0x4200000000000000000000000000000000000020;

    string internal constant LINEAGE_SCHEMA =
        "address student,address teacher,uint16 teacherShareBps";
    string internal constant LICENSE_SCHEMA =
        "bytes32 assetId,address performer,address licensee,bytes32 lineageUID";

    error WrongChain(uint256 actualChainId);

    function run()
        external
        returns (RagaRegistry registry, bytes32 lineageSchemaUID, bytes32 licenseSchemaUID)
    {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        uint256 privateKey = _readPrivateKey();
        address deployer = vm.addr(privateKey);
        ISchemaRegistry schemaRegistry = ISchemaRegistry(BASE_SEPOLIA_SCHEMA_REGISTRY);

        vm.startBroadcast(privateKey);

        lineageSchemaUID =
            schemaRegistry.register(LINEAGE_SCHEMA, ISchemaResolver(address(0)), true);
        licenseSchemaUID =
            schemaRegistry.register(LICENSE_SCHEMA, ISchemaResolver(address(0)), true);
        registry = new RagaRegistry(IEAS(BASE_SEPOLIA_EAS), lineageSchemaUID, licenseSchemaUID);

        vm.stopBroadcast();

        console2.log("Chain ID", block.chainid);
        console2.log("Deployer", deployer);
        console2.log("EAS", BASE_SEPOLIA_EAS);
        console2.log("SchemaRegistry", BASE_SEPOLIA_SCHEMA_REGISTRY);
        console2.log("RagaRegistry", address(registry));
        console2.log("Lineage schema UID");
        console2.logBytes32(lineageSchemaUID);
        console2.log("License schema UID");
        console2.logBytes32(licenseSchemaUID);
    }

    function _readPrivateKey() private view returns (uint256) {
        string memory encodedKey = vm.envString("PRIVATE_KEY");
        if (bytes(encodedKey).length == 64) {
            encodedKey = string.concat("0x", encodedKey);
        }
        return vm.parseUint(encodedKey);
    }
}
