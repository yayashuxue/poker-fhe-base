// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity >=0.8.13 <0.9.0;
import "fhevm/lib/TFHE.sol";

interface IDealer {
    function setDeal(uint256 n) external returns (uint[] memory);

    // //FHE enabled
    // function setDeal(uint8 n) external returns (euint8[] memory);
}