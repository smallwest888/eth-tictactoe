// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.4.0
pragma solidity ^0.8.27;

contract Game {
    enum Cell {
        Empty,
        X, 
        O
    }
    enum State {
        Draw, X, O, WinX, WinO
    }
    struct Session {
        bool exists;
        address playerO;
        address playerX;
        uint256 prizePool;
        Cell[3][3] board;
        State turn;
    }
    mapping(uint256 => Session) public games;
    uint256 gameCount = 0;
    function createGame() external payable returns(uint256) {
        gameCount += 1;
        games[gameCount] = Session({
            exists: true,
            playerO: address(0),
            playerX: msg.sender,
            prizePool: msg.value,
            board: [[Cell.Empty, Cell.Empty, Cell.Empty], [Cell.Empty, Cell.Empty, Cell.Empty], [Cell.Empty, Cell.Empty, Cell.Empty]],
            turn: State.X
        });
        return gameCount;
    }
    function joinGame(uint256 gameId) external payable {
        Session storage game = games[gameId];
        require(game.exists);
        require(msg.value >= game.prizePool);
        game.prizePool += msg.value;
    }
}
