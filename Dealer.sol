// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity >=0.8.13 <0.9.0;

import "fhevm/abstracts/EIP712WithModifier.sol";
import "fhevm/lib/TFHE.sol";
import "hardhat/console.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IDealer} from "../interfaces/IDealer.sol";

// contract Dealer is IDealer, EIP712WithModifier {
//     address public owner;

//     constructor() EIP712WithModifier("Authorization token", "1") {
//         owner = msg.sender;
//     }

//     uint[] public dealtCards;


//     function dealCard() internal returns (uint) {
//         uint randomHash = uint(keccak256(abi.encodePacked(block.timestamp, msg.sender, dealtCards.length)));
//         uint card = randomHash % 52 + 1;

//         dealtCards.push(card); // Add the card to dealtCards if it's not a duplicate
//         return card;
//     }
    
//     function setDeal(uint256 n) external returns (uint[] memory) { 

//         for (uint256 i = 0; i < n; i++) {
//             dealtCards[i] = dealCard();
//         }   

//         return dealtCards;
//     }
    
// }


// // FHE enabled:
contract Dealer is IDealer, EIP712WithModifier {
    address public owner;

    constructor() EIP712WithModifier("Authorization token", "1") {
        owner = msg.sender;
    }

    euint8[] public dealtCards;
    uint8 public mod = 52;

    event EncryptedCard(address player, euint8 card);
    
    function checkDuplication(euint8 _card) internal view returns (euint8) {
        euint8 total;
        for (uint8 i = 0; i < dealtCards.length; i++) {
            ebool duplicate = TFHE.eq(dealtCards[i], _card);
            total = TFHE.add(total, TFHE.cmux(duplicate, TFHE.asEuint8(1), TFHE.asEuint8(0)));
        }
        return total;
    }

    function dealCard() internal {
        console.log("Calling dealCard");
        euint8 card = TFHE.rem(TFHE.randEuint8(), mod); // mod 52
        // euint8 card = TFHE.randEuint8();
        emit EncryptedCard(msg.sender, card);

        if (dealtCards.length == 0) {
            dealtCards.push(card);
        } else if (TFHE.decrypt(checkDuplication(card)) == 0) {
            dealtCards.push(card);
        }
    }

    function setDeal(uint8 n) external returns (euint8[] memory) { //this count is 2n + 5 
        for (uint8 i = 0; i < n; i++) {
            dealCard();
        }

        return dealtCards;
    } 

}






