// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract TicTacToe {
    enum Cell { Empty, X, O }
    enum State { Waiting, Playing, Draw, WinX, WinO }

    struct Game {
        address playerX;
        address playerO;

        uint256 bet;        
        uint256 prizePool;  

        Cell[3][3] board;
        address turn;       
        State state;

        bool paid;          
    }

    uint256 public gameCount;
    mapping(uint256 => Game) private games;

    // Events for frontend
    event GameCreated(uint256 indexed gameId, address indexed playerX, uint256 bet);
    event GameJoined(uint256 indexed gameId, address indexed playerO, uint256 bet);
    event MoveMade(uint256 indexed gameId, address indexed player, uint8 x, uint8 y, Cell cell);
    // event GameEnded(uint256 indexed gameId, State result, address winner, uint256 payout);

    // Create Game
    function createGame() external payable returns (uint256 gameId) {
        // make sure they have tokens
        require(msg.value > 0, "bet=0");

        gameId = ++gameCount;
        Game storage g = games[gameId];

        g.playerX = msg.sender;
        g.bet = msg.value;
        g.prizePool = msg.value;
        g.turn = msg.sender;
        g.state = State.Waiting;

        emit GameCreated(gameId, msg.sender, msg.value);
    }

    function joinGame(uint256 gameId) external payable {
        Game storage g = games[gameId];
        require(g.playerX != address(0), "no game");
        require(g.state == State.Waiting, "not joinable");
        require(g.playerO == address(0), "full");
        require(msg.sender != g.playerX, "X cannot join");
        require(msg.value == g.bet, "bet must be matched");

        g.playerO = msg.sender;
        g.prizePool += msg.value;
        g.state = State.Playing;

        emit GameJoined(gameId, msg.sender, msg.value);
    }

    // Move
    function move(uint256 gameId, uint8 x, uint8 y) external {
        Game storage g = games[gameId];

        require(g.state == State.Playing, "the game is not active");
        require(msg.sender == g.turn, "it is not your turn");
        require(x < 3 && y < 3, "it is out of bounds");
        require(g.board[x][y] == Cell.Empty, "taken, please choose another cell");

        Cell placed;

        if (msg.sender == g.playerX) {
            placed = Cell.X;
        } else {
            require(msg.sender == g.playerO, "you are not the player");
            placed = Cell.O;
        }

        g.board[x][y] = placed;
        emit MoveMade(gameId, msg.sender, x, y, placed);

        // check if the game ends or not
        if (isWin(g.board, Cell.X)) {
            g.state = State.WinX;
            payoutWinner(g, g.playerX);
            return;
        }
        if (isWin(g.board, Cell.O)) {
            g.state = State.WinO;
            payoutWinner(g, g.playerO);
            return;
        }
        if (isDraw(g.board)) {
            g.state = State.Draw;
            refundDraw(g);
            return;
        }

        // switch turn
        g.turn = (g.turn == g.playerX) ? g.playerO : g.playerX;
    }

    // trigger payout or refund manuelly
    function claim(uint256 gameId) external {
        Game storage g = games[gameId];
        require(!g.paid, "already paid");
        require(g.state == State.Draw || g.state == State.WinX || g.state == State.WinO, "not finished");

        if (g.state == State.WinX) _payoutWinner(g, g.playerX);
        else if (g.state == State.WinO) _payoutWinner(g, g.playerO);
        else _refundDraw(g);
    }

    // frontend
    function getGame(uint256 gameId) external view returns (
            address playerX,
            address playerO,
            uint256 bet,
            uint256 prizePool,
            address turn,
            State state,
            bool paid
        )
    {
        Game storage g = games[gameId];
        return (g.playerX, g.playerO, g.bet, g.prizePool, g.turn, g.state, g.paid);
    }

    function getCell(uint256 gameId, uint8 x, uint8 y) external view returns (Cell) {
        require(x < 3 && y < 3, "out of bounds");
        return games[gameId].board[x][y];
    }

    function getBoard(uint256 gameId) external view returns (uint8[9] memory flat) {
        Game storage g = games[gameId];
        uint8 k = 0;
        for (uint8 i = 0; i < 3; i++) {
            for (uint8 j = 0; j < 3; j++) {
                flat[k++] = uint8(g.board[i][j]); 
            }
        }
    }

    // payout
    function payoutWinner(Game storage g, address winner) internal {
        if (g.paid) return;
        g.paid = true;

        uint256 amount = g.prizePool;
        g.prizePool = 0;

        (bool ok, ) = payable(winner).call{value: amount}("");
        require(ok, "payout failed");

        emit GameEnded(findGameIdUnsafe(g), g.state, winner, amount);
    }

    function refundDraw(Game storage g) internal {
        if (g.paid) return;
        g.paid = true;

        uint256 b = g.bet;
        g.prizePool = 0;

        (bool okX, ) = payable(g.playerX).call{value: b}("");
        require(okX, "refund X failed");
        (bool okO, ) = payable(g.playerO).call{value: b}("");
        require(okO, "refund O failed");

        emit GameEnded(findGameIdUnsafe(g), g.state, address(0), b * 2);
    }

    // Win / Draw Detect
    function isWin(Cell[3][3] memory b, Cell c) internal pure returns (bool) {
        for (uint8 i = 0; i < 3; i++) {
            if (b[i][0]==c && b[i][1]==c && b[i][2]==c) return true;
            if (b[0][i]==c && b[1][i]==c && b[2][i]==c) return true;
        }
        if (b[0][0]==c && b[1][1]==c && b[2][2]==c) return true;
        if (b[0][2]==c && b[1][1]==c && b[2][0]==c) return true;
        return false;
    }

    function isDraw(Cell[3][3] memory b) internal pure returns (bool) {
        for (uint8 i = 0; i < 3; i++) {
            for (uint8 j = 0; j < 3; j++) {
                if (b[i][j] == Cell.Empty) return false;
            }
        }
        return true;
    }
}
