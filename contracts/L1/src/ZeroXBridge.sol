// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract ZeroXBridge{
    address public admin;

    event WhitelistEvent(address indexed token);
    event DewhitelistEvent(address indexed token);

    mapping (address => bool) public whitelistedTokens;

    constructor(){
        admin = address(0x123);

    }
    modifier  onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
    _;
    }

    function whitelistToken(address _token) public onlyAdmin {
        whitelistedTokens[_token] = true;
        emit WhitelistEvent(_token);
    }

    function dewhitelistToken(address _token) public onlyAdmin {
        whitelistedTokens[_token] = false;
        emit DewhitelistEvent(_token);
    }
    function isWhitelisted(address _token) public view returns (bool) {
        return whitelistedTokens[_token];
    }
}