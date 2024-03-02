// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity >=0.8.13 <0.9.0;

import "contracts/PokerHandEvaluator.sol";
import "fhevm/abstracts/EIP712WithModifier.sol";
import "fhevm/lib/TFHE.sol";
import "hardhat/console.sol";
// import {IERC20} from "../interfaces/IERC20.sol";
import {IDealer} from "../interfaces/IDealer.sol";

contract Poker is EIP712WithModifier {

    address public owner;
    IDealer public dealer;
    using PokerHandEvaluator for *;

    constructor(address _dealerAddress) EIP712WithModifier("Authorization token", "1") {
        owner = msg.sender;   
        dealer = IDealer(_dealerAddress);
    }


    // -----------------------------------STORAGE------------------------------------------
    enum TableState {
        Active,
        Inactive
    }

    enum RoundState {
        Preflop,
        Flop,
        Turn,
        River,
        Showdown
    }  

    enum PlayerAction {
        Check,
        Call,
        Bet,
        Raise,
        Fold
    }

    enum PlayerState { 
        Active,
        Folded,
        AllIn
    }

    struct HandResult {
        uint score;
        address player;
    }

    struct Table {
        TableState tableState;
        uint totalHandsTillNow; //total hands till now
        uint buyInAmount;
        uint maxPlayers;
        address[] players;
        uint bigBlindAmount;
        // IERC20 token; // token used to bet and play
    }

    struct Round {
        RoundState roundState;
        bool isActive;
        uint turn; // index of the players array, who has the current turn
        address [] playersInRound; // players still in the round (not folded)
        uint highestChip; // current highest chip to be called
        uint[] chipsPlayersHaveBet; // array of chips each player has put in, compared with highestChip to see if player has to call again
        uint pot; // total chips in the current round
        uint buttonIndex; // Index for the Button (Dealer) in the players array
        address lastToAct; // Index of last player to act
    }
    // struct PlayerCardsEncrypted {
    //     euint8 card1Encrypted;
    //     euint8 card2Encrypted;
    // }
    struct PlayerCardsEncrypted {
        uint card1Encrypted;
        uint card2Encrypted;
    }
    struct PlayerCardsPlainText {
        uint8 card1;
        uint8 card2;
    }

    uint public totalTables = 0;
    uint8 public mod = 52;

    // id => Table
    mapping(uint => Table) public tables;

    // each tableId maps to a deck
    // tableId => totalHandsTillNow => deck
    // mapping(uint => mapping(uint => euint8[])) public decks;
    mapping(uint => mapping(uint => uint[])) public decks;

    // array of community cards
    // tableId => totalHandsTillNow => int[8] community cards
    mapping(uint => mapping(uint => uint[])) public communityCards;
    // mapping(uint => mapping(uint => euint8[])) public communityCards;

    //keeps track of remaining chips of a player in a table.... player => tableId => remainingChips
    mapping(address => mapping(uint => uint)) public playerChipsRemaining;

    // player => tableId => handNum => PlayerCards;
    mapping(address => mapping(uint => mapping(uint => PlayerCardsEncrypted))) public playerCardsEncryptedDuringHand;

    // maps roundNum to Round
    // tableId => totalHandsTillNow => Round
    mapping(uint => mapping(uint => Round)) public rounds;

    // player states
    // talbeId => totalHandsTillNow => player address => PlayerState
    mapping(uint => mapping(uint => mapping(address => PlayerState))) public playerStates;
    // -----------------------------------STORAGE------------------------------------------



    event NewTableCreated(uint tableId, Table table);
    event NewBuyIn(uint tableId, address player, uint amount);
    event PlayerCardsDealt(PlayerCardsEncrypted[] PlayerCardsEncrypted, uint tableId);
    event RoundOver(uint tableId, uint round);
    event CommunityCardsDealt(uint tableId, uint roundId, uint[] cards);
    event TableShowdown(uint tableId);
    event DebugPlayerCards(uint256 indexed tableId, uint card1Encrypted, uint card2Encrypted);
    // event DebugPlayerCards(uint256 indexed tableId, euint8 card1Encrypted, euint8 card2Encrypted);
    event DebugDeck(uint cardEncrypted);
    event RoundStateAdvanced(uint tableId, RoundState roundState, uint pot);
    event ChipsIntoPot(uint tableId, uint chips);
    event PlayerCall(uint tableId, address player, uint callAmount);
    event PlayerRaise(uint tableId, address player, uint raiseAmount);
    event LastToActPlayed(uint tableId, address player, RoundState roundState);
    event RoundTurnIncremented(uint tableId, address player, uint turn);
    event PlayerAllIn(uint tableId, address player, uint allInAmount);
    event PotDistributed(uint indexed tableId, address indexed winner, uint amount);



    /// @dev Initialize the table, this should only be called once
    /// @param _buyInAmount The minimum amount of tokens required to enter the table
    /// @param _maxPlayers The maximum number of players allowed in this table
    /// @param _bigBlind The big blind amount for the table
    function initializeTable(uint _buyInAmount, uint _maxPlayers, uint _bigBlind) external {

        address [] memory empty;

        tables[totalTables] = Table({
            tableState: TableState.Inactive,
            totalHandsTillNow: 0,
            buyInAmount: _buyInAmount, 
            maxPlayers: _maxPlayers,
            players: empty, // initializing with empty dynamic array
            bigBlindAmount: _bigBlind
            // token: IERC20(_token)
        });

        emit NewTableCreated(totalTables, tables[totalTables]);

        totalTables += 1;
    }

    /// @dev a player can call to withdraw their chips from the table
    /// @param _tableId the unique id of the table
    /// @param _amount The amount of tokens to withdraw from the table. (must be >= player's balance)
    function withdrawChips(uint _tableId, uint _amount) external {
        require(playerChipsRemaining[msg.sender][_tableId] >= _amount, "Not enough balance");
        playerChipsRemaining[msg.sender][_tableId] -= _amount;

        payable(msg.sender).transfer(_amount); // Send Ether back to the player
    }


    /// @dev players have to call this to buy in and enter the table
    /// @param _tableId the unique id of the table
    /// TODO: add logic to allow existing player at table to re-buy in
    function buyIn(uint _tableId) public payable {
        Table storage table = tables[_tableId];
        require(msg.value >= table.buyInAmount, "Not enough buyInAmount");
        require(table.players.length < table.maxPlayers, "Table is full");

        // The buy-in amount in Ether is automatically added to the contract's balance
        playerChipsRemaining[msg.sender][_tableId] += msg.value;

        // Add player to the table
        table.players.push(msg.sender);

        emit NewBuyIn(_tableId, msg.sender, msg.value);
    }



    function dealCards(uint _tableId) public {
        Table storage table = tables[_tableId];
        require(table.tableState == TableState.Inactive, "Game already going on");
        uint numOfPlayers = table.players.length;
        require(numOfPlayers > 1, "ERROR : not enough players");
        table.tableState = TableState.Active;

        uint[] memory cards = dealer.setDeal(2 * numOfPlayers + 5); // assuming 2 cards per player and 5 community cards
        decks[_tableId][table.totalHandsTillNow] = cards;


        Round storage round = rounds[_tableId][table.totalHandsTillNow];

        round.isActive = true;
        round.roundState = RoundState.Preflop;
        // TODO: Add logic to handle players at the table, but sitting out this round
        round.playersInRound = table.players;
        round.highestChip = table.bigBlindAmount;
        round.chipsPlayersHaveBet = new uint256[](numOfPlayers);  // Initialize chips array with zeros for each player
        round.turn = (getBBIndex(_tableId, table.totalHandsTillNow) + 1) % numOfPlayers;
        round.lastToAct = round.playersInRound[getBBIndex(_tableId, table.totalHandsTillNow)];

        PlayerCardsEncrypted[] memory playerCardsEncryptedArray = new PlayerCardsEncrypted[](numOfPlayers);

        for (uint i = 0; i < numOfPlayers; i++) {
            require(i < round.chipsPlayersHaveBet.length, "round.chips out of bounds");
            playerStates[_tableId][table.totalHandsTillNow][round.playersInRound[i]] = PlayerState.Active;

            if (i == (getSBIndex(_tableId, table.totalHandsTillNow))) { // last player, small blind
                // Ensure that the operation doesn't lead to underflows
                require(playerChipsRemaining[round.playersInRound[i]][_tableId] >= table.bigBlindAmount / 2, "Underflow for small blind");
                
                round.chipsPlayersHaveBet[i] = table.bigBlindAmount / 2;
                playerChipsRemaining[round.playersInRound[i]][_tableId] -= table.bigBlindAmount / 2;
                
            } else if (i == (getBBIndex(_tableId, table.totalHandsTillNow))) { // second to last player, big blind
            
                // Ensure that the operation doesn't lead to underflows
                require(playerChipsRemaining[round.playersInRound[i]][_tableId] >= table.bigBlindAmount, "Underflow for big blind");
                
                round.chipsPlayersHaveBet[i] = table.bigBlindAmount;
                playerChipsRemaining[round.playersInRound[i]][_tableId] -= table.bigBlindAmount;
            }

            // Ensure decks[_tableId] has enough elements
            require(2 * i + 1 < decks[_tableId][table.totalHandsTillNow].length, "decks out of bounds");
            
            // Save the encrypted card for each player
            playerCardsEncryptedArray[i].card1Encrypted = decks[_tableId][table.totalHandsTillNow][2 * i];
            playerCardsEncryptedArray[i].card2Encrypted = decks[_tableId][table.totalHandsTillNow][2 * i + 1];

            emit DebugPlayerCards(_tableId, playerCardsEncryptedArray[i].card1Encrypted, playerCardsEncryptedArray[i].card2Encrypted);
            playerCardsEncryptedDuringHand[round.playersInRound[i]][_tableId][table.totalHandsTillNow] = playerCardsEncryptedArray[i];

        }

        emit PlayerCardsDealt(playerCardsEncryptedArray, _tableId); // emit encrypted player cards for all players at once
        // round.pot += table.bigBlindAmount + (table.bigBlindAmount / 2);

    }


    /// @param _raiseAmount only required in case of raise. Else put zero. This is the amount you are putting in addition to what you have already put in this round
    function playHand(uint _tableId, PlayerAction _action, uint _raiseAmount) external {
        Table storage table = tables[_tableId];
        Round storage round = rounds[_tableId][table.totalHandsTillNow];

        require(table.tableState == TableState.Active, "Table is inactive");
        require(round.isActive, "No active round");
        require(round.playersInRound[round.turn] == msg.sender, "Not your turn");

        if (_action == PlayerAction.Call) {
            // in case of calling
            // deduct chips from user
            // keep the player in the round

            uint callAmount = round.highestChip - round.chipsPlayersHaveBet[round.turn];
            require(callAmount > 0, "Call amount is not positive");

            if (playerChipsRemaining[msg.sender][_tableId] <= callAmount) {
                // Player goes all in
                callAmount = playerChipsRemaining[msg.sender][_tableId];
                playerStates[_tableId][table.totalHandsTillNow][msg.sender] = PlayerState.AllIn;
                emit PlayerAllIn(_tableId, msg.sender, callAmount);
            } else {
                require(playerChipsRemaining[msg.sender][_tableId] >= callAmount, "Not enough chips to call");
                require(round.chipsPlayersHaveBet[round.turn] <= round.highestChip, "Player has already bet more or equal to the highest bet");
                emit PlayerCall(_tableId, round.playersInRound[round.turn], callAmount);
            }
            playerChipsRemaining[msg.sender][_tableId] -= callAmount;
            round.chipsPlayersHaveBet[round.turn] += callAmount;

        } else if (_action == PlayerAction.Bet) {
            // in case of an initial bet
            // deduct chips from the player's account
            // add those chips to the pot
            // update the highestChip for the round
            uint _betAmount = _raiseAmount;

            require(round.playersInRound[round.turn] == msg.sender, "Not your turn");

            if (_betAmount == playerChipsRemaining[msg.sender][_tableId]) {
                // Player goes all-in
                _betAmount = playerChipsRemaining[msg.sender][_tableId];
                playerStates[_tableId][table.totalHandsTillNow][msg.sender] = PlayerState.AllIn;
                emit PlayerAllIn(_tableId, msg.sender, _betAmount);
            } else {
                require(_betAmount >= table.bigBlindAmount, "Bet amount too low");
                require(playerChipsRemaining[msg.sender][_tableId] >= _betAmount, "Insufficient balance for bet");
                // Handle normal bet logic
                emit PlayerRaise(_tableId, round.playersInRound[round.turn], _betAmount);
            }

            playerChipsRemaining[msg.sender][_tableId] -= _betAmount;
            round.chipsPlayersHaveBet[round.turn] = _betAmount;
            round.highestChip = _betAmount;

            // Set the initial next player to act after the bet
            uint lastToActIndex = (round.turn == 0) ? round.playersInRound.length - 1 : round.turn - 1;
            address lastToActPlayer = round.playersInRound[lastToActIndex];

            // Find next active player after the bet
            while (playerStates[_tableId][table.totalHandsTillNow][lastToActPlayer] == PlayerState.Folded || playerStates[_tableId][table.totalHandsTillNow][lastToActPlayer] == PlayerState.AllIn) {
                lastToActIndex = (lastToActIndex == 0) ? round.playersInRound.length - 1 : lastToActIndex - 1;
                lastToActPlayer = round.playersInRound[lastToActIndex];
            }

            round.lastToAct = lastToActPlayer;

        } else if (_action == PlayerAction.Raise) {
            // in case of raising
            // deduct chips from the player's account
            // add those chips to the pot
            // update the highestChip for the round
            uint totalRaiseAmount = _raiseAmount + round.chipsPlayersHaveBet[round.turn];

            if (_raiseAmount == playerChipsRemaining[msg.sender][_tableId]) {
                // Player goes all-in
                totalRaiseAmount = playerChipsRemaining[msg.sender][_tableId];
                playerStates[_tableId][table.totalHandsTillNow][msg.sender] = PlayerState.AllIn;
                emit PlayerAllIn(_tableId, msg.sender, totalRaiseAmount);
            } else {
                uint minRaise = 2 * round.highestChip;
                require(playerChipsRemaining[msg.sender][_tableId] >= _raiseAmount, "Insufficient balance for raise");
                require(totalRaiseAmount >= minRaise, "Raise amount too low");
                emit PlayerRaise(_tableId, round.playersInRound[round.turn], totalRaiseAmount);
            }

            playerChipsRemaining[msg.sender][_tableId] -= _raiseAmount;
            round.chipsPlayersHaveBet[round.turn] = totalRaiseAmount;

            round.highestChip = totalRaiseAmount;
            emit PlayerRaise(_tableId, round.playersInRound[round.turn], _raiseAmount);

            // Set the initial next player to act after the raiser/re-raiser
            uint lastToActIndex = (round.turn == 0) ? round.playersInRound.length - 1 : round.turn - 1;
            address lastToActPlayer = round.playersInRound[lastToActIndex];

            // Find next active player after the raiser/re-raiser
            while (playerStates[_tableId][table.totalHandsTillNow][lastToActPlayer] == PlayerState.Folded || playerStates[_tableId][table.totalHandsTillNow][lastToActPlayer] == PlayerState.AllIn) {
                lastToActIndex = (lastToActIndex == 0) ? round.playersInRound.length - 1 : lastToActIndex - 1;
                lastToActPlayer = round.playersInRound[lastToActIndex];
            }

            round.lastToAct = lastToActPlayer;

        } else if (_action == PlayerAction.Check) {
            // you can only check if all the other values in the round.chips array is zero
            // i.e nobody has put any money till now
            for (uint i = 0; i < round.playersInRound.length; i++) {
                if (round.chipsPlayersHaveBet[i] > 0) {
                    require(round.chipsPlayersHaveBet[i] == round.chipsPlayersHaveBet[round.turn], "Check not possible after players have bet");
                }
            }

        } else if (_action == PlayerAction.Fold) {
            // in case of folding
            /// set player's state to Folded
            require(playerStates[_tableId][table.totalHandsTillNow][msg.sender] != PlayerState.Folded, "Player has already folded");
            playerStates[_tableId][table.totalHandsTillNow][msg.sender] = PlayerState.Folded;

            // in the case everyone has folded
            address ifOnlyActivePlayerAddress = ifOnlyOnePlayer(_tableId);
            if(ifOnlyActivePlayerAddress != address(0)){
                // there is only one address playing.
                // todo: fix bug
                distributePot(_tableId, ifOnlyActivePlayerAddress);
                _reInitiateTable(table, _tableId);
                return;
            }
        }

        require(round.turn < round.playersInRound.length, "Invalid turn value before increment");

        if (msg.sender == round.lastToAct) {
            emit LastToActPlayed(_tableId, msg.sender, round.roundState);
            advanceRoundState(_tableId);
        } else {
            _advanceTurn(_tableId);
        }
    }

    /// @dev method called to update the community cards for the next round
    function dealCommunityCards(uint _tableId, uint8 _numCards) internal {
        Table storage table = tables[_tableId];
        Round storage round = rounds[_tableId][table.totalHandsTillNow];
        // euint8[] memory _cards = new euint8[](_numCards);
        uint[] memory _cards = new uint[](_numCards);

        for (uint i=0; i<_numCards; i++) {
            _cards[i] = decks[_tableId][table.totalHandsTillNow][i + 2 * round.playersInRound.length + communityCards[_tableId][table.totalHandsTillNow].length];
            communityCards[_tableId][table.totalHandsTillNow].push(_cards[i]);
        }
        emit CommunityCardsDealt(_tableId, table.totalHandsTillNow, _cards);
    }


    function _advanceTurn(uint _tableId) internal {
        Table storage table = tables[_tableId];
        Round storage round = rounds[_tableId][table.totalHandsTillNow];
        require(table.tableState == TableState.Active, "No active round");

        // Increment the turn index, skipping folded or all-in players
        do {
            round.turn = (round.turn + 1) % round.playersInRound.length;
            emit RoundTurnIncremented(_tableId, round.playersInRound[round.turn], round.turn);
        } while(playerStates[_tableId][table.totalHandsTillNow][round.playersInRound[round.turn]] == PlayerState.Folded || playerStates[_tableId][table.totalHandsTillNow][round.playersInRound[round.turn]] == PlayerState.AllIn);
    }

    function advanceRoundState(uint _tableId) internal {
        Table storage table = tables[_tableId];
        Round storage round = rounds[_tableId][table.totalHandsTillNow];
        require(round.isActive, "No active round");

        // Consolidate bets into the pot
        for (uint i = 0; i < round.playersInRound.length; i++) {
            emit ChipsIntoPot(_tableId, round.chipsPlayersHaveBet[i]);
            round.pot += round.chipsPlayersHaveBet[i];
            round.chipsPlayersHaveBet[i] = 0;
        }

        if(round.roundState == RoundState.Preflop) {
            round.roundState = RoundState.Flop;
            dealCommunityCards(_tableId, 3); // Deal 3 cards for the flop
        } 
        else if(round.roundState == RoundState.Flop) {
            round.roundState = RoundState.Turn;
            dealCommunityCards(_tableId, 1); // Deal 1 card for the turn
        } 
        else if(round.roundState == RoundState.Turn) {
            round.roundState = RoundState.River;
            dealCommunityCards(_tableId, 1); // Deal 1 card for the river
        }
        else if(round.roundState == RoundState.River) {
            round.roundState = RoundState.Showdown;
            // Trigger showdown logic
            showdown(_tableId);
            _reInitiateTable(table, _tableId);
            emit RoundStateAdvanced(_tableId, round.roundState, round.pot);
            return;
        } 
        // else if (round.roundState == RoundState.Showdown) {
        //     _reInitiateTable(table, _tableId);
        // }

        emit RoundStateAdvanced(_tableId, round.roundState, round.pot);

        // Ensure there's more than one active or all-in player
        address ifOnlyOnePlayerAddress = ifOnlyOnePlayer(_tableId);
        require(ifOnlyOnePlayerAddress == address(0), "Game should end as only one player remains");

        _setFirstAndLastPlayerToActAfterRoundStateAdvanced(_tableId);

        round.highestChip = 0;
    
        // You might also want to handle the transition from Showdown back to Preflop if another game begins.
    }

    // Function to initiate the showdown logic
    function showdown(uint _tableId) internal {
        Table storage table = tables[_tableId];
        uint totalHands = table.totalHandsTillNow;
        uint numPlayers = table.players.length;
        HandResult[] memory results = new HandResult[](numPlayers);

        for (uint i = 0; i < numPlayers; i++) {
            address playerAddress = table.players[i];
            if (playerStates[_tableId][totalHands][playerAddress] != PlayerState.Folded) {
                uint[] memory playerHand = new uint[](7); // 2 private + 5 community cards
                // Populate playerHand with the player's cards and community cards
                // This part of the code will depend on how you've stored cards
                uint handScore = PokerHandEvaluator.evaluateHand(playerHand);
                results[i] = HandResult(handScore, playerAddress);
            }
        }

        // Determine the winner based on the highest score
        HandResult memory winner = determineWinner(results);
        distributePot(_tableId, winner.player);
    }

    // Determine the winner from the results
    function determineWinner(HandResult[] memory results) private pure returns (HandResult memory) {
        HandResult memory winner = results[0];
        for (uint i = 1; i < results.length; i++) {
            if (results[i].score > winner.score) {
                winner = results[i];
            }
        }
        return winner;
    }

function distributePot(uint _tableId, address winner) private {
    Table storage table = tables[_tableId];
    uint potAmount = rounds[_tableId][table.totalHandsTillNow].pot;

    require(potAmount > 0, "No chips in the pot");
    require(winner != address(0), "Invalid winner address");

    // Assuming playerBalances is a mapping of player addresses to their chip counts
    playerChipsRemaining[winner][_tableId]+= potAmount;

    // emit an event for the pot distribution (optional but recommended for transparency)
    emit PotDistributed(_tableId, winner, potAmount);

    // Reset the pot for the next hand
    rounds[_tableId][table.totalHandsTillNow].pot = 0;
}



    function _reInitiateTable(Table storage _table, uint _tableId) internal {
        _table.tableState = TableState.Inactive;
        _table.totalHandsTillNow += 1;
        delete communityCards[_tableId][_table.totalHandsTillNow]; // delete the community cards of the previous round
        delete decks[_tableId][_table.totalHandsTillNow];

        // initiate the round
        Round storage round = rounds[_tableId][_table.totalHandsTillNow];
        round.isActive = false;
        // TODO: Add logic to handle players that leave the round
        round.playersInRound = _table.players;
        round.highestChip = _table.bigBlindAmount;
        for (uint i = 0; i < round.playersInRound.length; i++) {
            playerStates[_tableId][_table.totalHandsTillNow][round.playersInRound[i]] = PlayerState.Active;
        }
    } 



    // ----------------------------------- HELPER FUNCTIONS ------------------------------------------

    function getSBIndex(uint tableId, uint roundIndex) public view returns(uint) {
        uint playersCount = tables[tableId].players.length;
        return (rounds[tableId][roundIndex].buttonIndex + 1) % playersCount;
    }

    function getBBIndex(uint tableId, uint roundIndex) public view returns(uint) {
        uint playersCount = tables[tableId].players.length;
        return (rounds[tableId][roundIndex].buttonIndex + 2) % playersCount;
    }

    function moveButton(uint tableId, uint roundIndex) internal {
        uint playersCount = tables[tableId].players.length;
        rounds[tableId][roundIndex].buttonIndex = (rounds[tableId][roundIndex].buttonIndex + 1) % playersCount;
    }


    function _setFirstAndLastPlayerToActAfterRoundStateAdvanced(uint _tableId) internal {
        Table storage table = tables[_tableId];
        Round storage round = rounds[_tableId][table.totalHandsTillNow];

        uint firstToActIndex = getSBIndex(_tableId, table.totalHandsTillNow);
        address firstToActPlayer = round.playersInRound[firstToActIndex];

        // Adjust firstToActIndex if the small blind is folded or all in
        if (playerStates[_tableId][table.totalHandsTillNow][firstToActPlayer] == PlayerState.Folded || playerStates[_tableId][table.totalHandsTillNow][firstToActPlayer] == PlayerState.AllIn) {
            do {
                firstToActIndex = (firstToActIndex + 1) % round.playersInRound.length;
                firstToActPlayer = round.playersInRound[firstToActIndex];
            } while (playerStates[_tableId][table.totalHandsTillNow][firstToActPlayer] == PlayerState.Folded || playerStates[_tableId][table.totalHandsTillNow][firstToActPlayer] == PlayerState.AllIn);
        }

        // Determine lastToActIndex
        uint lastToActIndex = (firstToActIndex == 0) ? round.playersInRound.length - 1 : firstToActIndex - 1;
        address lastToActPlayer = round.playersInRound[lastToActIndex];

        // Adjust lastToActIndex if necessary
        while (playerStates[_tableId][table.totalHandsTillNow][lastToActPlayer] == PlayerState.Folded || playerStates[_tableId][table.totalHandsTillNow][lastToActPlayer] == PlayerState.AllIn) {
            lastToActIndex = (lastToActIndex == 0) ? round.playersInRound.length - 1 : lastToActIndex - 1;
            lastToActPlayer = round.playersInRound[lastToActIndex];
        }

        round.lastToAct = lastToActPlayer;
        round.turn = firstToActIndex; // start the next round with this player
    }


    function _remove(uint index, uint[] storage arr) internal {
        arr[index] = arr[arr.length - 1];
        arr.pop();
    }

    // return address if it's the only active player. else return 0.
    function ifOnlyOnePlayer(uint _tableId) internal view returns(address) {
        Table storage table = tables[_tableId];
        Round storage round = rounds[_tableId][tables[_tableId].totalHandsTillNow];

        address onlyPlayer = address(0);
        for (uint i = 0; i < round.playersInRound.length; i++) {
            if (playerStates[_tableId][table.totalHandsTillNow][round.playersInRound[i]] == PlayerState.Active || 
                playerStates[_tableId][table.totalHandsTillNow][round.playersInRound[i]] == PlayerState.AllIn) {
                
                if(onlyPlayer == address(0)){
                    // it's only player so far
                    onlyPlayer = round.playersInRound[i];
                } else{
                    // there is multiple players
                    return address(0);
                }
            }
        }
        return onlyPlayer;
    }
    function getTable(uint _tableId) public view returns (Table memory) {
        return tables[_tableId];
    }

    function getRound(uint _tableId, uint roundIndex) public view returns (Round memory) {
        return rounds[_tableId][roundIndex];
    }

    function getChipsBetArray(uint _tableId, uint roundIndex) public view returns (uint256[] memory) {
        return rounds[_tableId][roundIndex].chipsPlayersHaveBet;
    }

    // Helper function to get the current players of a table
    function getCurrentPlayers(uint _tableId) external view returns (address[] memory) {
        return tables[_tableId].players;
    }

    // Helper function to get the max number of players for a table
    function getMaxPlayers(uint _tableId) external view returns (uint) {
        return tables[_tableId].maxPlayers;
    }

    function getCurrentTableState(uint _tableId) public view returns (Table memory) {
        return tables[_tableId];
    }

    function getDeck(uint _tableId) public view returns (uint[] memory) {
        Table storage table = tables[_tableId];
        return decks[_tableId][table.totalHandsTillNow];
    }
    // function getDeck(uint _tableId) public view returns (euint8[] memory) {
    //     Table storage table = tables[_tableId];
    //     return decks[_tableId][table.totalHandsTillNow];
    // } 

    function getPlayerCardsEncrypted(address _player, uint _tableId, uint _handNum) public view returns (PlayerCardsEncrypted memory) {
        return playerCardsEncryptedDuringHand[_player][_tableId][_handNum];
    }

    function getPlayerState(uint tableId, uint totalHands, address playerAddress) public view returns (PlayerState) {
        return playerStates[tableId][totalHands][playerAddress];
    }

    function getPlayerChipsRemaining(uint _tableId, address _player) public view returns (uint) {
        return playerChipsRemaining[_player][_tableId];
    }




    // ----------------------------------- HELPER FUNCTIONS ------------------------------------------



    // ----------------------------- TODO: ACTIVE PLAYER LOGIC -------------------------------
    // function addPlayer(uint tableId, address newPlayer) external {
    //     // Add to general list of players
    //     tables[tableId].players.push(newPlayer);

    //     // Add to list of active players for the current hand
    //     tables[tableId].activePlayers.push(newPlayer);
    // }

    // function removePlayer(uint tableId, address player) external {
    //     // Remove from general list of players (you might need a helper to find the index)
    //     uint index = findPlayerIndex(tableId, player);
    //     tables[tableId].players[index] = tables[tableId].players[tables[tableId].players.length - 1];
    //     tables[tableId].players.pop();

    //     // Remove from active players list
    //     uint activeIndex = findActivePlayerIndex(tableId, player);
    //     tables[tableId].activePlayers[activeIndex] = tables[tableId].activePlayers[tables[tableId].activePlayers.length - 1];
    //     tables[tableId].activePlayers.pop();

    //     // Handle button adjustment if the Button left
    //     if (tables[tableId].buttonIndex == activeIndex) {
    //         tables[tableId].buttonIndex = activeIndex % tables[tableId].activePlayers.length; // Move button to next player
    //     }
    // }

    // function findPlayerIndex(uint tableId, address player) internal view returns(uint) {
    //     for (uint i = 0; i < tables[tableId].players.length; i++) {
    //         if (tables[tableId].players[i] == player) {
    //             return i;
    //         }
    //     }
    //     revert("Player not found");
    // }

    // function findActivePlayerIndex(uint tableId, address player) internal view returns(uint) {
    //     for (uint i = 0; i < tables[tableId].activePlayers.length; i++) {
    //         if (tables[tableId].activePlayers[i] == player) {
    //             return i;
    //         }
    //     }
    //     revert("Active player not found");
    // }
    // ----------------------------- TODO: ACTIVE PLAYER LOGIC -------------------------------



    // /// @dev Starts a new round on a table
    // /// @param _tableId the unique id of the table
    // function startRound(uint _tableId) public {
    //     Table storage table = tables[_tableId];
    //     // require(table.state == TableState.Inactive, "Game already going on");
    //     // uint numOfPlayers = table.players.length;
    //     // require(numOfPlayers > 1, "ERROR : not enough players");
    //     table.state = TableState.Active;

    //     dealCards(_tableId);
    // }


    // function getDeck() public view returns (euint8[] memory) {
    //     return deck;
    // }

    // function getDeckLength() public view returns (uint) {
    //     return deck.length;
    // }

    // function joinGame() public {
    //     players[msg.sender].push(deck[deck.length - 2]);
    //     players[msg.sender].push(deck[deck.length - 1]);
    // }

    // function checkFirstCard(bytes32 publicKey, bytes calldata signature) public view onlySignedPublicKey(publicKey, signature) returns (bytes memory) {
    //     return  TFHE.reencrypt(players[msg.sender][0], publicKey, 0);
    // }
    // function checkSecondCard(bytes32 publicKey, bytes calldata signature) public view onlySignedPublicKey(publicKey, signature) returns (bytes memory) {
    //     return TFHE.reencrypt(players[msg.sender][1], publicKey, 0);
    // }

    // function test() public {
    //     euint8 card = TFHE.randEuint8();
    //     if (countPlain == 0) {
    //         deck[count] = card;
    //         count = TFHE.add(count, TFHE.asEuint8(1));
    //         countPlain += 1;
    //     } 
    //     euint8 total;
    //     for (uint8 i = 0; i < countPlain; i++) {
    //         ebool duplicate = TFHE.eq(deck[i], card);
    //         total = TFHE.add(total, TFHE.cmux(duplicate, TFHE.asEuint8(1), TFHE.asEuint8(0)));
    //     }
    //     count = TFHE.add(count, TFHE.asEuint8(1)); // add one
    // }

}   