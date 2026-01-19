// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract TicTacToe {
    enum Cell { Empty, X, O }
    enum State { Waiting, Playing, Draw, WinX, WinO }

    struct Game {
        address playerX;
        address playerO;

        uint256 bet;        // base bet required to join
        uint256 prizePool;  // current total payout

        // track how much each player actually contributed
        uint256 depositX;
        uint256 depositO;

        Cell[3][3] board;
        address turn;
        State state;

        // Raise/ challenge state
        bool raiseActive;      // is there an active raise to match?
        address raiser;        // who raised last
        uint256 targetDeposit; // raiser's total deposit after raising 
        uint256 raiseDeadline; // timestamp until opponent must match

        bool paid;
    }

    uint256 public gameCount;
    mapping(uint256 => Game) private games;

    // Events for frontend
    event GameCreated(uint256 indexed gameId, address indexed playerX, uint256 bet);
    event GameJoined(uint256 indexed gameId, address indexed playerO, uint256 bet);
    event MoveMade(uint256 indexed gameId, address indexed player, uint8 x, uint8 y, Cell cell);
    event GameEnded(uint256 indexed gameId, State result, address winner, uint256 payout);
    event Raised(uint256 indexed gameId, address indexed raiser, uint256 addedAmount, uint256 targetDeposit, uint256 deadline);
    event RaiseMatched(uint256 indexed gameId, address indexed matcher, uint256 paidAmount, uint256 newDepositX, uint256 newDepositO);
    event Loss(uint256 indexed gameId, address indexed loser, address indexed winner);


    // Create Game
    function createGame() external payable returns (uint256 gameId) {
        require(msg.value > 0, "bet=0");

        gameId = ++gameCount;
        Game storage g = games[gameId];

        g.playerX = msg.sender;
        g.bet = msg.value;

        g.prizePool = msg.value;
        g.depositX = msg.value;

        g.turn = msg.sender;
        g.state = State.Waiting;

        emit GameCreated(gameId, msg.sender, msg.value);
    }

    // join Game
    function joinGame(uint256 gameId) external payable {
        Game storage g = games[gameId];
        require(g.playerX != address(0), "no game");
        require(g.state == State.Waiting, "not joinable");
        require(g.playerO == address(0), "full");
        require(msg.sender != g.playerX, "X cannot join again");
        require(msg.value == g.bet, "bet must be matched");

        g.playerO = msg.sender;
        g.prizePool += msg.value;
        g.depositO += msg.value;

        g.state = State.Playing;

        emit GameJoined(gameId, msg.sender, msg.value);
    }

    //Initiate a raise: the opponent must match the total deposit before the deadline, otherwise they lose the game
    function raise(uint256 gameId) external payable{
        Game storage g = games[gameId];

        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(!g.raiseActive, "raise already active");
        require(msg.value > 0, "amount > 0");
        require(msg.sender == g.playerX || msg.sender == g.playerO, "not a player");
        require(msg.sender == g.turn, "not your turn");

        // Add funds to the prize pool and update deposit accounting 
        g.prizePool += msg.value;

        if (msg.sender == g.playerX) {
            g.depositX += msg.value;
            g.targetDeposit = g.depositX;
        } else {
            g.depositO += msg.value;
            g.targetDeposit = g.depositO;
        }

        g.raiseActive = true;
        g.raiser = msg.sender;
        g.raiseDeadline = block.timestamp + 60;

        emit Raised(gameId, msg.sender, msg.value, g.targetDeposit, g.raiseDeadline);
    }
    
    // match a raise: the opponent must exactly match the targetDeposit
    function matchRaise(uint256 gameId) external payable{
        Game storage g = games[gameId];

        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(g.raiseActive, "no active raise");
        require(block.timestamp <= g.raiseDeadline, "too late");
        require(msg.sender == g.playerX || msg.sender == g.playerO, "not a player");
        require(msg.sender != g.raiser, "raiser cannot match");

        // Compute the exact amount required to match the raiser's total deposit
        uint256 need;
        if(msg.sender == g.playerX){
            require(g.targetDeposit >= g.depositX, "internal error");
            need = g.targetDeposit - g.depositX;
            require(msg.value == need, "must match exactly");
            g.depositX += msg.value;
        } else {
            require(g.targetDeposit >= g.depositO, "internal error");
            need = g.targetDeposit - g.depositO;
            require(msg.value == need, "must match exactly");
            g.depositO += msg.value;
        }

        g.prizePool += msg.value;

        // clear raise state 
        g.raiseActive = false;
        g.raiser = address(0);
        g.targetDeposit = 0;
        g.raiseDeadline = 0;

        emit RaiseMatched(gameId, msg.sender, msg.value, g.depositX, g.depositO);

    }

    // If the opponent failes to match before the deaedline, they lose and the raiser wins the game
    function lose(uint256 gameId) external{
        Game storage g = games[gameId];

        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(g.raiseActive, "no active raise");
        require(block.timestamp > g.raiseDeadline, "not expired");

        address winner = g.raiser;
        require(winner != address(0), "no rasier");
        address loser = (winner == g.playerX) ? g.playerO : g.playerX;

        // End the game
        g.state = (winner == g.playerX) ? State.WinX : State.WinO;

        // clear raise state 
        g.raiseActive = false;
        g.raiser = address(0);
        g.targetDeposit = 0;
        g.raiseDeadline = 0;

        emit Loss(gameId, loser, winner);
        payoutWinner(gameId, g, winner);

    }

    

    // Move
    function move(uint256 gameId, uint8 x, uint8 y) external {
        Game storage g = games[gameId];

        require(g.state == State.Playing, "the game is not active");
        require(!g.paid, "already paid");
        require(msg.sender == g.turn, "it is not your turn");
        require(x < 3 && y < 3, "out of bounds");
        require(g.board[x][y] == Cell.Empty, "taken");
        require(!g.raiseActive, "raise pending; must wait for match or lose");

        Cell placed;

        if (msg.sender == g.playerX) {
            placed = Cell.X;
        } else {
            require(msg.sender == g.playerO, "you are not the player");
            placed = Cell.O;
        }

        g.board[x][y] = placed;
        emit MoveMade(gameId, msg.sender, x, y, placed);

        if (isWin(g.board, Cell.X)) {
            g.state = State.WinX;
            payoutWinner(gameId, g, g.playerX);
            return;
        }
        if (isWin(g.board, Cell.O)) {
            g.state = State.WinO;
            payoutWinner(gameId, g, g.playerO);
            return;
        }
        if (isDraw(g.board)) {
            g.state = State.Draw;
            refundDraw(gameId, g);
            return;
        }

        g.turn = (g.turn == g.playerX) ? g.playerO : g.playerX;
    }

    // trigger payout or refund manually
    function claim(uint256 gameId) external {
        Game storage g = games[gameId];

        require(!g.paid, "already paid");
        require(
            g.state == State.Draw || g.state == State.WinX || g.state == State.WinO,
            "not finished"
        );
        require(!g.raiseActive, "raise pending");

        if (g.state == State.WinX) payoutWinner(gameId, g, g.playerX);
        else if (g.state == State.WinO) payoutWinner(gameId, g, g.playerO);
        else refundDraw(gameId, g);
    }

    // frontend
    function getGame(uint256 gameId) external view returns (
        address playerX,
        address playerO,
        uint256 bet,
        uint256 prizePool,
        uint256 depositX,
        uint256 depositO,
        address turn,
        State state,
        bool raiseActive,
        address raiser,
        uint256 targetDeposit,
        uint256 raiseDeadline,
        bool paid
    ) {
        Game storage g = games[gameId];
        return (g.playerX, g.playerO, g.bet, g.prizePool, g.depositX, g.depositO, g.turn, g.state,g.raiseActive, g.raiser, g.targetDeposit, g.raiseDeadline, g.paid);
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
    function payoutWinner(uint256 gameId, Game storage g, address winner) internal {
        if (g.paid) return;
        g.paid = true;

        uint256 amount = g.prizePool;

        // effects first
        g.prizePool = 0;
        g.depositX = 0;
        g.depositO = 0;

        (bool ok, ) = payable(winner).call{value: amount}("");
        require(ok, "payout failed");

        emit GameEnded(gameId, g.state, winner, amount);
    }

    function refundDraw(uint256 gameId, Game storage g) internal {
        if (g.paid) return;
        g.paid = true;

        uint256 xAmt = g.depositX;
        uint256 oAmt = g.depositO;

        // effects first
        g.prizePool = 0;
        g.depositX = 0;
        g.depositO = 0;

        (bool okX, ) = payable(g.playerX).call{value: xAmt}("");
        require(okX, "refund X failed");
        (bool okO, ) = payable(g.playerO).call{value: oAmt}("");
        require(okO, "refund O failed");

        emit GameEnded(gameId, g.state, address(0), xAmt + oAmt);
    }

    // Win / Draw Detect
    function isWin(Cell[3][3] memory b, Cell c) internal pure returns (bool) {
        for (uint8 i = 0; i < 3; i++) {
            if (b[i][0] == c && b[i][1] == c && b[i][2] == c) return true;
            if (b[0][i] == c && b[1][i] == c && b[2][i] == c) return true;
        }
        if (b[0][0] == c && b[1][1] == c && b[2][2] == c) return true;
        if (b[0][2] == c && b[1][1] == c && b[2][0] == c) return true;
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

