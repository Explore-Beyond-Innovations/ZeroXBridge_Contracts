interface IGpsStatementVerifier {
    function verifyProofAndRegister(
        uint256[] calldata proofParams,
        uint256[] calldata proof,
        uint256[] calldata publicInputs,
        uint256 cairoVerifierId
    ) external returns (bool);
}

contract MockGpsStatementVerifier is IGpsStatementVerifier {
    bool public shouldVerifySucceed = true;
    mapping(bytes32 => bool) public registeredProofs;

    function setShouldVerifySucceed(bool _shouldSucceed) external {
        shouldVerifySucceed = _shouldSucceed;
    }

    function verifyProofAndRegister(
        uint256[] calldata proofParams,
        uint256[] calldata proof,
        uint256[] calldata publicInputs,
        uint256 cairoVerifierId
    ) external override returns (bool) {
        bytes32 proofHash = keccak256(abi.encodePacked(proof));
        require(!registeredProofs[proofHash], "Proof already registered");

        if (shouldVerifySucceed) {
            registeredProofs[proofHash] = true;
            return true;
        }
        return false;
    }

    function isProofRegistered(uint256[] calldata proof) external view returns (bool) {
        bytes32 proofHash = keccak256(abi.encodePacked(proof));
        return registeredProofs[proofHash];
    }
}
