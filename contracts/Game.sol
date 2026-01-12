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
        None,
        Draw,
        WinX,
        WinO,
        Playing
    }
    struct Session {
        address playerO;
        address playerX;
        uint256 prizePool;
        Cell[3][3] board;
        address turn;
        State state;
    }
    struct Position {
        uint8 x;
        uint8 y;
    }
    mapping(uint256 => Session) public games;
    uint256 gameCount = 0;
    function move(uint256 gameId, Position calldata position) external {
        Session storage game = games[gameId];
        require(game.state == State.Playing);
        require(game.turn == msg.sender);
        require(game.board[position.x][position.y] == Cell.Empty);
        require(
            game.board[position.x][position.y] == Cell.Empty,
            "This field is already taken"
        );
        game.board[position.x][position.y] = game.turn == game.playerX
            ? Cell.X
            : Cell.O;
    }
    function createGame() external payable returns (uint256) {
        gameCount += 1;
        games[gameCount] = Session({
            playerO: address(0),
            playerX: msg.sender,
            prizePool: msg.value,
            board: [
                [Cell.Empty, Cell.Empty, Cell.Empty],
                [Cell.Empty, Cell.Empty, Cell.Empty],
                [Cell.Empty, Cell.Empty, Cell.Empty]
            ],
            turn: msg.sender,
            state: State.Playing
        });
        return gameCount;
    }
    function joinGame(uint256 gameId) external payable {
        Session storage game = games[gameId];
        require(game.state == State.Playing, "The game is not joinable");
        require(game.playerO == address(0), "The game is full");
        require(msg.value >= game.prizePool, "Insufficient bet");
        game.prizePool += msg.value;
    }
}
