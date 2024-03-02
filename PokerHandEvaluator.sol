// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

library PokerHandEvaluator {

    // Hand rankings enumeration for clarity
    enum HandRanking {
        HighCard,
        OnePair,
        TwoPairs,
        ThreeOfAKind,
        Straight,
        Flush,
        FullHouse,
        FourOfAKind,
        StraightFlush
    }

    // Function to evaluate a hand and return its score
    function evaluateHand(uint[] memory hand) internal pure returns (uint) {
        require(hand.length == 7, "Invalid hand length");

        // Sort the hand for easier evaluation
        sortHand(hand);

        // Check for flush and straight
        bool isFlush = checkFlush(hand);
        bool isStraight = checkStraight(hand);

        // Check for matches and highest card
        (uint matchesScore, uint highestCard) = checkMatches(hand);

        if (isStraight && isFlush) return uint(HandRanking.StraightFlush) * 10000 + highestCard;
        if (matchesScore >= uint(HandRanking.FourOfAKind) * 10000) return matchesScore;
        if (isFlush) return uint(HandRanking.Flush) * 10000 + highestCard;
        if (isStraight) return uint(HandRanking.Straight) * 10000 + highestCard;
        return matchesScore; // This includes HighCard, OnePair, TwoPairs, ThreeOfAKind, FullHouse
    }

    // Function to sort the hand - simplistic bubble sort for demonstration; optimize for production
    function sortHand(uint[] memory hand) private pure {
        uint n = hand.length;
        for (uint i = 0; i < n-1; i++) {
            for (uint j = 0; j < n-i-1; j++) {
                if (hand[j] % 13 > hand[j+1] % 13) {
                    (hand[j], hand[j+1]) = (hand[j+1], hand[j]);
                }
            }
        }
    }

    // Check if the hand is a flush (all cards of the same suit)
    function checkFlush(uint[] memory hand) private pure returns (bool) {
        uint suit = hand[0] / 13;
        for (uint i = 1; i < hand.length; i++) {
            if (hand[i] / 13 != suit) return false;
        }
        return true;
    }

    // Check if the hand contains a straight (consecutive values)
    function checkStraight(uint[] memory hand) private pure returns (bool) {
        uint count = 1;
        for (uint i = 1; i < hand.length; i++) {
            if (hand[i] % 13 == (hand[i-1] % 13) + 1) {
                count++;
                if (count == 5) return true;
            } else if (hand[i] % 13 != hand[i-1] % 13) {
                count = 1; // Reset count if not consecutive or duplicate
            }
        }
        return false;
    }

    // Check for matches (pairs, three of a kind, etc.) and return a score
    function checkMatches(uint[] memory hand) private pure returns (uint, uint) {
        uint[] memory counts = new uint[](13); // There are 13 ranks
        for (uint i = 0; i < hand.length; i++) {
            counts[hand[i] % 13]++;
        }

        uint pairs = 0;
        uint threeOfAKind = 0;
        uint fourOfAKind = 0;
        uint highestCard = 0;

        for (uint i = 0; i < counts.length; i++) {
            if (counts[i] == 2) pairs++;
            if (counts[i] == 3) threeOfAKind++;
            if (counts[i] == 4) fourOfAKind++;
            if (counts[i] > 0) highestCard = i;
        }

        if (fourOfAKind > 0) return (uint(HandRanking.FourOfAKind) * 10000 + highestCard, highestCard);
        if (threeOfAKind > 0 && pairs > 0) return (uint(HandRanking.FullHouse) * 10000 + highestCard, highestCard);
        if (threeOfAKind > 0) return (uint(HandRanking.ThreeOfAKind) * 10000 + highestCard, highestCard);
        if (pairs == 2) return (uint(HandRanking.TwoPairs) * 10000 + highestCard, highestCard);
        if (pairs == 1) return (uint(HandRanking.OnePair) * 10000 + highestCard, highestCard);
        return (uint(HandRanking.HighCard) * 10000 + highestCard, highestCard); // High card
    }
}
