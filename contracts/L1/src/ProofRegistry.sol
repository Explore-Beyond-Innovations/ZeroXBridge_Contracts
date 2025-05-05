// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ISharpFactRegistry {
    function isValid(bytes32 fact) external view returns (bool);
}

interface IProofRegistry {
    function getVerifiedMerkleRoot(uint256 withdrawalCommitmentHash) external view returns (uint256);
    function registerWithdrawalProof(uint256 withdrawalCommitmentHash, uint256 merkleRoot) external;
}

struct VerifiedWithdrawalRoot {
    bool isVerified;
    uint256 merkleRoot;
}

// Calculate fact hash for cairo1 programs bootloaded in cairo0 by Atlantic.
function calculateCairo1FactHash(uint256 programHash, uint256[] memory input, uint256[] memory output)
    pure
    returns (bytes32)
{
    uint256 CAIRO1_BOOTLOADER_PROGRAM_HASH = 0x288ba12915c0c7e91df572cf3ed0c9f391aa673cb247c5a208beaa50b668f09;
    uint256 OUTPUT_CONST = 0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804;

    uint256[] memory bootloaderOutput = new uint256[](8 + input.length + output.length);
    bootloaderOutput[0] = 0x0;
    bootloaderOutput[1] = OUTPUT_CONST;
    bootloaderOutput[2] = 0x1;
    bootloaderOutput[3] = input.length + output.length + 5;
    bootloaderOutput[4] = programHash;
    bootloaderOutput[5] = 0x0;
    bootloaderOutput[6] = output.length;
    for (uint256 i = 0; i < output.length; i++) {
        bootloaderOutput[7 + i] = output[i];
    }
    bootloaderOutput[7 + output.length] = input.length;
    for (uint256 i = 0; i < input.length; i++) {
        bootloaderOutput[8 + output.length + i] = input[i];
    }

    bytes32 outputHash = keccak256(abi.encodePacked(bootloaderOutput));
    return keccak256(abi.encode(CAIRO1_BOOTLOADER_PROGRAM_HASH, outputHash));
}

function getCairo1FactHash(uint256 commitment, uint256 root) pure returns (bytes32) {
    // Cairo1 program hash is present in Atlantic query metadata at **"child_program_hash"** key.
    // IMPORTANT: In cairo1 query, program_hash refers to the program hash of the bootloader which
    //            is constant, your actual program hash is present in its output which is shown
    //            at "child_program_hash" key.
    uint256 CAIRO1_PROGRAM_HASH = 0x1b2f325bf7c611b8cf643eed5451102df4128cb17d621dad15e2cdb9d3e3afb;

    uint256[] memory input = new uint256[](1);
    input[0] = commitment;

    uint256[] memory output = new uint256[](1);
    output[0] = root;

    return calculateCairo1FactHash(CAIRO1_PROGRAM_HASH, input, output);
}

contract ProofRegistry is IProofRegistry {
    uint256 constant PROGRAM_HASH = 0x0;
    ISharpFactRegistry constant sharpFactRegistry = ISharpFactRegistry(0x07ec0D28e50322Eb0C159B9090ecF3aeA8346DFe);

    mapping(uint256 => VerifiedWithdrawalRoot) public verifiedWithdrawalRoots;

    event WithdrawalCommitmentVerified(uint256 withdrawalCommitmentHash, uint256 merkleRoot);

    function getVerifiedMerkleRoot(uint256 withdrawalCommitmentHash) public view returns (uint256) {
        require(verifiedWithdrawalRoots[withdrawalCommitmentHash].isVerified, "Withdrawal proof not found");
        return verifiedWithdrawalRoots[withdrawalCommitmentHash].merkleRoot;
    }

    function registerWithdrawalProof(uint256 withdrawalCommitmentHash, uint256 merkleRoot) public {
        bytes32 factHash = getCairo1FactHash(withdrawalCommitmentHash, merkleRoot);
        bool isValid = sharpFactRegistry.isValid(factHash);
        require(isValid, "Withdrawal proof not verified");

        verifiedWithdrawalRoots[withdrawalCommitmentHash] =
            VerifiedWithdrawalRoot({isVerified: true, merkleRoot: merkleRoot});
        emit WithdrawalCommitmentVerified(withdrawalCommitmentHash, merkleRoot);
    }
}
